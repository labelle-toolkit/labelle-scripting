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

test "csharp bulk v1.3: packed codec round-trips typed views, JSON stays the fallback" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // Every field kind survived the binary round-trip (f32/i64/bool/u64).
    try expect(mock.logsContain("CS_BULK_PACKED_1.5_-42_True_123"));
    // The stored JSON is in the mock's SCHEMA order (power,score,alive,
    // seed) — the packed set wrote it. The JSON fallback sorts keys, so
    // key order proves the path taken. (Entity 2: spawner made 1.)
    try expectComponent(2, "Stats", "{\"power\":1.5,\"score\":-42,\"alive\":true,\"seed\":123}");
    // The schema-less component round-trips through JSON.
    try expect(mock.logsContain("CS_BULK_PLAIN_2.5"));
    // JSON-fallback coercion (round 1): whole-number floats are spelled
    // as int-class tokens (`{"a":2}` — by the host AND by our own
    // fallback encoder) and must still land in the f32 view field.
    try expect(mock.logsContain("CS_BULK_PLAIN_INT_2"));
    try expect(mock.logsContain("CS_BULK_PLAIN_WHOLE_3"));
    try expectComponent(2, "Plain", "{\"a\":3}");
    // A bit-63 u64 rides tag 3 bit-exact (C# has a real ulong).
    try expect(mock.logsContain("CS_BULK_U64_OK"));
    try expectComponent(3, "Stats", "{\"power\":0,\"score\":0,\"alive\":false,\"seed\":9223372036854775809}");
    // Non-finite policy: NaN refused up front — nothing stored.
    try expect(mock.logsContain("CS_BULK_NAN_REFUSED"));
    try expect(mock.componentJson(4, "Stats") == null);
    // Absent components answer false through both routes.
    try expect(mock.logsContain("CS_BULK_ABSENT_OK"));
}

test "csharp bulk v1.3: batch refusals are loud — int fields, stale set, nesting, mismatch" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // Int-carrying components refused on both directions
    // (ArgumentException, caught in-script).
    try expect(mock.logsContain("CS_BULK_GET_INT_REFUSED"));
    try expect(mock.logsContain("CS_BULK_SET_INT_REFUSED"));
    // The exact-size positional-coupling guard fired; nothing applied.
    try expect(!mock.logsContain("CS_BULK_STALE_ACCEPTED"));
    try expect(mock.logsContain("CS_BULK_STALE_REFUSED"));
    // Duplicate component names refused before any host call.
    try expect(!mock.logsContain("CS_BULK_DUP_ACCEPTED"));
    try expect(mock.logsContain("CS_BULK_DUP_REFUSED"));
    // Float-only enforcement: the bool-carrying view TYPE refused
    // before any host call (zero-copy overlay would read garbage).
    try expect(!mock.logsContain("CS_BULK_BOOLVIEW_ACCEPTED"));
    try expect(mock.logsContain("CS_BULK_BOOLVIEW_REFUSED"));
    // Nested Batch calls refused.
    try expect(!mock.logsContain("CS_BULK_NESTED_ACCEPTED"));
    try expect(mock.logsContain("CS_BULK_NESTED_REFUSED"));
    // Layout mismatch (zero-stream-float component vs one-field view)
    // refused before any delegate call.
    try expect(!mock.logsContain("CS_BULK_MISMATCH_ACCEPTED"));
    try expect(!mock.logsContain("CS_BULK_MISMATCH_RAN"));
    try expect(mock.logsContain("CS_BULK_MISMATCH_REFUSED"));
}

test "csharp bulk stage 3: iterator exit semantics — early exit commits, throw aborts" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // Empty query: 0, the delegate never ran.
    try expect(mock.logsContain("CS_BULK_EMPTY_0"));
    try expect(!mock.logsContain("CS_BULK_EMPTY_RAN"));
    // BatchWhile stopped after the first row and COMMITTED its write
    // (the script re-read x==11 / 2 / 3 through the contract itself).
    try expect(mock.logsContain("CS_BULK_WHILE_COMMIT_OK"));
    // The throwing delegate aborted the whole write (x stayed 11).
    try expect(!mock.logsContain("CS_BULK_THROW_SWALLOWED"));
    try expect(mock.logsContain("CS_BULK_THROW_ABORTED"));
}

test "csharp bulk stage 3: the ref-struct iterator round-trips the steady state" {
    fresh();
    defer scripting.Controller.deinit();
    try setup();

    // The raw tier saw exactly 3 entities × stride 4 on the fresh set.
    try expect(mock.logsContain("CS_BULK_RAW_3_12"));

    tick(0.016);
    try expect(mock.logsContain("CS_BULK_ITER_3"));
    // Entities 8..10 are the iterator's set (see BulkProbe.cs's id
    // ledger); write-through refs mapped [X, Y | Vx, Vy] as the stream
    // lays out, and the bounce flipped entity 10's Vx.
    try expectComponent(8, "BatchPos", "{\"x\":11,\"y\":-10}");
    try expectComponent(9, "BatchPos", "{\"x\":12,\"y\":-10}");
    try expectComponent(10, "BatchPos", "{\"x\":13,\"y\":-10}");
    try expectComponent(10, "BatchVel", "{\"vx\":-10,\"vy\":-10}");
    try expectComponent(8, "BatchVel", "{\"vx\":10,\"vy\":-10}");
    // Second tick is steady state (entity 10 moves backward, bounced).
    tick(0.016);
    try expectComponent(8, "BatchPos", "{\"x\":21,\"y\":-20}");
    try expectComponent(10, "BatchPos", "{\"x\":3,\"y\":-20}");
}
