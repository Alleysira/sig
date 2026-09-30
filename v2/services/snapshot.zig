const std = @import("std");
const start = @import("start_service");
const lib = @import("lib");
const services = @import("services");
const snapshot = @import("snapshot");

const download = snapshot.download;

const Metrics = download.Metrics;
const DownloadResult = download.DownloadResult;
const Downloader = download.Downloader;

comptime {
    _ = start;
}

pub const name = .snapshot;
pub const panic = start.panic;
pub const std_options = start.options;

pub const ReadOnly = services.snapshot.ReadOnly;
pub const ReadWrite = services.snapshot.ReadWrite;

pub fn serviceMain(runner: lib.runner.Connection, ro: ReadOnly, rw: ReadWrite) !noreturn {
    const logger = rw.tel.acquireLogger(@tagName(name), "main");
    const metrics = rw.tel.metricAppender().appendFields(Metrics, Metrics.fields_config);
    rw.tel.signalReady();

    const snapshot_dir_path = ro.config.folder_buffer[0..ro.config.folder_len];
    const known_validators = ro.config.knownValidators();

    var snapshot_dir = try std.fs.cwd().makeOpenPath(snapshot_dir_path, .{ .iterate = true });
    defer snapshot_dir.close();

    // ── Tracked deviation: cold-start bypass for development ──────────────────
    // On a slot-0 local cluster, no peer ever advertises a snapshot, so the
    // gossip download waits forever then fatally fails (SnapshotDownloadFailed).
    // When `skip_on_cold_start` is set AND there is no existing snapshot on
    // disk, skip the download entirely and send an empty snapshot to
    // accounts_db (open + close the writer ring → getBufferBlocking returns an
    // empty buffer → loadSnapshot sees EOF → empty account set). This keeps SIG
    // alive as a non-voting observer; it will NOT hold the full account set.
    // See DEVIATIONS.md. Falls through to the idle-spin loop (never returns an
    // error — topology kills all services on first exit).
    if (ro.config.skip_on_cold_start) {
        if (try download.findExistingSnapshot(snapshot_dir)) |existing| {
            logger.info().logf("cold-start bypass: existing snapshot found, sending it name={f}", .{existing});
            sendSnapshotToAccountsDb(runner, rw, snapshot_dir, existing, logger) catch |err| {
                logger.err().logf("cold-start bypass: failed sending existing snapshot: {s}", .{@errorName(err)});
                return err;
            };
        } else {
            logger.info().log("cold-start bypass: no existing snapshot, sending empty snapshot to accounts_db");
            // Open + immediately close the writer ring: accounts_db's
            // getBufferBlocking sees the reader close and returns an empty
            // buffer, which loadSnapshot treats as EOF (empty account set).
            var out = rw.ready_snapshot_out.ring.getView(.writer);
            out.close();
            // Advance completion to 100% so accounts_db does not block on the
            // completion atomic waiting for download progress that will never
            // come.
            rw.ready_snapshot_out.completion.store(100.0, .monotonic);
        }
        logger.info().log("snapshot service finished (cold-start bypass)");
        while (true) try runner.activity.signalIdleSpinning();
    }

    const result: DownloadResult = result: {
        logger.info().logf("snapshot path {s}", .{snapshot_dir_path});

        if (try download.findExistingSnapshot(snapshot_dir)) |existing| {
            break :result .{ .already_exists = existing };
        }

        var downloader = try Downloader.init(
            rw.source_from_gossip,
            known_validators,
            snapshot_dir,
            metrics,
            .from(logger),
        );
        defer downloader.deinit();

        break :result try downloader.run();
    };

    const ready_snapshot = switch (result) {
        .already_exists => |existing| blk: {
            logger.info().logf("snapshot already exists, skipping download name={f}", .{
                existing,
            });
            break :blk existing;
        },
        .downloaded => |snap| blk: {
            logger.info().logf("snapshot download completed slot={d} hash={f} path={s}/{f}", .{
                snap.slot,
                snap.hash,
                snapshot_dir_path,
                snap,
            });
            break :blk snap;
        },
        .failed => |reason| {
            logger.err().logf("snapshot download failed reason={s}", .{
                @tagName(reason),
            });
            return error.SnapshotDownloadFailed;
        },
    };

    sendSnapshotToAccountsDb(runner, rw, snapshot_dir, ready_snapshot, logger) catch |err| {
        logger.err().logf("failed sending snapshot to accounts_db: {s}", .{@errorName(err)});
        return err;
    };

    logger.info().log("snapshot service finished");
    while (true) try runner.activity.signalIdleSpinning();
}

/// Send the decompressed snapshot data to the accounts_db service via the
/// `ready_snapshot_out` ring. Extracted so the cold-start bypass path can reuse
/// it for an existing snapshot.
fn sendSnapshotToAccountsDb(
    runner: lib.runner.Connection,
    rw: ReadWrite,
    snapshot_dir: std.fs.Dir,
    ready_snapshot: snapshot.api.ReadySnapshot,
    logger: anytype,
) !void {
    const Global = struct {
        var zst_reader: lib.solana.snapshot.ZstReader = undefined;
    };

    var snapshot_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot_path = try ready_snapshot.name(&snapshot_path_buf);

    const zst_reader = &Global.zst_reader;
    try zst_reader.init(snapshot_dir, snapshot_path);
    defer zst_reader.deinit();

    var out = rw.ready_snapshot_out.ring.getView(.writer);
    defer out.close();

    while (true) {
        const buf: []u8 = try out.getBufferBlocking(runner);
        if (buf.len == 0) break; // reader closed their side

        // cap decompress size to ensure advance() is called frequently enough to unblock rooted
        const decompressed = buf[0..@min(buf.len, 128 * 1024)];
        const n = try zst_reader.read(.from(logger), decompressed);

        // Update the completion value
        const total: f64 = @floatFromInt(zst_reader.file_size);
        const consumed: f64 = @floatFromInt(zst_reader.file_reader.getOffset());
        var completion = @min(100.0, (consumed * 100) / total);
        if (zst_reader.file_size == 0) completion = 100.0; // guard against 0-len snapshots
        rw.ready_snapshot_out.completion.store(completion, .monotonic);

        if (n == 0) break; // file reader EOF
        out.advance(n);
    }
}
