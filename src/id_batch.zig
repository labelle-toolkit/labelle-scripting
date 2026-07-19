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
//! STASHES the pending batch: `(names, entity_count, per-row stride, ids)`.
//! The binding is otherwise unchanged (same count-header read, same float
//! decode).
//!
//! SET: the binding hands back the pure positional f32 stream (no header).
//! `setWithIds` uses the id path ONLY when the incoming stream matches the
//! stash EXACTLY — same names, same count, and `stream.len == count *
//! stashed_stride` (the stride the GET recorded, never one re-inferred from
//! a possibly-mutated stream). Then it re-attaches the stashed ids, applies
//! via `_batch_set_ids` (BY ID, skipping vanished/recycled), and CONSUMES
//! the stash. So a destroy+spawn between the paired get and set can no
//! longer land a stale row on a new occupant.
//!
//! ## Stash lifecycle (scripting#58 review — the one-stash hazard)
//!
//! The stash is a single process-wide record, so strict get→set pairing is
//! the ONLY case that may take the id path; every deviation degrades to the
//! POSITIONAL `_batch_set` (which re-queries and applies with its own
//! exact-size guard, or surfaces the host's name-based refusals):
//!
//!   - INTERLEAVED gets — a second `batch_get` (raw API or a nested block
//!     iterator) overwrites the stash; the first buffer's set then no
//!     longer matches (names/count/len) and falls to positional, so it can
//!     never reattach the inner query's ids to the outer stream.
//!   - UNPAIRED nonempty set — no valid stash → positional (NEVER feed a
//!     raw f32 stream to `_batch_set_ids`, whose first 8 bytes per row are
//!     an entity id).
//!   - RESIZED stream — `stream.len != count * stashed_stride` → positional
//!     (the stashed stride is authoritative; a divisible-but-wrong length
//!     can't be re-interpreted as a different row shape).
//!   - CONSUMED / stale — the stash is cleared on every id-path set AND at
//!     the start of every get (a malformed / count-0 get leaves none), so a
//!     later unpaired set can never reuse spent ids.
//!
//! Only one `-Dlanguage=…` backend is compiled into any game, so the
//! module-level state below is a process singleton with no cross-language
//! contention.

const std = @import("std");
const contract = @import("contract.zig");

/// The engine floor probe, re-exported for callers that gate on it.
pub const host_has_id_batch = contract.host_has_id_batch;

const PREFIX = contract.BATCH_ID_ROW_PREFIX; // 8 (u64 id per row)

/// Cap on the stashed names-key length. Component-name JSON arrays are
/// short; a longer one simply can't be keyed, so its batch declines the id
/// path and uses the positional setter (a safe, correct degradation).
const NAMES_CAP = 256;

/// Process-lifetime grow-only buffers. `page_allocator` keeps this
/// libc-independent (unlike the per-VM libc-realloc scratch, this module
/// is shared by native backends that may not link libc). Grows rarely —
/// once the swarm reaches steady size the capacity settles and every tick
/// reuses it, matching the per-VM scratch's amortized-zero behavior.
const gpa = std.heap.page_allocator;

// ── The single pending id-backed batch (see the stash-lifecycle note) ──
var stash_valid: bool = false;
var stash_names: [NAMES_CAP]u8 = undefined;
var stash_names_len: usize = 0;
var stash_count: usize = 0; // entities the get resolved
var stash_stride: usize = 0; // f32-stream BYTES per row, from the get
var id_store: []u64 = &.{}; // ids[0..stash_count] valid while stash_valid

var row_scratch: []u8 = &.{};

/// Test seam: reallocations across the buffers (proves they settle).
pub var growth_count: usize = 0;

fn clearStash() void {
    stash_valid = false;
    stash_names_len = 0;
    stash_count = 0;
    stash_stride = 0;
}

/// Record the names key for the current stash; false when it can't be held
/// (too long), in which case the caller leaves the stash INVALID so the
/// paired set degrades to the positional path.
fn recordNames(names: []const u8) bool {
    if (names.len > NAMES_CAP) return false;
    @memcpy(stash_names[0..names.len], names);
    stash_names_len = names.len;
    return true;
}

