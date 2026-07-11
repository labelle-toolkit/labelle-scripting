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
