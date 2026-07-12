//! labelle-declare-csharp — the C# declare-mode schema extractor (the rust /
//! crystal tools' CoreCLR-family sibling; RFC-LANGUAGE-PLUGINS §4/§7,
//! labelle-scripting#27, labelle-engine#743/#774/#619, consumed by the
//! assembler's generic `.languages` declare invocation path).
//!
//! Usage: labelle-declare-csharp --cache-dir <dir> <decl0.cs> [more.cs ...]
//!
//! C# is a compiled language, so — like the rust tool (tools/declare-rs) and
//! crystal tool (tools/declare-crystal), and unlike the lua/ruby/ts tools which
//! RUN a source string against an embedded VM — this is a COMPILE-AND-RUN
//! PROBE: it stages a tiny C# program under `<dir>` carrying the SHIPPED
//! `Labelle` declare surface (native-csharp/src/Declare.cs) around the game's
//! declaration files, `dotnet build`s it, and runs it; the probe prints the
//! accumulated schema JSON:
//!
//!   {"components":[{"name":"Kinematics","persist":"persistent",
//!     "fields":[{"name":"accel","type":"f32","default":1.0}, …]}, …]}
//!
//! The JSON is BYTE-compatible with the lua/ruby/rust/crystal/ts runners' — one
//! schema contract, N runners (the assembler's parseSchema never learns which
//! language produced it). Exit 0 with the schema on stdout (one line;
//! `{"components":[]}` when nothing is declared). Exit 1 with a message on
//! stderr for a dotnet build or probe-run failure (the compiler's diagnostics
//! carry the location). Exit 2 for usage errors (missing `--cache-dir`, no
//! declaration files).
//!
//! The `--cache-dir` is the rev-17 invocation contract: the assembler passes a
//! PERSISTENT per-project dir the tool uses as the probe's staging + build
//! output root, so an incremental re-extract reuses dotnet's `obj/` and is
//! warm. The dir is OPAQUE to the assembler — it never learns "csharp" or
//! "dotnet".
//!
//! Built host-targeted by the `labelle-declare-csharp` build step regardless of
//! `-Dlanguage` (build.zig): the assembler runs it at GENERATE time on the
//! developer machine, whatever platform the game itself targets. Needs the .NET
//! SDK on PATH (the CoreCLR host family is desktop-first, .NET >= 7).

const std = @import("std");
const extract = @import("extract.zig");

/// Per-file source cap. Declaration files are hand-written schema — megabytes
/// means something is wrong, and a bound keeps a stray path from OOMing the
/// generate step. (The rust/crystal tools' MAX_DECL_BYTES twin.)
const MAX_DECL_BYTES = 4 * 1024 * 1024;

const usage =
    \\labelle-declare-csharp — extract C#-declared components/events as schema JSON
    \\
    \\Usage: labelle-declare-csharp --cache-dir <dir> <decl0.cs> [more.cs ...]
    \\
    \\Stages a probe program under <dir> carrying the shipped Labelle declare
    \\surface around the given declaration files, `dotnet build`s + runs it, and
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
                try std.Io.File.stderr().writeStreamingAll(io, "labelle-declare-csharp: --cache-dir needs an argument\n");
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
                "labelle-declare-csharp: cannot read {s}: {s}\n",
                .{ path, @errorName(err) },
            ) catch "labelle-declare-csharp: cannot read a declaration file\n";
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            std.process.exit(1);
        };
        try inputs.append(allocator, .{ .path = path, .source = source });
    }
    defer if (cache_dir) |d| allocator.free(d);

    if (cache_dir == null) {
        try std.Io.File.stderr().writeStreamingAll(io, "labelle-declare-csharp: --cache-dir is required\n");
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
