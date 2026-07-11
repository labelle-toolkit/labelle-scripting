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

const std = @import("std");
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
        .typescript => @import("ts_suite.zig"),
    };
}

// The declare-mode extractor goldens (tools/declare via the `declare_core`
// named module) ride the LUA test binary only: extract.zig's lua_* externs
// resolve against the lua objects the lua-language module compiled in —
// the ruby binary carries mruby, no lua symbols. The comptime gate keeps
// the module unanalyzed (and so unlinked) everywhere else.
comptime {
    if (scripting.language == .lua) _ = @import("declare_tool.zig");
}

// The console-eval SHARED-code suite (response builder, params decoding,
// hook-shim AstGen check — labelle-scripting#4) also rides the lua binary
// only: the code under test is language-independent, so one mirror is the
// whole coverage. Each language's eval CORE (Vm.evalConsole) is tested in
// its own suite.
comptime {
    if (scripting.language == .lua) _ = @import("eval_shared_suite.zig");
}

test "dispatch contract (#3): explicit-tick-only, zero-arg deinit" {
    // The assembler's splice (labelle-assembler#596) emits
    // `scripting.Controller.tick(&g, scaled_dt)` EXPLICITLY and selects
    // the generated deinit call by arity. If this test fails, you are
    // about to double-tick every scripted game (a `Systems` decl gets
    // auto-ticked by the engine ON TOP of the splice's explicit tick) or
    // break every generated deinit block — coordinate an assembler
    // release first. See the Controller doc in src/root.zig.
    comptime {
        std.debug.assert(!@hasDecl(scripting, "Systems"));
        std.debug.assert(!@hasDecl(scripting.Controller, "Systems"));
        const deinit_info = @typeInfo(@TypeOf(scripting.Controller.deinit)).@"fn";
        std.debug.assert(deinit_info.params.len == 0);
    }
    // And the explicit-tick shape itself: (game: anytype, dt: f32).
    comptime {
        const tick_info = @typeInfo(@TypeOf(scripting.Controller.tick)).@"fn";
        std.debug.assert(tick_info.params.len == 2);
        std.debug.assert(tick_info.params[1].type.? == f32);
    }
}
