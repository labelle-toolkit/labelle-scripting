//! Dev-mode script disk watcher (labelle-engine#740, hot reload).
//!
//! A deliberately simple MTIME+SIZE POLLER over one flat directory — not
//! std.fs.watch, not kqueue/inotify/ReadDirectoryChangesW backends. The
//! poll runs a few times per second in dev builds only (root.zig's
//! `hot_reload` glue drives it off the Controller tick and the whole
//! path is compiled out unless `-Dhot_reload=true`), a directory of game
//! scripts is a few dozen files, and one stat per file per quarter
//! second is unmeasurable — while platform watch backends are three
//! codepaths of them. The trade: a rewrite that changes neither the
//! mtime (sub-granularity on coarse filesystems) nor the size can be
//! missed; editors save with fresh mtimes, so in practice it isn't.
//!
//! DECOUPLED from the VM on purpose: this module knows nothing about
//! scripts, registries or languages beyond "files with this extension in
//! this directory". It reports (name, filename) changes; the caller
//! (root.zig's `hot_reload`) reads the file and feeds the reload seam.
//! That is what makes the layer testable against plain temp dirs.
//!
//! Naming: the reported `name` is the assembler's registered-stem rule
//! (labelle-assembler src/script_scanner.zig `stripPrefixAndExt` —
//! `10_spawner.rb` registers as "spawner"), mirrored here so a watched
//! file maps onto the name its `registerScript` call used. Windows-robust
//! by construction: entries are plain filenames from directory iteration
//! (no separator handling anywhere).

const std = @import("std");

/// Watched-file capacity — mirrors root.zig's MAX_REGISTERED_SCRIPTS
/// (a watched dir maps 1:1 onto registrations).
pub const max_watched_files = 128;

/// Longest tracked filename, matching the VM chunkname caps
/// (CHUNKNAME_CAP/FILENAME_CAP): longer names would truncate in error
/// locations anyway; here they are skipped (and dev-mode logged by the
/// glue's read failure, not silently half-tracked).
pub const filename_cap = 128;

/// One reported change: the script's registered-stem `name` and the
/// `file` (plain filename inside the watched dir) to read it back from.
/// Both borrow the watcher's entry storage — valid until the next
/// `poll` on the same watcher.
pub const Change = struct {
    name: []const u8,
    file: []const u8,
};

/// Monotonic count of aborted scan passes (iteration errors) — a test/
/// introspection seam in the house counter style; never reset.
pub var scan_error_count: usize = 0;

/// Test seam: make the next poll's scan fail before visiting any entry,
/// exercising the abort path (state kept, sweep skipped) without needing
/// a fault-injecting filesystem.
pub var debug_fail_scan: bool = false;

