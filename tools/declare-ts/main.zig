//! labelle-declare-ts — the TYPESCRIPT declare-mode schema extractor (the
//! lua/ruby runners' embedded-VM sibling; RFC-LANGUAGE-PLUGINS rev 20,
//! labelle-engine#773, consumed by the assembler's per-language declare
//! runner table).
//!
//! Usage: labelle-declare-ts [--cache-dir <dir>] <module.js> [more.js ...]
//!
//! Evaluates each declaration file as its own ES MODULE (see
//! tools/declare-ts/extract.zig) against the declare stub `labelle`
//! (tools/declare-ts/declare_prelude.js) so its `labelle.component(...)` /
//! `labelle.event(...)` declarations record — nothing else runs — and prints
//! the accumulated schema JSON on stdout:
//!
//!   {"components":[{"name":"Hunger","persist":"persistent",
//!     "fields":[{"name":"level","type":"f32","default":0.875}, …]}, …]}
//!
//! The JSON is BYTE-compatible with the lua/ruby runners' — one schema
//! contract, N runners (the assembler's parseSchema never learns which
//! language produced it). Exit 0 with the schema on stdout (one line;
//! `{"components":[]}` when nothing is declared). Exit 1 with a
//! file-and-name-bearing message on stderr for any malformed declaration or
//! throwing module body. Exit 2 for usage errors.
//!
//! RFC rev 20 option (b): under transpile-then-declare the assembler hands
//! this tool the EMITTED `.js` (it transpiles `components/*.ts` +
//! `events/*.ts` FIRST), so the tool is a pure quickjs evaluator that knows
//! NOTHING about tsc — the assembler owns ALL tsc.
//!
//! Built host-targeted by the `labelle-declare-ts` build step regardless of
//! `-Dlanguage` (build.zig): the assembler runs it at GENERATE time on the
//! developer machine, whatever platform the game itself targets. The
//! per-language STEP NAME is the assembler contract; the tool's dir presence
//! (tools/declare-ts) gates the capability for older labelle-scripting pins.

const std = @import("std");
const extract = @import("extract.zig");

/// Per-file source cap. Declaration files are hand-written (then transpiled) —
/// megabytes means something is wrong, and a bound keeps a stray path from
/// OOMing the generate step.
const MAX_SCRIPT_BYTES = 4 * 1024 * 1024;

const usage =
    \\labelle-declare-ts — extract script-declared components/events as schema JSON
    \\
    \\Usage: labelle-declare-ts [--cache-dir <dir>] <module.js> [more.js ...]
    \\
    \\--cache-dir is accepted and ignored (the assembler's generic declare
    \\contract hands every runner a workspace; an embedded VM needs none).
    \\
    \\Evaluates each file as an ES module against the declare stub (only
    \\`labelle` is in scope; hooks never run) and prints the schema on stdout.
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
        // persistent per-project workspace as a leading `--cache-dir <dir>`. A
        // native compile-and-run probe uses it as a build cache; this embedded
        // quickjs evaluator has none to warm, so it ACCEPTS and IGNORES the
        // flag + its value — the assembler stays language-blind, handing every
        // runner (embedded or native) the identical argv.
        if (std.mem.eql(u8, arg, "--cache-dir")) {
            _ = args.next() orelse {
                try std.Io.File.stderr().writeStreamingAll(io, "labelle-declare-ts: --cache-dir needs an argument\n");
                std.process.exit(2);
            };
            continue;
        }
        const path = try allocator.dupe(u8, arg);
        errdefer allocator.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_SCRIPT_BYTES)) catch |err| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "labelle-declare-ts: cannot read {s}: {s}\n",
                .{ path, @errorName(err) },
            ) catch "labelle-declare-ts: cannot read a declaration file\n";
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
