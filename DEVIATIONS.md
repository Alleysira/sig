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
shred version, and a cold-start snapshot bypass **from config**, so SIG stays alive
as a gossip/shred observer. **SIG still does not vote** — it has no vote/stake
accounts and the Config has no vote field. The honest evidence level is
`started`/`joined` (observer), never `voting`.

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

### 4. `v2/services/snapshot.zig` — cold-start snapshot bypass

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

The original snapshot-download path is otherwise unchanged (extracted the
snapshot-sending block into `sendSnapshotToAccountsDb` for reuse).

## What this does NOT change

- SIG does not gain a vote account, stake account, or any voting capability. It
  remains a non-voting observer.
- The cold-start bypass means SIG holds an **empty** account set — it observes the
  gossip/shred stream but cannot execute transactions against the full state. This
  is a research-grade, observer-only relaxation.
- Public-cluster behavior (`testnet`/`mainnet`/`devnet`) is byte-identical: the new
  config fields all default to empty/zero/false, and the `development` branch is
  only taken when `config.cluster == .development`.

## Build

This fork is built into the image `solana-diff/sig:v0.2.0-arm64-dev` (native arm64
builder). See `solana-package/Dockerfile.sig` and `solana-package/build-sig.sh`.
