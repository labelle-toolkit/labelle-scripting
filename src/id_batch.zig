//! Binding-side id-column codec for the contract v1.4 id-tagged batch
//! variant (`labelle_component_batch_get_ids`/`_batch_set_ids`,
//! labelle-engine#788, engine ≥ 2.7.0).
//!
//! ## Why it lives here (one Zig codec, all seven languages)
//!
//! The whole point of #57 is that the flat-float SCRIPT API is UNCHANGED:
//! scripts still write/read the same flat f32 buffer laid out
//! `[u32 count][f32 stream]` (positional). The id column that makes the
//! batch safe against destroy+spawn is held ENTIRELY binding-side — this
//! module is where it is held. Both binding families route through it:
//!
//!   - the embedded VMs (ruby/lua/ts) call `stripIds`/`setWithIds` from
//!     their Zig binding directly, inside a `comptime host_has_id_batch`
//!     gate (so an old host never references the `_ids` externs);
//!   - the native families (rust/crystal/csharp/go) call the ordinary
//!     `labelle_scripting_bulk_batch_get`/`_set` shims (src/bulk_shims.zig)
//!     which route through here TRANSPARENTLY — the native code keeps
//!     decoding the positional `[u32 count][f32 stream]` layout and never
//!     learns the id column exists.
//!
//! ## The round trip
//!
//! GET: the host's `_batch_get_ids` writes `[u32 count]` then per entity
//! `[u64 id][f32 stream]`. `stripIds` COMPACTS that in place to the
//! positional `[u32 count][f32 stream]` the binding already decodes, and
//! STASHES the u64 ids in a module-level store. The binding is otherwise
//! unchanged (same count-header read, same float decode).
//!
//! SET: the binding hands back the pure positional f32 stream (no header).
//! `setWithIds` re-attaches the stashed ids — one per row, in get order —
//! to rebuild `[u64 id][f32 stream]` rows and calls `_batch_set_ids`,
//! which applies BY ID (skipping vanished / recycled / departed entities).
//! So a destroy+spawn between the paired get and set can no longer land a
//! stale row on a new occupant.
//!
//! ## Single active language per build
//!
//! Only one `-Dlanguage=…` backend is compiled into any game, so the two
//! module-level grow-only buffers below are a process singleton with no
//! cross-language contention — the same model the per-VM scratch buffers
//! already use. The get→set pairing must not interleave a DIFFERENT
//! batch query between the paired calls (it would clobber the id store) —
//! the identical constraint the shared transfer scratch already imposes,
//! and one the block iterators (get→yield→set, no intervening batch FFI)
//! never trip.

const std = @import("std");
const contract = @import("contract.zig");

/// The engine floor probe, re-exported for callers that gate on it.
pub const host_has_id_batch = contract.host_has_id_batch;

const PREFIX = contract.BATCH_ID_ROW_PREFIX; // 8 (u64 id per row)

/// Process-lifetime grow-only buffers. `page_allocator` keeps this
/// libc-independent (unlike the per-VM libc-realloc scratch, this module
/// is shared by native backends that may not link libc). Grows rarely —
/// once the swarm reaches steady size the capacity settles and every tick
/// reuses it, matching the per-VM scratch's amortized-zero behavior.
const gpa = std.heap.page_allocator;

var id_store: []u64 = &.{};
var id_len: usize = 0; // ids stashed by the last stripIds

var row_scratch: []u8 = &.{};

/// Test seam: reallocations across both buffers (proves they settle).
pub var growth_count: usize = 0;

fn ensureIds(n: usize) []u64 {
    if (id_store.len >= n) return id_store;
    const grown = gpa.realloc(id_store, @max(n, 64)) catch @panic("labelle: id_batch id store OOM");
    id_store = grown;
    growth_count += 1;
    return id_store;
}

fn ensureRows(n: usize) []u8 {
    if (row_scratch.len >= n) return row_scratch;
    const grown = gpa.realloc(row_scratch, @max(n, 256)) catch @panic("labelle: id_batch row scratch OOM");
    row_scratch = grown;
    growth_count += 1;
    return row_scratch;
}