/// The mtime+size poller for one directory. Plain value struct; the
/// caller owns `dir` (opened with `.iterate = true`) and closes it after
/// the watcher's last poll.
pub const Watcher = struct {
    io: std.Io,
    /// Must be opened with iteration capability. Borrowed, never closed
    /// here.
    dir: std.Io.Dir,
    /// Extension filter including the dot (".lua"). Borrowed — callers
    /// pass string literals (root.zig derives it from the selected
    /// language at comptime).
    extension: []const u8,
    entries: [max_watched_files]FileEntry = undefined,
    count: usize = 0,
    /// The first poll records the baseline silently (whatever is on disk
    /// at watch start IS the built-in state); only later polls report.
    primed: bool = false,

    const FileEntry = struct {
        file_buf: [filename_cap]u8,
        file_len: usize,
        mtime_ns: i128,
        size: u64,

        fn file(self: *const FileEntry) []const u8 {
            return self.file_buf[0..self.file_len];
        }
    };

    pub fn init(io: std.Io, dir: std.Io.Dir, extension: []const u8) Watcher {
        return .{ .io = io, .dir = dir, .extension = extension };
    }

    /// Scan the directory once; report up to `out.len` changed (or newly
    /// appeared) matching files since the previous poll. The first poll
    /// primes the baseline and reports nothing. Deleted files are
    /// dropped from tracking silently — there is nothing sane to unload
    /// (the VM keeps the last-loaded code; a restored file re-reports).
    /// Filesystem errors degrade to "no changes seen" — dev-mode
    /// polling must never take the game down; an ITERATION error aborts
    /// the whole pass conservatively (state kept, sweep skipped — a
    /// transient dir-read failure must not read as "every file was
    /// deleted", which would re-adopt them next poll and spuriously
    /// re-run their reloads). Overflow is lossless: changes beyond
    /// `out.len` are deferred (baseline untouched) and reported by
    /// subsequent polls.
    pub fn poll(self: *Watcher, out: []Change) usize {
        var reported: usize = 0;
        var seen: [max_watched_files]bool = @splat(false);
        var scan_ok = true;

        var it = self.dir.iterate();
        while (true) {
            if (debug_fail_scan) {
                debug_fail_scan = false;
                scan_ok = false;
                break;
            }
            const dirent = (it.next(self.io) catch {
                scan_ok = false;
                break;
            }) orelse break;
            if (dirent.kind != .file) continue;
            if (!std.mem.endsWith(u8, dirent.name, self.extension)) continue;
            if (dirent.name.len > filename_cap) continue;
            const st = self.dir.statFile(self.io, dirent.name, .{}) catch continue;
            const mtime_ns: i128 = st.mtime.nanoseconds;

            if (self.find(dirent.name)) |idx| {
                seen[idx] = true;
                const e = &self.entries[idx];
                if (e.mtime_ns == mtime_ns and e.size == st.size) continue;
                // The baseline commits ONLY alongside a report (or during
                // the priming pass): a change that overflowed `out` keeps
                // its stale baseline and surfaces on the NEXT poll — a
                // bulk save/checkout drains losslessly over successive
                // polls instead of silently leaving scripts stale.
                if (self.primed and reported >= out.len) continue;
                e.mtime_ns = mtime_ns;
                e.size = st.size;
                if (self.primed) {
                    out[reported] = self.changeFor(e);
                    reported += 1;
                }
            } else {
                // Same overflow rule for adoption: a new file that can't
                // be reported this pass stays untracked and re-discovers
                // next poll.
                if (self.primed and reported >= out.len) continue;
                if (self.count >= max_watched_files) continue;
                const e = &self.entries[self.count];
                @memcpy(e.file_buf[0..dirent.name.len], dirent.name);
                e.file_len = dirent.name.len;
                e.mtime_ns = mtime_ns;
                e.size = st.size;
                seen[self.count] = true;
                self.count += 1;
                if (self.primed) {
                    out[reported] = self.changeFor(e);
                    reported += 1;
                }
            }
        }

        // A failed scan means `seen` is a LIE for every unvisited entry
        // — running the deletion sweep on it would drop live tracking
        // (and priming on it would freeze a half-baseline). Changes
        // already reported above were real; hand those back and leave
        // everything else exactly as it was.
        if (!scan_ok) {
            scan_error_count += 1;
            return reported;
        }

        // Drop entries whose file vanished (swap-remove; order is not
        // meaningful here). Backwards so the swapped-in tail entry —
        // already visited by the scan above — keeps its `seen` slot
        // aligned when it moves down.
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (seen[i]) continue;
            self.count -= 1;
            self.entries[i] = self.entries[self.count];
            seen[i] = seen[self.count];
        }

        self.primed = true;
        return reported;
    }

    /// Force `file` to re-report on the next poll: the caller was handed
    /// this change but failed to process it (the atomic-save race — the
    /// editor was still writing when the read happened). Resets the
    /// entry's baseline to an impossible stat, so the very next poll
    /// sees a difference and re-reports; the same lossless principle as
    /// the overflow deferral. Unknown files are a no-op.
    pub fn markDirty(self: *Watcher, file: []const u8) void {
        const idx = self.find(file) orelse return;
        self.entries[idx].mtime_ns = -1;
        self.entries[idx].size = std.math.maxInt(u64);
    }

    fn find(self: *Watcher, file: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*e, idx| {
            if (std.mem.eql(u8, e.file(), file)) return idx;
        }
        return null;
    }

    fn changeFor(self: *Watcher, e: *const Watcher.FileEntry) Change {
        return .{ .name = stemOf(e.file(), self.extension), .file = e.file() };
    }
};

/// The registered-stem rule, mirroring the assembler's
/// `script_scanner.stripPrefixAndExt` byte for byte: strip a numeric
/// ordering prefix (digits + one underscore — only when BOTH are
/// present) and the extension. `10_spawner.lua` → "spawner";
/// `spawner.lua` → "spawner"; `10spawner.lua` → "10spawner".
pub fn stemOf(filename: []const u8, extension: []const u8) []const u8 {
    var start: usize = 0;
    while (start < filename.len and std.ascii.isDigit(filename[start])) start += 1;
    if (start > 0 and start < filename.len and filename[start] == '_') {
        start += 1;
    } else {
        start = 0;
    }
    var end = filename.len;
    if (std.mem.endsWith(u8, filename, extension)) end -= extension.len;
    if (end < start) return filename[0..0];
    return filename[start..end];
}