fn namesMatch(names: []const u8) bool {
    return stash_names_len == names.len and
        std.mem.eql(u8, stash_names[0..stash_names_len], names);
}

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
/// `[u32 count][f32 stream]*` the binding decodes, and stash the pending
/// batch (`names`, count, per-row stride, ids) so the paired `setWithIds`
/// can reattach the ids.
///
/// `raw` is the binding's transfer scratch bounded to the written length;
/// `n` is the byte length `_batch_get_ids` returned (already ≤ cap by the
/// caller's grow-retry and NOT a sentinel — the caller checks
/// `BATCH_INT_REFUSED`/0 first). Returns the compacted floats-only byte
/// length (`4 + count*stride`) for the binding to decode exactly as it
/// decodes the positional variant. Every call FIRST invalidates any prior
/// stash (a new get supersedes the old pending batch).
pub fn stripIds(names: []const u8, raw: []u8, n: usize) usize {
    // A new get always supersedes the previous pending batch — interleaved
    // gets can never leave two live stashes.
    clearStash();
    if (n < 4 or raw.len < n) return n; // malformed — nothing to compact
    const count = std.mem.readInt(u32, raw[0..4], .little);
    if (count == 0) {
        // Empty result: record an empty pairing so the paired empty set is
        // recognized (and any nonempty later set is treated as unpaired).
        if (recordNames(names)) stash_valid = true;
        return 4; // count header only, no rows
    }
    const body = n - 4;
    const row_size = body / count; // 8 + stride, per row
    // A row must carry at least its id prefix, and the body must divide
    // evenly. A malformed shape leaves the buffer untouched, reports it
    // whole, and holds NO stash (the set will go positional).
    if (row_size < PREFIX or row_size * count != body) return n;
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
    if (recordNames(names)) {
        stash_valid = true;
        stash_count = count;
        stash_stride = stride;
    }
    return dst;
}

/// Apply the binding's pure positional f32 `stream` (no header — exactly
/// what the binding packs today).
///
/// Takes the id path ONLY for the exact buffer the paired `stripIds`
/// recorded — same `names`, same count, and `stream.len == count *
/// stashed_stride` — then reattaches the stashed ids, applies via
/// `_batch_set_ids`, and CONSUMES the stash. Any deviation (no stash,
/// interleaved different query, resized stream, standalone/unpaired set)
/// falls to the POSITIONAL `_batch_set`, which re-queries and applies with
/// its own exact-size guard (and surfaces the host's name-based refusals —
/// int -2, unknown -1). Returns the contract rc.
pub fn setWithIds(names: []const u8, stream: []const u8) i32 {
    if (stash_valid and namesMatch(names) and stream.len == stash_count * stash_stride) {
        // Paired id-path set — consumed whatever the outcome, so spent ids
        // can never be reused by a later unpaired set.
        defer clearStash();
        if (stash_count == 0) {
            // Empty paired set: zero rows.
            return contract.labelle_component_batch_set_ids(names.ptr, names.len, null, 0);
        }
        const stride = stash_stride;
        const row_size = PREFIX + stride;
        const total = stash_count * row_size;
        const buf = ensureRows(total);
        var i: usize = 0;
        while (i < stash_count) : (i += 1) {
            const row = buf[i * row_size ..];
            std.mem.writeInt(u64, row[0..8], id_store[i], .little);
            @memcpy(row[PREFIX..][0..stride], stream[i * stride ..][0..stride]);
        }
        return contract.labelle_component_batch_set_ids(names.ptr, names.len, buf.ptr, total);
    }
    // Unpaired / interleaved-mismatch / resized: the POSITIONAL setter. It
    // re-queries the current set and applies the flat stream with its own
    // exact-size preflight — never the id-tagged reader, whose first 8
    // bytes per row are an entity id (a raw f32 stream there is corruption).
    const p: ?[*]const u8 = if (stream.len == 0) null else stream.ptr;
    return contract.labelle_component_batch_set(names.ptr, names.len, p, stream.len);
}

/// The entity count of the currently-stashed pending batch (0 when none) —
/// test/introspection seam.
pub fn stashedCount() usize {
    return if (stash_valid) stash_count else 0;
}

/// Test seam: drop any pending stash so a suite can assert the
/// no-stash/standalone path from a known-clean state. Never needed in a
/// game (the lifecycle clears itself), but tests share this process-global.
pub fn resetStash() void {
    clearStash();
}
