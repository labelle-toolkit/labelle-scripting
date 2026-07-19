//! The crystal sub-module driven end to end against the mock host world
//! — see tests/root.zig for the linking model and hygiene notes shared
//! by every language suite.
//!
//! The crystal binary's extra ingredient is the localized script object
//! (build.zig's two-step wiring: `crystal build --cross-compile`, then
//! main-localization): the SHIPPED glue + Labelle module recomposed
//! around tests/crystal/game/'s scenario scripts (tests/crystal/main.cr
//! — relative requires, crystal's #[path]). Contract symbols resolve
//! against mock_world.zig exactly as in every other suite; the
//! `labelle_cr_*` glue entries resolve against the object — both are
//! the production linking model.
//!
//! Scenario selection: `Game.register` runs afresh inside every
//! `Controller.setup` and PULLS the scenario name through
//! `labelle_cr_test_scenario`, a host symbol THIS file exports — the
//! crystal twin of the rust suite's selector with the direction
//! inverted, because the runtime boot's top-level pass re-initializes
//! crystal-side statics (a pre-boot push into a class var would be
//! wiped by the first setup) and no crystal code may run before boot
//! at all. Scripts assert their own invariants by RAISING — which the
//! glue rescues (that containment is itself under test), the script is
//! evicted or the hook skipped, and the verdict component never lands:
//! script-side assertion failures surface as missing-component
//! failures here.
//!
//! One crystal-only wrinkle: the runtime (GC + top level) boots ONCE
//! per process at the first successful setup and stays up across
//! deinits — so unlike the embedded suites, "fresh" means a fresh
//! REGISTRY, never a fresh runtime. That is the production semantic
//! too (src/crystal/vm.zig's runtime_booted). Its failure half —
//! boot fails → setup errs loudly → the process is POISONED — cannot
//! be staged in this binary at all (poisoning is process-wide), so it
//! rides a dedicated second binary: tests/crystal_boot_suite.zig.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The selected scenario, held HOST-side (module doc): the test
/// object's `Game.register` pulls it through the export below at
/// register time — always post-boot, never wiped by the boot's
/// top-level initializer pass.
var scenario_buf: [64]u8 = undefined;
var scenario_len: usize = 0;

/// Test-only host symbol the crystal game module binds (`lib LibSuite`
/// in tests/crystal/game/game.cr). Same-binary resolution, like every
/// contract symbol.
export fn labelle_cr_test_scenario(out: [*]u8, cap: usize) usize {
    const n = @min(scenario_len, cap);
    @memcpy(out[0..n], scenario_buf[0..n]);
    return n;
}

/// The test object's TOP LEVEL (tests/crystal/game/game.cr) probes
/// this during the boot's main_user_code pass and raises on 1 — the
/// staged boot failure. In THIS binary it is hardwired 0: a failed
/// boot poisons crystal scripting process-wide (src/crystal/vm.zig),
/// so the containment pin lives in its own binary,
/// tests/crystal_boot_suite.zig.
export fn labelle_cr_test_boot_should_fail() i32 {
    return 0;
}

fn selectScenario(name: []const u8) void {
    scenario_len = @min(name.len, scenario_buf.len);
    @memcpy(scenario_buf[0..scenario_len], name[0..scenario_len]);
}

