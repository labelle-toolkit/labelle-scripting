//! Id-tagged batch codec suite (contract v1.4, labelle-engine#788 / #57):
//! the binding-side id-column codec (src/id_batch.zig) and the mock
//! world's `_ids` exports, driven directly — no VM, language-independent,
//! so like the eval-shared suite one mirror (the LUA binary) is the whole
//! coverage.
//!
//! What it pins:
//!   - `stripIds` compacts the host's `[u32 count][ (u64 id)(floats) ]*`
//!     to the positional `[u32 count][floats]*` the bindings decode, and
//!     stashes the ids;
//!   - `setWithIds` re-attaches those ids and applies BY ID through the
//!     mock's `_batch_set_ids`;
//!   - the KEY new capability: a destroy+spawn between get and set skips
//!     the stale row instead of landing it on the new occupant (which the
//!     POSITIONAL host path — still present, still tested below — cannot
//!     do; it refuses the whole batch);
//!   - the comptime `host_has_id_batch` probe is TRUE here (the engine
//!     stub carries the `batch_id_row_prefix` marker), matching the mock's
//!     `_ids` exports — the same probe-matches-link-truth invariant a
//!     generated game ≥ 2.7.0 has.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const contract = scripting.contract;
const id_batch = scripting.id_batch;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// "BatchPos" (x,y) is the mock's float-only round-trip component — stride
// 2 floats = 8 bytes; the id-tagged row is 8 (id) + 8 (floats) = 16 bytes.
const NAMES = "[\"BatchPos\"]";

fn setPos(id: u64, x: f32, y: f32) void {
    var buf: [64]u8 = undefined;
    const j = std.fmt.bufPrint(&buf, "{{\"x\":{d},\"y\":{d}}}", .{ x, y }) catch unreachable;
    mock.setComponentDirect(id, "BatchPos", j);
}

test "id_batch: host_has_id_batch is TRUE under the v1.4 test stub" {
    try expect(contract.host_has_id_batch);
    try expectEqual(@as(usize, 8), contract.BATCH_ID_ROW_PREFIX);
}

test "id_batch.stripIds compacts the id-tagged buffer and stashes the ids" {
    // Hand-build a two-row id-tagged buffer: [u32 2] then per row
    // [u64 id][f32 x][f32 y].
    var raw: [4 + 2 * 16]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 2, .little);
    // row 0: id 5, (1.0, 2.0)
    std.mem.writeInt(u64, raw[4..][0..8], 5, .little);
    std.mem.writeInt(u32, raw[12..][0..4], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, raw[16..][0..4], @bitCast(@as(f32, 2.0)), .little);
    // row 1: id 9, (3.0, 4.0)
    std.mem.writeInt(u64, raw[20..][0..8], 9, .little);
    std.mem.writeInt(u32, raw[28..][0..4], @bitCast(@as(f32, 3.0)), .little);
    std.mem.writeInt(u32, raw[32..][0..4], @bitCast(@as(f32, 4.0)), .little);

    const compacted = id_batch.stripIds(&raw, raw.len);
    // Compacted = [u32 2] + 4 floats = 4 + 16 = 20 bytes.
    try expectEqual(@as(usize, 20), compacted);
    try expectEqual(@as(u32, 2), std.mem.readInt(u32, raw[0..4], .little));
    try expectEqual(@as(usize, 2), id_batch.stashedCount());
    const f0: f32 = @bitCast(std.mem.readInt(u32, raw[4..][0..4], .little));
    const f1: f32 = @bitCast(std.mem.readInt(u32, raw[8..][0..4], .little));
    const f2: f32 = @bitCast(std.mem.readInt(u32, raw[12..][0..4], .little));
    const f3: f32 = @bitCast(std.mem.readInt(u32, raw[16..][0..4], .little));
    try expectEqual(@as(f32, 1.0), f0);
    try expectEqual(@as(f32, 2.0), f1);
    try expectEqual(@as(f32, 3.0), f2);
    try expectEqual(@as(f32, 4.0), f3);
}

