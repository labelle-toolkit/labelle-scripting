//! labelle-scripting acceptance tests: the SELECTED language sub-module
//! driven end to end against the mock host world (tests/mock_world.zig).
//!
//! The linking model IS the production one — src/contract.zig declares the
//! `labelle_*` symbols `extern`, mock_world.zig `export`s them into this
//! test binary, exactly as the assembler-generated game will. So every
//! assertion here exercises the same seam a shipped game uses; only the
//! world behind the symbols is a toy — and it is language-agnostic: every
//! suite runs against the same mock.
//!
//! One test binary per language: build.zig instantiates this root once
//! per `Language` value and the comptime switch below pulls in that
//! language's suite; `zig build test` runs them all.
//!
//! Test hygiene (applies to every suite): plugin VM + registry + mock
//! world are process-global (the contract is process-global by nature),
//! so every test starts with `fresh()` and tears its VM down via defer.

const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

// Force semantic analysis of the mock so its `export fn labelle_*` symbols
// are emitted — the plugin's externs resolve against them at link time.
comptime {
    _ = mock;
}

test {
    _ = switch (scripting.language) {
        .lua => @import("lua_suite.zig"),
        .ruby => @import("ruby_suite.zig"),
    };
}
