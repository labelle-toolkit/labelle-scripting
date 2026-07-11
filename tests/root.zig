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

// The declare-mode extractor goldens (tools/declare via the `declare_core`
// named module) ride the same test binary: its lua externs resolve against
// the lua objects `labelle_scripting` already compiled in.
test {
    _ = @import("declare_tool.zig");
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

test "a chunk whose body errors is evicted before any hook fires" {
    fresh();
    scripting.registerScript("half_baked",
        \\-- update/deinit land in the env BEFORE the body errors; without
        \\-- eviction the registry would still dispatch to them.
        \\function update(dt)
        \\    labelle.log("half_baked update ran")
        \\end
        \\function deinit()
        \\    labelle.log("half_baked deinit ran")
        \\end
        \\error("half_baked top-level boom")
    );
    scripting.registerScript("counter", @embedFile("lua/counter.lua"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The load failure itself was logged with its location...
    try expect(mock.logsContain("half_baked:9"));
    try expect(mock.logsContain("half_baked top-level boom"));
    // ...and neither hook of the half-loaded script ever fired.
    try expect(!mock.logsContain("half_baked update ran"));
    try expect(!mock.logsContain("half_baked deinit ran"));
    // The bystander ran init + update untouched by the eviction.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":1}");
}

test "a script whose init() errors is evicted from update and deinit" {
    fresh();
    scripting.registerScript("bad_init",
        \\function init()
        \\    error("bad_init boom")
        \\end
        \\function update(dt)
        \\    labelle.log("bad_init update ran")
        \\end
        \\function deinit()
        \\    labelle.log("bad_init deinit ran")
        \\end
    );
    scripting.registerScript("counter", @embedFile("lua/counter.lua"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The init failure carries its traceback plus one eviction line.
    try expect(mock.logsContain("bad_init boom"));
    try expect(mock.logsContain("script evicted"));
    // The quarantined script received no further hooks...
    try expect(!mock.logsContain("bad_init update ran"));
    try expect(!mock.logsContain("bad_init deinit ran"));
    // ...while the sibling initialized and advanced through both ticks.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "prelude json round-trips nested component tables" {
    fresh();
    scripting.registerScript("json_roundtrip", @embedFile("lua/json_roundtrip.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "RoundTrip", "{\"ok\":true}");
}

test "labelle.array: explicit empty arrays encode as [] and round-trip" {
    fresh();
    scripting.registerScript("array_marker", @embedFile("lua/array_marker.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Encoder-level properties assert inside the script (a failure
    // evicts it and the components below never appear); the Zig side
    // pins the byte-exact JSON after each hop — set with an explicit
    // empty array, then get→set untouched (decode re-tags the array,
    // so [] survives the round trip instead of collapsing to {}).
    try expectComponent(1, "Path", "{\"waypoints\":[]}");
    try expectComponent(1, "PathAgain", "{\"waypoints\":[]}");
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

test "labelle.u64str renders bit-63 ids as unsigned decimals" {
    fresh();
    scripting.registerScript("u64str_check", @embedFile("lua/u64str_check.lua"));
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
    // decimal exceeds Lua's integer range, so any tonumber() leak in the
    // query path would degrade it to a float addressing the wrong entity.
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("big_id_check", @embedFile("lua/big_id_check.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    // get/set through the QUERIED wrapper landed on the right entity
    // (the script's own asserts would otherwise fail its init — evicting
    // it and leaving these components unset)...
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    // ...and the id renders unsigned end to end.
    try expectComponent(big_id, "BigId", "{\"idstr\":\"9223372036854775809\"}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

test "game.query grows past the fixed shim buffer and yields ALL ids" {
    fresh();
    // 420 entities with 20-digit ids ≈ 8.8 KB of id JSON — past the
    // shim's 8 KiB QUERY_BUF_CAP, so raw_query must see required > cap
    // and retry right-sized. The base id leaves headroom for all 421
    // creates below u64 max.
    const base: u64 = std.math.maxInt(u64) - 1000;
    mock.setNextEntityId(base);
    scripting.registerScript("big_query_check", @embedFile("lua/big_query_check.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Guard the premise first: the complete result really does exceed
    // the shim's fixed 8192-byte buffer (bindings.zig QUERY_BUF_CAP) —
    // probed through the same contract sizing the shim uses.
    const names = "[\"Marker\"]";
    var dummy: [1]u8 = undefined;
    const required = scripting.contract.labelle_query(names.ptr, names.len, &dummy, 0);
    try expect(required > 8192);

    // The script's own asserts police the id set (each created id seen
    // exactly once — any silent prefix evicts it and BigQuery never
    // appears); the Zig side pins the count.
    try expectComponent(base + 420, "BigQuery", "{\"count\":420}");
    try expectEqual(@as(usize, 421), mock.aliveCount());
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

test "eviction purges the dead scripts' handlers; siblings keep firing" {
    fresh();
    // Chunk-scope handler + failing init(): the init-fail eviction path
    // must take the handler with the script.
    scripting.registerScript("doomed",
        \\labelle.on("ping", function(ev)
        \\    labelle.log("doomed handler ran")
        \\end)
        \\function init()
        \\    error("doomed init boom")
        \\end
    );
    // Chunk-scope handler + failing chunk BODY: the load-fail eviction
    // path (the handler registered BEFORE the body erred).
    scripting.registerScript("body_boom",
        \\labelle.on("ping", function(ev)
        \\    labelle.log("body_boom handler ran")
        \\end)
        \\error("body_boom top-level")
    );
    scripting.registerScript("survivor",
        \\local state
        \\labelle.on("ping", function(ev)
        \\    local s = state:get("Pings")
        \\    s.n = s.n + 1
        \\    state:set("Pings", s)
        \\end)
        \\function init()
        \\    state = Entity.new()
        \\    state:set("Pings", { n = 0 })
        \\end
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
    // ...while neither evicted script's chunk-scope handler fired.
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
    // The registering call site is a LOCAL helper closing over an alias
    // of labelle.on: it touches no globals, so it carries NO _ENV
    // upvalue — a caller-_ENV walk finds no script env behind the call
    // and would record owner = nil, exempting the handler from the
    // eviction purge. Ownership must come from the VM's current-script
    // tracking instead: init() runs with the script stamped current, so
    // the handler is owned by "aliased" and dies with it.
    scripting.registerScript("aliased",
        \\local on = labelle.on
        \\local function sub(n, f) on(n, f) end
        \\function init()
        \\    sub("ping", function(ev)
        \\        labelle.log("aliased handler ran")
        \\    end)
        \\    error("aliased init boom")
        \\end
    );
    scripting.registerScript("survivor",
        \\local state
        \\labelle.on("ping", function(ev)
        \\    local s = state:get("Pings")
        \\    s.n = s.n + 1
        \\    state:set("Pings", s)
        \\end)
        \\function init()
        \\    state = Entity.new()
        \\    state:set("Pings", { n = 0 })
        \\end
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
        \\local state
        \\labelle.on("ping", function(ev)
        \\    error("first handler boom")
        \\end)
        \\labelle.on("ping", function(ev)
        \\    local s = state:get("Flow")
        \\    s.pings = s.pings + 1
        \\    state:set("Flow", s)
        \\end)
        \\labelle.on("pong", function(ev)
        \\    local s = state:get("Flow")
        \\    s.pongs = s.pongs + 1
        \\    state:set("Flow", s)
        \\end)
        \\function init()
        \\    state = Entity.new()
        \\    state:set("Flow", { pings = 0, pongs = 0 })
        \\end
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
    // and carrying the traceback the xpcall message handler captured.
    try expectEqual(@as(usize, 1), mock.logCount("first handler boom"));
    try expect(mock.logsContain("event 'ping' handler (owner 'isolated')"));
    try expect(mock.logsContain("stack traceback:"));

    // The throwing handler was NOT purged (errors evict scripts, not
    // handlers): next tick it throws — and is isolated — again.
    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Flow", "{\"pings\":2,\"pongs\":1}");
    try expectEqual(@as(usize, 2), mock.logCount("first handler boom"));
}

test "event payloads carry u64 ids bit-exact through json.decode" {
    fresh();
    // Bit-63 id: its unsigned decimal exceeds math.maxinteger, so a
    // tonumber() in the payload number path would degrade it to an
    // imprecise float and the handler's writes would miss the entity.
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("payload_id_check", @embedFile("lua/payload_id_check.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("owner__ping", "{\"owner\":9223372036854775809}");
    scripting.Controller.tick(.{}, 0.016);

    // The handler wrapped the PAYLOAD id and wrote through it — the
    // component landing on the real u64-addressed entity is the proof
    // (the script's own asserts pin integer-ness and bit-equality).
    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Owned", "{\"seen\":true,\"tag\":42}");
}

test "components larger than the initial scratch round-trip via e:get" {
    fresh();
    // {"blob":"xxx…"} is ~5 KiB — past the shim's 4 KiB initial scratch,
    // so raw_component_get sees required > cap (all-or-nothing: nothing
    // written yet), grows the scratch once and retries. A failed assert
    // evicts the script and BigOk never lands.
    scripting.registerScript("big_component",
        \\function init()
        \\    local e = Entity.new()
        \\    local blob = string.rep("x", 5000)
        \\    assert(e:set("Big", { blob = blob }), "set refused")
        \\    local back = e:get("Big")
        \\    assert(back ~= nil, "get returned nil")
        \\    assert(#back.blob == 5000, "blob truncated: " .. #back.blob)
        \\    assert(back.blob == blob, "blob corrupted")
        \\    e:set("BigOk", { len = #back.blob })
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "BigOk", "{\"len\":5000}");
}

test "event payloads larger than the initial scratch deliver intact; scratch settles" {
    fresh();
    scripting.registerScript("big_events",
        \\local state
        \\labelle.on("blob__event", function(ev)
        \\    local s = state:get("Blob") or { count = 0 }
        \\    assert(type(ev.data) == "string", "payload missing")
        \\    assert(#ev.data == 5000, "payload truncated: " .. tostring(#ev.data))
        \\    assert(ev.data == string.rep("y", 5000), "payload corrupted")
        \\    state:set("Blob", { count = s.count + 1, len = #ev.data })
        \\end)
        \\function init()
        \\    state = Entity.new()
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // ~5 KiB payload: the poll probe reports it, the scratch grows once
    // right-sized, the real read consumes the entry whole. A truncation
    // or corruption trips the handler's asserts (isolated + logged) and
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

test "labelle.component refs address components through every name-taking seam" {
    fresh();
    scripting.registerScript("component_ref", @embedFile("lua/component_ref.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The script's own asserts police ref/string equivalence, query-by-ref
    // and the non-ref-table rejection (any failure evicts it and RefOk
    // never lands); the Zig side pins that the ref writes reached the SAME
    // "Hunger"/"Tag" names a string write would (Tag was removed via ref).
    try expectComponent(1, "Hunger", "{\"level\":0.5,\"starving\":false}");
    try expect(mock.componentJson(1, "Tag") == null);
    try expectComponent(1, "RefOk", "{\"ok\":true}");
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
