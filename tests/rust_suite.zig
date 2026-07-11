//! The rust sub-module driven end to end against the mock host world —
//! see tests/root.zig for the linking model and hygiene notes shared by
//! every language suite.
//!
//! The rust binary's extra ingredient is the cargo-built staticlib
//! (build.zig's test wiring): the SHIPPED glue + labelle module
//! recomposed around tests/rust/game/'s scenario scripts
//! (tests/rust/src/lib.rs). Contract symbols resolve against
//! mock_world.zig exactly as in every other suite; the `labelle_rs_*`
//! glue entries resolve against the archive — both are the production
//! linking model (in a real game the assembler's build step links the
//! same archive into the same binary as the host's exports).
//!
//! Scenario selection: `register` runs afresh inside every
//! `Controller.setup`, and the test crate's game module exports
//! `labelle_rs_test_select` (test-only) to pick which scripts it
//! registers — the rust analog of the lua suite registering different
//! sources per test. Scripts assert their own invariants and a failed
//! assert PANICS — which the glue catches (that containment is itself
//! under test), the script is evicted or the hook skipped, and the
//! verdict component never lands: script-side asserts surface as
//! missing-component failures here.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Test-crate-only export (tests/rust/game/mod.rs): choose the scenario
/// the next setup's `register` builds.
extern fn labelle_rs_test_select(ptr: [*]const u8, len: usize) void;

fn selectScenario(name: []const u8) void {
    labelle_rs_test_select(name.ptr, name.len);
}

/// Reset ALL global state — Controller, registry, mock world AND the
/// crate-side scenario selector.
fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    selectScenario("");
    mock.reset();
}

fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

test "behavior script drives the mock world through init and five ticks" {
    fresh();
    selectScenario("behavior");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // init() ran during setup: player entity exists at the origin.
    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("rust: player 1 ready"));

    // Host emits tick_started before each tick (the POC driver's shape);
    // the script's on_event sees each one during the inbox dispatch.
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
    try expect(mock.logsContain("rust: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("rust: bullet away"));
    // Controller.tick stamped the dt into the host.
    try expectEqual(@as(f32, 1.0 / 60.0), mock.world.dt);
}

test "a panicking update is caught EVERY tick and never starves siblings" {
    fresh();
    // counter (entity 1), exploder BETWEEN them, counter_after (entity
    // 2): per-script containment, not per-tick.
    selectScenario("errors");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);

    // Both bystanders advanced every tick and saw the stamped dt via
    // labelle::dt() — the ticks survived the panicking script between
    // them, and no panic crossed the FFI boundary (an unwind through an
    // extern "C" fn would have aborted this whole test process).
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");
    try expectComponent(2, "Counter", "{\"dt\":0.125,\"n\":3}");
    try expectEqual(@as(f32, 0.125), mock.world.dt);

    // Logged once per tick, attributed; update panics do NOT evict (the
    // script's state is intact — the author gets the report every tick).
    // The count is EXACT: the glue's panic hook logs the LOCATION line
    // and the catch site logs the message — a hook that duplicated the
    // message would double this to 6.
    try expectEqual(@as(usize, 3), mock.logCount("boom on tick"));
    try expect(mock.logsContain("script 'exploder'"));
    try expect(mock.logsContain("panicked"));
    try expectEqual(@as(usize, 0), mock.logCount("script evicted"));

    // The panic LOCATION reached the game's log sink through the glue's
    // panic hook (the catch site can't see it; only the hook can) — and
    // the sink is the ONLY destination: the hook replaces rust's default
    // stderr reporter. That stderr silence is load-bearing beyond
    // tidiness: zig's build runner relays a PASSING test binary's
    // residual stderr through its failure printer (`failed command:`
    // phantom in green builds), so expected-panic noise must never
    // reach stderr — CI's no-failed-command grep pins the observable.
    try expectEqual(@as(usize, 3), mock.logCount("rust: script panic at"));
    try expect(mock.logsContain("panics.rs"));
}

test "a script whose init panics is evicted from update and deinit" {
    fresh();
    selectScenario("bad_init");
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The init failure was logged and evicted the script...
    try expect(mock.logsContain("bad_init boom"));
    try expect(mock.logsContain("script evicted"));
    // ...the quarantined script received no further hooks...
    try expect(!mock.logsContain("bad_init update ran"));
    try expect(!mock.logsContain("bad_init deinit ran"));
    // ...while the sibling registered AFTER it initialized (entity 1)
    // and advanced through both ticks.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "a panicking register() drops every registration and the game keeps running" {
    fresh();
    selectScenario("register_panic");
    // Setup itself succeeds — a broken game module must not brick the
    // host boot; it logs and runs scriptless.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("register() panicked"));
    try expect(mock.logsContain("register scenario panic"));
    try expect(mock.logsContain("rust: no scripts registered"));
    try expect(mock.logsContain("rust setup failed"));

    // All-or-nothing: nothing registered, ticks are inert, nothing dies.
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.aliveCount());
}

