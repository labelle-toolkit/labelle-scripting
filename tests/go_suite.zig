//! The go sub-module driven end to end against the mock host world —
//! see tests/root.zig for the linking model and hygiene notes shared by
//! every language suite.
//!
//! The go binary's extra ingredient is the c-archive (build.zig's test
//! wiring): the SHIPPED glue + labelle package (native-go/, reached by
//! the test module's `replace labelle => ../../native-go` directive)
//! recomposed around tests/go/game/'s scenario scripts (tests/go/
//! main.go is the eight-line stub the shipped glue/main.go models).
//! Contract symbols resolve against mock_world.zig exactly as in every
//! other suite; the `labelle_go_*` glue entries resolve against the
//! archive — both are the production linking model (in a real game the
//! assembler's build step links the same archive into the same binary
//! as the host's exports).
//!
//! Scenario selection: `Register` runs afresh inside every
//! `Controller.setup`, and the test archive's game module exports
//! `labelle_go_test_select` (test-only) to pick which scripts it
//! registers — the go analog of the rust suite's labelle_rs_test_select.
//! Scripts assert their own invariants and a failed assert PANICS —
//! which the glue recovers (that containment is itself under test), the
//! script is evicted or the hook skipped, and the verdict component
//! never lands: script-side panics surface as missing-component
//! failures here.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Test-archive-only export (tests/go/main.go): choose the scenario the
/// next setup's `Register` builds.
extern fn labelle_go_test_select(ptr: [*]const u8, len: usize) void;

fn selectScenario(name: []const u8) void {
    labelle_go_test_select(name.ptr, name.len);
}

/// Reset ALL global state — Controller, registry, mock world AND the
/// archive-side scenario selector.
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

    // Init() ran during setup: player entity exists at the origin.
    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("go: player 1 ready"));

    // Host emits tick_started before each tick (the POC driver's shape);
    // the script's OnEvent sees each one during the inbox dispatch.
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
    try expect(mock.logsContain("go: saw tick 4"));
    // Third tick: bullet spawned + event emitted toward the game.
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
    try expect(mock.logsContain("go: bullet away"));
    // Controller.tick stamped the dt into the host (the script's Dt()
    // agreed with its hook argument — asserted in-script, so a drift
    // would have panicked and Position never reached 50).
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

    // Both bystanders advanced every tick — the ticks survived the
    // panicking script between them, and no panic crossed the FFI
    // boundary (an unwind through a cgo export would have killed this
    // whole test process).
    try expectComponent(1, "Counter", "{\"dt\":0.125,\"n\":3}");
    try expectComponent(2, "Counter", "{\"dt\":0.125,\"n\":3}");

    // Logged once per tick, attributed; update panics do NOT evict (the
    // script's state is intact — the author gets the report every tick).
    // The count is EXACT: the glue logs ONE line per panic (recovered Go
    // panics write nothing to stderr, so unlike rust there is no second
    // location line to disambiguate — a duplicate would double this).
    try expectEqual(@as(usize, 3), mock.logCount("boom on tick"));
    try expect(mock.logsContain("script 'exploder'"));
    try expect(mock.logsContain("panicked"));
    try expectEqual(@as(usize, 0), mock.logCount("script evicted"));
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

test "a panicking Register() drops every registration and the game keeps running" {
    fresh();
    selectScenario("register_panic");
    // Setup itself succeeds — a broken game module must not brick the
    // host boot; it logs and runs scriptless.
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expect(mock.logsContain("Register() panicked"));
    try expect(mock.logsContain("register scenario panic"));
    try expect(mock.logsContain("go: no scripts registered"));
    try expect(mock.logsContain("go setup failed"));

    // All-or-nothing: nothing registered, ticks are inert, nothing dies.
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.aliveCount());
}

