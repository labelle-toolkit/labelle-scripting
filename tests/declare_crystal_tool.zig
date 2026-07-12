//! The crystal declare runner's golden (labelle-engine#775) — the second
//! native-family member of the cross-runner byte-parity contract, rust's twin.
//!
//! Crystal has no interpreter, so — like the rust runner (tests/declare_rust_
//! tool.zig) and unlike the lua/ruby runners (which RUN a script string
//! in-process against a stub) — the crystal runner is the
//! labelle-declare-crystal TOOL: a probe it `crystal build`s at generate.
//! build.zig runs the built tool over the GAME-SHAPED fixtures
//! (tools/declare-crystal/testdata/components.cr + events.cr — bare macros, NO
//! `require` lines, so a green run proves the tool's injected prelude) with a
//! scratch `--cache-dir`, and captures its stdout; it is `@embedFile`d here as
//! `crystal_declare_schema_out`. This binary rides the CRYSTAL test binary only
//! (tests/root.zig's comptime gate + build.zig's crystal-present wiring), the
//! same way the lua/ruby/rust goldens ride theirs.

const std = @import("std");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;

/// The tool's stdout, captured by build.zig running labelle-declare-crystal
/// over the testdata fixtures.
const tool_out = @embedFile("crystal_declare_schema_out");
/// The two fixtures the tool actually compiled (game-shaped, no `require` lines).
const components_src = @embedFile("declare_cr_components_src");
const events_src = @embedFile("declare_cr_events_src");

test "cross-runner golden: the crystal half — byte-identical to the lua/ruby/rust runners' schema" {
    // The tool compiled the SHIPPED component/event macros around the
    // game-shaped fixtures and printed the schema; it must equal the SAME
    // expected literal the lua, ruby and rust runners pin
    // (declare_cross_golden.expected_json) — one logical declaration set, one
    // schema, whatever the language. The tool prints one line + a trailing
    // newline (the labelle-declare main.zig contract), so trim it before the
    // byte compare.
    const trimmed = std.mem.trimEnd(u8, tool_out, "\r\n");
    try testing.expectEqualStrings(cross.expected_json, trimmed);
}

test "drift pin: the compiled crystal fixtures carry the golden's declarations verbatim" {
    // The fixtures are what the tool actually compiles; the golden's
    // crystal_components_source / crystal_events_source are the canonical
    // declaration text. Each block must appear verbatim in its fixture so the
    // golden stays the one source of truth across languages (the rust prelude
    // drift-pin technique — containment tolerates each fixture's file header
    // comment; the ABSENCE of a `require "./labelle"` line is what proves the
    // tool injects it).
    if (std.mem.indexOf(u8, components_src, cross.crystal_components_source) == null) {
        std.debug.print(
            "the golden's crystal_components_source is not present verbatim in tools/declare-crystal/testdata/components.cr\n",
            .{},
        );
        return error.CrystalFixtureDrifted;
    }
    if (std.mem.indexOf(u8, events_src, cross.crystal_events_source) == null) {
        std.debug.print(
            "the golden's crystal_events_source is not present verbatim in tools/declare-crystal/testdata/events.cr\n",
            .{},
        );
        return error.CrystalFixtureDrifted;
    }
    // The fixtures must be game-shaped: no `require` STATEMENT (the tool
    // injects `require "./labelle"`). A fixture that hand-added it would pass
    // the byte test while HIDING a broken injection. Line-based via
    // starts-with, NOT indexOf: a header COMMENT explaining the injected
    // prelude (which necessarily mentions `require "./labelle"`) is a `#`
    // comment line and must not trip this — only a real statement line does.
    // The per-line trim also drops any `\r`, so the check is
    // line-ending-agnostic.
    for ([_][]const u8{ components_src, events_src }) |src| {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            const stripped = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, stripped, "require")) {
                std.debug.print(
                    "a crystal fixture hand-added a `require` statement — that hides a broken prelude injection\n",
                    .{},
                );
                return error.CrystalFixtureNotGameShaped;
            }
        }
    }
}
