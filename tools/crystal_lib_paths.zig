//! `crystal env CRYSTAL_LIBRARY_PATH` is a COLON-SEPARATED search-path
//! list, exactly like CRYSTAL_PATH (a user override commonly reads
//! `/custom/libs:/opt/crystal/lib`; single-dir installs — brew, the
//! official tarball — happen to print one entry, which is how a naive
//! whole-value `addLibraryPath` survives the common case while turning
//! every multi-entry environment into one literal bogus path and losing
//! gc/pcre2 at link). This iterator is the one splitting point: build.zig
//! walks it for the crystal suite's library paths, and the assembler's
//! `{crystal_env:CRYSTAL_LIBRARY_PATH}` splice row must apply the same
//! split (plugin.labelle documents it) — one path per entry, empties
//! skipped, whitespace (the trailing newline of `crystal env` output)
//! trimmed.
//!
//! Lives in tools/ as a named test import (`crystal_lib_paths`): build.zig
//! path-imports it directly, while tests/ is its own module root, so the
//! suite reaches it the way it reaches `declare_core` — cross-root path
//! imports don't resolve (the eval shared suite carries its pin).

const std = @import("std");

pub const PathIterator = struct {
    inner: std.mem.TokenIterator(u8, .scalar),

    /// The next non-empty, whitespace-trimmed entry, or null.
    pub fn next(self: *PathIterator) ?[]const u8 {
        while (self.inner.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len > 0) return entry;
        }
        return null;
    }
};

/// Iterate the entries of a colon-separated crystal path value.
pub fn iterate(value: []const u8) PathIterator {
    return .{ .inner = std.mem.tokenizeScalar(u8, value, ':') };
}