test "u64 entity ids round-trip bit-exact at 0x8000000000000001" {
    fresh();
    // Force the next id past the signed-integer boundary: any int64/float
    // hop in the wrapper or the query parse would drift it and the
    // script's checks would panic — evicting it, and these components
    // would never land.
    mock.setNextEntityId(0x8000000000000001);
    selectScenario("big_id");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    const big_id: u64 = 0x8000000000000001;
    try expectComponent(big_id, "Marker", "{\"tag\":42}");
    // The id renders unsigned end to end (9223372036854775809, not a
    // negative int64 or a rounded float).
    try expectComponent(big_id, "BigId", "{\"idstr\":\"9223372036854775809\"}");
    try expectEqual(@as(usize, 1), mock.aliveCount());
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

test "the guest runtime coexists: goroutines compute, the hook applies, GC churns" {
    fresh();
    selectScenario("goroutines");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Init forced a runtime.GC() against live state and logged ready —
    // the guest GC ran with the host alive, no crash.
    try expect(mock.logsContain("go: goroutines ready"));

    // Each tick: ten goroutines sum 0..99 in parallel, join, then the
    // MAIN thread applies the result through the contract. The value
    // (4950) proves the goroutine fan-out/join produced the right
    // answer AND that forced per-tick GC never corrupted anything.
    for (0..3) |_| scripting.Controller.tick(.{}, 0.016);
    try expectComponent(1, "Sum", "{\"total\":4950}");
    try expect(mock.logsContain("go: goroutine sum ok"));
}

test "bulk v1.3: batch_get/batch_set round-trip the whole query as one f32 stream" {
    fresh();
    selectScenario("bulk_batch");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Int-carrying components refused LOUDLY on both directions — as
    // error values, the go spelling of ruby's ArgumentError raise.
    try expect(mock.logsContain("go: get int refused:true"));
    try expect(mock.logsContain("go: set int refused:true"));

    scripting.Controller.tick(.{}, 0.016);
    // 3 matching entities (the lone BatchPos-only one filtered out),
    // stride 4 → exactly 12 floats crossed.
    try expect(mock.logsContain("go: batch count:3 floats:12"));
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

test "bulk v1.3: batch_set errors when the entity set changed since batch_get" {
    fresh();
    selectScenario("bulk_stale");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    // The exact-size positional-coupling guard fired and surfaced as
    // ErrBatchEntitySetChanged — safe to catch and re-get.
    try expect(mock.logsContain("go: stale refused:true"));
    // NOTHING was applied: the survivor keeps its batch_get-era value.
    try expectComponent(1, "BatchPos", "{\"x\":0,\"y\":0}");
}

test "bulk v1.3: the typed view tier round-trips through Batch2" {
    fresh();
    selectScenario("bulk_iter");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("go: iter n:3"));
    // The callback's writes landed through the one batch_set — typed
    // views mapped [x, y | vx, vy] exactly as the stream lays out.
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

test "bulk v1.3: view-tier exit semantics — early exit commits, panic aborts, refusals" {
    fresh();
    selectScenario("bulk_iter_edge");
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // Empty query: 0, the callback never ran.
    try expect(mock.logsContain("go: empty n:0"));
    try expect(!mock.logsContain("go: empty ran"));
    // Early exit (return false) after mutating entity 1 only: its write
    // COMMITTED, not-yet-visited entities round-tripped unchanged.
    try expect(mock.logsContain("go: while n:3"));
    try expectComponent(1, "BatchPos", "{\"x\":11,\"y\":0}");
    try expectComponent(2, "BatchPos", "{\"x\":2,\"y\":0}");
    try expectComponent(3, "BatchPos", "{\"x\":3,\"y\":0}");
    // The panicking callback aborted the whole write (x stays 11, the
    // 999 never landed) — and the panic never crossed the FFI boundary.
    try expect(mock.logsContain("go: panic aborted:true"));
    // Duplicate component names refused before any host call (the 555
    // never landed — x still 11).
    try expect(mock.logsContain("go: dup refused:true"));
    // Layout mismatch (a zero-stream-float component vs a one-field
    // view) refused before any callback call.
    try expect(mock.logsContain("go: mismatch refused:true"));
    try expect(!mock.logsContain("go: mismatch ran"));
    try expectComponent(4, "BatchPos", "{\"x\":50,\"y\":0}");
}

test "console eval is a documented refusal for native-compiled go" {
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

test "registered sources are refused loudly — go code arrives compiled, not as text" {
    fresh();
    scripting.registerScript("stray", "func update() {}");
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

test "the Zig-side scratch seam is constitutionally silent for go" {
    fresh();
    // No VM shim exists on the Zig side (buffers live in the archive),
    // so nothing may ever count a growth — the shape-parity counter
    // stays pinned at zero.
    try expectEqual(@as(usize, 0), scripting.scratchGrowthCount());
}