/// Compact the host's `_batch_get_ids` output IN PLACE from
/// `[u32 count][ (u64 id)(f32 stream) ]*` to the positional
/// `[u32 count][f32 stream]*` the binding decodes, stashing the ids.
///
/// `raw` is the binding's transfer scratch (len ≥ `n`); `n` is the byte
/// length `_batch_get_ids` returned (already known ≤ cap by the caller's
/// grow-retry, and NOT one of the sentinels — the caller checks
/// `BATCH_INT_REFUSED`/0 first). Returns the compacted, floats-only byte
/// length (`4 + count*stride`) for the binding to decode exactly as it
/// decodes the positional variant.
pub fn stripIds(raw: []u8, n: usize) usize {
    if (n < 4) return n; // malformed — nothing to compact (caller-guarded)
    const count = std.mem.readInt(u32, raw[0..4], .little);
    if (count == 0) {
        id_len = 0;
        return 4; // count header only, no rows
    }
    const body = n - 4;
    const row_size = body / count; // 8 + stride, per row
    // Defensive: a row must carry at least its id prefix, and the body
    // must divide evenly. A malformed shape leaves the buffer untouched
    // and reports it whole (the binding's own belt catches oddities).
    if (row_size < PREFIX or row_size * count != body) {
        id_len = 0;
        return n;
    }
    const stride = row_size - PREFIX; // f32-stream bytes per row
    const ids = ensureIds(count);
    var dst: usize = 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const row = raw[4 + i * row_size ..];
        ids[i] = std.mem.readInt(u64, row[0..8], .little);
        // Leftward move (dst < src always, 8 bytes removed per row) —
        // copyForwards is safe for overlapping-shift-left.
        std.mem.copyForwards(u8, raw[dst..][0..stride], row[PREFIX..][0..stride]);
        dst += stride;
    }
    id_len = count;
    return dst;
}

/// Re-attach the stashed ids to the binding's pure positional f32 `stream`
/// (no header — exactly what the binding packs today) and apply via
/// `_batch_set_ids`. Rebuilds `[u64 id][f32 stream]` rows, one id per row
/// in get order. Returns the contract rc (0 ok, -1 shape/name/apply,
/// -2 int-field refusal). A `stream` whose length is not a whole number of
/// rows against the stashed count is layout drift — refused -1, nothing
/// sent.
pub fn setWithIds(names: []const u8, stream: []const u8) i32 {
    const count = id_len;
    // No stashed rows (empty query, or a standalone set not paired with a
    // get — e.g. the int-refusal probe): hand the stream straight to the
    // host so its NAME-based refusals still fire (int fields -2, unknown
    // names -1) — an empty stream is the legit 0-row case, a non-empty one
    // surfaces as the host's shape -1. Never swallow a refusal here.
    if (count == 0) {
        const p: ?[*]const u8 = if (stream.len == 0) null else stream.ptr;
        return contract.labelle_component_batch_set_ids(names.ptr, names.len, p, stream.len);
    }
    const stride = stream.len / count;
    // Layout drift (the script resized the array between get and set):
    // delegate to the host so its name refusals still fire and a genuine
    // shape mismatch surfaces as -1, rather than silently reshaping.
    if (stride * count != stream.len) {
        return contract.labelle_component_batch_set_ids(names.ptr, names.len, stream.ptr, stream.len);
    }
    const row_size = PREFIX + stride;
    const total = count * row_size;
    const buf = ensureRows(total);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const row = buf[i * row_size ..];
        std.mem.writeInt(u64, row[0..8], id_store[i], .little);
        @memcpy(row[PREFIX..][0..stride], stream[i * stride ..][0..stride]);
    }
    return contract.labelle_component_batch_set_ids(names.ptr, names.len, buf.ptr, total);
}

/// The number of ids stashed by the most recent `stripIds` — the id-path
/// analogue of the positional variant's entity count. Test/introspection
/// seam.
pub fn stashedCount() usize {
    return id_len;
}
