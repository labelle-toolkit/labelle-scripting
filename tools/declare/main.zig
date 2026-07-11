//! labelle-declare — the declare-mode schema extractor (RFC-LANGUAGE-PLUGINS
//! revs 6-7, labelle-engine#237; consumed by labelle-assembler#585).
//!
//! Usage: labelle-declare <script.lua> [more.lua ...]
//!
//! Loads each script chunk in a stub VM (see tools/declare/extract.zig) so
//! its chunk-scope `labelle.component(...)` declarations record — nothing
//! else runs — and prints the accumulated schema JSON on stdout:
//!
//!   {"components":[{"name":"Hunger","persist":"persistent",
//!     "fields":[{"name":"level","type":"f32","default":1.0}, …]}, …]}
//!
//! Exit 0 with the schema on stdout (one line; `{"components":[]}` when no
//! script declares anything). Exit 1 with a file-and-name-bearing message
//! on stderr for any malformed declaration or erroring chunk body. Exit 2
//! for usage errors.
//!
//! Built host-targeted by the `labelle-declare` build step regardless of
//! `-Dlanguage` (build.zig): the assembler runs it at GENERATE time on the
//! developer machine, whatever platform the game itself targets.

const std = @import("std");
const extract = @import("extract.zig");

/// Per-script source cap. Game scripts are hand-written logic — megabytes
/// means something is wrong, and a bound keeps a stray path from OOMing
/// the generate step.
const MAX_SCRIPT_BYTES = 4 * 1024 * 1024;

const usage =
    \\labelle-declare — extract script-declared components as schema JSON
    \\
    \\Usage: labelle-declare <script.lua> [more.lua ...]
    \\
    \\Runs each chunk body against the declare stub (only `labelle` is in
    \\scope; init/update never run) and prints the schema on stdout.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // program name

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
        const path = try allocator.dupe(u8, arg);
        errdefer allocator.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_SCRIPT_BYTES)) catch |err| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "labelle-declare: cannot read {s}: {s}\n",
                .{ path, @errorName(err) },
            ) catch "labelle-declare: cannot read a script file\n";
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            std.process.exit(1);
        };
        try inputs.append(allocator, .{ .path = path, .source = source });
    }

    if (inputs.items.len == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }

    const outcome = try extract.run(allocator, inputs.items);
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
