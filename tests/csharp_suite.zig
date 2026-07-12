//! The csharp sub-module driven end to end against the mock host world —
//! see tests/root.zig for the linking model and hygiene notes shared by
//! every language suite.
//!
//! The csharp binary's extra ingredient is a CoreCLR-hosted managed
//! assembly (build.zig's `dotnet build` wiring): the SHIPPED Labelle +
//! Glue module recomposed around tests/csharp/game/'s scenario scripts
//! (tests/csharp/LabelleScriptsTest.csproj — C#'s spelling of the rust
//! suite's #[path] recomposition). src/csharp/vm.zig loads it at RUNTIME
//! through hostfxr and resolves the [UnmanagedCallersOnly] entries;
//! contract symbols resolve against mock_world.zig exactly as in every
//! other suite — but here through the managed side's [LibraryImport]
//! resolver (GetMainProgramHandle), which is why build.zig links this
//! binary `rdynamic` so the mock's exports are visible to the process
//! handle. Both are the production resolution model.
//!
//! Scenario: unlike the crystal/rust suites there is no host-side scenario
//! selector — `Game.Register` (tests/csharp/game/Game.cs) registers a
//! fixed spawner + hunger-system pair that exercises the whole lifecycle
//! and contract surface; every test drives the Controller and asserts on
//! the mock world (logs, components, events).
//!
//! CoreCLR wrinkle: the runtime boots ONCE per process at the first setup
//! and stays up across deinits (src/csharp/vm.zig's runtime_booted) — so
//! "fresh" means a fresh REGISTRY (the managed Glue rebuilds it every
//! setup), never a fresh runtime. That is the production semantic too.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Reset per-test state — Controller + registry + mock world. (The CoreCLR
/// runtime itself is process-wide and stays booted; see the module doc.)
fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    mock.reset();
}

var game_stub: u8 = 0;

fn setup() !void {
    try scripting.Controller.setup(&game_stub);
}

fn tick(dt: f32) void {
    scripting.Controller.tick(&game_stub, dt);
}

fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

test "csharp: CoreCLR host boots, setup runs Game.Register + every Init" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // Both scripts' Init ran (spawner first by registration order).
    try expect(mock.logsContain("CS_INIT"));
    try expect(mock.logsContain("CS_CTRL_READY"));
    const init_at = mock.logIndexOf("CS_INIT").?;
    const ready_at = mock.logIndexOf("CS_CTRL_READY").?;
    try expect(init_at < ready_at);

    // The spawner's Init created the worker (entity 1 — first create after
    // reset) and wrote Hunger THROUGH the contract into the mock ECS.
    try expectComponent(1, "Hunger", "{\"level\":0.875,\"starving\":false}");
}

test "csharp: Update decays the level through the real ECS" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    tick(0.016);
    // 0.875 - 0.25 decay, written back and re-readable.
    try expect(mock.logsContain("CS_LEVEL_0.625"));
    try expectComponent(1, "Hunger", "{\"level\":0.625,\"starving\":false}");
}

test "csharp: events round-trip through subscribe + poll-drain to OnEvent" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // The hunger system subscribed to "hunger__feed" in Init; the mock
    // queues the emission into the inbox because of that subscription.
    mock.hostEmit("hunger__feed", "{\"entity\":1,\"amount\":0.5}");
    tick(0.016); // dispatch_inbox drains BEFORE Update runs

    // Feed handler ran: 0.875 + 0.5 re-read AFTER the write.
    try expect(mock.logsContain("CS_FED_LEVEL_1.375"));
}

test "csharp: Deinit tears down LIFO against setup" {
    fresh();
    try setup();
    scripting.Controller.deinit();

    // hunger registered second, so its Deinit (CS_CTRL_DONE) runs BEFORE
    // the spawner's (CS_DEINIT) — reverse registration order.
    const done_at = mock.logIndexOf("CS_CTRL_DONE").?;
    const deinit_at = mock.logIndexOf("CS_DEINIT").?;
    try expect(done_at < deinit_at);
}

test "csharp: registered sources are refused (compiled family)" {
    fresh();
    defer scripting.Controller.deinit();
    // C# scripts arrive through Game.Register in the assembly, not through
    // registerScript — a hand-registered source is refused loudly.
    scripting.registerScript("stray", "// not runnable");
    try setup();
    try expect(mock.logsContain("csharp is compiled"));
    // The refusal did not stop the assembly's own scripts from running.
    try expect(mock.logsContain("CS_INIT"));
}

test "csharp: console eval is refused for the compiled family" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();
    const res = scripting.Controller.evalCommand("1 + 1");
    try expect(!res.ok);
    try expect(std.mem.indexOf(u8, res.text, "compiled languages (csharp)") != null);
}
