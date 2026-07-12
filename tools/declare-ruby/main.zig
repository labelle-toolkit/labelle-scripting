//! labelle-declare-ruby — the RUBY declare-mode schema extractor (the lua
//! runner's per-language sibling; RFC-LANGUAGE-PLUGINS revs 6-7,
//! labelle-engine#237, consumed by the assembler's per-language declare
//! runner table).
//!
//! Usage: labelle-declare-ruby <script.rb> [more.rb ...]
//!
//! Loads each script chunk in a fresh stub VM (see
//! tools/declare-ruby/extract.zig) so its chunk-scope
//! `Labelle.component(...)` declarations record — nothing else runs — and
//! prints the accumulated schema JSON on stdout:
//!
//!   {"components":[{"name":"Hunger","persist":"persistent",
//!     "fields":[{"name":"level","type":"f32","default":0.875}, …]}, …]}
//!
//! The JSON is BYTE-compatible with the lua runner's — one schema
//! contract, N runners (the assembler's parseSchema never learns which
//! language produced it). Exit 0 with the schema on stdout (one line;
//! `{"components":[]}` when no script declares anything). Exit 1 with a
//! file-and-name-bearing message on stderr for any malformed declaration
//! or erroring chunk body. Exit 2 for usage errors.
//!
//! Built host-targeted by the `labelle-declare-ruby` build step regardless
//! of `-Dlanguage` (build.zig): the assembler runs it at GENERATE time on
//! the developer machine, whatever platform the game itself targets. The
//! per-language STEP NAME is the assembler contract: its declare phase
//! selects the runner by the project's script language and probes
//! capability by the tools/declare-ruby directory's presence (older
//! labelle-scripting pins without it skip gracefully).

const std = @import("std");
const extract = @import("extract.zig");

/// Per-script source cap. Game scripts are hand-written logic — megabytes
/// means something is wrong, and a bound keeps a stray path from OOMing
/// the generate step.
const MAX_SCRIPT_BYTES = 4 * 1024 * 1024;

const usage =
    \\labelle-declare-ruby — extract script-declared components as schema JSON
    \\
    \\Usage: labelle-declare-ruby [--cache-dir <dir>] <script.rb> [more.rb ...]
    \\
    \\--cache-dir is accepted and ignored (the assembler's generic declare
    \\contract hands every runner a workspace; an embedded VM needs none).
    \\
    \\Runs each chunk body against the declare stub (only `Labelle` is in
    \\scope; init/update/controllers never run) and prints the schema on
    \\stdout.
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
        // The assembler's generic `.languages` declare invocation contract
        // (RFC-LANGUAGE-PLUGINS rev 17 §7, labelle-engine#619) passes a
        // persistent per-project workspace as a leading `--cache-dir <dir>`.
        // A native compile-and-run probe uses it as a cargo target-dir; this
        // embedded mruby extractor has no build to warm, so it ACCEPTS and
        // IGNORES the flag + its value — the assembler stays language-blind,
        // handing every runner (embedded or native) the identical argv.
        if (std.mem.eql(u8, arg, "--cache-dir")) {
            _ = args.next(); // skip the value; embedded VMs need no workspace
            continue;
        }
        const path = try allocator.dupe(u8, arg);
        errdefer allocator.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_SCRIPT_BYTES)) catch |err| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "labelle-declare-ruby: cannot read {s}: {s}\n",
                .{ path, @errorName(err) },
            ) catch "labelle-declare-ruby: cannot read a script file\n";
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