/// Reset ALL per-test state — Controller, registry, mock world AND the
/// host-side scenario selection. (The crystal runtime itself is
/// process-wide and stays booted; see the module doc.)
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
    try expect(mock.logsContain("crystal: player 1 ready"));

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
    try expect(mock.logsContain("crystal: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("crystal: bullet away"));
    // Controller.tick stamped the dt into the host.
    try expectEqual(@as(f32, 1.0 / 60.0), mock.world.dt);
}

test "a raising update is rescued EVERY tick and never starves siblings" {
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
    // Labelle.dt — the ticks survived the raising script between them,
    // and no exception crossed the FFI boundary (an escape would have
    // killed this whole test process: crystal's "Failed to raise an
    // exception: END_OF_STACK" abort).
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");
    try expectComponent(2, "Counter", "{\"dt\":0.125,\"n\":3}");
    try expectEqual(@as(f32, 0.125), mock.world.dt);

    // Logged EXACTLY once per tick — class + message, attributed to the
    // script and hook; update raises do NOT evict (the script's state
    // is intact — the author gets the report every tick). No panic-hook
    // second line exists in crystal (nothing ever reaches stderr, so
    // the CI phantom-'failed command:' grep stays quiet by
    // construction).
    try expectEqual(@as(usize, 3), mock.logCount("boom on tick"));
    try expectEqual(@as(usize, 3), mock.logCount("script 'exploder' in update raised"));
    try expect(mock.logsContain("Exception: boom on tick"));
    try expectEqual(@as(usize, 0), mock.logCount("script evicted"));
}

test "a script whose init raises is evicted from update and deinit" {
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

test "a raising register() drops every registration and the game keeps running" {
    fresh();
    selectScenario("register_raise");
    // Setup itself succeeds — a broken game module must not brick the
    // host boot; it logs and runs scriptless.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("register() raised"));
    try expect(mock.logsContain("register scenario raise"));
    try expect(mock.logsContain("crystal: no scripts registered"));
    try expect(mock.logsContain("crystal setup failed"));

    // All-or-nothing: nothing registered, ticks are inert, nothing dies.
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.aliveCount());
}

test "u64 entity ids round-trip bit-exact at 0x8000000000000001" {
    fresh();
    // Force the next id past the signed-integer boundary: any
    // Int64/float hop in the wrapper or the query parse would drift it
    // (crystal's to_i64 hazard — the POC's bisect namesake) and the
    // script's raises would evict it, so these components would never
    // land.
    mock.setNextEntityId(0x8000000000000001);
    selectScenario("big_id");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    // The id renders unsigned end to end (9223372036854775809, not a
    // negative Int64 or a rounded float).
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

    // The script's own raises police the id SET (sorted compare against
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
    // rejected inside the script via raise).
    try expect(mock.entityAlive(1));
    try expect(mock.componentJson(1, "Alive") == null);
    try expectComponent(2, "Prefab", "{\"name\":\"ship\"}");
    try expectComponent(2, "Position", "{\"x\":5,\"y\":10}");
    try expectComponent(2, "Tag", "{\"kind\":\"spawned\"}");
    try expectEqualStrings("menu", mock.sceneName());

    // deinit() hooks run before the registry drops.
    scripting.Controller.deinit();
    try expect(mock.logsContain("crystal: lifecycle deinit ran"));
    try expect(mock.eventsContain("shutdown_done {\"from\":1}"));

    // A second setup re-runs register() + init() against the same
    // (uncleared) world: fresh script state, fresh entities — and the
    // process-wide crystal runtime carries over without a second boot.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.entityAlive(3)); // second marker
    try expectComponent(4, "Prefab", "{\"name\":\"ship\"}"); // second ship
    try expectEqual(@as(usize, 4), mock.aliveCount());
}

test "GC collections stay enabled: per-tick churn + forced collect, 110 ticks" {
    fresh();
    // THE ticket acceptance (labelle-engine#741): the runtime boot
    // registered the host thread's stack with bdw-gc, so full
    // collections — forced EVERY tick by the script, 110 in a row —
    // run with collections enabled and the live set survives: the
    // workload keeps advancing bit-exact afterwards. A mis-registered
    // stack dies inside the first few GC.collect calls (bdw-gc scans
    // garbage), so completing the run IS the assertion; the verdict
    // component carries the count.
    selectScenario("gc_churn");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    for (0..110) |_| {
        scripting.Controller.tick(.{}, 0.016);
    }
    try expectComponent(1, "GcChurn", "{\"collects\":110,\"settled\":true,\"ticks\":110}");
    // The workload really ran through the collections: every Hot entity
    // advanced all 110 rounds (component data lives host-side, beyond
    // the GC's reach — but the script state driving it is all heap).
    try expectComponent(2, "Hot", "{\"count\":110}");
    try expectComponent(51, "Hot", "{\"count\":110}");
    // And the Zig-side scratch seam is constitutionally silent for
    // crystal: no VM shim exists, so nothing may ever count a growth.
    try expectEqual(@as(usize, 0), scripting.scratchGrowthCount());
}

test "console eval is a documented refusal for native-compiled crystal" {
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

test "registered sources are refused loudly — crystal code arrives compiled, not as text" {
    fresh();
    scripting.registerScript("stray", "def update(dt); end");
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

test "bulk v1.3: packed codec round-trips typed views, JSON stays the fallback" {
    fresh();
    selectScenario("bulk_packed");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Every field kind survived the binary round-trip (f32/i64/bool/u64).
    try expect(mock.logsContain("crystal: packed:1.5:-42:true:123"));
    // The stored JSON is in the mock's SCHEMA order (power,score,alive,
    // seed) — the packed set wrote it. The JSON fallback sorts keys
    // (alive,power,score,seed), so key order proves the path taken.
    try expectComponent(1, "Stats", "{\"power\":1.5,\"score\":-42,\"alive\":true,\"seed\":123}");
    // The schema-less component round-trips through JSON.
    try expect(mock.logsContain("crystal: plain:2.5"));
    // JSON-fallback coercion (round 1): whole-number floats spelled as
    // int-class tokens (`{"a":2}`) must still land in the f32 view
    // field; a whole-number set_from round-trips too.
    try expect(mock.logsContain("crystal: plain int:2.0"));
    try expect(mock.logsContain("crystal: plain whole:3.0"));
    try expectComponent(1, "Plain", "{\"a\":3.0}");
    // A bit-63 u64 rides tag 3 bit-exact (crystal has a real UInt64);
    // the host stored the unsigned value via the packed path.
    try expect(mock.logsContain("crystal: u64rt:true"));
    try expectComponent(2, "Stats", "{\"power\":0,\"score\":0,\"alive\":false,\"seed\":9223372036854775809}");
    // Non-finite policy: NaN refused up front — nothing stored.
    try expect(mock.logsContain("crystal: nan_refused:true"));
    try expect(mock.componentJson(3, "Stats") == null);
    // Absent components answer false through both routes.
    try expect(mock.logsContain("crystal: absent:true"));
}

test "bulk v1.3: batch_get/batch_set round-trip the whole query as one f32 stream" {
    fresh();
    selectScenario("bulk_batch");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Int-carrying components refused LOUDLY on both directions
    // (ArgumentError raises, rescued in-script).
    try expect(!mock.logsContain("crystal: get refusal missed"));
    try expect(!mock.logsContain("crystal: set refusal missed"));
    try expect(mock.logsContain("crystal: get int refused:true"));
    try expect(mock.logsContain("crystal: set int refused:true"));

    scripting.Controller.tick(.{}, 0.016);
    // 3 matching entities (the lone BatchPos-only one filtered out),
    // stride 4 → exactly 12 floats crossed.
    try expect(mock.logsContain("crystal: batch count:3 floats:12"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(2, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(3, "BatchPos", "{\"x\":13,\"y\":-10}");
    // Second tick reuses the same buffers and advances again.
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "BatchPos", "{\"x\":21,\"y\":-20}");
    try expectComponent(3, "BatchPos", "{\"x\":23,\"y\":-20}");
    // The filtered-out entity was never rewritten.
    try expectComponent(4, "BatchPos", "{\"x\":7,\"y\":8}");
}

test "bulk v1.3: batch_set raises when the entity set changed since batch_get" {
    fresh();
    selectScenario("bulk_stale");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // The exact-size positional-coupling guard fired and surfaced as a
    // catchable BatchError telling the script to re-get.
    try expect(!mock.logsContain("crystal: stale write accepted"));
    try expect(mock.logsContain("crystal: stale refused:"));
    try expect(mock.logsContain("entity set changed"));
    // NOTHING was applied: the survivor keeps its batch_get-era value.
    try expectComponent(1, "BatchPos", "{\"x\":0,\"y\":0}");
}

test "bulk stage 3: the typed block tier round-trips through Labelle.batch" {
    fresh();
    selectScenario("bulk_iter");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("crystal: iter n:3"));
    // The block's writes landed through the one batch_set — typed
    // write-through views mapped [x, y | vx, vy] as the stream lays out.
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(2, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(3, "BatchPos", "{\"x\":13,\"y\":-10}");
    try expectComponent(3, "BatchVel", "{\"vx\":-10,\"vy\":-10}");
    try expectComponent(1, "BatchVel", "{\"vx\":10,\"vy\":-10}");
    // Second tick is steady state (entity 3 moves backward, bounced).
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "BatchPos", "{\"x\":21,\"y\":-20}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":-20}");
}

test "bulk stage 3: block-tier exit semantics — break commits, raise aborts, nested/mismatch refuse" {
    fresh();
    selectScenario("bulk_iter_edge");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Empty query: 0, the block never ran.
    try expect(mock.logsContain("crystal: empty n:0"));
    try expect(!mock.logsContain("crystal: empty ran"));
    // break after mutating entity 1 only: its write COMMITTED (the
    // views write through to the buffer), not-yet-yielded entities
    // round-tripped unchanged; `break value` came back as the call's
    // value.
    try expect(mock.logsContain("crystal: break r::halted"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":0}");
    try expectComponent(2, "BatchPos", "{\"x\":2,\"y\":0}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":0}");
    // The raising block aborted the whole write (x stays 11, the 999
    // never landed) — and the raise stayed catchable in-script.
    try expect(!mock.logsContain("crystal: raise swallowed"));
    try expect(mock.logsContain("crystal: block raised: boom"));
    // Duplicate component names refused before any host call (the 555
    // never landed).
    try expect(!mock.logsContain("crystal: dup accepted"));
    try expect(mock.logsContain("crystal: dup refused:"));
    try expect(mock.logsContain("named by both views"));
    // Nested batch calls refused loudly.
    try expect(!mock.logsContain("crystal: nested accepted"));
    try expect(mock.logsContain("crystal: nested refused:"));
    // Layout mismatch (a zero-stream-float component vs a one-field
    // view) refused before any yield.
    try expect(!mock.logsContain("crystal: mismatch accepted"));
    try expect(!mock.logsContain("crystal: mismatch ran"));
    try expect(mock.logsContain("crystal: mismatch refused:"));
    try expectComponent(4, "BatchPos", "{\"x\":50,\"y\":0}");
}
