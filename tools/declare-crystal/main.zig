//! labelle-declare-crystal — the CRYSTAL declare-mode schema extractor (the
//! rust tool's native-family sibling; RFC-LANGUAGE-PLUGINS §4,
//! labelle-engine#775/#774/#619, consumed by the assembler's generic
//! `.languages` declare invocation path).
//!
//! Usage: labelle-declare-crystal --cache-dir <dir> <decl0.cr> [more.cr ...]
//!
//! Crystal has no interpreter, so — like the rust tool (tools/declare-rs) and
//! unlike the lua/ruby tools, which RUN a script chunk against a stub VM — this
//! is a COMPILE-AND-RUN PROBE: it stages a tiny crystal program under `<dir>`
//! carrying the SHIPPED `Labelle.component`/`event` macros around the game's
//! declaration files, `crystal build -Ddeclare`s it, and runs it; the probe
//! prints the accumulated schema JSON:
//!
//!   {"components":[{"name":"Kinematics","persist":"persistent",
//!     "fields":[{"name":"accel","type":"f32","default":1.0}, …]}, …]}
//!
//! The JSON is BYTE-compatible with the lua/ruby/rust runners' — one schema
//! contract, N runners (the assembler's parseSchema never learns which language
//! produced it). Exit 0 with the schema on stdout (one line; `{"components":[]}`
//! when nothing is declared). Exit 1 with a message on stderr for a crystal
//! build or probe-run failure (the compiler's diagnostics carry the location).
//! Exit 2 for usage errors (missing `--cache-dir`, no declaration files).
//!
//! The `--cache-dir` is the rev-17 invocation contract: the assembler passes a
//! PERSISTENT per-project dir the tool uses as the crystal compile cache
//! (`CRYSTAL_CACHE_DIR`) + staging root, so an incremental re-extract is warm.
//! Crystal's whole-program compile is slow, so the warm cache is load-bearing.
//! The dir is OPAQUE to the assembler — it never learns "crystal".
//!
//! Built host-targeted by the `labelle-declare-crystal` build step regardless
//! of `-Dlanguage` (build.zig): the assembler runs it at GENERATE time on the
//! developer machine, whatever platform the game itself targets.

const std = @import("std");
const extract = @import("extract.zig");

/// Per-file source cap. Declaration files are hand-written schema — megabytes
/// means something is wrong, and a bound keeps a stray path from OOMing the
/// generate step. (The rust tool's MAX_DECL_BYTES twin.)
const MAX_DECL_BYTES = 4 * 1024 * 1024;

const usage =
    \\labelle-declare-crystal — extract crystal-declared components/events as schema JSON
    \\
    \\Usage: labelle-declare-crystal --cache-dir <dir> <decl0.cr> [more.cr ...]
    \\
    \\Stages a probe program under <dir> carrying the shipped component/event
    \\macros around the given declaration files, `crystal build`s + runs it, and
    \\prints the schema on stdout.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    var cache_dir: ?[]const u8 = null;

    var inputs: std.ArrayList(extract.Input) = .empty;
    defer {
        for (inputs.items) |input| {
            allocator.free(input.path);
            allocator.free(input.source);
        }
        inputs.deinit(allocator);
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stderr().writeStreamingAll(io, usage);
            return;
        }
        if (std.mem.eql(u8, arg, "--cache-dir")) {
            const dir = args.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(io, "labelle-declare-crystal: --cache-dir needs an argument\n");
                std.process.exit(2);
            };
            cache_dir = try allocator.dupe(u8, dir);
            continue;
        }
        const path = try allocator.dupe(u8, arg);
        errdefer allocator.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_DECL_BYTES)) catch |err| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "labelle-declare-crystal: cannot read {s}: {s}\n",
                .{ path, @errorName(err) },
            ) catch "labelle-declare-crystal: cannot read a declaration file\n";
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            std.process.exit(1);
        };
        try inputs.append(allocator, .{ .path = path, .source = source });
    }
    defer if (cache_dir) |d| allocator.free(d);

    if (cache_dir == null) {
        try std.Io.File.stderr().writeStreamingAll(io, "labelle-declare-crystal: --cache-dir is required\n");
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }
    if (inputs.items.len == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }

    const outcome = try extract.run(allocator, io, init.environ_map, cache_dir.?, inputs.items);
    defer outcome.deinit(allocator);
    switch (outcome) {
        .schema => |json| {
            try std.Io.File.stdout().writeStreamingAll(io, json);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
        },
        .failure => |msg| {
            try std.Io.File.stderr().writeStreamingAll(io, msg);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}
