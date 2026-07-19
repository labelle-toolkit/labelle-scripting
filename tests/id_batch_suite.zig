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

    const compacted = id_batch.stripIds(NAMES, &raw, raw.len);
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
    const n = id_batch.stripIds(NAMES, buf[0..raw_n], raw_n);
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
    const n = id_batch.stripIds(NAMES, buf[0..raw_n], raw_n);
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

// ── stash lifecycle (scripting#58 review — the one-stash hazard) ──────────

const NAMES_VEL = "[\"BatchVel\"]";

fn setVel(id: u64, vx: f32, vy: f32) void {
    var buf: [64]u8 = undefined;
    const j = std.fmt.bufPrint(&buf, "{{\"vx\":{d},\"vy\":{d}}}", .{ vx, vy }) catch unreachable;
    mock.setComponentDirect(id, "BatchVel", j);
}

/// Get one query through the id path and stash it; returns the flat
/// (positional) f32-stream length (bytes) the "script" would see.
fn getAndStash(names: []const u8, buf: []u8) usize {
    const raw_n = contract.labelle_component_batch_get_ids(names.ptr, names.len, buf.ptr, buf.len);
    return id_batch.stripIds(names, buf[0..raw_n], raw_n);
}

fn writeF32(dst: []u8, off: usize, v: f32) void {
    std.mem.writeInt(u32, dst[off..][0..4], @bitCast(v), .little);
}

test "id_batch: interleaved get/get/set/set never crosses ids between queries" {
    // get(A) then get(B) overwrites the single stash; set(A) must NOT
    // reattach B's ids to A's stream — it degrades to the positional path,
    // which re-queries A's own entities. set(B) stays on the id path.
    mock.reset();
    id_batch.invalidateStash();
    const a1 = mock.createEntityDirect();
    const a2 = mock.createEntityDirect();
    setPos(a1, 1, 1);
    setPos(a2, 2, 2);
    const b1 = mock.createEntityDirect();
    const b2 = mock.createEntityDirect();
    setVel(b1, 10, 10);
    setVel(b2, 20, 20);

    var bufA: [256]u8 = undefined;
    var bufB: [256]u8 = undefined;
    const na = getAndStash(NAMES, &bufA); // stash = A
    const nb = getAndStash(NAMES_VEL, &bufB); // stash = B (overwrites A)
    try expectEqual(@as(usize, 20), na);
    try expectEqual(@as(usize, 20), nb);
    try expectEqual(@as(usize, 2), id_batch.stashedCount()); // B is pending

    // A's marked stream — set(A) while B is stashed → positional re-query.
    var streamA: [16]u8 = undefined;
    writeF32(&streamA, 0, 100);
    writeF32(&streamA, 4, 101);
    writeF32(&streamA, 8, 102);
    writeF32(&streamA, 12, 103);
    try expectEqual(@as(i32, 0), id_batch.setWithIds(NAMES, &streamA));

    // B's marked stream — set(B) matches the stash → id path.
    var streamB: [16]u8 = undefined;
    writeF32(&streamB, 0, 200);
    writeF32(&streamB, 4, 201);
    writeF32(&streamB, 8, 202);
    writeF32(&streamB, 12, 203);
    try expectEqual(@as(i32, 0), id_batch.setWithIds(NAMES_VEL, &streamB));

    // Each query's entities got THEIR OWN stream — no cross-contamination.
    try expectEqualStrings("{\"x\":100,\"y\":101}", mock.componentJson(a1, "BatchPos").?);
    try expectEqualStrings("{\"x\":102,\"y\":103}", mock.componentJson(a2, "BatchPos").?);
    try expectEqualStrings("{\"vx\":200,\"vy\":201}", mock.componentJson(b1, "BatchVel").?);
    try expectEqualStrings("{\"vx\":202,\"vy\":203}", mock.componentJson(b2, "BatchVel").?);
}

test "id_batch: a standalone set (no paired get) uses the positional path, not the id reader" {
    mock.reset();
    id_batch.invalidateStash();
    const e1 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    try expectEqual(@as(usize, 0), id_batch.stashedCount());
    // A raw f32 stream with NO stashed ids. Fed to `_batch_set_ids` its
    // first 8 bytes (two f32) would be read as an entity id → garbage lookup
    // → silent no-op. The positional path re-queries and actually applies.
    var stream: [8]u8 = undefined;
    writeF32(&stream, 0, 9);
    writeF32(&stream, 4, 9);
    try expectEqual(@as(i32, 0), id_batch.setWithIds(NAMES, &stream));
    try expectEqualStrings("{\"x\":9,\"y\":9}", mock.componentJson(e1, "BatchPos").?);
}

test "id_batch: a resized stream is refused via positional, not misread as id rows" {
    mock.reset();
    id_batch.invalidateStash();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);
    var buf: [256]u8 = undefined;
    _ = getAndStash(NAMES, &buf);
    try expectEqual(@as(usize, 2), id_batch.stashedCount());
    // Script grew the flat array to 32 bytes (still divisible by count 2 →
    // would infer stride 16). The stashed stride (8) is authoritative:
    // 32 != 2*8 → positional, whose preflight refuses (-1), nothing written.
    var resized: [32]u8 = undefined;
    @memset(&resized, 0);
    try expectEqual(@as(i32, -1), id_batch.setWithIds(NAMES, &resized));
    try expectEqualStrings("{\"x\":1,\"y\":2}", mock.componentJson(e1, "BatchPos").?);
    try expectEqualStrings("{\"x\":3,\"y\":4}", mock.componentJson(e2, "BatchPos").?);
}

