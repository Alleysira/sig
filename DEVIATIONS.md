# SIG v2 — tracked source deviations

This fork (`Alleysira/sig`) carries tracked source deviations on top of upstream
`Syndica/sig` to let SIG v2 join a **local development cluster** (e.g. a Kurtosis
enclave testnet) as a **non-voting observer**. This mirrors the provenance
discipline of the `Alleysira/firedancer` fork (6 tracked deviation files).

The parent commit is a byte-identical clean upstream pin; each deviation below is
a minimal, semantically-bounded change. A build from this fork is **NOT** a clean
upstream build. See `solana-package/clients.lock.json` for the pin + deviation
list, and `AGENTS.md` (Evidence levels) for the honesty rules these deviations
respect.

## Why the deviations exist

SIG v2 cannot join an isolated local cluster out of the box because three startup
gates assume a **public** Solana cluster:

1. **Gossip entrypoint discovery** — `main.zig` calls
   `gossip.ClusterInfo.getFromEcho(port, cluster)`, which iterates
   `cluster.getEntrypoints()`. `Cluster` has only `testnet`/`mainnet`/`devnet`, all
   returning **public** Solana entrypoints. In an isolated enclave no public
   entrypoint responds, so `getFromEcho` returns `error.NoValidEntrypoint` and SIG
   dies before any service starts.

2. **Shred version** — `getFromEcho` also discovers the shred version via the echo
   handshake; a local cluster's shred version comes from `solana-genesis`, not from
   a public peer.

3. **Mandatory snapshot download** — `services/snapshot.zig` calls
   `Downloader.run()` when no existing snapshot is on disk. On a slot-0 local
   cluster no peer ever advertises a snapshot, so the download fatally fails with
   `error.SnapshotDownloadFailed`, killing the whole process (the topology's
   `wait` kills all services on the first exit). SIG has no snapshot of its own.

These deviations add a `development` cluster path that supplies the entrypoints,
shred version, and a snapshot-gate toggle **from config**, so SIG can join a local
cluster. **SIG still does not vote** — it has no vote/stake accounts and the Config
has no vote field. The honest evidence level is `started`/`joined` (observer),
never `voting`.

### Two operating modes for the snapshot gate

The `skip_on_cold_start` config field selects between two observer modes:

- **Functional observer** (`skip_on_cold_start = false`, the default and the
  primary mode): SIG runs the **normal** snapshot path — `Downloader.run()`
  fetches a **real** full snapshot over HTTP from a bootstrap validator that
  produces + advertises snapshots (Agave serves `/snapshot-{slot}-{hash}.tar.zst`
  at its RPC port when snapshots are enabled, and advertises
  `CrdsValue::SnapshotHashes` in gossip; SIG's gossip service picks those up into
  `SnapshotSource{rpc_addr = bootstrap RPC}` and `known_validators = .{"*"}`
  trusts the bootstrap). SIG then decompresses the `.tar.zst` (whose `version`
  tar entry is exactly `"1.2.0"`, matching Agave's `VERSION_STRING_V1_2_0`) and
  builds real account state. Because SIG has no repair, a **real shred stream**
  (the upstream `shred-stream` tool, `tools/shred_stream.zig`, built by the
  default `zig build` step per `build.zig:35`) must then feed SIG the slots after
  the snapshot slot. This is the official "Running a functional Sig validator"
  path (README §steps 1-4): real leader schedule + real snapshot + real shred
  stream. SIG observes and processes real data but still does not vote.

- **Cold-start bypass** (`skip_on_cold_start = true`, the fallback): if no
  bootstrap snapshot is available (e.g. a slot-0 cluster with no snapshot-
  producing peer), the bypass sends an **empty** snapshot to `accounts_db` and
  idle-spins, so SIG stays alive as a gossip/shred observer with an empty account
  set. This is a research-grade relaxation used only when a real snapshot cannot
  be arranged.

## Deviation files

### 1. `v2/lib/solana/cluster.zig` — add `.development` cluster value

Added `development = 3` to the `Cluster` enum. Its `getEntrypoints()` returns an
empty list (matching the existing doc comment "For development this returns an
empty list, because the caller must provide entrypoints manually"); its
`getRpcUrl()` returns `""`.

### 2. `v2/main.zig` — manual `ClusterInfo` + config plumbing

- `Config.Gossip`: added `advertise_ip: []const u8 = ""` (the observer's reachable
  IP, resolved by the launcher via `hostname -I`) and
  `development_entrypoints: []const []const u8 = &.{}` (list of `"host:port"`
  gossip entrypoints to seed). Both default empty, so public-cluster configs are
  unaffected.
- `Config.ShredNetwork`: added `shred_version: u16 = 0`.
- `Config.Snapshot`: added `skip_on_cold_start: bool = false`.
- At the startup gate (was `getFromEcho(port, cluster)`), when
  `config.cluster == .development`, construct `gossip.ClusterInfo` manually via the
  new `clusterInfoFromConfig(config)` helper (resolves entrypoints with
  `std.net.getAddressList`, dedups, sets `public_ip` from `advertise_ip`, sets
  `shred_version` from config). Otherwise the original `getFromEcho` path is
  unchanged.
- `populateSnapshotConfig` now also sets `data.skip_on_cold_start`.

### 3. `v2/components/snapshot/api.zig` — `skip_on_cold_start` field

Added `skip_on_cold_start: bool` as a trailing field of the `SnapshotConfig`
`extern struct` (safe — C ABI trailing bool). Populated by
`populateSnapshotConfig` in `main.zig`.

### 4. `v2/services/snapshot.zig` — snapshot-gate toggle (cold-start bypass)

When `ro.config.skip_on_cold_start` is true:
- If an existing snapshot is on disk, send it to `accounts_db` normally (reuses the
  extracted `sendSnapshotToAccountsDb` helper).
- If no existing snapshot, open + immediately close the `ready_snapshot_out` writer
  ring (accounts_db's `getBufferBlocking` sees the reader close and returns an
  empty buffer, which `loadSnapshot` treats as EOF → empty account set), set the
  completion atomic to 100%, and fall through to the idle-spin loop.
- **Never returns an error** in the bypass path — `topology.wait` kills all
  services on the first exit, so the bypass falls through to the same
  `while (true) try runner.activity.signalIdleSpinning();` idle-spin as the normal
  path.

When `ro.config.skip_on_cold_start` is false (the default, functional mode), the
original snapshot-download path runs unchanged — `Downloader.run()` fetches a real
snapshot over HTTP, decompresses it, and `sendSnapshotToAccountsDb` feeds real
account state to `accounts_db`. This is the path used by the official "functional
validator" run.

The original snapshot-download path is otherwise unchanged (extracted the
snapshot-sending block into `sendSnapshotToAccountsDb` for reuse).

## What this does NOT change

- SIG does not gain a vote account, stake account, or any voting capability. It
  remains a non-voting observer.
- In functional mode SIG holds a **real** account set (from the bootstrap
  snapshot); in cold-start bypass mode it holds an **empty** account set. Either
  way it observes the gossip/shred stream but does not vote.
- Public-cluster behavior (`testnet`/`mainnet`/`devnet`) is byte-identical: the new
  config fields all default to empty/zero/false, and the `development` branch is
  only taken when `config.cluster == .development`.

## Build

This fork is built into the image `solana-diff/sig:v0.2.0-arm64-functional` (native
arm64 builder; the default `zig build` step also produces the `shred-stream` tool
used by the functional path). See `solana-package/Dockerfile.sig` and
`solana-package/build-sig.sh`.
