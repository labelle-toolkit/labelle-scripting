//! The crystal BOOT-containment pin — a dedicated test binary
//! (build.zig wires it beside the main crystal suite, same localized
//! object, same mock world), because what it pins is process-wide:
//!
//! a failed runtime boot must (1) fail `Controller.setup` loudly with
//! the per-stage report, and (2) POISON crystal scripting for the
//! process — no retry. The no-retry half is empirical, established in
//! this repo: the retry design was implemented first, and re-running
//! the boot after a stage-3 failure (a raise mid-`main_user_code`)
//! re-ran the ENTIRE top level over the half-initialized first pass —
//! the process then died with SIGSEGV under the gc_churn workload's
//! forced collections. Poison-and-restart is the only sound policy,
//! and a poisoned process can host no other crystal test — hence this
//! binary (the main suite, tests/crystal_suite.zig, boots ONCE
//! successfully and never sees the flag).
//!
//! The staged failure rides the boot probe in the test object's game
//! module (tests/crystal/game/game.cr): its TOP LEVEL raises while
//! `labelle_cr_test_boot_should_fail` — exported HERE — reads 1,
//! which is exactly a game constant initializer throwing during the
//! boot's main_user_code pass, the realistic failure.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Force semantic analysis of the mock so its `export fn labelle_*`
// symbols are emitted — the plugin's externs resolve against them at
// link time (same note as tests/root.zig).
comptime {
    _ = mock;
}

/// The staged-failure flag the test object's top level probes.
var boot_should_fail = false;

export fn labelle_cr_test_boot_should_fail() i32 {
    return @intFromBool(boot_should_fail);
}

/// The object also binds the scenario pull (tests/crystal/game/game.cr
/// `lib LibSuite`); no scenario ever registers here — setup never gets
/// past the failing boot.
export fn labelle_cr_test_scenario(out: [*]u8, cap: usize) usize {
    _ = out;
    _ = cap;
    return 0;
}

test "a failed runtime boot fails setup loudly and poisons crystal scripting for the process" {
    mock.reset();
    boot_should_fail = true;
    defer boot_should_fail = false;

    // First setup: the top-level probe raises during main_user_code
    // (boot stage 3) → the boot reports the stage and setup FAILS — a
    // swallowed failure here would latch "booted" over a runtime whose
    // GC/constant tables never initialized and corrupt quietly forever
    // after (the codex-review bug this suite exists to pin).
    try std.testing.expectError(
        error.CrystalRuntimeBootFailed,
        scripting.Controller.setup(.{}),
    );
    // Both halves of the report: the glue's static per-stage line and
    // the Zig arm's consequence line.
    try expect(mock.logsContain("runtime boot failed during top-level initialization"));
    try expect(mock.logsContain("crystal runtime boot failed — no scripts"));
    try expect(mock.logsContain("restart the game"));
    // No VM latched: ticking is inert, nothing runs, nothing dies.
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.aliveCount());

    // Second setup — even with the failure's CAUSE cleared: a partial
    // boot cannot be retried (module doc — the empirical SIGSEGV), so
    // the arm refuses with the pointed poisoned message instead of
    // re-running the top level over the half-initialized first pass.
    boot_should_fail = false;
    mock.reset();
    try std.testing.expectError(
        error.CrystalRuntimeBootFailed,
        scripting.Controller.setup(.{}),
    );
    try expect(mock.logsContain("boot previously failed"));
    try expect(mock.logsContain("partial boot cannot be retried"));
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.aliveCount());
}