test "id_batch: the stash is consumed after a set — a later unpaired set can't reuse spent ids" {
    mock.reset();
    id_batch.invalidateStash();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);
    var buf: [256]u8 = undefined;
    const n = getAndStash(NAMES, &buf);
    try expectEqual(@as(usize, 2), id_batch.stashedCount());

    var stream1: [16]u8 = undefined;
    @memcpy(&stream1, buf[4..n]);
    writeF32(&stream1, 0, 50); // e1.x
    // First set: paired id path, applies, and CONSUMES the stash.
    try expectEqual(@as(i32, 0), id_batch.setWithIds(NAMES, &stream1));
    try expectEqual(@as(usize, 0), id_batch.stashedCount());
    try expectEqualStrings("{\"x\":50,\"y\":2}", mock.componentJson(e1, "BatchPos").?);

    // Destroy e1, spawn e3 — the CURRENT query is [e2, e3]. A follow-up set
    // with NO fresh get must go positional (re-query [e2,e3], apply BOTH).
    // With a stale stash it would send spent ids [e1,e2] and leave the
    // spawned e3 untouched.
    mock.destroyEntityDirect(e1);
    const e3 = mock.createEntityDirect();
    setPos(e3, 7, 8);
    var stream2: [16]u8 = undefined;
    writeF32(&stream2, 0, 60);
    writeF32(&stream2, 4, 61);
    writeF32(&stream2, 8, 62);
    writeF32(&stream2, 12, 63);
    try expectEqual(@as(i32, 0), id_batch.setWithIds(NAMES, &stream2));
    try expectEqualStrings("{\"x\":60,\"y\":61}", mock.componentJson(e2, "BatchPos").?);
    // The SPAWNED e3 was updated too → positional re-query, not stale ids.
    try expectEqualStrings("{\"x\":62,\"y\":63}", mock.componentJson(e3, "BatchPos").?);
}

test "id_batch: same-shape interleaved gets poison the stash (paired set degrades to positional)" {
    // Two gets of the same names+count+stride while the first is still
    // pending: the identity can't tell the buffers apart, so the stash is
    // poisoned and the paired set takes the POSITIONAL path instead of
    // pairing with possibly-wrong ids. Observable via a count-change: the
    // positional path REFUSES the count-2 stream (-1), whereas the id path
    // would have returned 0 (skipping the dead row) and mutated e1.
    mock.reset();
    id_batch.invalidateStash();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    _ = getAndStash(NAMES, &buf1); // get1: stash {names, count 2, stride 8}
    _ = getAndStash(NAMES, &buf2); // get2: SAME identity while get1 pending → poison
    try expectEqual(@as(usize, 2), id_batch.stashedCount());

    // Change the current query count, then set the (poisoned) stream.
    mock.destroyEntityDirect(e2);
    var stream: [16]u8 = undefined;
    writeF32(&stream, 0, 77);
    writeF32(&stream, 4, 78);
    writeF32(&stream, 8, 79);
    writeF32(&stream, 12, 80);
    // Poison → positional _batch_set, whose preflight refuses the count-2
    // stream against the now-count-1 query.
    try expectEqual(@as(i32, -1), id_batch.setWithIds(NAMES, &stream));
    // Nothing written — the poisoned set never reached the id reader.
    try expectEqualStrings("{\"x\":1,\"y\":2}", mock.componentJson(e1, "BatchPos").?);
}

test "id_batch: a failed get clears the stash — the next set goes positional, not stale-id" {
    // Finding #1: a terminal-failure get never reaches `stripIds`, so the
    // binding/shim calls `invalidateStash()` on that exit (modeled here).
    // Without it a failed get would leave a prior get's ids for the next
    // set to mispair with.
    mock.reset();
    id_batch.invalidateStash();
    const e1 = mock.createEntityDirect();
    const e2 = mock.createEntityDirect();
    setPos(e1, 1, 2);
    setPos(e2, 3, 4);
    var buf: [256]u8 = undefined;
    _ = getAndStash(NAMES, &buf); // a successful get leaves a pending stash
    try expectEqual(@as(usize, 2), id_batch.stashedCount());

    // A failing get (refused / not bound) drops the stash on its exit path.
    id_batch.invalidateStash();
    try expectEqual(@as(usize, 0), id_batch.stashedCount());

    // Destroy e2, then set: with no stash the set goes positional (refuses
    // the count-changed 2-row stream, -1). A leftover stale stash would
    // instead take the id path (skip the dead e2, return 0, mutate e1).
    mock.destroyEntityDirect(e2);
    var stream: [16]u8 = undefined;
    @memset(&stream, 0);
    try expectEqual(@as(i32, -1), id_batch.setWithIds(NAMES, &stream));
    try expectEqualStrings("{\"x\":1,\"y\":2}", mock.componentJson(e1, "BatchPos").?);
}