test "u64 entity ids round-trip bit-exact at 0x8000000000000001" {
    fresh();
    // Force the next id past the signed-integer boundary: any i64/float
    // hop in the wrapper or the query parse would drift it and the
    // script's asserts would panic — evicting it, and these components
    // would never land.
    mock.setNextEntityId(0x8000000000000001);
    selectScenario("big_id");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    // The id renders unsigned end to end (9223372036854775809, not a
    // negative i64 or a rounded float).
    try expectComponent(big_id, "BigId", "{\"idstr\":\"9223372036854775809\"}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

test "query_into grows past its starting capacity and yields ALL ids" {
    fresh();
    // 420 entities with 20-digit ids ≈ 8.8 KB of id JSON. The script
    // starts its scratch at 64 bytes on purpose — the wrapper must see
    // required > capacity, grow once and re-query for the full set.
    const base: u64 = std.math.maxInt(u64) - 1000;
    mock.setNextEntityId(base);
    selectScenario("big_query");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Premise guard: the complete result really is bigger than the
    // script's deliberate 64-byte start — probed through the same
    // contract sizing the wrapper uses.
    const names = "[\"Marker\"]";
    var dummy: [1]u8 = undefined;
    const required = scripting.contract.labelle_query(names.ptr, names.len, &dummy, 0);
    try expect(required > 64);

    // The script's own asserts police the id SET (sorted compare against
    // what it created); the Zig side pins the count and the world.
    try expectComponent(base + 420, "BigQuery", "{\"count\":420}");
    try expectEqual(@as(usize, 421), mock.aliveCount());
}

test "the inbox drain fans decoded events out to every live script" {
    fresh();
    // Two subscriber instances (entities 1 and 2) — the plugin-wide
    // inbox must fan out to both, in one drain.
    selectScenario("events");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "Seen", "{\"amount\":0,\"count\":0,\"nested_ok\":false}");

    // Two queued events, one tick: both drained, both scripts saw both,
    // nested payload arrived intact.
    const payload = "{\"amount\":7,\"box\":{\"w\":2,\"tags\":[\"fragile\"]}}";
    mock.hostEmit("cargo__delivered", payload);
    mock.hostEmit("cargo__delivered", payload);
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Seen", "{\"amount\":7,\"count\":2,\"nested_ok\":true}");
    try expectComponent(2, "SeenB", "{\"amount\":7,\"count\":2,\"nested_ok\":true}");

    // Unsubscribed events never reach the inbox — nothing moves.
    mock.hostEmit("unrelated_event", "{\"x\":1}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Seen", "{\"amount\":7,\"count\":2,\"nested_ok\":true}");
}

test "controller lifecycle: prefab/scene/remove, deinit hooks, re-setup" {
    fresh();
    selectScenario("lifecycle");
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

    // deinit() hooks run before the registry drops.
    scripting.Controller.deinit();
    try expect(mock.logsContain("rust: lifecycle deinit ran"));
    try expect(mock.eventsContain("shutdown_done {\"from\":1}"));

    // A second setup re-runs register() + init() against the same
    // (uncleared) world: fresh script state, fresh entities.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.entityAlive(3)); // second marker
    try expectComponent(4, "Prefab", "{\"name\":\"ship\"}"); // second ship
    try expectEqual(@as(usize, 4), mock.aliveCount());
}

test "hot loop: reused buffers settle after warm-up and never grow again" {
    fresh();
    selectScenario("alloc");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // 110 ticks: 10 warm-up, 100 measured (the script records its three
    // buffer capacities after warm-up and trips on ANY later growth).
    for (0..110) |_| {
        scripting.Controller.tick(.{}, 0.016);
    }
    try expectComponent(1, "AllocProbe", "{\"settled\":true,\"ticks\":110}");
    // The workload really ran: every Hot entity advanced all 110 rounds.
    try expectComponent(2, "Hot", "{\"count\":110}");
    try expectComponent(51, "Hot", "{\"count\":110}");
    // And the Zig-side scratch seam is constitutionally silent for rust:
    // no VM shim exists, so nothing may ever count a growth.
    try expectEqual(@as(usize, 0), scripting.scratchGrowthCount());
}

test "console eval is a documented refusal for native-compiled rust" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // With the VM "running", the refusal names the real limitation…
    const r = scripting.Controller.evalCommand("1+2");
    try expect(!r.ok);
    try expect(std.mem.indexOf(u8, r.text, "eval not supported for native-compiled languages") != null);

    // …and the full studio-command path wraps it into valid response
    // JSON (ok:false + error), so the console degrades gracefully.
    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand("{\"code\":\"1+2\"}", &buf);
    const parsed = try std.json.parseFromSlice(
        struct { ok: bool, @"error": []const u8 = "" },
        std.testing.allocator,
        response,
        .{},
    );
    defer parsed.deinit();
    try expect(!parsed.value.ok);
    try expect(std.mem.indexOf(u8, parsed.value.@"error", "native-compiled") != null);
}

test "registered sources are refused loudly — rust code arrives compiled, not as text" {
    fresh();
    scripting.registerScript("stray", "fn update() {}");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // loadScript logged the pointed refusal (and admitted nothing — no
    // hook registry exists to evict from)…
    try expect(mock.logsContain("registered source 'stray' ignored"));
    // …the registration itself survives harmlessly (process-lifetime,
    // like every backend), and ticking is unaffected.
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());
    scripting.Controller.tick(.{}, 0.016);
}
