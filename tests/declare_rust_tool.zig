//! The rust declare runner's golden (labelle-engine#774, rev 17) — the
//! native-family member of the cross-runner byte-parity contract.
//!
//! Rust has no interpreter, so unlike the lua/ruby runners (which RUN a script
//! string in-process against a stub — tests/declare_tool.zig,
//! declare_ruby_tool.zig), the rust runner is the labelle-declare-rs TOOL: a
//! probe it cargo-BUILDS at generate. build.zig runs the built tool over the
//! GAME-SHAPED fixtures (tools/declare-rs/testdata/components.rs + events.rs —
//! bare macros, NO `use` lines, so a green run proves the tool's injected
//! prelude) with a scratch `--cache-dir`, and captures its stdout; it is
//! `@embedFile`d here as `rust_declare_schema_out`. This binary rides the RUST
//! test binary only (tests/root.zig's comptime gate), the same way the lua/ruby
//! goldens ride theirs.

const std = @import("std");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;

/// The tool's stdout, captured by build.zig running labelle-declare-rs over the
/// testdata fixtures.
const tool_out = @embedFile("rust_declare_schema_out");
/// The two fixtures the tool actually compiled (game-shaped, no `use` lines).
const components_src = @embedFile("declare_rs_components_src");
const events_src = @embedFile("declare_rs_events_src");

test "cross-runner golden: the rust half — byte-identical to the lua/ruby runners' schema" {
    // The tool compiled the SHIPPED component!/event! macros around the
    // game-shaped fixtures and printed the schema; it must equal the SAME
    // expected literal the lua and ruby runners pin
    // (declare_cross_golden.expected_json) — one logical declaration set, one
    // schema, whatever the language. The tool prints one line + a trailing
    // newline (the labelle-declare main.zig contract), so trim it before the
    // byte compare.
    const trimmed = std.mem.trimEnd(u8, tool_out, "\r\n");
    try testing.expectEqualStrings(cross.expected_json, trimmed);
}

test "drift pin: the compiled rust fixtures carry the golden's declarations verbatim" {
    // The fixtures are what the tool actually compiles; the golden's
    // rust_components_source / rust_events_source are the canonical declaration
    // text. Each block must appear verbatim in its fixture so the golden stays
    // the one source of truth across languages (the ruby prelude drift-pin
    // technique — containment tolerates each fixture's file header comment; the
    // ABSENCE of `use crate::labelle` lines is what proves the tool injects
    // them).
    if (std.mem.indexOf(u8, components_src, cross.rust_components_source) == null) {
        std.debug.print(
            "the golden's rust_components_source is not present verbatim in tools/declare-rs/testdata/components.rs\n",
            .{},
        );
        return error.RustFixtureDrifted;
    }
    if (std.mem.indexOf(u8, events_src, cross.rust_events_source) == null) {
        std.debug.print(
            "the golden's rust_events_source is not present verbatim in tools/declare-rs/testdata/events.rs\n",
            .{},
        );
        return error.RustFixtureDrifted;
    }
    // The fixtures must be game-shaped: no `use crate::labelle` STATEMENT (the
    // tool injects the prelude). A fixture that hand-added it would pass the byte
    // test while HIDING a broken injection. Line-based, not substring: a header
    // COMMENT explaining the injected prelude (which necessarily mentions `use
    // crate::labelle`) must not trip this — only a real statement line does. The
    // per-line trim also drops any `\r`, so the check is line-ending-agnostic.
    for ([_][]const u8{ components_src, events_src }) |src| {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            const stripped = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, stripped, "use crate::labelle")) {
                std.debug.print(
                    "a rust fixture hand-added a `use crate::labelle` statement — that hides a broken prelude injection\n",
                    .{},
                );
                return error.RustFixtureNotGameShaped;
            }
        }
    }
}
