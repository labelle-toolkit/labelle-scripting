//! The ruby (mruby) sub-module driven end to end against the mock host
//! world — see tests/root.zig for the linking model and hygiene notes
//! shared by every language suite.
//!
//! The suite mirrors the lua one test-for-test where the semantics are
//! shared (behavior port, eviction, handler purge and isolation, u64
//! fidelity, scratch settling, lifecycle), then adds the ruby-specific
//! surface: top-level hook isolation without lua's _ENV (the harvest
//! protocol), Labelle::Controller lifecycle and ordering, the
//! Component.ref `into:` pattern with its zero-allocation proof, and
//! FrameArray.

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
/// the Zig-side encoder is deterministic (sorted keys).
fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

/// Assert log line `a` appears before log line `b` (both must exist).
fn expectLogOrder(a: []const u8, b: []const u8) !void {
    const ia = mock.logIndexOf(a) orelse {
        std.debug.print("missing log line '{s}'\n", .{a});
        return error.TestExpectedLog;
    };
    const ib = mock.logIndexOf(b) orelse {
        std.debug.print("missing log line '{s}'\n", .{b});
        return error.TestExpectedLog;
    };
    try expect(ia < ib);
}

test "behavior script drives the mock world through init and five ticks" {
    fresh();
    scripting.registerScript("behavior", @embedFile("ruby/behavior.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // init ran during setup: player entity exists at the origin.
    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("ruby: player 1 ready"));

    // Host emits tick_started before each tick (the POC driver's shape);
    // the script's Labelle.on handler sees each one during inbox dispatch.
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
    try expect(mock.logsContain("ruby: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("ruby: bullet away"));
    // Controller.tick stamped the dt into the host.
    try expectEqual(@as(f32, 1.0 / 60.0), mock.world.dt);
}

test "script errors are logged with backtraces and never kill the tick" {
    fresh();
    // Registered FIRST so a crash here would starve the scripts after it.
    scripting.registerScript("exploder",
        \\def update(dt)
        \\  raise "boom on tick"
        \\end
    );
    // Doesn't even parse — load must log and skip it.
    scripting.registerScript("broken", "def oops(");
    scripting.registerScript("counter", @embedFile("ruby/counter.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);

    // The bystander advanced every tick and saw the stamped dt via
    // Labelle.time_dt — the ticks survived both broken scripts.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");

    // Runtime error: named location + message + backtrace.
    try expect(mock.logsContain("exploder:2"));
    try expect(mock.logsContain("boom on tick"));
    try expect(mock.logsContain("backtrace:"));
    // Parse error carries the broken script's name and the parser line.
    try expect(mock.logsContain("broken"));
    try expect(mock.logsContain("syntax error"));
}

test "a chunk whose body raises is evicted before any hook fires" {
    fresh();
    scripting.registerScript("half_baked",
        \\# update/deinit land on Object BEFORE the body raises; without
        \\# eviction (and the leftover-hook strip) the NEXT script's
        \\# harvest would adopt them, or dispatch would still find them.
        \\def update(dt)
        \\  Labelle.log("half_baked update ran")
        \\end
        \\def deinit
        \\  Labelle.log("half_baked deinit ran")
        \\end
        \\raise "half_baked top-level boom"
    );
    scripting.registerScript("counter", @embedFile("ruby/counter.rb"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The load failure itself was logged with its location...
    try expect(mock.logsContain("half_baked:10"));
    try expect(mock.logsContain("half_baked top-level boom"));
    // ...and neither hook of the half-loaded script ever fired.
    try expect(!mock.logsContain("half_baked update ran"));
    try expect(!mock.logsContain("half_baked deinit ran"));
    // The bystander (loaded AFTER the failed body — its harvest must not
    // adopt the leftovers) ran init + its own update untouched.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":1}");
}

test "a script whose init raises is evicted from update and deinit" {
    fresh();
    scripting.registerScript("bad_init",
        \\def init
        \\  raise "bad_init boom"
        \\end
        \\def update(dt)
        \\  Labelle.log("bad_init update ran")
        \\end
        \\def deinit
        \\  Labelle.log("bad_init deinit ran")
        \\end
    );
    scripting.registerScript("counter", @embedFile("ruby/counter.rb"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.tick(.{}, 0.125);
    scripting.Controller.deinit();

    // The init failure carries its backtrace plus one eviction line.
    try expect(mock.logsContain("bad_init boom"));
    try expect(mock.logsContain("script evicted"));
    // The quarantined script received no further hooks...
    try expect(!mock.logsContain("bad_init update ran"));
    try expect(!mock.logsContain("bad_init deinit ran"));
    // ...while the sibling initialized and advanced through both ticks.
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":2}");
}

test "json codec round-trips; {} vs [] survive natively" {
    fresh();
    scripting.registerScript("json_roundtrip", @embedFile("ruby/json_roundtrip.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Codec properties assert inside the script (a failure evicts it and
    // the components never appear); the Zig side pins the byte-exact
    // JSON after each hop — set with both empties, then get→set
    // untouched: Hash stays {}, Array stays [] with no marker needed
    // (ruby's native answer to lua's labelle.array).
    try expectComponent(1, "Path", "{\"meta\":{},\"waypoints\":[]}");
    try expectComponent(1, "PathAgain", "{\"meta\":{},\"waypoints\":[]}");
    try expectComponent(2, "RoundTrip", "{\"ok\":true}");
}

test "Labelle.each iterates the mock world's matching ids" {
    fresh();
    scripting.registerScript("query_check", @embedFile("ruby/query_check.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Entities 1..3 carry Marker (sum 6), only 2 also carries Extra, the
    // bare entity 4 never shows up, unknown names yield zero matches.
    try expectComponent(5, "QueryResult", "{\"both\":1,\"count\":3,\"none\":0,\"sum\":6}");
}

test "Labelle.u64str renders bit-63 ids as unsigned decimals" {
    fresh();
    scripting.registerScript("u64str_check", @embedFile("ruby/u64str_check.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Exact decimals for 0, 1, 2^62, 0x8000000000000001, 0xFFFFFFFFFFFFFFFF
    // (sorted keys — see the script for which literal is which).
    try expectComponent(1, "U64Str", "{\"all_ones\":\"18446744073709551615\"," ++
        "\"high_one\":\"9223372036854775809\",\"one\":\"1\"," ++
        "\"pow62\":\"4611686018427387904\",\"zero\":\"0\"}");
}

test "Labelle.each round-trips bit-63 entity ids exactly" {
    fresh();
    // Force the next id past the signed-integer boundary: its unsigned
    // decimal exceeds mrb_int range, so anything but the Zig-side
    // wrapping parse would raise (mruby) or drift (a float path) and the
    // wrapper would address the wrong entity.
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("big_id_check", @embedFile("ruby/big_id_check.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    try expectComponent(big_id, "BigId", "{\"idstr\":\"9223372036854775809\"}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

test "Labelle.each grows the scratch past its initial cap and yields ALL ids" {
    fresh();
    // 420 entities with 20-digit ids ≈ 8.8 KB of id JSON — past the
    // 4 KiB initial scratch, so raw_query must see required > cap and
    // grow + retry. The base id leaves headroom for all 421 creates
    // below u64 max.
    const base: u64 = std.math.maxInt(u64) - 1000;
    mock.setNextEntityId(base);
    scripting.registerScript("big_query_check", @embedFile("ruby/big_query_check.rb"));
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

test "Labelle.on dispatch fires with decoded symbol-keyed payloads" {
    fresh();
    scripting.registerScript("event_payload", @embedFile("ruby/event_payload.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Two queued events, one tick: both drained, handlers fan out in
    // order, nested payload decoded to real Hashes/Arrays.
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

test "Labelle.event returns the frozen name: one constant drives emit AND on" {
    fresh();
    // The fixture declares hunger__feed at file scope (the SAME line the
    // declare runner reads as schema), asserts the frozen-name return,
    // Labelle.id == 0 and the name-validation raises at chunk scope
    // (a failure there evicts the script and Fed never exists), then
    // subscribes and emits exclusively through the constant.
    scripting.registerScript("event_declared", @embedFile("ruby/event_declared.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expectComponent(1, "Fed", "{\"count\":0,\"ok\":true}");

    // Tick once: update() emits toward the host through the constant —
    // the frozen string crosses raw_event_emit intact.
    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.eventsContain("hunger__feed {\"amount\":0.5,\"entity\":\"1\"}"));

    // The host emits the same event back: the subscription registered
    // through the constant (raw_event_subscribe + handler-table key)
    // receives it with the decoded payload.
    mock.hostEmit("hunger__feed", "{\"entity\":1,\"amount\":0.5}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Fed", "{\"amount\":0.5,\"count\":1,\"ok\":true}");
}

test "eviction purges the dead scripts' handlers; siblings keep firing" {
    fresh();
    // Handler registered in init + failing init: the init-fail eviction
    // path must take the handler with the script.
    scripting.registerScript("doomed",
        \\def init
        \\  Labelle.on("ping") { |_ev| Labelle.log("doomed handler ran") }
        \\  raise "doomed init boom"
        \\end
    );
    // Chunk-scope handler + failing chunk BODY: the load-fail eviction
    // path (the handler registered BEFORE the body raised).
    scripting.registerScript("body_boom",
        \\Labelle.on("ping") { |_ev| Labelle.log("body_boom handler ran") }
        \\raise "body_boom top-level"
    );
    scripting.registerScript("survivor",
        \\def init
        \\  @state = Labelle::Entity.create
        \\  @state.set("Pings", n: 0)
        \\  Labelle.on("ping") do |_ev|
        \\    s = @state.get("Pings")
        \\    s[:n] += 1
        \\    @state.set("Pings", s)
        \\  end
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
    // ...while neither evicted script's handler fired.
    try expect(!mock.logsContain("doomed handler ran"));
    try expect(!mock.logsContain("body_boom handler ran"));

    // Later events keep flowing to the survivor only.
    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Pings", "{\"n\":2}");
    try expect(!mock.logsContain("doomed handler ran"));
    try expect(!mock.logsContain("body_boom handler ran"));
}

test "ownership survives registration through helper-method indirection" {
    fresh();
    // The registering call site is a top-level HELPER method invoked from
    // init: ownership cannot be derived from any caller-frame inspection —
    // it must come from the VM's current-script stamp, which survives the
    // indirection. The handler is owned by "aliased" and dies with it.
    scripting.registerScript("aliased",
        \\def sub(n, &f)
        \\  Labelle.on(n, &f)
        \\end
        \\def init
        \\  sub("ping") { |_ev| Labelle.log("aliased handler ran") }
        \\  raise "aliased init boom"
        \\end
    );
    scripting.registerScript("survivor",
        \\def init
        \\  @state = Labelle::Entity.create
        \\  @state.set("Pings", n: 0)
        \\  Labelle.on("ping") do |_ev|
        \\    s = @state.get("Pings")
        \\    s[:n] += 1
        \\    @state.set("Pings", s)
        \\  end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);

    try expect(mock.logsContain("aliased init boom"));
    try expect(mock.logsContain("script evicted"));
    try expectComponent(1, "Pings", "{\"n\":1}");
    try expect(!mock.logsContain("aliased handler ran"));
}

test "a raising handler is isolated: fan-out and drain continue, error logged once" {
    fresh();
    scripting.registerScript("isolated",
        \\def init
        \\  @state = Labelle::Entity.create
        \\  @state.set("Flow", pings: 0, pongs: 0)
        \\  Labelle.on("ping") do |_ev|
        \\    raise "first handler boom"
        \\  end
        \\  Labelle.on("ping") do |_ev|
        \\    s = @state.get("Flow")
        \\    s[:pings] += 1
        \\    @state.set("Flow", s)
        \\  end
        \\  Labelle.on("pong") do |_ev|
        \\    s = @state.get("Flow")
        \\    s[:pongs] += 1
        \\    @state.set("Flow", s)
        \\  end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Two events, one tick: the FIRST ping handler raises — the second
    // must still fire (fan-out survives) and the drain must continue on
    // to pong (the queue survives), all within the same dispatch.
    mock.hostEmit("ping", "{}");
    mock.hostEmit("pong", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Flow", "{\"pings\":1,\"pongs\":1}");

    // The failure was logged exactly once, attributed (event + owner)
    // and carrying the handler's backtrace.
    try expectEqual(@as(usize, 1), mock.logCount("first handler boom"));
    try expect(mock.logsContain("event 'ping' handler (owner 'isolated')"));
    try expect(mock.logsContain("backtrace:"));

    // The raising handler was NOT purged (errors evict scripts, not
    // handlers): next tick it raises — and is isolated — again.
    mock.hostEmit("ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Flow", "{\"pings\":2,\"pongs\":1}");
    try expectEqual(@as(usize, 2), mock.logCount("first handler boom"));
}

test "event payloads carry u64 ids bit-exact through the decoder" {
    fresh();
    mock.setNextEntityId(0x8000000000000001);
    scripting.registerScript("payload_id_check", @embedFile("ruby/payload_id_check.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    mock.hostEmit("owner__ping", "{\"owner\":9223372036854775809}");
    scripting.Controller.tick(.{}, 0.016);

    // The handler wrapped the PAYLOAD id and wrote through it — the
    // component landing on the real u64-addressed entity is the proof
    // (the script's own raises pin Integer-ness and bit-equality).
    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Owned", "{\"seen\":true,\"tag\":42}");
}

test "components larger than the initial scratch round-trip via get" {
    fresh();
    // {"blob":"xxx…"} is ~5 KiB — past the 4 KiB initial scratch, so
    // raw_component_get sees required > cap (all-or-nothing: nothing
    // written yet), grows once and retries. A raise evicts the script
    // and BigOk never lands.
    scripting.registerScript("big_component",
        \\def init
        \\  e = Labelle::Entity.create
        \\  blob = "x" * 5000
        \\  raise "set refused" unless e.set("Big", blob: blob)
        \\  back = e.get("Big")
        \\  raise "get returned nil" if back.nil?
        \\  raise "blob truncated: #{back[:blob].size}" unless back[:blob].size == 5000
        \\  raise "blob corrupted" unless back[:blob] == blob
        \\  e.set("BigOk", len: back[:blob].size)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "BigOk", "{\"len\":5000}");
}

test "event payloads larger than the initial scratch deliver intact; scratch settles" {
    fresh();
    scripting.registerScript("big_events",
        \\def init
        \\  @state = Labelle::Entity.create
        \\  @expected = "y" * 5000
        \\  Labelle.on("blob__event") do |ev|
        \\    s = @state.get("Blob") || { count: 0 }
        \\    raise "payload missing" unless ev[:data].is_a?(String)
        \\    raise "payload truncated: #{ev[:data].size}" unless ev[:data].size == 5000
        \\    raise "payload corrupted" unless ev[:data] == @expected
        \\    @state.set("Blob", count: s[:count] + 1, len: ev[:data].size)
        \\  end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // ~5 KiB payload: the poll probe reports it, the scratch grows once
    // right-sized, the real read consumes the entry whole. A truncation
    // or corruption trips the handler's raises (isolated + logged) and
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
    scripting.registerScript("lifecycle", @embedFile("ruby/lifecycle.rb"));
    try scripting.Controller.setup(.{});

    // init: marker (1) created + Alive removed again; prefab ship (2)
    // spawned at the params position; scene switched (the "nope" arm
    // rejected inside the script via raise).
    try expect(mock.entityAlive(1));
    try expect(mock.componentJson(1, "Alive") == null);
    try expectComponent(2, "Prefab", "{\"name\":\"ship\"}");
    try expectComponent(2, "Position", "{\"x\":5,\"y\":10}");
    try expectComponent(2, "Tag", "{\"kind\":\"spawned\"}");
    try expectEqualStrings("menu", mock.sceneName());

    // deinit hooks run before the VM closes.
    scripting.Controller.deinit();
    try expect(mock.logsContain("ruby: lifecycle deinit ran"));
    try expect(mock.eventsContain("shutdown_done {\"from\":1}"));

    // Registrations survive deinit: a second setup boots a fresh VM and
    // runs init again against the same (uncleared) world.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.entityAlive(3)); // second marker
    try expectComponent(4, "Prefab", "{\"name\":\"ship\"}"); // second ship
    try expectEqual(@as(usize, 4), mock.aliveCount());
}

test "registerScript replaces sources by name" {
    fresh();
    scripting.registerScript("dup", "def init; Labelle::Entity.create.set('V', v: 1); end");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());
    // Same name = replacement, not a second script.
    scripting.registerScript("dup", "def init; Labelle::Entity.create.set('V', v: 2); end");
    try expectEqual(@as(usize, 1), scripting.registeredScriptCount());

    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expectComponent(1, "V", "{\"v\":2}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
}

// ── ruby-specific surface ────────────────────────────────────────────────

test "top-level hooks are isolated per script (no Object-level collision)" {
    fresh();
    scripting.registerScript("iso_a", @embedFile("ruby/iso_a.rb"));
    scripting.registerScript("iso_b", @embedFile("ruby/iso_b.rb"));
    try scripting.Controller.setup(.{});

    scripting.Controller.tick(.{}, 0.016);
    scripting.Controller.tick(.{}, 0.016);

    // Both scripts' same-named update hooks ran — against their OWN
    // @ivar state on their own receivers.
    try expectComponent(1, "IsoA", "{\"n\":2}");
    try expectComponent(2, "IsoB", "{\"n\":20}");

    // Both same-named deinit hooks fire too.
    scripting.Controller.deinit();
    try expect(mock.logsContain("iso_a deinit"));
    try expect(mock.logsContain("iso_b deinit"));
}

test "HungerController: the Component.ref into: pattern end to end" {
    fresh();
    scripting.registerScript("hunger_controller", @embedFile("ruby/hunger_controller.rb"));
    try scripting.Controller.setup(.{});

    // The plain init hook seeded the worker BEFORE controller setup ran.
    try expectComponent(1, "Hunger", "{\"level\":0.875,\"starving\":false}");
    try expectLogOrder("ruby: worker 1 ready", "ruby: hunger controller ready");

    // Two decay ticks (DECAY 0.5 × dt 0.5 = 0.25/tick), still fed.
    scripting.Controller.tick(.{}, 0.5);
    try expectComponent(1, "Hunger", "{\"level\":0.625,\"starving\":false}");
    scripting.Controller.tick(.{}, 0.5);
    try expectComponent(1, "Hunger", "{\"level\":0.375,\"starving\":false}");

    // Third tick crosses the starving threshold (0.125 <= 0.25).
    scripting.Controller.tick(.{}, 0.5);
    try expectComponent(1, "Hunger", "{\"level\":0.125,\"starving\":true}");

    // Command-as-event: the feed handler runs during inbox dispatch
    // BEFORE the controller tick — +0.75 then the tick's -0.25.
    mock.hostEmit("hunger__feed", "{\"entity\":1,\"amount\":0.75}");
    scripting.Controller.tick(.{}, 0.5);
    try expectComponent(1, "Hunger", "{\"level\":0.625,\"starving\":false}");

    // Teardown runs on deinit.
    scripting.Controller.deinit();
    try expect(mock.logsContain("ruby: hunger controller done"));
}

test "Labelle.component at runtime: the declare DSL line yields a working ref-parity view class" {
    // One DSL, two consumers (the lua component-ref rule): the SAME
    // chunk-scope `Labelle.component "Hunger", level: 0.875, ...` the
    // declare runner (tools/declare-ruby, tests/declare_ruby_tool.zig)
    // extracts as schema must, at runtime, hand the script a
    // Component.ref-equivalent view class — get into it, set from it,
    // interchangeable with the explicit-fields ref. The fixture raises on
    // any mismatch: a raising init evicts the script, so DslOk landing IS
    // the assertion.
    fresh();
    scripting.registerScript("component_dsl", @embedFile("ruby/component_dsl.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "DslOk", "{\"ok\":true}");
    // The final write-back went through the DSL view's set_from path
    // (sorted keys, exact floats)...
    try expectComponent(1, "Hunger", "{\"level\":0.25,\"starving\":true}");
    // ...and the braced-spec + trailing-opts spelling wrote too.
    try expectComponent(1, "Tag", "{\"kind\":\"worker\"}");
}

test "view construction rejects >32 fields at the defining line, never as a late get/set raise" {
    // The runtime half of the field-cap parity (the declare half is
    // tests/declare_ruby_tool.zig's): the raw fast path sizes per-call
    // buffers by bindings.zig's MAX_REF_FIELDS=32, so an over-wide view
    // would construct fine and then raise inside EVERY get_into/set —
    // Component.__view rejects it at construction instead, for both
    // spellings, and the failing chunk is evicted with the pointed
    // message naming the defining line.
    fresh();
    scripting.registerScript("wide_dsl",
        \\spec = {}
        \\33.times { |i| spec["f%02d" % i] = 0 }
        \\WideDsl = Labelle.component("WideDsl", spec)
    );
    // The explicit-fields v0.2 spelling trips the same construction check.
    scripting.registerScript("wide_ref",
        \\fields = []
        \\33.times { |i| fields << ("g%02d" % i).to_sym }
        \\WideRef = Labelle::Component.ref("WideRef", *fields)
    );
    // Exactly 32 is the edge the raw fast path accepts: construct, fill
    // by index, set from the view, refill into a fresh instance.
    scripting.registerScript("cap_edge",
        \\spec = {}
        \\32.times { |i| spec["f%02d" % i] = 0 }
        \\Wide32 = Labelle.component("Wide32", spec)
        \\def init
        \\  e = Labelle::Entity.create
        \\  w = Wide32.new
        \\  32.times { |i| w[i] = i }
        \\  raise "wide set refused" unless e.set(w)
        \\  w2 = Wide32.new
        \\  raise "wide get_into failed" if e.get_into(Wide32, w2).nil?
        \\  raise "wide field mismatch" unless w2.f00 == 0 && w2.f31 == 31
        \\  e.set("CapOk", ok: true)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Both over-wide scripts failed AT LOAD, message + defining line...
    try expect(mock.logsContain("component 'WideDsl' has 33 fields"));
    try expect(mock.logsContain("wide_dsl:3"));
    try expect(mock.logsContain("component 'WideRef' has 33 fields"));
    try expect(mock.logsContain("wide_ref:3"));
    try expect(mock.logsContain("split the component"));
    // ...and the 32-field edge drove the whole fast path.
    try expectComponent(1, "CapOk", "{\"ok\":true}");
}

test "controllers: registration order, LIFO teardown, setup eviction" {
    fresh();
    scripting.registerScript("controller_alpha", @embedFile("ruby/controller_alpha.rb"));
    scripting.registerScript("controller_beta", @embedFile("ruby/controller_beta.rb"));
    // A controller registered by a script whose init fails must never be
    // instantiated — script eviction takes registered classes with it.
    scripting.registerScript("doomed_ctrl",
        \\class DoomedController < Labelle::Controller
        \\  def setup
        \\    Labelle.log("doomed controller setup")
        \\  end
        \\end
        \\def init
        \\  raise "doomed script boom"
        \\end
    );
    try scripting.Controller.setup(.{});

    // Setup order: init hooks first (both scripts), then controllers in
    // registration order.
    try expectLogOrder("alpha init", "beta init");
    try expectLogOrder("beta init", "alpha setup");
    try expectLogOrder("alpha setup", "beta setup");

    // Gamma's setup raised: evicted, logged, siblings untouched.
    try expect(mock.logsContain("gamma setup boom"));
    try expect(mock.logsContain("controller evicted"));
    // The doomed script's controller never even instantiated.
    try expect(mock.logsContain("doomed script boom"));
    try expect(!mock.logsContain("doomed controller setup"));

    // Ticks reach surviving controllers (alpha advances its component;
    // beta's script-level update hook also keeps running).
    scripting.Controller.tick(.{}, 0.25);
    scripting.Controller.tick(.{}, 0.25);
    try expectComponent(1, "AlphaTicks", "{\"dt\":0.25,\"n\":2}");
    try expect(!mock.logsContain("gamma ticked"));

    // Controller subscriptions receive events.
    mock.hostEmit("order__ping", "{}");
    scripting.Controller.tick(.{}, 0.25);
    try expect(mock.logsContain("beta handler ran"));

    // Teardown: reverse registration order (beta before alpha), before
    // the plain deinit hooks; gamma (evicted) never tears down.
    scripting.Controller.deinit();
    try expectLogOrder("beta teardown", "alpha teardown");
    try expectLogOrder("alpha teardown", "beta deinit ran 3");
    try expect(!mock.logsContain("gamma teardown"));
}

test "zero-alloc steady state: into refills, FrameArray reuse, flat GC counters" {
    fresh();
    scripting.registerScript("zero_alloc", @embedFile("ruby/zero_alloc.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // 105 ticks: 5 warm-up, then 100 measured with the GC DISABLED —
    // the script asserts per tick that BOTH the arena index (per-tick
    // transient count) and the live-object count (strict allocation
    // counter) sit exactly at their tick-5 baselines. Any allocation in
    // the get_into/set/FrameArray hot loop moves live and fails the
    // verdict below; FrameArray growth would show in `growth`.
    for (0..105) |_| {
        scripting.Controller.tick(.{}, 0.02);
    }
    try expectComponent(1, "ZeroAlloc", "{\"arena_ok\":true,\"count\":1050," ++
        "\"growth\":0,\"live_ok\":true,\"ticks\":105}");

    // The measured window's component writes really happened (the loop
    // ran 10 rounds × 105 ticks against the live component).
    const hot = mock.componentJson(1, "Hot") orelse return error.TestExpectedComponent;
    try expect(std.mem.indexOf(u8, hot, "\"count\":1050") != null);
}

test "FrameArray unit semantics" {
    fresh();
    scripting.registerScript("frame_array", @embedFile("ruby/frame_array.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "FrameArrayOk", "{\"ok\":true}");
}

test "a raising controller setup rolls back its own handlers only" {
    fresh();
    // One script, three ownership grains on the SAME event: a handler
    // registered by init, a handler registered by a sibling controller's
    // successful setup, and handlers registered by a setup that then
    // raises. The failed setup's handlers must be rolled back — they
    // would otherwise keep firing into the dropped instance forever —
    // while the other two grains (same script! same owner symbol!) keep
    // firing, which is why the rollback is a snapshot of handler-list
    // lengths around each setup, not a script-ownership purge.
    scripting.registerScript("half_ctrl",
        \\def init
        \\  @e = Labelle::Entity.create
        \\  @e.set("Zombie", n: 0)
        \\  Labelle.on("zombie__ping") do |_ev|
        \\    s = @e.get("Zombie")
        \\    s[:n] += 1
        \\    @e.set("Zombie", s)
        \\  end
        \\end
        \\class GoodController < Labelle::Controller
        \\  def setup
        \\    on("zombie__ping") { |_ev| log("good handler ran") }
        \\  end
        \\end
        \\class HalfSetupController < Labelle::Controller
        \\  def setup
        \\    on("zombie__ping") { |_ev| log("zombie handler ran") }
        \\    on("zombie__fresh") { |_ev| log("zombie fresh ran") }
        \\    raise "half setup boom"
        \\  end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("half setup boom"));
    try expect(mock.logsContain("controller evicted"));

    // zombie__fresh IS subscribed host-side (subscription precedes the
    // raise and the contract has no unsubscribe) — the entry gets
    // drained, but its rolled-back handler list must not exist.
    mock.hostEmit("zombie__ping", "{}");
    mock.hostEmit("zombie__fresh", "{}");
    scripting.Controller.tick(.{}, 0.016);

    // The init handler and the sibling controller's fired...
    try expectComponent(1, "Zombie", "{\"n\":1}");
    try expect(mock.logsContain("good handler ran"));
    // ...the failed setup's never do: truncation rollback on the shared
    // name, whole-list removal on the fresh name.
    try expect(!mock.logsContain("zombie handler ran"));
    try expect(!mock.logsContain("zombie fresh ran"));

    // And they stay dead on later dispatches.
    mock.hostEmit("zombie__ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Zombie", "{\"n\":2}");
    try expectEqual(@as(usize, 2), mock.logCount("good handler ran"));
    try expect(!mock.logsContain("zombie handler ran"));
}

test "init-failure evictions leave no GC arena residue" {
    // Baseline: the probe alone — its first update records the absolute
    // arena index at a fixed point of the tick.
    fresh();
    scripting.registerScript("arena_probe", @embedFile("ruby/arena_probe.rb"));
    try scripting.Controller.setup(.{});
    scripting.Controller.tick(.{}, 0.016);
    const baseline = mock.componentJson(1, "ProbeArena") orelse
        return error.TestExpectedComponent;
    var saved: [64]u8 = undefined;
    @memcpy(saved[0..baseline.len], baseline); // survives the reset below
    const baseline_json = saved[0..baseline.len];

    // Eviction-heavy run, fresh VM: eight scripts whose init raises load
    // BEFORE the same probe. The pinned invariant: however many eviction
    // entries ran, the probe reads the SAME absolute arena index — no
    // per-eviction residue.
    //
    // Scope honesty: Vm.evictScript carries the same explicit arena
    // save/restore as every other entry, but this test alone cannot
    // distinguish its presence TODAY — mrb_funcall_with_block self-
    // restores the arena around the callee (vendor/mruby/src/vm.c, the
    // `int ai = mrb_gc_arena_save` / `mrb_gc_arena_restore(mrb, ai)`
    // bracket) and re-protects only the RETURN value, and this entry
    // deals purely in immediates (symbol argument, nil return). The
    // bracket becomes load-bearing — and this test the tripwire — the
    // moment the eviction entry materializes any heap value outside the
    // funcall: a String argument, a diagnostic return, a formatted
    // exception message. That is exactly the shape loadScript's bracket
    // already protects against (parse products are top-level heap).
    fresh();
    inline for (0..8) |i| {
        scripting.registerScript(std.fmt.comptimePrint("bad{d}", .{i}),
            \\def init
            \\  raise "bad init"
            \\end
        );
    }
    scripting.registerScript("arena_probe", @embedFile("ruby/arena_probe.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    scripting.Controller.tick(.{}, 0.016);

    // Premise: all eight evictions actually happened...
    try expectEqual(@as(usize, 8), mock.logCount("script evicted"));
    // ...and left zero arena residue: byte-identical probe readings.
    const got = mock.componentJson(1, "ProbeArena") orelse
        return error.TestExpectedComponent;
    try expectEqualStrings(baseline_json, got);
}

test "top-level helpers are private to their script (no Object hijack)" {
    fresh();
    // The lua caller-_ENV ownership test, mirrored: script A's update
    // calls a helper A defined; script B later defines the same helper
    // name. Without the generalized harvest both helpers would live on
    // Object and B's def would hijack A's harvested update (receivers
    // inherit from Object).
    scripting.registerScript("helper_a",
        \\def helper
        \\  "A"
        \\end
        \\def update(dt)
        \\  @e ||= Labelle::Entity.create
        \\  @e.set("HelperA", saw: helper)
        \\end
    );
    scripting.registerScript("helper_b",
        \\def helper
        \\  "B"
        \\end
        \\def update(dt)
        \\  @e ||= Labelle::Entity.create
        \\  @e.set("HelperB", saw: helper)
        \\end
    );
    // A third script with NO helper of its own: the name must not resolve
    // at all — under the leak it would silently get A's or B's.
    scripting.registerScript("helper_none",
        \\def init
        \\  @e = Labelle::Entity.create
        \\  @e.set("HelperLeak", leaked: Object.new.respond_to?(:helper, true))
        \\end
        \\def update(dt)
        \\  helper
        \\rescue NameError
        \\  s = @e.get("HelperLeak")
        \\  s[:raised] = true
        \\  @e.set("HelperLeak", s)
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);

    // helper_none's init ran during setup → entity 1; the two updates
    // created entities 2 and 3 on the first tick.
    try expectComponent(2, "HelperA", "{\"saw\":\"A\"}");
    try expectComponent(3, "HelperB", "{\"saw\":\"B\"}");
    // No global leak: the name neither enumerates on Object nor resolves
    // from a script that never defined it.
    try expectComponent(1, "HelperLeak", "{\"leaked\":false,\"raised\":true}");
}

// ── Console eval (labelle-scripting#4) ──────────────────────────────────

test "console eval renders expression results via inspect" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const r = scripting.Controller.evalCommand("1+2");
    try expect(r.ok);
    try expectEqualStrings("3", r.text);

    // inspect, not to_s: strings come back quoted, like irb/mirb.
    const s = scripting.Controller.evalCommand("\"hi\".upcase");
    try expect(s.ok);
    try expectEqualStrings("\"HI\"", s.text);
}

test "console eval persists top-level locals across evals (mirb keep)" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // One reused compile context = mruby's own REPL persistence: the
    // local's NAME survives in cxt->syms and its VALUE in the kept
    // top-level stack slots.
    const set = scripting.Controller.evalCommand("x = 5");
    try expect(set.ok);
    try expectEqualStrings("5", set.text); // assignments yield their value

    const get = scripting.Controller.evalCommand("x");
    try expect(get.ok);
    try expectEqualStrings("5", get.text);
}

test "console eval errors carry class, message and backtrace; VM and tick survive" {
    fresh();
    scripting.registerScript("counter", @embedFile("ruby/counter.rb"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.125);

    const err = scripting.Controller.evalCommand("raise \"console boom\"");
    try expect(!err.ok);
    try expect(std.mem.indexOf(u8, err.text, "RuntimeError") != null);
    try expect(std.mem.indexOf(u8, err.text, "console boom") != null);
    try expect(std.mem.indexOf(u8, err.text, "console:1") != null);

    // Parse errors surface the same isolated way (capture_errors →
    // SyntaxError with the line prefix)...
    const bad = scripting.Controller.evalCommand("def (");
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

test "console eval reaches the game world through the Labelle API" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const r = scripting.Controller.evalCommand(
        "Labelle::Entity.create.set(\"FromEval\", {a: 1})",
    );
    try expect(r.ok);
    try expectEqualStrings("true", r.text); // Entity#set returns rc == 0
    try expectComponent(1, "FromEval", "{\"a\":1}");
}

test "console eval bounds oversized results into valid truncated response JSON" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    var buf: [scripting.eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand(
        "{\"code\":\"\\\"x\\\" * 9000\"}",
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
    // inspect renders the string QUOTED: the value opens with `"` + x's.
    try expect(std.mem.startsWith(u8, parsed.value.value, "\"xxx"));
    try expect(std.mem.endsWith(u8, parsed.value.value, scripting.eval.truncation_marker));
}

test "console eval during ticking leaves registered scripts undisturbed" {
    fresh();
    scripting.registerScript("counter", @embedFile("ruby/counter.rb"));
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

test "console eval: mruby inspect hex-escapes invalid bytes (already JSON-safe)" {
    fresh();
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // The ruby render path is `#inspect`, and mruby's String#inspect
    // hex-escapes non-UTF-8 bytes — so invalid bytes never reach the
    // response builder raw from here (the builder's U+FFFD replacement
    // is pinned language-independently in the shared suite and by the
    // lua suite, whose tostring DOES pass raw bytes).
    const r = scripting.Controller.evalCommand("255.chr");
    try expect(r.ok);
    try expectEqualStrings("\"\\xff\"", r.text);
}
