//! Test root for the lua SANDBOX-PROFILE binary (labelle-engine#740).
//!
//! The mod sandbox profile is a comptime module configuration — the
//! `plugin_params` module's `sandbox = true` decl, exactly what the
//! assembler stages for a project's `.params = .{ .sandbox = true }` —
//! so it cannot share a module instance with the default-profile suites:
//! build.zig wires this root against its own lua module carrying the
//! opted-in params (see the "lua sandbox-profile binary" block there).
//! Same mock world, same linking model as tests/root.zig.

const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

comptime {
    _ = mock;
}

test {
    _ = @import("lua_sandbox_suite.zig");
}
