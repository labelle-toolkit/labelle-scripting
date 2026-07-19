//! The typescript (QuickJS) sub-module driven end to end against the mock
//! host world — see tests/root.zig for the linking model and hygiene
//! notes shared by every language suite.
//!
//! The suite mirrors the lua one test-for-test where the semantics are
//! shared (behavior port, eviction, handler purge and isolation, u64
//! fidelity, scratch settling, lifecycle), then pins the typescript-
//! specific surface: ES-module isolation (module scope + exported hooks —
//! including that an UNexported hook is not a hook), BigInt entity ids
//! end to end, `get(name, into)` refills, FrameArray, and the
//! steady-state allocation proof on QuickJS's live malloc counter.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Reset ALL global state (see the lua suite's fresh()).
fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    mock.reset();
}

/// Assert a component's stored JSON byte-for-byte — meaningful because
/// the Zig-side encoder is deterministic (sorted keys, integral floats
/// as integers).
fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

test "behavior script drives the mock world through init and five ticks" {
    fresh();
    scripting.registerScript("behavior", @embedFile("ts/behavior.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // init() ran during setup: player entity exists at the origin.
    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("ts: player 1 ready"));

    // Host emits tick_started before each tick (the POC driver's shape);
    // the script's labelle.on handler sees each one during inbox dispatch.
    var buf: [32]u8 = undefined;
    for (1..6) |n| {
        const payload = try std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n});
        mock.hostEmit("tick_started", payload);
        scripting.Controller.tick(.{}, 1.0 / 60.0);
    }

    // +10 per tick for 5 ticks — and although JS has only doubles, the
    // encoder renders the integral result as "50", byte-exact with lua.
    try expectComponent(1, "Position", "{\"x\":50,\"y\":0}");
    // The tick-4 event reaction wrote TickLog.
    try expectComponent(1, "TickLog", "{\"last\":4}");
    try expect(mock.logsContain("ts: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game — the
    // BigInt id encoded as a bare unsigned integer.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("ts: bullet away"));
    // Controller.tick stamped the dt into the host.
    try expectEqual(@as(f32, 1.0 / 60.0), mock.world.dt);
}

test "script errors are logged with stacks and never kill the tick" {
    fresh();
    // Registered FIRST so a crash here would starve the scripts after it.
    scripting.registerScript("exploder",
        \\// update always throws; the plugin must trap + log + move on
        \\export function update(dt) {
        \\  throw new Error("boom on tick");
        \\}
    );
    // Doesn't even parse — load must log and skip it.
    scripting.registerScript("broken", "export function (");
    scripting.registerScript("counter", @embedFile("ts/counter.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);

    // The bystander advanced every tick and saw the stamped dt via
    // labelle.time_dt() — the ticks survived both broken scripts.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");

    // Runtime error: message + stack with the named module's location.
    try expect(mock.logsContain("Error: boom on tick"));
    try expect(mock.logsContain("stack:"));
    try expect(mock.logsContain("exploder:3"));
    // Parse error carries the broken script's name and SyntaxError class.
    try expect(mock.logsContain("SyntaxError"));
    try expect(mock.logsContain("broken:1"));
}

test "a module whose body throws is evicted before any hook fires" {
    fresh();
    scripting.registerScript("half_baked",
        \\// update/deinit are exported BEFORE the body throws; without
        \\// eviction the registry would still dispatch to them.
        \\export function update(dt) {
        \\  labelle.log("half_baked update ran");
        \\}
        \\export function deinit() {
        \\  labelle.log("half_baked deinit ran");
        \\}
        \\throw new Error("half_baked top-level boom");
    );
    scripting.registerScript("counter", @embedFile("ts/counter.js"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The load failure itself was logged with its location (a module
    // body throw surfaces through the module promise's rejection)...
    try expect(mock.logsContain("half_baked top-level boom"));
    try expect(mock.logsContain("half_baked:9"));
    // ...and neither hook of the half-loaded script ever fired.
    try expect(!mock.logsContain("half_baked update ran"));
    try expect(!mock.logsContain("half_baked deinit ran"));
    // The bystander ran init + update untouched by the eviction.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":1}");
}

test "a script whose init() throws is evicted from update and deinit" {
    fresh();
    scripting.registerScript("bad_init",
        \\export function init() {
        \\  throw new Error("bad_init boom");
        \\}
        \\export function update(dt) {
        \\  labelle.log("bad_init update ran");
        \\}
        \\export function deinit() {
        \\  labelle.log("bad_init deinit ran");
        \\}
    );
    scripting.registerScript("counter", @embedFile("ts/counter.js"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The init failure carries its stack plus one eviction line.
    try expect(mock.logsContain("bad_init boom"));
    try expect(mock.logsContain("script evicted"));
    // The quarantined script received no further hooks...
    try expect(!mock.logsContain("bad_init update ran"));
    try expect(!mock.logsContain("bad_init deinit ran"));
    // ...while the sibling initialized and advanced through both ticks.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "hooks are module EXPORTS: an unexported update never fires" {
    fresh();
    // The export IS the hook contract (module namespaces are the
    // registry): a top-level `function update` without `export` is
    // module-private and must be skipped silently, not dispatched.
    scripting.registerScript("unexported",
        \\function update(dt) {
        \\  labelle.log("unexported update ran");
        \\}
        \\export function init() {
        \\  labelle.log("unexported init ran");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);

    try expect(mock.logsContain("unexported init ran"));
    try expect(!mock.logsContain("unexported update ran"));
}

test "module scope isolates same-named state and hooks across scripts" {
    fresh();
    // Both scripts export `update`/`deinit` and keep module-scope `let`
    // state under the SAME names — ES-module scoping (the lua-_ENV /
    // ruby-harvest equivalent) must keep them fully apart.
    scripting.registerScript("iso_a", @embedFile("ts/iso_a.js"));
    scripting.registerScript("iso_b", @embedFile("ts/iso_b.js"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.016);
    scripting.Controller.tick(.{}, 0.016);

    try expectComponent(1, "IsoA", "{\"n\":2}");
    try expectComponent(2, "IsoB", "{\"n\":20}");

    scripting.Controller.deinit();
    try expect(mock.logsContain("iso_a deinit"));
    try expect(mock.logsContain("iso_b deinit"));
}

test "json codec round-trips; {} vs [] survive natively" {
    fresh();
    scripting.registerScript("json_roundtrip", @embedFile("ts/json_roundtrip.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Codec properties assert inside the script (a failure evicts it and
    // the components never appear); the Zig side pins the byte-exact JSON
    // after each hop — set with both empties, then get→set untouched:
    // objects stay {}, arrays stay [] with no marker needed (JS's native
    // answer to lua's labelle.array).
    try expectComponent(1, "Path", "{\"meta\":{},\"waypoints\":[]}");
    try expectComponent(1, "PathAgain", "{\"meta\":{},\"waypoints\":[]}");
    try expectComponent(2, "RoundTrip", "{\"ok\":true}");
}

test "game.query iterates the mock world's matching ids" {
    fresh();
    scripting.registerScript("query_check", @embedFile("ts/query_check.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Entities 1..3 carry Marker (sum 6), only 2 also carries Extra, the
    // bare entity 4 never shows up, unknown names yield zero matches.
    try expectComponent(5, "QueryResult", "{\"both\":1,\"count\":3,\"none\":0,\"sum\":6}");
}

test "labelle.u64str renders bit-63 ids as unsigned decimals" {
    fresh();
    scripting.registerScript("u64str_check", @embedFile("ts/u64str_check.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Exact decimals for 0, 1, 2^62, 0x8000000000000001, 0xFFFFFFFFFFFFFFFF
    // (sorted keys — see the script for which literal is which).
    try expectComponent(1, "U64Str", "{\"all_ones\":\"18446744073709551615\"," ++
        "\"high_one\":\"9223372036854775809\",\"one\":\"1\"," ++
        "\"pow62\":\"4611686018427387904\",\"zero\":\"0\"}");
}

test "game.query round-trips bit-63 entity ids exactly" {
    fresh();
    // Force the next id past the signed-integer boundary: its unsigned
    // decimal exceeds Number.MAX_SAFE_INTEGER, so any JSON.parse-style
    // float leak in the query path would round it to the wrong entity.
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("big_id_check", @embedFile("ts/big_id_check.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    // get/set through the QUERIED wrapper landed on the right entity
    // (the script's own asserts — BigInt === BigInt — would otherwise
    // fail its init, evicting it and leaving these components unset)...
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    // ...and the id renders unsigned end to end.
    try expectComponent(big_id, "BigId", "{\"idstr\":\"9223372036854775809\"}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

test "game.query grows the scratch past its initial cap and yields ALL ids" {
    fresh();
    // 420 entities with 20-digit ids ≈ 8.8 KB of id JSON — past the
    // 4 KiB initial scratch, so raw_query must see required > cap and
    // grow + retry. The base id leaves headroom for all 421 creates
    // below u64 max.
    const base: u64 = std.math.maxInt(u64) - 1000;
    mock.setNextEntityId(base);
    scripting.registerScript("big_query_check", @embedFile("ts/big_query_check.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Guard the premise first: the complete result really does exceed
    // the initial scratch capacity — probed through the same contract
    // sizing the shim uses.
    const names = "[\"Marker\"]";
    var dummy: [1]u8 = undefined;
    const required = scripting.contract.labelle_query(names.ptr, names.len, &dummy, 0);
    try expect(required > 4096);

    try expectComponent(base + 420, "BigQuery", "{\"count\":420}");
    try expectEqual(@as(usize, 421), mock.aliveCount());
}

test "labelle.on dispatch fires with decoded payloads" {
    fresh();
    scripting.registerScript("event_payload", @embedFile("ts/event_payload.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Two queued events, one tick: both drained, handlers fan out in
    // order, nested payload decoded to real objects/arrays.
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

test "eviction purges the dead scripts' handlers; siblings keep firing" {
    fresh();
    // Module-scope handler + failing init(): the init-fail eviction path
    // must take the handler with the script.
    scripting.registerScript("doomed",
        \\labelle.on("ping", (ev) => {
        \\  labelle.log("doomed handler ran");
        \\});
        \\export function init() {
        \\  throw new Error("doomed init boom");
        \\}
    );
    // Module-scope handler + failing module BODY: the load-fail eviction
    // path (the handler registered BEFORE the body threw).
    scripting.registerScript("body_boom",
        \\labelle.on("ping", (ev) => {
        \\  labelle.log("body_boom handler ran");
        \\});
        \\throw new Error("body_boom top-level");
    );
    scripting.registerScript("survivor",
        \\let state = null;
        \\labelle.on("ping", (ev) => {
        \\  const s = state.get("Pings");
        \\  s.n += 1;
        \\  state.set("Pings", s);
        \\});
        \\export function init() {
        \\  state = Entity.create();
        \\  state.set("Pings", { n: 0 });
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);

    // Both evictions logged...
    try expect(mock.logsContain("doomed init boom"));
    try expect(mock.logsContain("script evicted"));
    try expect(mock.logsContain("body_boom top-level"));
    // ...the sibling's handler saw the event (so dispatch DID run)...
    try expectComponent(1, "Pings", "{\"n\":1}");
    // ...while neither evicted script's module-scope handler fired.
    try expect(!mock.logsContain("doomed handler ran"));
    try expect(!mock.logsContain("body_boom handler ran"));

    // Later events keep flowing to the survivor only.
    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Pings", "{\"n\":2}");
    try expect(!mock.logsContain("doomed handler ran"));
    try expect(!mock.logsContain("body_boom handler ran"));
}

test "ownership survives labelle.on aliasing through script-local helpers" {
    fresh();
    // The registering call site is a module-scope helper closing over an
    // alias of labelle.on: nothing at the call site names the script, so
    // ownership must come from the VM's current-script stamp — init()
    // runs with the script stamped current, so the handler is owned by
    // "aliased" and dies with it.
    scripting.registerScript("aliased",
        \\const on = labelle.on;
        \\const sub = (n, f) => on(n, f);
        \\export function init() {
        \\  sub("ping", (ev) => {
        \\    labelle.log("aliased handler ran");
        \\  });
        \\  throw new Error("aliased init boom");
        \\}
    );
    scripting.registerScript("survivor",
        \\let state = null;
        \\labelle.on("ping", (ev) => {
        \\  const s = state.get("Pings");
        \\  s.n += 1;
        \\  state.set("Pings", s);
        \\});
        \\export function init() {
        \\  state = Entity.create();
        \\  state.set("Pings", { n: 0 });
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);

    // The eviction was logged, the sibling's handler fired…
    try expect(mock.logsContain("aliased init boom"));
    try expect(mock.logsContain("script evicted"));
    try expectComponent(1, "Pings", "{\"n\":1}");
    // …and the aliased-registration handler was purged with its owner.
    try expect(!mock.logsContain("aliased handler ran"));
}

test "a throwing handler is isolated: fan-out and drain continue, error logged once" {
    fresh();
    scripting.registerScript("isolated",
        \\let state = null;
        \\labelle.on("ping", (ev) => {
        \\  throw new Error("first handler boom");
        \\});
        \\labelle.on("ping", (ev) => {
        \\  const s = state.get("Flow");
        \\  s.pings += 1;
        \\  state.set("Flow", s);
        \\});
        \\labelle.on("pong", (ev) => {
        \\  const s = state.get("Flow");
        \\  s.pongs += 1;
        \\  state.set("Flow", s);
        \\});
        \\export function init() {
        \\  state = Entity.create();
        \\  state.set("Flow", { pings: 0, pongs: 0 });
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Two events, one tick: the FIRST ping handler throws — the second
    // must still fire (fan-out survives) and the drain must continue on
    // to pong (the queue survives), all within the same dispatch.
    mock.hostEmit("ping", "{}");
    mock.hostEmit("pong", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Flow", "{\"pings\":1,\"pongs\":1}");

    // The failure was logged exactly once, attributed (event + owner)
    // and carrying the handler's stack.
    try expectEqual(@as(usize, 1), mock.logCount("first handler boom"));
    try expect(mock.logsContain("event 'ping' handler (owner 'isolated')"));
    try expect(mock.logsContain("stack:"));

    // The throwing handler was NOT purged (errors evict scripts, not
    // handlers): next tick it throws — and is isolated — again.
    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Flow", "{\"pings\":2,\"pongs\":1}");
    try expectEqual(@as(usize, 2), mock.logCount("first handler boom"));
}

test "event payloads carry u64 ids bit-exact as BigInt" {
    fresh();
    // Bit-63 id: its unsigned decimal exceeds Number.MAX_SAFE_INTEGER, so
    // a JSON.parse-style number path would round it to an imprecise float
    // and the handler's writes would miss the entity. The Zig decoder
    // must hand the handler a BigInt instead.
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("payload_id_check", @embedFile("ts/payload_id_check.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("owner__ping", "{\"owner\":9223372036854775809}");
    scripting.Controller.tick(.{}, 0.016);

    // The handler wrapped the PAYLOAD id and wrote through it — the
    // component landing on the real u64-addressed entity is the proof
    // (the script's own asserts pin BigInt-ness and bit-equality).
    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Owned", "{\"seen\":true,\"tag\":42}");
}

test "components larger than the initial scratch round-trip via e.get" {
    fresh();
    // {"blob":"xxx…"} is ~5 KiB — past the 4 KiB initial scratch, so
    // raw_component_get sees required > cap (all-or-nothing: nothing
    // written yet), grows the scratch once and retries. A throw evicts
    // the script and BigOk never lands.
    scripting.registerScript("big_component",
        \\export function init() {
        \\  const e = Entity.create();
        \\  const blob = "x".repeat(5000);
        \\  if (!e.set("Big", { blob })) throw new Error("set refused");
        \\  const back = e.get("Big");
        \\  if (back === null) throw new Error("get returned null");
        \\  if (back.blob.length !== 5000) throw new Error(`blob truncated: ${back.blob.length}`);
        \\  if (back.blob !== blob) throw new Error("blob corrupted");
        \\  e.set("BigOk", { len: back.blob.length });
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "BigOk", "{\"len\":5000}");
}

test "event payloads larger than the initial scratch deliver intact; scratch settles" {
    fresh();
    scripting.registerScript("big_events",
        \\let state = null;
        \\const expected = "y".repeat(5000);
        \\labelle.on("blob__event", (ev) => {
        \\  const s = state.get("Blob") ?? { count: 0 };
        \\  if (typeof ev.data !== "string") throw new Error("payload missing");
        \\  if (ev.data.length !== 5000) throw new Error(`payload truncated: ${ev.data.length}`);
        \\  if (ev.data !== expected) throw new Error("payload corrupted");
        \\  state.set("Blob", { count: s.count + 1, len: ev.data.length });
        \\});
        \\export function init() {
        \\  state = Entity.create();
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // ~5 KiB payload: the poll probe reports it, the scratch grows once
    // right-sized, the real read consumes the entry whole. A truncation
    // or corruption trips the handler's throws (isolated + logged) and
    // the count below stalls.
    const payload = "{\"data\":\"" ++ ("y" ** 5000) ++ "\"}";
    mock.hostEmit("blob__event", payload);
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Blob", "{\"count\":1,\"len\":5000}");

    // 99 more deliveries: the grow-only scratch is REUSED — the growth
    // counter must not move again (no per-event reallocation).
    const settled = scripting.scratchGrowthCount();
    for (0..99) |_| {
        mock.hostEmit("blob__event", payload);
        scripting.Controller.tick(.{}, 0.016);
    }
    try expectEqual(settled, scripting.scratchGrowthCount());
    try expectComponent(1, "Blob", "{\"count\":100,\"len\":5000}");
}

test "controller lifecycle: prefab/scene/remove, deinit hooks, re-setup" {
    fresh();
    scripting.registerScript("lifecycle", @embedFile("ts/lifecycle.js"));
    try scripting.Controller.setup(.{});

    // init(): marker (1) created + Alive removed again; prefab ship (2)
    // spawned at the params position; scene switched (the "nope" arm
    // rejected inside the script via throw).
    try expect(mock.entityAlive(1));
    try expect(mock.componentJson(1, "Alive") == null);
    try expectComponent(2, "Prefab", "{\"name\":\"ship\"}");
    try expectComponent(2, "Position", "{\"x\":5,\"y\":10}");
    try expectComponent(2, "Tag", "{\"kind\":\"spawned\"}");
    try expectEqualStrings("menu", mock.sceneName());

    // deinit() hooks run before the VM closes.
    scripting.Controller.deinit();
    try expect(mock.logsContain("ts: lifecycle deinit ran"));
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
    scripting.registerScript("dup", "export function init() { Entity.create().set('V', { v: 1 }); }");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());
    // Same name = replacement, not a second script.
    scripting.registerScript("dup", "export function init() { Entity.create().set('V', { v: 2 }); }");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());

    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expectComponent(1, "V", "{\"v\":2}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

test "labelle.component refs address components through every name-taking seam" {
    fresh();
    scripting.registerScript("component_ref", @embedFile("ts/component_ref.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The script's own asserts police ref/string equivalence, query-by-ref
    // and the non-ref-object rejection (any failure evicts it and RefOk
    // never lands); the Zig side pins that the ref writes reached the SAME
    // "Hunger"/"Tag" names a string write would (Tag was removed via ref).
    try expectComponent(1, "Hunger", "{\"level\":0.5,\"starving\":false}");
    try expect(mock.componentJson(1, "Tag") == null);
    try expectComponent(1, "RefOk", "{\"ok\":true}");
}

test "FrameArray unit semantics" {
    fresh();
    scripting.registerScript("frame_array", @embedFile("ts/frame_array.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "FrameArrayOk", "{\"ok\":true}");
}

test "steady-state allocation: into-refills + FrameArray hold the live malloc count flat" {
    fresh();
    scripting.registerScript("steady_alloc", @embedFile("ts/steady_alloc.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // 105 ticks: 5 warm-up (shapes, inline caches, scratch growth), then
    // a GC to settle any warm-up cycles and a baseline of QuickJS's LIVE
    // malloc count (JS_ComputeMemoryUsage.malloc_count — refcounting
    // frees acyclic garbage at last reference, so net-zero ticks keep it
    // EXACTLY constant; the mruby disabled-GC live-count's equivalent).
    // The script asserts per tick that the counter sits at its baseline
    // across 100 working ticks of get(into)/set/FrameArray traffic; any
    // per-tick accretion (leaked handle, growing cache, cyclic garbage)
    // moves it and fails the verdict below. FrameArray growth would show
    // in `growth`.
    for (0..105) |_| {
        scripting.Controller.tick(.{}, 0.02);
    }
    try expectComponent(1, "SteadyAlloc", "{\"count\":1050," ++
        "\"growth\":0,\"live_ok\":true,\"ticks\":105}");

    // The measured window's component writes really happened (the loop
    // ran 10 rounds × 105 ticks against the live component).
    const hot = mock.componentJson(1, "Hot") orelse return error.TestExpectedComponent;
    try expect(std.mem.indexOf(u8, hot, "\"count\":1050") != null);
}

// ── Console eval (labelle-scripting#4) ──────────────────────────────────

test "console eval renders expression results" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const r = scripting.Controller.evalCommand("1+2");
    try expect(r.ok);
    try expectEqualStrings("3", r.text);

    // Plain objects render through JSON.stringify (the parens keep the
    // braces an expression rather than a block).
    const obj = scripting.Controller.evalCommand("({a: 1})");
    try expect(obj.ok);
    try expectEqualStrings("{\"a\":1}", obj.text);
}

test "console eval persists state across evals on the shared globals" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Global-mode eval: the assignment's completion value renders and
    // the binding lands on globalThis for the next eval.
    const set = scripting.Controller.evalCommand("x = 5");
    try expect(set.ok);
    try expectEqualStrings("5", set.text);

    const get = scripting.Controller.evalCommand("x");
    try expect(get.ok);
    try expectEqualStrings("5", get.text);
}

test "console eval errors carry message and stack; VM and tick survive" {
    fresh();
    scripting.registerScript("counter", @embedFile("ts/counter.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);

    const err = scripting.Controller.evalCommand("throw new Error(\"console boom\")");
    try expect(!err.ok);
    try expect(std.mem.indexOf(u8, err.text, "Error: console boom") != null);
    try expect(std.mem.indexOf(u8, err.text, "console") != null);

    // Syntax errors surface the same isolated way...
    const bad = scripting.Controller.evalCommand("function (");
    try expect(!bad.ok);
    try expect(std.mem.indexOf(u8, bad.text, "SyntaxError") != null);

    // ...the VM survived: the next eval works...
    const again = scripting.Controller.evalCommand("1+1");
    try expect(again.ok);
    try expectEqualStrings("2", again.text);

    // ...and the tick keeps driving the registered scripts.
    scripting.Controller.tick(.{}, 0.125);
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "console eval reaches the game world through the labelle API" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const r = scripting.Controller.evalCommand("Entity.create().set(\"FromEval\", {a: 1})");
    try expect(r.ok);
    try expectEqualStrings("true", r.text);
    try expectComponent(1, "FromEval", "{\"a\":1}");
}

test "console eval bounds oversized results into valid truncated response JSON" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand(
        "{\"code\":\"\\\"x\\\".repeat(9000)\"}",
        &buf,
    );
    try expect(response.len <= scripting.eval.max_response_len);
    const parsed = try std.json.parseFromSlice(
        struct { ok: bool, value: []const u8 },
        std.testing.allocator,
        response,
        .{},
    );
    defer parsed.deinit();
    try expect(parsed.value.ok);
    try expect(std.mem.startsWith(u8, parsed.value.value, "xxxx"));
    try expect(std.mem.endsWith(u8, parsed.value.value, scripting.eval.truncation_marker));
}

test "console eval during ticking leaves registered scripts undisturbed" {
    fresh();
    scripting.registerScript("counter", @embedFile("ts/counter.js"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    const r = scripting.Controller.evalCommand("globalThis.session_note = \"between ticks\"");
    try expect(r.ok);
    scripting.Controller.tick(.{}, 0.125);

    // The counter advanced exactly twice — the eval neither consumed a
    // tick nor disturbed the script registry.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "console eval: a failing microtask never masks the sync eval error" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The eval queues a microtask that ITSELF throws, then throws
    // synchronously. The context has ONE pending-exception slot: the
    // response must carry the SYNC error (captured before the job
    // drain), while the job's failure surfaces through the log — the
    // handler throw is caught by the promise machinery (the derived
    // promise rejects; ExecutePendingJob returns clean), so it reaches
    // the log via the unhandled-rejection tracker, not the rc<0 leg.
    const r = scripting.Controller.evalCommand(
        "Promise.resolve().then(() => { throw new Error(\"job boom\") }); throw new Error(\"eval boom\")",
    );
    try expect(!r.ok);
    try expect(std.mem.indexOf(u8, r.text, "eval boom") != null);
    try expect(std.mem.indexOf(u8, r.text, "job boom") == null);
    try expect(mock.logsContain("unhandled promise rejection"));
    try expect(mock.logsContain("job boom"));

    // Jobs-only (no sync throw): result unaffected, rejection logged —
    // the drain still runs on the success path exactly as before.
    const ok_case = scripting.Controller.evalCommand(
        "Promise.resolve().then(() => { throw new Error(\"job2 boom\") }); 42",
    );
    try expect(ok_case.ok);
    try expectEqualStrings("42", ok_case.text);
    try expect(mock.logsContain("job2 boom"));
}

test "console eval: lone surrogates render into valid UTF-8 response JSON" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // JS strings are UTF-16 and can hold unpaired surrogates; whatever
    // byte shape ToCString picks for one (U+FFFD directly, or CESU-8
    // surrogate bytes the response builder then replaces), the response
    // must stay valid UTF-8 JSON. Soft-pin the bookends only.
    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand(
        "{\"code\":\"\\\"a\\\" + String.fromCharCode(0xD800) + \\\"z\\\"\"}",
        &buf,
    );
    try expect(std.unicode.utf8ValidateSlice(response));
    const parsed = try std.json.parseFromSlice(
        struct { ok: bool, value: []const u8 },
        std.testing.allocator,
        response,
        .{},
    );
    defer parsed.deinit();
    try expect(parsed.value.ok);
    try expect(std.mem.startsWith(u8, parsed.value.value, "a"));
    try expect(std.mem.endsWith(u8, parsed.value.value, "z"));
}

// ── bulk component access (contract v1.3, labelle-scripting#44) ──────────
// The typescript port of the ruby suite's bulk coverage: packed codec
// fast path (+ JSON fallbacks), batch_get/batch_set round-trip +
// refusals, and the callback iterator (early-return commits, throw
// aborts). JS-specific pins: integral doubles tag as i64 on the packed
// set (JS has one number type), and 64-bit values past 2^53 materialize
// as BigInt on the packed get — exactly the JSON decoder's line.

test "bulk v1.3: packed codec rides the get-into/set fast path, JSON stays the fallback" {
    fresh();
    // "Stats" is in the mock's packed schema table (one field per scalar
    // kind); "Plain" is NOT — its set/get must degrade to the JSON path
    // (set_packed -1 / get_packed 0xFF), invisibly to the script.
    scripting.registerScript("packed_rt",
        \\export function init() {
        \\  const e = Entity.create();
        \\  if (!e.set("Stats", { power: 1.5, score: -42, alive: true, seed: 123 }))
        \\    throw new Error("packed set refused");
        \\  const s = {};
        \\  if (e.get("Stats", s) === null) throw new Error("packed get_into failed");
        \\  labelle.log(`packed:${s.power}:${s.score}:${s.alive}:${s.seed}`);
        \\  if (!e.set("Plain", { a: 2.5 })) throw new Error("plain set refused");
        \\  const p = {};
        \\  if (e.get("Plain", p) === null) throw new Error("plain get_into failed");
        \\  labelle.log(`plain:${p.a}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Every field kind survived the binary round-trip (f32/i64/bool/u64).
    try expect(mock.logsContain("packed:1.5:-42:true:123"));
    // The stored JSON is in the mock's SCHEMA order (power,score,alive,
    // seed) — the packed set wrote it. The JSON encoder would have sorted
    // the keys (alive,power,score,seed), so key order proves the path.
    try expectComponent(1, "Stats", "{\"power\":1.5,\"score\":-42,\"alive\":true,\"seed\":123}");
    // The schema-less component still round-trips — through JSON.
    try expect(mock.logsContain("plain:2.5"));
    try expectComponent(1, "Plain", "{\"a\":2.5}");
}

test "bulk v1.3: integral doubles tag as i64 on the packed set (never through f32's mantissa)" {
    fresh();
    // JS has ONE number type: 1e15 is an integral double far past f32's
    // 24-bit mantissa. The JSON encoder renders it "1000000000000000"
    // (integral-when-integral) and the packed set must land the SAME
    // exact value in the i64 field — so integral doubles within ±2^53
    // tag as i64, never f32. The schema-order stored JSON proves the
    // packed path carried it.
    scripting.registerScript("packed_integral",
        \\export function init() {
        \\  const e = Entity.create();
        \\  if (!e.set("Stats", { power: 2.5, score: 1e15, alive: false, seed: 7 }))
        \\    throw new Error("set refused");
        \\  const s = {};
        \\  if (e.get("Stats", s) === null) throw new Error("get_into failed");
        \\  labelle.log(`integral:${s.score === 1e15}:${typeof s.score}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("integral:true:number"));
    try expectComponent(1, "Stats", "{\"power\":2.5,\"score\":1000000000000000,\"alive\":false,\"seed\":7}");
}

test "bulk v1.3: batch_get/batch_set round-trip the whole query as one f32 stream" {
    fresh();
    scripting.registerScript("batch_rt",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\const buf = [];
        \\export function init() {
        \\  for (let i = 1; i <= 3; i++) {
        \\    const e = Entity.create();
        \\    e.set("BatchPos", { x: i, y: 0 });
        \\    e.set("BatchVel", { vx: 10, vy: -10 });
        \\  }
        \\  const lone = Entity.create();
        \\  lone.set("BatchPos", { x: 7, y: 8 });
        \\}
        \\export function update(dt) {
        \\  const count = labelle.batch_get(NAMES, buf);
        \\  labelle.log(`batch count:${count} floats:${buf.length}`);
        \\  for (let i = 0; i < count; i++) {
        \\    const b = i * 4;
        \\    buf[b] += buf[b + 2];     // x += vx
        \\    buf[b + 1] += buf[b + 3]; // y += vy
        \\  }
        \\  labelle.batch_set(NAMES, buf, count);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // 3 matching entities (the lone BatchPos-only one is filtered out),
    // stride 4 → the reused Array holds exactly 12 floats.
    try expect(mock.logsContain("batch count:3 floats:12"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(2, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(3, "BatchPos", "{\"x\":13,\"y\":-10}");
    // A second tick reuses the same Array and advances again — the
    // steady-state shape.
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "BatchPos", "{\"x\":21,\"y\":-20}");
    try expectComponent(3, "BatchPos", "{\"x\":23,\"y\":-20}");
    // The filtered-out entity was never rewritten.
    try expectComponent(4, "BatchPos", "{\"x\":7,\"y\":8}");
}

test "bulk v1.3: batch refuses int-carrying components loudly (never a silent coercion)" {
    fresh();
    // "Stats" carries i64/u64 fields → the host refuses the whole batch
    // ((size_t)-2 from batch_get, -2 from batch_set) and the binding
    // throws TypeError — int corruption through f32 must be loud, never
    // a silent fallback.
    scripting.registerScript("batch_refuse",
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("Stats", { power: 1, score: 5, alive: true, seed: 9 });
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  try {
        \\    labelle.batch_get(["BatchPos", "Stats"], []);
        \\    labelle.log("get refusal missed");
        \\  } catch (err) {
        \\    labelle.log(`get refused (${err.constructor.name}): ${err.message}`);
        \\  }
        \\  try {
        \\    labelle.batch_set(["Stats"], [1.0, 2.0, 3.0, 4.0], 1);
        \\    labelle.log("set refusal missed");
        \\  } catch (err) {
        \\    labelle.log(`set refused: ${err.message}`);
        \\  }
        \\  labelle.log("still alive");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("get refusal missed"));
    try expect(!mock.logsContain("set refusal missed"));
    // The throw names its class, the refused component list and the reason.
    try expect(mock.logsContain("get refused (TypeError): labelle: batch refused for [\"BatchPos\",\"Stats\"]"));
    try expect(mock.logsContain("int-typed"));
    try expect(mock.logsContain("set refused: labelle: batch refused for [\"Stats\"]"));
    // The throw is catchable — the script kept running.
    try expect(mock.logsContain("still alive"));
    // And nothing was written through the refused paths.
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
}

test "bulk v1.3: batch_set throws when the entity set changed since batch_get" {
    fresh();
    scripting.registerScript("batch_stale",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\const es = [];
        \\const buf = [];
        \\export function init() {
        \\  for (let i = 0; i < 2; i++) {
        \\    const e = Entity.create();
        \\    e.set("BatchPos", { x: i, y: 0 });
        \\    e.set("BatchVel", { vx: 1, vy: 1 });
        \\    es.push(e);
        \\  }
        \\}
        \\export function update(dt) {
        \\  const count = labelle.batch_get(NAMES, buf);
        \\  es[1].destroy(); // the forbidden move: destroy between get and set
        \\  try {
        \\    labelle.batch_set(NAMES, buf, count);
        \\    labelle.log("stale write accepted");
        \\  } catch (err) {
        \\    labelle.log(`stale refused (${err.constructor.name}): ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // The exact-size positional-coupling guard fired and surfaced as a
    // catchable plain Error telling the script to re-get.
    try expect(!mock.logsContain("stale write accepted"));
    try expect(mock.logsContain("stale refused (Error):"));
    try expect(mock.logsContain("entity set changed"));
}

test "bulk stage 3: the labelle.batch callback iterator round-trips through ONE reused view" {
    fresh();
    scripting.registerScript("batch_block",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\export function init() {
        \\  for (let i = 1; i <= 3; i++) {
        \\    const e = Entity.create();
        \\    e.set("BatchPos", { x: i, y: 0 });
        \\    e.set("BatchVel", { vx: 10, vy: -10 });
        \\  }
        \\}
        \\export function update(dt) {
        \\  let same = 0;
        \\  let seen = null;
        \\  const n = labelle.batch(NAMES, (e) => {
        \\    if (seen === null) seen = e;
        \\    if (seen === e) same += 1; // view REUSE: one object across calls
        \\    e.x += e.vx;
        \\    e.y += e.vy;
        \\    if (e.x > 12.0) e.vx = -e.vx; // bounce entity 3 (x reaches 13)
        \\  });
        \\  labelle.log(`block n:${n} same_view:${same}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // 3 entities, every call saw the SAME view object, count returned.
    try expect(mock.logsContain("block n:3 same_view:3"));
    // The callback's writes landed through the one batch_set: accessors
    // mapped [x, y, vx, vy] exactly as the stream is laid out.
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(2, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(3, "BatchPos", "{\"x\":13,\"y\":-10}");
    try expectComponent(3, "BatchVel", "{\"vx\":-10,\"vy\":-10}");
    try expectComponent(1, "BatchVel", "{\"vx\":10,\"vy\":-10}");
    // Second tick rides the CACHED view — steady state advances again
    // (entity 3 now moves backward with its flipped vx).
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "BatchPos", "{\"x\":21,\"y\":-20}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":-20}");
}

test "bulk stage 3: labelle.batch on an empty result never calls the callback" {
    fresh();
    scripting.registerScript("batch_block_empty",
        \\export function init() {
        \\  try {
        \\    labelle.batch(["BatchPos", "BatchVel"]);
        \\    labelle.log("callback-less accepted");
        \\  } catch (err) {
        \\    labelle.log(`callback-less refused: ${err.message}`);
        \\  }
        \\  const n = labelle.batch(["BatchPos", "BatchVel"], (e) => labelle.log("callback ran"));
        \\  labelle.log(`empty n:${n}`);
        \\  try {
        \\    labelle.batch([], (e) => {});
        \\    labelle.log("empty names accepted");
        \\  } catch (err) {
        \\    labelle.log(`empty names refused: ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // No callback is a caller bug — refused up front, even on an empty set.
    try expect(!mock.logsContain("callback-less accepted"));
    try expect(mock.logsContain("callback-less refused: labelle.batch requires a callback function"));
    // No matching entities: 0 returned, the callback never ran.
    try expect(!mock.logsContain("callback ran"));
    try expect(mock.logsContain("empty n:0"));
    try expect(!mock.logsContain("empty names accepted"));
    try expect(mock.logsContain("empty names refused: labelle.batch: expected at least one component name"));
}

test "bulk stage 3: labelle.batch refuses ambiguous and probe-defeating layouts loudly" {
    fresh();
    scripting.registerScript("batch_block_refuse",
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  e.set("Plain", { a: 2.5 });
        \\  // The same component named twice: every field name collides —
        \\  // the view could not disambiguate e.x, so it must not exist.
        \\  try {
        \\    labelle.batch(["BatchPos", "BatchPos"], (v) => {});
        \\    labelle.log("dup accepted");
        \\  } catch (err) {
        \\    labelle.log(`dup refused: ${err.message}`);
        \\  }
        \\  // "Plain" has no schema — it contributes ZERO stream floats
        \\  // (the mock's stand-in for a non-scalar component) while its
        \\  // JSON shows a number, so the derived layout cannot match the
        \\  // stream stride. The cross-check must refuse, never mis-map.
        \\  try {
        \\    labelle.batch(["BatchPos", "Plain"], (v) => {});
        \\    labelle.log("mismatch accepted");
        \\  } catch (err) {
        \\    labelle.log(`mismatch refused: ${err.message}`);
        \\  }
        \\  labelle.log("still alive");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("dup accepted"));
    try expect(mock.logsContain("dup refused:"));
    try expect(mock.logsContain("appears in more than one named component"));
    try expect(!mock.logsContain("mismatch accepted"));
    try expect(mock.logsContain("mismatch refused:"));
    try expect(mock.logsContain("does not match the host stream"));
    // Both throws are catchable; nothing was written through either.
    try expect(mock.logsContain("still alive"));
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
}

test "bulk stage 3: labelle.batch surfaces batch_get's throw and a throwing callback writes NOTHING" {
    fresh();
    scripting.registerScript("batch_block_errors",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 5, y: 6 });
        \\  e.set("BatchVel", { vx: 1, vy: 1 });
        \\  // A THROWING callback abandons the WHOLE batch: it unwinds out
        \\  // of labelle.batch before the write, so batch_set never runs
        \\  // and the mutation before the throw is not applied.
        \\  try {
        \\    labelle.batch(NAMES, (v) => {
        \\      v.x = 999.0;
        \\      throw new Error("boom");
        \\    });
        \\    labelle.log("throw swallowed");
        \\  } catch (err) {
        \\    labelle.log(`callback threw: ${err.message}`);
        \\  }
        \\  // Unsupported-host parity: labelle.batch's first act IS
        \\  // raw_batch_get, so a host without batch support surfaces the
        \\  // exact same throw. Prove the pass-through (and that batch_set
        \\  // is never reached) by stubbing raw_batch_get to throw the
        \\  // pre-v1.3 message verbatim.
        \\  labelle.raw_batch_get = () => {
        \\    throw new Error(
        \\      "labelle: batch_get — the host engine lacks batch support " +
        \\        "(script contract v1.3 needs labelle-engine >= 2.6.0); " +
        \\        "use per-entity get/set on this engine",
        \\    );
        \\  };
        \\  labelle.raw_batch_set = () => labelle.log("batch_set reached");
        \\  try {
        \\    labelle.batch(NAMES, (v) => labelle.log("callback ran on old host"));
        \\    labelle.log("old host accepted");
        \\  } catch (err) {
        \\    labelle.log(`old host refused: ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The callback's throw propagated and nothing was written.
    try expect(!mock.logsContain("throw swallowed"));
    try expect(mock.logsContain("callback threw: boom"));
    try expectComponent(1, "BatchPos", "{\"x\":5,\"y\":6}");
    // The unsupported-host throw passed through IDENTICALLY; the callback
    // never ran and batch_set was never reached.
    try expect(!mock.logsContain("old host accepted"));
    try expect(!mock.logsContain("callback ran on old host"));
    try expect(!mock.logsContain("batch_set reached"));
    try expect(mock.logsContain("old host refused: labelle: batch_get — the host engine lacks batch support"));
}

test "bulk stage 3: returning false from the callback COMMITS the writes made so far" {
    fresh();
    // Early-exit semantics: the callback returning `false` (strictly) is
    // the iterator early-exit — everything written up to that point
    // flushes through the one batch_set (entities not yet visited write
    // back unchanged); only a THROW aborts (previous test). Any other
    // return value (undefined included) continues the iteration.
    scripting.registerScript("batch_block_break",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\const early = (limit) =>
        \\  labelle.batch(NAMES, (e) => {
        \\    e.x += 100.0;
        \\    if (e.x > limit) return false;
        \\  });
        \\export function init() {
        \\  for (let i = 1; i <= 3; i++) {
        \\    const e = Entity.create();
        \\    e.set("BatchPos", { x: i, y: 0 });
        \\    e.set("BatchVel", { vx: 0, vy: 0 });
        \\  }
        \\  const r = labelle.batch(NAMES, (e) => {
        \\    e.x += 10.0;
        \\    return false; // stop after the first entity — and COMMIT
        \\  });
        \\  labelle.log(`stop r:${r}`);
        \\  labelle.log(`early r:${early(50)}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The count comes back on the commit paths (early stop included).
    try expect(mock.logsContain("stop r:3"));
    try expect(mock.logsContain("early r:3"));
    // stop after mutating entity 1 only: its write COMMITTED, the
    // not-yet-visited entities round-tripped unchanged (x stays 2 / 3)...
    // then early(50) mutated entity 1 again (11 + 100) and stopped.
    try expectComponent(1, "BatchPos", "{\"x\":111,\"y\":0}");
    try expectComponent(2, "BatchPos", "{\"x\":2,\"y\":0}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":0}");
}

test "bulk stage 3: single-name coercion and the discovery race" {
    fresh();
    scripting.registerScript("batch_block_round1",
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  // Single non-array name is coerced ([name]).
        \\  const n = labelle.batch("BatchPos", (v) => {
        \\    v.x += 1.0;
        \\  });
        \\  labelle.log(`single n:${n}`);
        \\  // Discovery race: batch_get saw entities but the layout probe's
        \\  // re-query comes back empty (entity destroyed mid-tick) — a
        \\  // clear throw, not a low-level undefined error. Stub the
        \\  // re-query leg to force the race deterministically (an UNCACHED
        \\  // names-set, so first-use discovery actually runs).
        \\  e.set("BatchVel", { vx: 1, vy: 1 });
        \\  labelle.raw_query = () => [];
        \\  try {
        \\    labelle.batch(["BatchVel"], (v) => {});
        \\    labelle.log("race accepted");
        \\  } catch (err) {
        \\    labelle.log(`race refused: ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("single n:1"));
    try expectComponent(1, "BatchPos", "{\"x\":2,\"y\":2}");
    try expect(!mock.logsContain("race accepted"));
    try expect(mock.logsContain("race refused:"));
    try expect(mock.logsContain("vanished between batch_get and layout discovery"));
}

test "bulk v1.3: an unrepresentable packed value falls back to JSON end-to-end" {
    fresh();
    // score is an i64 in the mock's Stats schema; a JS 1e30 is finite and
    // integral but past 2^53, so it tags f32 — and f32 1e30 is out of i64
    // range, so the host REFUSES the packed set (-1, engine parity:
    // refuse, never clamp) and the binding falls back to the JSON path —
    // which encodes the value faithfully.
    scripting.registerScript("packed_range",
        \\export function init() {
        \\  const e = Entity.create();
        \\  if (!e.set("Stats", { power: 1.5, score: 1e30, alive: true, seed: 9 }))
        \\    throw new Error("set failed");
        \\  labelle.log("range done");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("range done"));
    // SORTED keys = the JSON encoder wrote it (the packed set stores
    // schema order: power,score,alive,seed) — proof the refusal engaged
    // the fallback. Order-assert instead of byte-assert: the encoder's
    // 1e30 rendering is not part of this pin.
    const json = mock.componentJson(1, "Stats") orelse return error.TestExpectedComponent;
    const ia = std.mem.indexOf(u8, json, "\"alive\"") orelse return error.TestExpectedKey;
    const ip = std.mem.indexOf(u8, json, "\"power\"") orelse return error.TestExpectedKey;
    const isc = std.mem.indexOf(u8, json, "\"score\"") orelse return error.TestExpectedKey;
    const isd = std.mem.indexOf(u8, json, "\"seed\"") orelse return error.TestExpectedKey;
    try expect(ia < ip and ip < isc and isc < isd);
}

test "bulk v1.3: 64-bit values round-trip as BigInt through the packed pair" {
    fresh();
    // seed (u64 schema kind) holds 0x8000000000000001 — past 2^53, so the
    // value lives in JS as BigInt (Number would round it to the wrong
    // value): SET wraps the BigInt mod 2^64 into the i64 tag (the
    // documented two's-complement bitcast pair), the host bitcasts into
    // the u64 field, GET emits tag 3 and the binding materializes the
    // unsigned BigInt — bit-exact end to end, exactly the JSON decoder's
    // Number/BigInt line.
    scripting.registerScript("packed_u64",
        \\export function init() {
        \\  const e = Entity.create();
        \\  if (!e.set("Stats", { power: 0.0, score: 0, alive: false, seed: 9223372036854775809n }))
        \\    throw new Error("set failed");
        \\  const s = {};
        \\  if (e.get("Stats", s) === null) throw new Error("get_into failed");
        \\  labelle.log(`u64rt:${s.seed === 9223372036854775809n}:${typeof s.seed}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("u64rt:true:bigint"));
    // The host stored the UNSIGNED value (the packed set's schema-order
    // serialization proves the packed path carried it, not JSON).
    try expectComponent(1, "Stats", "{\"power\":0,\"score\":0,\"alive\":false,\"seed\":9223372036854775809}");
}

test "bulk v1.3: non-finite floats take the same refusal on the packed and JSON routes" {
    fresh();
    // Parity pin: the JSON encoder throws TypeError ("json_encode:
    // non-finite number") on NaN/Inf. The packed fast path must not
    // smuggle those into the host, so it bails to the JSON fallback —
    // which throws the SAME canonical error. Both routes agree: one
    // refusal, nothing stored.
    scripting.registerScript("packed_nonfinite",
        \\export function init() {
        \\  const e = Entity.create();
        \\  try {
        \\    e.set("Stats", { power: NaN, score: 0, alive: false, seed: 0 });
        \\    labelle.log("nan accepted");
        \\  } catch (err) {
        \\    labelle.log(`nan refused: ${err.message}`);
        \\  }
        \\  try {
        \\    e.set("Stats", { power: Infinity });
        \\    labelle.log("inf accepted");
        \\  } catch (err) {
        \\    labelle.log(`inf refused: ${err.message}`);
        \\  }
        \\  labelle.log("nonfinite done");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("nan accepted"));
    try expect(!mock.logsContain("inf accepted"));
    // Same canonical message from both entry points.
    try expect(mock.logsContain("nan refused: labelle: json_encode: non-finite number"));
    try expect(mock.logsContain("inf refused: labelle: json_encode: non-finite number"));
    try expect(mock.logsContain("nonfinite done"));
    // Nothing was stored by either refusal.
    try expect(mock.componentJson(1, "Stats") == null);
}

test "bulk stage 3: batch_set refuses non-numbers and non-finite elements before any write" {
    fresh();
    // Round-1 review (PR #48): NaN/Infinity would ride straight into
    // component fields through the f32 stream — they now refuse AT THE
    // BINDING as the canonical non-finite TypeError, naming the element,
    // with nothing handed to the host (the json_encode non-finite policy
    // applied to the stream; ruby's identical gap retrofits via #45).
    scripting.registerScript("batch_set_strict",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  e.set("BatchVel", { vx: 3, vy: 4 });
        \\  const buf = [];
        \\  const count = labelle.batch_get(NAMES, buf);
        \\  buf[1] = "9"; // strings never coerce into the stream
        \\  try {
        \\    labelle.batch_set(NAMES, buf, count);
        \\    labelle.log("string accepted");
        \\  } catch (err) {
        \\    labelle.log(`string refused (${err.constructor.name}): ${err.message}`);
        \\  }
        \\  buf[1] = NaN;
        \\  try {
        \\    labelle.batch_set(NAMES, buf, count);
        \\    labelle.log("nan accepted");
        \\  } catch (err) {
        \\    labelle.log(`nan refused: ${err.message}`);
        \\  }
        \\  buf[1] = Infinity;
        \\  try {
        \\    labelle.batch_set(NAMES, buf, count);
        \\    labelle.log("inf accepted");
        \\  } catch (err) {
        \\    labelle.log(`inf refused: ${err.message}`);
        \\  }
        \\  // The callback-iterator path hits the same guard at commit
        \\  // time: the trailing batch_set throws out of labelle.batch.
        \\  try {
        \\    labelle.batch(NAMES, (d) => {
        \\      d.y = NaN;
        \\    });
        \\    labelle.log("view nan accepted");
        \\  } catch (err) {
        \\    labelle.log(`view nan refused: ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("string accepted"));
    try expect(mock.logsContain("string refused (TypeError): labelle: batch_set: array element 1 is not a number"));
    try expect(!mock.logsContain("nan accepted"));
    try expect(mock.logsContain("nan refused: labelle: batch_set: non-finite number at element 1"));
    try expect(!mock.logsContain("inf accepted"));
    try expect(mock.logsContain("inf refused: labelle: batch_set: non-finite number at element 1"));
    try expect(!mock.logsContain("view nan accepted"));
    try expect(mock.logsContain("view nan refused: labelle: batch_set: non-finite number at element 1"));
    // Every refusal fired BEFORE any host write — both components keep
    // their original values.
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
    try expectComponent(1, "BatchVel", "{\"vx\":3,\"vy\":4}");
}

test "bulk stage 3: a single component ref (and refs in lists) drive labelle.batch" {
    fresh();
    // The component_name contract shared with Entity get/set and
    // game.query: labelle.batch takes a single name string, a single
    // labelle.component REF, or a list mixing both.
    scripting.registerScript("batch_ref",
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  e.set("BatchVel", { vx: 1, vy: 1 });
        \\  const Ref = labelle.component("BatchPos");
        \\  const n = labelle.batch(Ref, (v) => {
        \\    v.x += 1.0;
        \\  });
        \\  labelle.log(`ref n:${n}`);
        \\  const mn = labelle.batch([Ref, "BatchVel"], (v) => {});
        \\  labelle.log(`mix n:${mn}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("ref n:1"));
    try expect(mock.logsContain("mix n:1"));
    try expectComponent(1, "BatchPos", "{\"x\":2,\"y\":2}");
}

test "bulk v1.3 (#45 review): overflow floats ride the f64 tag (no throw); non-packable sets keep the JSON fallback" {
    fresh();
    // A finite float beyond ±f32 range is NOT refused at the binding
    // (codex #53): the binding cannot know the target field width, and
    // such a value is legitimate for an f64 field. It rides the SET-side
    // f64 tag, and the host coerces per field type. Two legs:
    //   1. Overflow on a PACKABLE component — the set SUCCEEDS (host
    //      narrows, parity with JSON); the OLD binding threw here.
    //   2. A NON-PACKABLE component (not in the packed schema) — the
    //      lossy 0.1 rides tag 4, set_from refuses (-1), and the JSON
    //      encoder stores it (the fallback the #50/precision work must
    //      not break).
    scripting.registerScript("packed_fallback",
        \\export function init() {
        \\  const e = Entity.create();
        \\  const ok1 = e.set("BatchPos", { x: 1e39, y: 0 });
        \\  labelle.log(`overflow set:${ok1}`);
        \\  const e2 = Entity.create();
        \\  const ok2 = e2.set("Widget", { a: 0.1, n: 7 });
        \\  labelle.log(`widget set:${ok2}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // No throw on either — the overflow set committed, and the
    // non-packable set fell through to the JSON encoder.
    try expect(mock.logsContain("overflow set:true"));
    try expect(mock.logsContain("widget set:true"));
    const j = mock.componentJson(2, "Widget") orelse return error.TestExpectedComponent;
    try expect(std.mem.indexOf(u8, j, "\"a\":0.1") != null);
    try expect(std.mem.indexOf(u8, j, "\"n\":7") != null);
}

test "bulk stage 3 (#45): batch_set refuses finite elements beyond ±f32 max before any write" {
    fresh();
    // The batch twin of the packed-path guard above: finiteness is
    // asserted AFTER the f32 narrow, so 1e100 refuses with the same
    // loudness as NaN/Inf — nothing handed to the host.
    scripting.registerScript("batch_overflow",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  e.set("BatchVel", { vx: 3, vy: 4 });
        \\  const buf = [];
        \\  const count = labelle.batch_get(NAMES, buf);
        \\  buf[1] = 1e100; // finite at f64, inf after the f32 narrow
        \\  try {
        \\    labelle.batch_set(NAMES, buf, count);
        \\    labelle.log("huge accepted");
        \\  } catch (err) {
        \\    labelle.log(`huge refused: ${err.message}`);
        \\  }
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("huge accepted"));
    try expect(mock.logsContain("huge refused: labelle: batch_set: element 1 overflows f32 range"));
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
    try expectComponent(1, "BatchVel", "{\"vx\":3,\"vy\":4}");
}

test "bulk v1.3 (#45): a float past f32 precision reaches int fields exactly (SET tag 4)" {
    fresh();
    // 16777217 (2^24 + 1) is the first integer f32 cannot hold, but in
    // JS it is a Number ≤ 2^53 so it already tags as i64 (exact). The
    // f64 SET tag (4) matters for a NON-integral Number destined for a
    // FLOAT field beyond f32 precision: it carries full f64 precision to
    // the host, which narrows into the f32 field — identical to the JSON
    // route. Here 0.1 (which f32 cannot hold exactly) rides tag 4.
    scripting.registerScript("packed_precision",
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("Stats", { power: 0.1, score: 16777217, alive: true, seed: 1 });
        \\  labelle.log("precision done");
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("precision done"));
    // SCHEMA order proves the packed path carried it (the JSON fallback
    // sorts keys); the score is EXACT.
    try expectComponent(1, "Stats", "{\"power\":0.1,\"score\":16777217,\"alive\":true,\"seed\":1}");
}

test "bulk stage 3 (#50): a typo'd batch-view field write throws instead of silently vanishing" {
    fresh();
    // The reused batch view is sealed behind a Proxy: writing a field
    // the view does NOT have (`e.xx`, a typo) throws a TypeError naming
    // the field and the known fields — a bare object would grow an
    // ordinary `xx` property, the backing buffer untouched, and the
    // subsequent batch_set would commit with the intended write silently
    // absent. Known-field writes are unaffected.
    scripting.registerScript("view_seal",
        \\const NAMES = ["BatchPos", "BatchVel"];
        \\export function init() {
        \\  const e = Entity.create();
        \\  e.set("BatchPos", { x: 1, y: 2 });
        \\  e.set("BatchVel", { vx: 3, vy: 4 });
        \\  try {
        \\    labelle.batch(NAMES, (v) => {
        \\      v.xx = v.x + 1; // typo — not a view field
        \\    });
        \\    labelle.log("typo accepted");
        \\  } catch (err) {
        \\    labelle.log(`typo refused (${err.constructor.name}): ${err.message}`);
        \\  }
        \\  // SYMBOL keys pass straight through (gemini #53): runtimes and
        \\  // test frameworks legitimately stamp Symbol-keyed internals on
        \\  // any object — those are never a field typo, so the trap must
        \\  // not throw on them (only unknown STRING keys are typos).
        \\  try {
        \\    labelle.batch(NAMES, (v) => {
        \\      v[Symbol("tag")] = 1; // internal marker — must NOT throw
        \\    });
        \\    labelle.log("symbol accepted");
        \\  } catch (err) {
        \\    labelle.log(`symbol refused: ${err.message}`);
        \\  }
        \\  // A KNOWN-field write still lands: the seal only rejects
        \\  // unknown STRING props.
        \\  const n = labelle.batch(NAMES, (v) => {
        \\    v.x = v.x + 10;
        \\  });
        \\  labelle.log(`known n:${n}`);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("typo accepted"));
    try expect(mock.logsContain("typo refused (TypeError): labelle.batch view: unknown field 'xx'"));
    // A Symbol key passed through the trap without throwing.
    try expect(!mock.logsContain("symbol refused:"));
    try expect(mock.logsContain("symbol accepted"));
    // The typo'd batch committed NOTHING through its silent property:
    // x is unchanged by that call (still 1). The known-field write then
    // moved it to 11.
    try expect(mock.logsContain("known n:1"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":2}");
}