test "id_batch: full round-trip through the mock's _ids exports" {
    mock.reset();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);

    // GET via the id-tagged extern (resolves to the mock export), then
    // strip the id column binding-side.
    var buf: [256]u8 = undefined;
    const raw_n = contract.labelle_component_batch_get_ids(NAMES.ptr, NAMES.len, &buf, buf.len);
    try expect(raw_n != 0 and raw_n != contract.BATCH_INT_REFUSED);
    const n = id_batch.stripIds(&buf, raw_n);
    try expectEqual(@as(usize, 2), id_batch.stashedCount());
    try expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[0..4], .little));
    // 2 entities × 2 floats = 4 floats = 16 bytes + 4 header = 20.
    try expectEqual(@as(usize, 20), n);

    // Mutate the flat float stream (no ids visible to the "script").
    var stream: [16]u8 = undefined;
    @memcpy(&stream, buf[4..20]);
    std.mem.writeInt(u32, stream[0..4], @bitCast(@as(f32, 10)), .little); // e1.x
    std.mem.writeInt(u32, stream[4..8], @bitCast(@as(f32, 20)), .little); // e1.y
    std.mem.writeInt(u32, stream[8..12], @bitCast(@as(f32, 30)), .little); // e2.x
    std.mem.writeInt(u32, stream[12..16], @bitCast(@as(f32, 40)), .little); // e2.y

    const rc = id_batch.setWithIds(NAMES, &stream);
    try expectEqual(@as(i32, 0), rc);
    try expectEqualStrings("{\"x\":10,\"y\":20}", mock.componentJson(e1, "BatchPos").?);
    try expectEqualStrings("{\"x\":30,\"y\":40}", mock.componentJson(e2, "BatchPos").?);
}

test "id_batch: destroy+spawn between get and set skips the stale row (new occupant untouched)" {
    mock.reset();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);

    var buf: [256]u8 = undefined;
    const raw_n = contract.labelle_component_batch_get_ids(NAMES.ptr, NAMES.len, &buf, buf.len);
    const n = id_batch.stripIds(&buf, raw_n);
    try expectEqual(@as(usize, 20), n);
    try expectEqual(@as(usize, 2), id_batch.stashedCount());

    // Mark every field, then the same-count destroy+spawn.
    var stream: [16]u8 = undefined;
    std.mem.writeInt(u32, stream[0..4], @bitCast(@as(f32, 100)), .little);
    std.mem.writeInt(u32, stream[4..8], @bitCast(@as(f32, 101)), .little);
    std.mem.writeInt(u32, stream[8..12], @bitCast(@as(f32, 200)), .little);
    std.mem.writeInt(u32, stream[12..16], @bitCast(@as(f32, 201)), .little);

    mock.destroyEntityDirect(e2); // destroy e2
    const e3 = mock.createEntityDirect(); // spawn a replacement (same query count)
    setPos(e3, 7, 8);

    // setWithIds still sends BOTH stashed ids (e1, e2). The host applies e1,
    // skips e2 (dead), and never touches e3 (its id was not in the buffer).
    const rc = id_batch.setWithIds(NAMES, &stream);
    try expectEqual(@as(i32, 0), rc);
    try expectEqualStrings("{\"x\":100,\"y\":101}", mock.componentJson(e1, "BatchPos").?);
    // The stale row for e2 did NOT land on the new occupant e3.
    try expectEqualStrings("{\"x\":7,\"y\":8}", mock.componentJson(e3, "BatchPos").?);
    try expect(!mock.entityAlive(e2));
}

test "id_batch: the POSITIONAL host path (pre-2.7 fallback) refuses a count-changed batch" {
    // The v1.3 positional exports the bindings fall back to on an engine in
    // [2.6.0, 2.7.0) are STILL present and STILL guard count coupling. This
    // pins that the fallback behavior the comptime `else` branch selects is
    // intact: a destroy that changes the re-queried count refuses -1, having
    // written nothing (the exact hole the id path closes).
    mock.reset();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);

    // Positional get: [u32 count][f32 stream] — 2 entities × 2 floats.
    var buf: [256]u8 = undefined;
    const gn = mock.batchGetDirect(NAMES, buf[0..]);
    try expectEqual(@as(usize, 4 + 16), gn);
    // The pure f32 stream the positional set expects (no header).
    const stream = buf[4..gn];

    // Destroy one entity, then apply the (now stale-sized) stream: the
    // preflight count mismatch refuses -1.
    mock.destroyEntityDirect(e2);
    const rc = mock.batchSetDirect(NAMES, stream);
    try expectEqual(@as(i32, -1), rc);
    // Nothing was written — e1 keeps its original value.
    try expectEqualStrings("{\"x\":1,\"y\":2}", mock.componentJson(e1, "BatchPos").?);
}

test "id_batch: int-carrying component refuses on the id path (like positional)" {
    mock.reset();
    const e1 = mock.createEntityDirect();
    mock.setComponentDirect(e1, "Stats", "{\"power\":1,\"score\":2,\"alive\":true,\"seed\":3}");
    var buf: [256]u8 = undefined;
    const n = contract.labelle_component_batch_get_ids("[\"Stats\"]", 9, &buf, buf.len);
    try expectEqual(contract.BATCH_INT_REFUSED, n);
    const rc = contract.labelle_component_batch_set_ids("[\"Stats\"]", 9, &buf, 0);
    try expectEqual(@as(i32, -2), rc);
}
