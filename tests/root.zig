//! labelle-scripting acceptance tests: the lua sub-module driven end to
//! end against the mock host world (tests/mock_world.zig).
//!
//! The linking model IS the production one — src/contract.zig declares the
//! `labelle_*` symbols `extern`, mock_world.zig `export`s them into this
//! test binary, exactly as the assembler-generated game will. So every
//! assertion here exercises the same seam a shipped game uses; only the
//! world behind the symbols is a toy.
//!
//! Test hygiene: plugin VM + registry + mock world are process-global (the
//! contract is process-global by nature), so every test starts with
//! `fresh()` and tears its VM down via defer.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

// Force semantic analysis of the mock so its `export fn labelle_*` symbols
// are emitted — the plugin's externs resolve against them at link time.
comptime {
    _ = mock;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Reset ALL global state. Deinit first (idempotent) so a VM left behind
/// by a failed test doesn't leak into the next one, then wipe registry and
/// world.
fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    mock.reset();
}

/// Assert a component's stored JSON byte-for-byte — meaningful because the
/// prelude encoder is deterministic (sorted keys).
fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

test "behavior script drives the mock world through init and five ticks" {
    fresh();
    scripting.registerScript("behavior", @embedFile("lua/behavior.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // init() ran during setup: player entity exists at the origin.
    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("lua: player 1 ready"));

    // Host emits tick_started before each tick (the POC driver's shape);
    // the script's labelle.on handler sees each one during inbox dispatch.
    var buf: [32]u8 = undefined;
    for (1..6) |n| {
        const payload = try std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n});
        mock.hostEmit("tick_started", payload);
        scripting.Controller.tick(.{}, 1.0 / 60.0);
    }

    // +10 per tick for 5 ticks.
    try expectComponent(1, "Position", "{\"x\":50,\"y\":0}");
    // The tick-4 event reaction wrote TickLog.
    try expectComponent(1, "TickLog", "{\"last\":4}");
    try expect(mock.logsContain("lua: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("lua: bullet away"));
    // Controller.tick stamped the dt into the host.
    try expectEqual(@as(f32, 1.0 / 60.0), mock.world.dt);
}

test "script errors are logged with tracebacks and never kill the tick" {
    fresh();
    // Registered FIRST so a crash here would starve the scripts after it.
    scripting.registerScript("exploder",
        \\-- update always raises; the plugin must trap + log + move on
        \\function update(dt)
        \\    error("boom on tick")
        \\end
    );
    // Doesn't even compile — load must log and skip it.
    scripting.registerScript("broken", "function (");
    scripting.registerScript("counter", @embedFile("lua/counter.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);

    // The bystander advanced every tick and saw the stamped dt via
    // labelle.time_dt() — the ticks survived both broken scripts.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");

    // Runtime error: named chunk location + message + full traceback.
    try expect(mock.logsContain("exploder:3"));
    try expect(mock.logsContain("boom on tick"));
    try expect(mock.logsContain("stack traceback:"));
    // Compile error carries the broken script's chunkname too.
    try expect(mock.logsContain("broken:1"));
}

test "prelude json round-trips nested component tables" {
    fresh();
    scripting.registerScript("json_roundtrip", @embedFile("lua/json_roundtrip.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "RoundTrip", "{\"ok\":true}");
}

test "game.query iterates the mock world's matching ids" {
    fresh();
    scripting.registerScript("query_check", @embedFile("lua/query_check.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Entities 1..3 carry Marker (sum 6), only 2 also carries Extra, the
    // bare entity 4 never shows up, unknown names yield zero matches.
    try expectComponent(5, "QueryResult", "{\"both\":1,\"count\":3,\"none\":0,\"sum\":6}");
}

test "labelle.on dispatch fires with decoded payloads" {
    fresh();
    scripting.registerScript("event_payload", @embedFile("lua/event_payload.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Two queued events, one tick: both drained, handlers fan out in
    // order, nested payload decoded to real tables.
    const payload = "{\"amount\":7,\"box\":{\"w\":2,\"tags\":[\"fragile\"]}}";
    mock.hostEmit("cargo__delivered", payload);
    mock.hostEmit("cargo__delivered", payload);
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Seen", "{\"amount\":7,\"count\":2,\"fanout\":2,\"nested_ok\":true}");

    // Unsubscribed events never reach the inbox — nothing moves.
    mock.hostEmit("unrelated_event", "{\"x\":1}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Seen", "{\"amount\":7,\"count\":2,\"fanout\":2,\"nested_ok\":true}");
}

test "controller lifecycle: prefab/scene/remove, deinit hooks, re-setup" {
    fresh();
    scripting.registerScript("lifecycle", @embedFile("lua/lifecycle.lua"));
    try scripting.Controller.setup(.{});

    // init(): marker (1) created + Alive removed again; prefab ship (2)
    // spawned at the params position; scene switched (the "nope" arm
    // rejected inside the script via assert).
    try expect(mock.entityAlive(1));
    try expect(mock.componentJson(1, "Alive") == null);
    try expectComponent(2, "Prefab", "{\"name\":\"ship\"}");
    try expectComponent(2, "Position", "{\"x\":5,\"y\":10}");
    try expectComponent(2, "Tag", "{\"kind\":\"spawned\"}");
    try expectEqualStrings("menu", mock.sceneName());

    // deinit() hooks run before the VM closes.
    scripting.Controller.deinit();
    try expect(mock.logsContain("lua: lifecycle deinit ran"));
    try expect(mock.eventsContain("shutdown_done {\"from\":1}"));

    // Registrations survive deinit: a second setup boots a fresh VM and
    // runs init() again against the same (uncleared) world.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.entityAlive(3)); // second marker
    try expectComponent(4, "Prefab", "{\"name\":\"ship\"}"); // second ship
    try expectEqual(@as(usize, 4), mock.aliveCount());
}

test "registerScript replaces sources by name" {
    fresh();
    scripting.registerScript("dup", "function init() Entity.new():set('V', { v = 1 }) end");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());
    // Same name = replacement, not a second script.
    scripting.registerScript("dup", "function init() Entity.new():set('V', { v = 2 }) end");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());

    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expectComponent(1, "V", "{\"v\":2}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}
