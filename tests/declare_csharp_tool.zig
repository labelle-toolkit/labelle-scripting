//! The C# declare runner's golden (labelle-scripting#27, labelle-engine#743) —
//! the CoreCLR-family member of the cross-runner byte-parity contract, rust's /
//! crystal's twin.
//!
//! C# is compiled, so — like the rust runner (tests/declare_rust_tool.zig) and
//! crystal runner (tests/declare_crystal_tool.zig), and unlike the lua/ruby/ts
//! runners (which RUN a source string in-process against a stub) — the C#
//! runner is the labelle-declare-csharp TOOL: a probe it `dotnet build`s at
//! generate. build.zig runs the built tool over the GAME-SHAPED fixtures
//! (tools/declare-csharp/testdata/components.cs + events.cs — bare
//! `[LabelleComponent]` / `[LabelleEvent]` records, NO `using` lines, so a green
//! run proves the tool needs no prelude injection) with a scratch `--cache-dir`,
//! and captures its stdout; it is `@embedFile`d here as
//! `csharp_declare_schema_out`. This binary rides the CSHARP test binary only
//! (tests/root.zig's comptime gate + build.zig's dotnet-present wiring), the
//! same way the lua/ruby/rust/crystal goldens ride theirs.

const std = @import("std");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;

/// The tool's stdout, captured by build.zig running labelle-declare-csharp over
/// the testdata fixtures.
const tool_out = @embedFile("csharp_declare_schema_out");
/// The two fixtures the tool actually compiled (game-shaped, no `using` lines).
const components_src = @embedFile("declare_cs_components_src");
const events_src = @embedFile("declare_cs_events_src");

test "cross-runner golden: the C# half — byte-identical to the lua/ruby/rust/crystal/ts runners' schema" {
    // The tool compiled the SHIPPED declare surface around the game-shaped
    // fixtures and printed the schema; it must equal the SAME expected literal
    // every other runner pins (declare_cross_golden.expected_json) — one logical
    // declaration set, one schema, whatever the language. The tool prints one
    // line + a trailing newline (the labelle-declare main.zig contract), so trim
    // it before the byte compare.
    const trimmed = std.mem.trimEnd(u8, tool_out, "\r\n");
    try testing.expectEqualStrings(cross.expected_json, trimmed);
}

test "drift pin: the compiled C# fixtures carry the golden's declarations verbatim" {
    // The fixtures are what the tool actually compiles; the golden's
    // csharp_components_source / csharp_events_source are the canonical
    // declaration text. Each block must appear verbatim in its fixture so the
    // golden stays the one source of truth across languages (the rust/crystal
    // drift-pin technique — containment tolerates each fixture's file header
    // comment).
    if (std.mem.indexOf(u8, components_src, cross.csharp_components_source) == null) {
        std.debug.print(
            "the golden's csharp_components_source is not present verbatim in tools/declare-csharp/testdata/components.cs\n",
            .{},
        );
        return error.CsharpFixtureDrifted;
    }
    if (std.mem.indexOf(u8, events_src, cross.csharp_events_source) == null) {
        std.debug.print(
            "the golden's csharp_events_source is not present verbatim in tools/declare-csharp/testdata/events.cs\n",
            .{},
        );
        return error.CsharpFixtureDrifted;
    }
    // The fixtures must be game-shaped: no `using` DIRECTIVE (the declare
    // surface is global — a game's declaration files need no import, and the
    // tool injects no prelude). A fixture that hand-added a `using` would pass
    // the byte test while HIDING a dependence on an import the tool never
    // supplies. Line-based via starts-with, NOT indexOf: a header COMMENT that
    // mentions "using" is a `//` line and must not trip this — only a real
    // directive line does. The per-line trim also drops any `\r`, so the check
    // is line-ending-agnostic.
    for ([_][]const u8{ components_src, events_src }) |src| {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            const stripped = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, stripped, "using")) {
                std.debug.print(
                    "a C# fixture hand-added a `using` directive — the declare surface is global; that hides a real dependency\n",
                    .{},
                );
                return error.CsharpFixtureNotGameShaped;
            }
        }
    }
}
