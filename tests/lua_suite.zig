//! The lua sub-module driven end to end against the mock host world —
//! see tests/root.zig for the linking model and hygiene notes shared by
//! every language suite.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

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

test "labelle.event returns the name: one binding drives emit AND on" {
    fresh();
    // The fixture declares hunger__feed at chunk scope (the SAME line the
    // declare runner reads as schema), asserts the returned name,
    // labelle.id == 0 and the name-validation errors at chunk scope (a
    // failure there evicts the script and Fed never exists), then
    // subscribes and emits exclusively through the binding.
    scripting.registerScript("event_declared", @embedFile("lua/event_declared.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expectComponent(1, "Fed", "{\"count\":0,\"ok\":true}");

    // Tick once: update() emits toward the host through the binding.
    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.eventsContain("hunger__feed {\"amount\":0.5,\"entity\":\"1\"}"));

    // The host emits the same event back: the subscription registered
    // through the binding (raw_event_subscribe + handler-table key)
    // receives it with the decoded payload.
    mock.hostEmit("hunger__feed", "{\"entity\":1,\"amount\":0.5}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Fed", "{\"amount\":0.5,\"count\":1,\"ok\":true}");
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

test "FrameArray unit semantics" {
    fresh();
    scripting.registerScript("frame_array", @embedFile("lua/frame_array.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The script's asserts police the semantics (push/get/set/each/clear/
    // deliberate growth — any failure evicts it); the Zig side pins that
    // it made it all the way through.
    try expectComponent(1, "FrameArrayOk", "{\"ok\":true}");
}

test "e:get(name, into) refills the caller's table and clears stale keys" {
    fresh();
    scripting.registerScript("get_into", @embedFile("lua/get_into.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The script's asserts police identity, the stale-key clear ({a,b}
    // refilled from {a} → b gone), absent-leaves-untouched, fresh nested
    // tables and the ref spelling; the Zig side pins the verdict plus the
    // final stored payloads the refills were reading.
    try expectComponent(1, "Cfg", "{\"a\":5}");
    try expectComponent(1, "Hunger", "{\"level\":0.25}");
    try expectComponent(2, "GetIntoOk", "{\"ok\":true}");
}

// ── Console eval (labelle-scripting#4) ──────────────────────────────────

test "console eval renders expression results" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const r = scripting.Controller.evalCommand("1+2");
    try expect(r.ok);
    try expectEqualStrings("3", r.text);

    // Multiple return values render print-style (tab-separated) — the
    // expression-first compile (`return <code>;`) keeps them all.
    const multi = scripting.Controller.evalCommand("1, \"two\"");
    try expect(multi.ok);
    try expectEqualStrings("1\ttwo", multi.text);
}

test "console eval persists state across evals in a session env that shadows _G" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Statement (the `return` wrap doesn't parse → statement fallback):
    // the assignment lands in the persistent console _ENV.
    const set = scripting.Controller.evalCommand("x = 5");
    try expect(set.ok);
    try expectEqualStrings("", set.text); // statements yield no results

    const get = scripting.Controller.evalCommand("x");
    try expect(get.ok);
    try expectEqualStrings("5", get.text);

    // The session env SHADOWS the real globals (loadScript's isolation
    // shape): console writes never leak into _G where scripts would see
    // them.
    const raw = scripting.Controller.evalCommand("rawget(_G, \"x\")");
    try expect(raw.ok);
    try expectEqualStrings("nil", raw.text);
}

test "console eval errors carry the traceback and never kill the VM or the tick" {
    fresh();
    scripting.registerScript("counter", @embedFile("lua/counter.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);

    const err = scripting.Controller.evalCommand("error(\"console boom\")");
    try expect(!err.ok);
    try expect(std.mem.indexOf(u8, err.text, "console boom") != null);
    try expect(std.mem.indexOf(u8, err.text, "console:1") != null);
    try expect(std.mem.indexOf(u8, err.text, "stack traceback:") != null);

    // Compile errors surface the same way (location included)...
    const bad = scripting.Controller.evalCommand("function (");
    try expect(!bad.ok);
    try expect(std.mem.indexOf(u8, bad.text, "console:1") != null);

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

    const r = scripting.Controller.evalCommand("Entity.new():set(\"FromEval\", { a = 1 })");
    try expect(r.ok);
    try expectComponent(1, "FromEval", "{\"a\":1}");
}

test "console eval bounds oversized results into valid truncated response JSON" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand(
        "{\"code\":\"return string.rep(\\\"x\\\", 9000)\"}",
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
    scripting.registerScript("counter", @embedFile("lua/counter.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    const r = scripting.Controller.evalCommand("session_note = \"between ticks\"");
    try expect(r.ok);
    scripting.Controller.tick(.{}, 0.125);

    // The counter advanced exactly twice — the eval neither consumed a
    // tick nor disturbed the script registry.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "hot loop: 1k entities of get-into + FrameArray hold steady-state memory flat" {
    fresh();
    scripting.registerScript("hot_loop", @embedFile("lua/hot_loop.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // 110 ticks: 10 warm-up, then 100 measured. The script (see
    // hot_loop.lua for the three collectgarbage("count") pins and the
    // GC-step seam assertions) runs the full boundary workload each tick
    // — query, get-into, mutate, set, FrameArray fill/clear — and writes
    // one deterministic verdict; a violated bound lands here as a false.
    for (0..110) |_| {
        scripting.Controller.tick(.{}, 0.016);
    }
    try expectComponent(1, "HotLoop", "{\"cycles_ok\":true,\"fa_growth\":0," ++
        "\"growth_ok\":true,\"read_ok\":true,\"running_ok\":true," ++
        "\"steps_ok\":true,\"tick_ok\":true,\"ticks\":110}");

    // The measured numbers were logged for forensics (bound tuning reads
    // them from CI output when a pin ever trips)...
    try expect(mock.logsContain("HotLoopStats"));
    // ...and the workload really ran: every entity advanced 110 rounds
    // (level 1000 - 110 * 0.25, count 110 — both exact in binary).
    try expectComponent(2, "Hot", "{\"count\":110,\"level\":972.5}");
    try expectComponent(1001, "Hot", "{\"count\":110,\"level\":972.5}");
}

test "console eval: invalid UTF-8 result bytes become replacement chars in valid response JSON" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // lua strings are arbitrary bytes; JSON is UTF-8 by definition — a
    // raw 0xFF passed through would make the WHOLE response unparseable
    // on the studio side even though the eval succeeded.
    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand(
        "{\"code\":\"return string.char(255)\"}",
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
    try expectEqualStrings(scripting.eval.replacement_char, parsed.value.value);

    // Mixed: the VALID multi-byte é passes through whole — only the raw
    // invalid byte is replaced.
    const mixed = scripting.handleEvalCommand(
        "{\"code\":\"return \\\"é\\\" .. string.char(255) .. \\\"z\\\"\"}",
        &buf,
    );
    try expect(std.unicode.utf8ValidateSlice(mixed));
    const p2 = try std.json.parseFromSlice(
        struct { ok: bool, value: []const u8 },
        std.testing.allocator,
        mixed,
        .{},
    );
    defer p2.deinit();
    try expect(p2.value.ok);
    try expectEqualStrings("é" ++ scripting.eval.replacement_char ++ "z", p2.value.value);
}

// ── bulk component access (contract v1.3, labelle-scripting#44) ──────────
// The lua port of the ruby suite's bulk coverage: packed codec fast path
// (+ JSON fallbacks), batch_get/batch_set round-trip + refusals, and the
// for-in block iterator (break/return commit, error aborts).

test "bulk v1.3: packed codec rides the get-into/set fast path, JSON stays the fallback" {
    fresh();
    // "Stats" is in the mock's packed schema table (one field per scalar
    // kind); "Plain" is NOT — its set/get must degrade to the JSON path
    // (set_packed -1 / get_packed 0xFF), invisibly to the script.
    scripting.registerScript("packed_rt",
        \\function init()
        \\  local e = Entity.new()
        \\  if not e:set("Stats", { power = 1.5, score = -42, alive = true, seed = 123 }) then
        \\    error("packed set refused")
        \\  end
        \\  local s = {}
        \\  if e:get("Stats", s) == nil then error("packed get_into failed") end
        \\  labelle.log("packed:" .. s.power .. ":" .. s.score .. ":" .. tostring(s.alive) .. ":" .. s.seed)
        \\  if not e:set("Plain", { a = 2.5 }) then error("plain set refused") end
        \\  local p = { stale = 9 }
        \\  if e:get("Plain", p) == nil then error("plain get_into failed") end
        \\  labelle.log("plain:" .. p.a .. ":" .. tostring(p.stale))
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Every field kind survived the binary round-trip (f32/i64/bool/u64).
    try expect(mock.logsContain("packed:1.5:-42:true:123"));
    // The stored JSON is in the mock's SCHEMA order (power,score,alive,
    // seed) — the packed set wrote it. The JSON encoder would have sorted
    // the keys (alive,power,score,seed), so key order proves the path.
    try expectComponent(1, "Stats", "{\"power\":1.5,\"score\":-42,\"alive\":true,\"seed\":123}");
    // The schema-less component still round-trips — through JSON — and
    // the refill cleared the stale key (decode_into's contract, kept by
    // both paths).
    try expect(mock.logsContain("plain:2.5:nil"));
    try expectComponent(1, "Plain", "{\"a\":2.5}");
}

test "bulk v1.3: packed get-into clears stale keys like decode_into" {
    fresh();
    scripting.registerScript("packed_clear",
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("Stats", { power = 2.5, score = 1, alive = false, seed = 0 })
        \\  local s = { leftover = "x" }
        \\  e:get("Stats", s)
        \\  labelle.log("clear:" .. tostring(s.leftover) .. ":" .. s.power)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("clear:nil:2.5"));
}

test "bulk v1.3: batch_get/batch_set round-trip the whole query as one f32 stream" {
    fresh();
    scripting.registerScript("batch_rt",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\local buf = {}
        \\function init()
        \\  for i = 1, 3 do
        \\    local e = Entity.new()
        \\    e:set("BatchPos", { x = i, y = 0 })
        \\    e:set("BatchVel", { vx = 10, vy = -10 })
        \\  end
        \\  local lone = Entity.new()
        \\  lone:set("BatchPos", { x = 7, y = 8 })
        \\end
        \\function update(dt)
        \\  local count = labelle.batch_get(NAMES, buf)
        \\  labelle.log("batch count:" .. count .. " floats:" .. #buf)
        \\  for i = 0, count - 1 do
        \\    local b = i * 4
        \\    buf[b + 1] = buf[b + 1] + buf[b + 3] -- x += vx
        \\    buf[b + 2] = buf[b + 2] + buf[b + 4] -- y += vy
        \\  end
        \\  labelle.batch_set(NAMES, buf, count)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // 3 matching entities (the lone BatchPos-only one is filtered out),
    // stride 4 → the reused table holds exactly 12 floats.
    try expect(mock.logsContain("batch count:3 floats:12"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(2, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(3, "BatchPos", "{\"x\":13,\"y\":-10}");
    // A second tick reuses the same table and advances again — the
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
    // raises — int corruption through f32 must be loud, never a silent
    // fallback.
    scripting.registerScript("batch_refuse",
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("Stats", { power = 1, score = 5, alive = true, seed = 9 })
        \\  e:set("BatchPos", { x = 1, y = 2 })
        \\  local ok, err = pcall(function() labelle.batch_get({ "BatchPos", "Stats" }, {}) end)
        \\  if ok then labelle.log("get refusal missed") else labelle.log("get refused: " .. err) end
        \\  local ok2, err2 = pcall(function() labelle.batch_set({ "Stats" }, { 1.0, 2.0, 3.0, 4.0 }, 1) end)
        \\  if ok2 then labelle.log("set refusal missed") else labelle.log("set refused: " .. err2) end
        \\  labelle.log("still alive")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("get refusal missed"));
    try expect(!mock.logsContain("set refusal missed"));
    // The raise names the refused component list and the reason.
    try expect(mock.logsContain("get refused: labelle: batch refused for [\"BatchPos\",\"Stats\"]"));
    try expect(mock.logsContain("int-typed"));
    try expect(mock.logsContain("set refused: labelle: batch refused for [\"Stats\"]"));
    // The raise is catchable — the script kept running.
    try expect(mock.logsContain("still alive"));
    // And nothing was written through the refused paths.
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
}

test "bulk v1.3: batch_set raises when the entity set changed since batch_get" {
    fresh();
    scripting.registerScript("batch_stale",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\local es = {}
        \\local buf = {}
        \\function init()
        \\  for i = 1, 2 do
        \\    local e = Entity.new()
        \\    e:set("BatchPos", { x = i, y = 0 })
        \\    e:set("BatchVel", { vx = 1, vy = 1 })
        \\    es[i] = e
        \\  end
        \\end
        \\function update(dt)
        \\  local count = labelle.batch_get(NAMES, buf)
        \\  es[2]:destroy() -- the forbidden move: destroy between get and set
        \\  local ok, err = pcall(function() labelle.batch_set(NAMES, buf, count) end)
        \\  if ok then labelle.log("stale write accepted") else labelle.log("stale refused: " .. err) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // The exact-size positional-coupling guard fired and surfaced as a
    // catchable error telling the script to re-get.
    try expect(!mock.logsContain("stale write accepted"));
    try expect(mock.logsContain("stale refused:"));
    try expect(mock.logsContain("entity set changed"));
}

test "bulk stage 3: the labelle.batch for-in iterator round-trips through ONE reused view" {
    fresh();
    scripting.registerScript("batch_block",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\function init()
        \\  for i = 1, 3 do
        \\    local e = Entity.new()
        \\    e:set("BatchPos", { x = i, y = 0 })
        \\    e:set("BatchVel", { vx = 10, vy = -10 })
        \\  end
        \\end
        \\function update(dt)
        \\  local same = 0
        \\  local seen = nil
        \\  local n = 0
        \\  for e in labelle.batch(NAMES) do
        \\    n = n + 1
        \\    if seen == nil then seen = e end
        \\    if seen == e then same = same + 1 end -- view REUSE: one table
        \\    e.x = e.x + e.vx
        \\    e.y = e.y + e.vy
        \\    if e.x > 12.0 then e.vx = -e.vx end -- bounce entity 3 (x reaches 13)
        \\  end
        \\  labelle.log("block n:" .. n .. " same_view:" .. same)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // 3 entities, every iteration saw the SAME view table, and normal
    // loop exhaustion COMMITTED through the one batch_set: accessors
    // mapped [x, y, vx, vy] exactly as the stream is laid out.
    try expect(mock.logsContain("block n:3 same_view:3"));
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

test "bulk stage 3: labelle.batch on an empty result iterates zero times; empty names refuse" {
    fresh();
    scripting.registerScript("batch_block_empty",
        \\function init()
        \\  local n = 0
        \\  for e in labelle.batch({ "BatchPos", "BatchVel" }) do n = n + 1 end
        \\  labelle.log("empty n:" .. n)
        \\  local ok, err = pcall(function()
        \\    for e in labelle.batch({}) do end
        \\  end)
        \\  if ok then labelle.log("empty names accepted") else labelle.log("empty names refused: " .. err) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // No matching entities: zero iterations, no error, nothing written.
    try expect(mock.logsContain("empty n:0"));
    try expect(!mock.logsContain("empty names accepted"));
    try expect(mock.logsContain("labelle.batch: expected at least one component name"));
}

test "bulk stage 3: labelle.batch refuses ambiguous and probe-defeating layouts loudly" {
    fresh();
    scripting.registerScript("batch_block_refuse",
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("BatchPos", { x = 1, y = 2 })
        \\  e:set("Plain", { a = 2.5 })
        \\  -- The same component named twice: every field name collides —
        \\  -- the view could not disambiguate e.x, so it must not exist.
        \\  local ok, err = pcall(function()
        \\    for v in labelle.batch({ "BatchPos", "BatchPos" }) do end
        \\  end)
        \\  if ok then labelle.log("dup accepted") else labelle.log("dup refused: " .. err) end
        \\  -- "Plain" has no schema — it contributes ZERO stream floats
        \\  -- (the mock's stand-in for a non-scalar component) while its
        \\  -- JSON shows a number, so the derived layout cannot match the
        \\  -- stream stride. The cross-check must refuse, never mis-map.
        \\  local ok2, err2 = pcall(function()
        \\    for v in labelle.batch({ "BatchPos", "Plain" }) do end
        \\  end)
        \\  if ok2 then labelle.log("mismatch accepted") else labelle.log("mismatch refused: " .. err2) end
        \\  labelle.log("still alive")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("dup accepted"));
    try expect(mock.logsContain("dup refused:"));
    try expect(mock.logsContain("appears in more than one named component"));
    try expect(!mock.logsContain("mismatch accepted"));
    try expect(mock.logsContain("mismatch refused:"));
    try expect(mock.logsContain("does not match the host stream"));
    // Both raises are catchable; nothing was written through either.
    try expect(mock.logsContain("still alive"));
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
}

test "bulk stage 3: labelle.batch surfaces batch_get's raise and an erroring body writes NOTHING" {
    fresh();
    scripting.registerScript("batch_block_errors",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("BatchPos", { x = 5, y = 6 })
        \\  e:set("BatchVel", { vx = 1, vy = 1 })
        \\  -- An ERRORING loop body abandons the WHOLE batch: the closer
        \\  -- sees the error, batch_set never runs, so the mutation before
        \\  -- the error is not applied.
        \\  local ok, err = pcall(function()
        \\    for v in labelle.batch(NAMES) do
        \\      v.x = 999.0
        \\      error("boom", 0)
        \\    end
        \\  end)
        \\  if ok then labelle.log("error swallowed") else labelle.log("body errored: " .. err) end
        \\  -- Unsupported-host parity: labelle.batch's first act IS
        \\  -- raw_batch_get, so a host without batch support surfaces the
        \\  -- exact same raise. Prove the pass-through (and that batch_set
        \\  -- is never reached) by stubbing raw_batch_get to raise the
        \\  -- pre-v1.3 message verbatim.
        \\  labelle.raw_batch_get = function(_names, _arr)
        \\    error("labelle: batch_get — the host engine lacks batch support " ..
        \\      "(script contract v1.3 needs labelle-engine >= 2.6.0); " ..
        \\      "use per-entity get/set on this engine", 0)
        \\  end
        \\  labelle.raw_batch_set = function(_names, _arr, _n)
        \\    labelle.log("batch_set reached")
        \\  end
        \\  local ok2, err2 = pcall(function()
        \\    for v in labelle.batch(NAMES) do labelle.log("body ran on old host") end
        \\  end)
        \\  if ok2 then labelle.log("old host accepted") else labelle.log("old host refused: " .. err2) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The body's error propagated and nothing was written.
    try expect(!mock.logsContain("error swallowed"));
    try expect(mock.logsContain("body errored: boom"));
    try expectComponent(1, "BatchPos", "{\"x\":5,\"y\":6}");
    // The unsupported-host raise passed through IDENTICALLY; the body
    // never ran and batch_set was never reached.
    try expect(!mock.logsContain("old host accepted"));
    try expect(!mock.logsContain("body ran on old host"));
    try expect(!mock.logsContain("batch_set reached"));
    try expect(mock.logsContain("old host refused: labelle: batch_get — the host engine lacks batch support"));
}

test "bulk stage 3: break and return from the loop body COMMIT the writes made so far" {
    fresh();
    // Nonlocal-exit semantics, carried by the generic-for CLOSING value:
    // break/return are the NORMAL iterator early-exit — everything
    // written up to that point flushes through the one batch_set
    // (entities not yet visited write back unchanged); only an ERROR
    // aborts (previous test).
    scripting.registerScript("batch_block_break",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\local function early(limit)
        \\  for e in labelle.batch(NAMES) do
        \\    e.x = e.x + 100.0
        \\    if e.x > limit then return "stopped" end
        \\  end
        \\  return "ran out"
        \\end
        \\function init()
        \\  for i = 1, 3 do
        \\    local e = Entity.new()
        \\    e:set("BatchPos", { x = i, y = 0 })
        \\    e:set("BatchVel", { vx = 0, vy = 0 })
        \\  end
        \\  for e in labelle.batch(NAMES) do
        \\    e.x = e.x + 10.0
        \\    break
        \\  end
        \\  labelle.log("break done")
        \\  labelle.log("early r:" .. early(50))
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("break done"));
    // `return` out of the enclosing function commits the same way.
    try expect(mock.logsContain("early r:stopped"));
    // break after mutating entity 1 only: its write COMMITTED, the
    // not-yet-visited entities round-tripped unchanged (x stays 2 / 3)...
    // then early(50) mutated entity 1 again (11 + 100) and returned.
    try expectComponent(1, "BatchPos", "{\"x\":111,\"y\":0}");
    try expectComponent(2, "BatchPos", "{\"x\":2,\"y\":0}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":0}");
}

test "bulk stage 3: single-name coercion, unknown-field raise, and the discovery race" {
    fresh();
    scripting.registerScript("batch_block_round1",
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("BatchPos", { x = 1, y = 2 })
        \\  -- Single non-array name is coerced ({ name }).
        \\  local n = 0
        \\  for v in labelle.batch("BatchPos") do
        \\    v.x = v.x + 1.0
        \\    n = n + 1
        \\  end
        \\  labelle.log("single n:" .. n)
        \\  -- Single component REF (the labelle.component form every
        \\  -- name-taking site accepts — Entity get/set, game.query): a
        \\  -- ref is a TABLE, so it must not be mistaken for a names list.
        \\  local Ref = labelle.component("BatchPos")
        \\  local rn = 0
        \\  for v in labelle.batch(Ref) do
        \\    v.x = v.x + 1.0
        \\    rn = rn + 1
        \\  end
        \\  labelle.log("ref n:" .. rn)
        \\  -- Refs mix into lists too (the resolve_names leg).
        \\  e:set("BatchVel", { vx = 1, vy = 1 })
        \\  local mn = 0
        \\  for v in labelle.batch({ Ref, "BatchVel" }) do mn = mn + 1 end
        \\  labelle.log("mix n:" .. mn)
        \\  -- A typo'd field name raises instead of silently reading nil
        \\  -- (no names are reserved — the view's base offset lives in an
        \\  -- upvalue, not on the table).
        \\  local ok, err = pcall(function()
        \\    for v in labelle.batch("BatchPos") do local _ = v.z end
        \\  end)
        \\  if ok then labelle.log("typo accepted") else labelle.log("typo refused: " .. err) end
        \\  -- Discovery race: batch_get saw entities but the layout probe's
        \\  -- re-query comes back empty (entity destroyed mid-tick) — a
        \\  -- clear raise, not a low-level nil error. Stub the re-query leg
        \\  -- to force the race deterministically (an UNCACHED names-set,
        \\  -- so first-use discovery actually runs).
        \\  labelle.raw_query = function(_names_json) return "" end
        \\  local ok2, err2 = pcall(function()
        \\    for v in labelle.batch({ "BatchVel" }) do end
        \\  end)
        \\  if ok2 then labelle.log("race accepted") else labelle.log("race refused: " .. err2) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("single n:1"));
    // The single-ref form iterated too (+1 more on x), and refs mixed
    // into a names list resolve through the same component_name leg.
    try expect(mock.logsContain("ref n:1"));
    try expect(mock.logsContain("mix n:1"));
    try expectComponent(1, "BatchPos", "{\"x\":3,\"y\":2}");
    try expect(!mock.logsContain("typo accepted"));
    try expect(mock.logsContain("typo refused:"));
    try expect(mock.logsContain("unknown field 'z'"));
    try expect(!mock.logsContain("race accepted"));
    try expect(mock.logsContain("race refused:"));
    try expect(mock.logsContain("vanished between batch_get and layout discovery"));
}

test "bulk v1.3: an unrepresentable packed value falls back to JSON end-to-end" {
    fresh();
    // score is an i64 in the mock's Stats schema; a lua float 1.0e30 is
    // finite but out of i64 range, so the host REFUSES the packed set
    // (-1, engine parity: refuse, never clamp) and the prelude falls
    // back to the JSON path — which encodes the value faithfully.
    scripting.registerScript("packed_range",
        \\function init()
        \\  local e = Entity.new()
        \\  if not e:set("Stats", { power = 1.5, score = 1.0e30, alive = true, seed = 9 }) then
        \\    error("set failed")
        \\  end
        \\  labelle.log("range done")
        \\end
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

test "bulk v1.3: the 64-bit bitcast pair round-trips a bit-63 u64 through lua" {
    fresh();
    // seed (u64 schema kind) holds 0x8000000000000001 — lua integers are
    // signed 64-bit, so the value travels as its bitcast
    // -9223372036854775807 through the whole packed cycle: GET emits tag
    // 3, the shim bitcasts to the signed integer (the entity-id rule),
    // SET re-emits tag 1, the host bitcasts back — bit-exact end to end.
    scripting.registerScript("packed_u64",
        \\function init()
        \\  local e = Entity.new()
        \\  if not e:set("Stats", { power = 0.0, score = 0, alive = false, seed = -9223372036854775807 }) then
        \\    error("set failed")
        \\  end
        \\  local s = {}
        \\  if e:get("Stats", s) == nil then error("get_into failed") end
        \\  labelle.log("u64rt:" .. tostring(s.seed == -9223372036854775807))
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("u64rt:true"));
    // The host stored the UNSIGNED value (the packed set's schema-order
    // serialization proves the packed path carried it, not JSON).
    try expectComponent(1, "Stats", "{\"power\":0,\"score\":0,\"alive\":false,\"seed\":9223372036854775809}");
}

test "bulk v1.3: non-finite floats take the same refusal on the packed and JSON routes" {
    fresh();
    // Parity pin: json.encode errors ("json.encode: non-finite number")
    // on NaN/Inf. The packed fast path must not smuggle those into the
    // host, so it bails to the JSON fallback — which raises the SAME
    // canonical error. Both routes agree: one refusal, nothing stored.
    scripting.registerScript("packed_nonfinite",
        \\function init()
        \\  local e = Entity.new()
        \\  local ok, err = pcall(function()
        \\    e:set("Stats", { power = 0 / 0, score = 0, alive = false, seed = 0 })
        \\  end)
        \\  if ok then labelle.log("nan accepted") else labelle.log("nan refused: " .. err) end
        \\  local ok2, err2 = pcall(function()
        \\    e:set("Stats", { power = math.huge })
        \\  end)
        \\  if ok2 then labelle.log("inf accepted") else labelle.log("inf refused: " .. err2) end
        \\  labelle.log("nonfinite done")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("nan accepted"));
    try expect(!mock.logsContain("inf accepted"));
    // Same canonical message from both entry points.
    try expect(mock.logsContain("nan refused:"));
    try expect(mock.logsContain("inf refused:"));
    try expectEqual(@as(usize, 2), mock.logCount("json.encode: non-finite number"));
    try expect(mock.logsContain("nonfinite done"));
    // Nothing was stored by either refusal.
    try expect(mock.componentJson(1, "Stats") == null);
}

test "bulk stage 3: batch_set refuses numeric strings and non-finite elements before any write" {
    fresh();
    // Round-1 review (PR #48): lua_tonumberx would silently coerce a
    // numeric STRING into the stream, and NaN/Inf would ride straight
    // into component fields — both now refuse AT THE BINDING, naming the
    // element, with nothing handed to the host (the json.encode
    // non-finite policy applied to the stream; ruby's identical gap
    // retrofits via #45).
    scripting.registerScript("batch_set_strict",
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("BatchPos", { x = 1, y = 2 })
        \\  e:set("BatchVel", { vx = 3, vy = 4 })
        \\  local buf = {}
        \\  local count = labelle.batch_get(NAMES, buf)
        \\  buf[2] = "9" -- numeric string: tonumber would take it; we must not
        \\  local ok, err = pcall(function() labelle.batch_set(NAMES, buf, count) end)
        \\  if ok then labelle.log("string accepted") else labelle.log("string refused: " .. err) end
        \\  buf[2] = 0 / 0
        \\  local ok2, err2 = pcall(function() labelle.batch_set(NAMES, buf, count) end)
        \\  if ok2 then labelle.log("nan accepted") else labelle.log("nan refused: " .. err2) end
        \\  buf[2] = math.huge
        \\  local ok3, err3 = pcall(function() labelle.batch_set(NAMES, buf, count) end)
        \\  if ok3 then labelle.log("inf accepted") else labelle.log("inf refused: " .. err3) end
        \\  -- The block-iterator path hits the same guard at commit time:
        \\  -- the closer's batch_set raises out of the loop.
        \\  local ok4, err4 = pcall(function()
        \\    for d in labelle.batch(NAMES) do d.y = 0 / 0 end
        \\  end)
        \\  if ok4 then labelle.log("view nan accepted") else labelle.log("view nan refused: " .. err4) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("string accepted"));
    try expect(mock.logsContain("string refused: labelle: batch_set: array element 2 is not a number"));
    try expect(!mock.logsContain("nan accepted"));
    try expect(mock.logsContain("nan refused: labelle: batch_set: non-finite number at element 2"));
    try expect(!mock.logsContain("inf accepted"));
    try expect(mock.logsContain("inf refused: labelle: batch_set: non-finite number at element 2"));
    try expect(!mock.logsContain("view nan accepted"));
    try expect(mock.logsContain("view nan refused:"));
    try expect(mock.logsContain("non-finite number at element 2"));
    // Every refusal fired BEFORE any host write — both components keep
    // their original values.
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
    try expectComponent(1, "BatchVel", "{\"vx\":3,\"vy\":4}");
}

test "bulk v1.3 (#45 review): overflow floats ride the f64 tag (no throw); non-packable sets keep the JSON fallback" {
    fresh();
    // A finite float beyond ±f32 range is NOT refused at the binding
    // (codex #53): the binding cannot know the target field width, and
    // such a value is legitimate for an f64 field. It rides the SET-side
    // f64 tag, and the host coerces per field type. Two legs:
    //   1. Overflow on a PACKABLE component — the set SUCCEEDS (host
    //      narrows, parity with JSON); the OLD binding raised here.
    //   2. A NON-PACKABLE component (not in the packed schema) — the
    //      lossy 0.1 rides tag 4, set_packed refuses (-1), and the
    //      prelude's JSON leg stores it (the fallback the #50/precision
    //      work must not break).
    scripting.registerScript("packed_fallback",
        \\function init()
        \\  local e = Entity.new()
        \\  local ok1 = e:set("BatchPos", { x = 1e39, y = 0 })
        \\  labelle.log("overflow set:" .. tostring(ok1))
        \\  local e2 = Entity.new()
        \\  local ok2 = e2:set("Widget", { a = 0.1, n = 7 })
        \\  labelle.log("widget set:" .. tostring(ok2))
        \\end
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
        \\local NAMES = { "BatchPos", "BatchVel" }
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("BatchPos", { x = 1, y = 2 })
        \\  e:set("BatchVel", { vx = 3, vy = 4 })
        \\  local buf = {}
        \\  local count = labelle.batch_get(NAMES, buf)
        \\  buf[2] = 1e100 -- finite at f64, inf after the f32 narrow
        \\  local ok, err = pcall(function() labelle.batch_set(NAMES, buf, count) end)
        \\  if ok then labelle.log("huge accepted") else labelle.log("huge refused: " .. err) end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(!mock.logsContain("huge accepted"));
    try expect(mock.logsContain("huge refused: labelle: batch_set: element 2 overflows f32 range"));
    // The refusal fired BEFORE any host write — both components keep
    // their original values.
    try expectComponent(1, "BatchPos", "{\"x\":1,\"y\":2}");
    try expectComponent(1, "BatchVel", "{\"vx\":3,\"vy\":4}");
}

test "bulk v1.3 (#45): a float past f32 precision reaches int fields exactly (SET tag 4)" {
    fresh();
    // 16777217.0 (2^24 + 1) is the first integer f32 cannot hold: the
    // old f32 tagging rounded it to 16777216 BEFORE the host saw it — a
    // silent off-by-one into the i64 field where the JSON path is
    // exact. The SET-side f64 tag (4) carries full precision: the host
    // coerces float→int exactly under its range refusal, and an
    // in-range non-integral float (0.1) rides the same tag to the f32
    // field with identical results.
    scripting.registerScript("packed_precision",
        \\function init()
        \\  local e = Entity.new()
        \\  e:set("Stats", { power = 0.1, score = 16777217.0, alive = true, seed = 1 })
        \\  labelle.log("precision done")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("precision done"));
    // SCHEMA order proves the packed path carried it (the JSON fallback
    // sorts keys); the score is EXACT.
    try expectComponent(1, "Stats", "{\"power\":0.1,\"score\":16777217,\"alive\":true,\"seed\":1}");
}
