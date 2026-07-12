//! The rust declare runner's golden (labelle-engine#774) — the native-family
//! member of the cross-runner byte-parity contract.
//!
//! Rust has no interpreter, so unlike the lua/ruby runners (which RUN a script
//! string in-process against a stub — tests/declare_tool.zig,
//! declare_ruby_tool.zig), the rust runner is a probe cargo-BUILDS at generate:
//! the SHIPPED `labelle::component!`/`event!` macros (native/src/labelle.rs)
//! register schemas under the `declare` feature and the probe's main prints
//! the accumulated JSON. build.zig cargo-builds tools/declare-rs (which
//! recomposes those macros around the cross-runner golden fixture,
//! src/decls.rs) and RUNS it; the probe's stdout is `@embedFile`d here as
//! `rust_declare_schema_out`. This binary rides the RUST test binary only
//! (tests/root.zig's comptime gate), the same way the lua/ruby goldens ride
//! theirs.

const std = @import("std");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;

/// The declare probe's stdout, captured by build.zig's cargo-build-and-run.
const probe_out = @embedFile("rust_declare_schema_out");
/// The fixture the probe actually compiled (tools/declare-rs/src/decls.rs).
const decls_src = @embedFile("declare_rs_decls_src");

test "cross-runner golden: the rust half — byte-identical to the lua/ruby runners' schema" {
    // The probe compiled the SHIPPED component!/event! macros around the
    // golden fixture and printed the schema; it must equal the SAME expected
    // literal the lua and ruby runners pin (declare_cross_golden.expected_json)
    // — one logical declaration set, one schema, whatever the language. The
    // probe prints one line + a trailing newline (the labelle-declare main.zig
    // contract), so trim it before the byte compare.
    const trimmed = std.mem.trimEnd(u8, probe_out, "\r\n");
    try testing.expectEqualStrings(cross.expected_json, trimmed);
}

test "drift pin: the compiled rust fixture carries the golden's rust_source verbatim" {
    // decls.rs is what the probe actually compiles; rust_source is the golden's
    // canonical declaration text. The block must appear verbatim in the
    // fixture so the golden stays the one source of truth across languages
    // (the ruby prelude drift-pin technique — containment tolerates the
    // fixture's file header and `use` lines around the declarations).
    if (std.mem.indexOf(u8, decls_src, cross.rust_source) == null) {
        std.debug.print(
            "the golden's rust_source is not present verbatim in tools/declare-rs/src/decls.rs\n",
            .{},
        );
        return error.RustFixtureDrifted;
    }
}
