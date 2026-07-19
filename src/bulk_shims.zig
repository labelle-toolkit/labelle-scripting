//! Probe-gated bulk-access shims for the NATIVE language families
//! (rust / crystal / csharp — labelle-scripting#44, stage 3 of #41).
//!
//! ## Why these exist
//!
//! The embedded-VM bindings (ruby/lua/ts) reference the four contract
//! v1.3 externs (`labelle_component_get_packed` & co, src/contract.zig)
//! from ZIG code, so `contract.host_has_bulk_access` — a COMPTIME probe
//! of the engine module — can fold every reference away when the host
//! engine predates 2.6.0: an old game never names the symbols and links
//! clean.
//!
//! The native families cannot use that probe: their binding layer lives
//! OUTSIDE the Zig build — a cargo-built staticlib (native/src/
//! labelle.rs), a crystal object (native-crystal/src/labelle.cr), a
//! managed assembly resolving P/Invoke against the process
//! (native-csharp/src/Labelle.cs). A direct extern/`[LibraryImport]`
//! reference to the v1.3 symbols would make every rust/crystal game
//! UNLINKABLE against a pre-2.6.0 engine (and csharp's resolver would
//! fault at first call). So the plugin's ZIG side — which IS compiled
//! per-game, with the engine module in scope — exports this ALWAYS-
//! PRESENT shim surface instead, gated on the same comptime probe:
//!
//!   - on a v1.3+ host each shim forwards to the real contract export;
//!   - on an older host the gate folds the forward away (the extern is
//!     never referenced — no link error) and the shim answers the
//!     documented "unsupported" value: 0 from get_packed (the absent
//!     sentinel — the caller's JSON fallback engages), -1 from
//!     set_packed (the refusal — same fallback), 0 from batch_get and
//!     -1 from batch_set (belt only: wrappers must check
//!     `labelle_scripting_bulk_capability` FIRST and surface the loud
//!     "needs labelle-engine >= 2.6.0" error — there is no batch
//!     fallback, and silently degrading a whole-query read would be
//!     data loss; the semantics mirror src/ruby/bindings.zig verbatim).
//!
//! `labelle_scripting_bulk_capability` is the managed side's RUNTIME
//! capability query — the runtime spelling of the Zig-side comptime
//! probe, and exactly as truthful (both answer from the same
//! `@hasDecl`, which matches link-time truth on every platform).
//!
//! The shims live in the `labelle_scripting_` symbol namespace (the
//! plugin's, like `labelle_rs_*`/`labelle_cr_*`), NOT the contract's
//! `labelle_` root namespace — they are plugin surface, versioned with
//! the plugin, not host surface.
//!
//! Wiring: each native backend's src/<lang>/bindings.zig references
//! this file from a `comptime` block, so the exports are emitted into
//! any game (or test binary) built with `-Dlanguage=rust|crystal|
//! csharp` and into nothing else. In this repo's test binaries the
//! engine stub (src/engine_stub.zig) answers the probe TRUE and
//! tests/mock_world.zig exports the four contract symbols — the same
//! probe-matches-link-truth invariant a generated game has.

const contract = @import("contract.zig");
const id_batch = @import("id_batch.zig");

/// 1 when the host engine exports the contract v1.3 bulk-access
/// symbols (labelle-engine >= 2.6.0), else 0. The native bindings call
/// this before their FIRST batch use and surface the documented
/// "host engine lacks batch support" error on 0; the packed paths need
/// no pre-check (their unsupported answers below alias the ordinary
/// absent/refused sentinels, which already route to the JSON
/// fallback).
export fn labelle_scripting_bulk_capability() u32 {
    return if (comptime contract.host_has_bulk_access) 1 else 0;
}

/// Forward of `labelle_component_get_packed` (contract v1.3). On a
/// pre-v1.3 host: 0 — the absent sentinel, so the caller's JSON
/// fallback path engages exactly as it does for a missing component.
export fn labelle_scripting_bulk_get_packed(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_get_packed(id, name, name_len, out, out_cap);
    }
    return 0;
}

/// Forward of `labelle_component_set_packed` (contract v1.3). On a
/// pre-v1.3 host: -1 — the refusal sentinel, so the caller's JSON
/// fallback path engages exactly as it does for a non-packable
/// component.
export fn labelle_scripting_bulk_set_packed(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    buf: ?[*]const u8,
    buf_len: usize,
) i32 {
    if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_set_packed(id, name, name_len, buf, buf_len);
    }
    return -1;
}

/// Forward of the batched read (contract v1.3+). On an engine ≥ 2.7.0
/// (contract v1.4) this DEFAULTS to the id-tagged `_batch_get_ids` and
/// strips the id column binding-side: `out` still returns the positional
/// `[u32 count][f32 stream]` the native decoders expect (the id column is
/// stashed for the paired set), so rust/crystal/csharp/go stay UNCHANGED
/// while gaining the destroy+spawn safety. On a v1.3-only host it forwards
/// the positional `_batch_get`. On a pre-v1.3 host: 0 (malformed/not-bound)
/// — belt only; the binding wrappers check `labelle_scripting_bulk_capability`
/// first and raise the loud unsupported error instead of ever reading it.
export fn labelle_scripting_bulk_batch_get(
    names_json: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    if (comptime contract.host_has_id_batch) {
        // Id path: fetch `[u32 count][ (u64 id)(floats) ]*`, then compact
        // in place to `[u32 count][floats]*` and stash the ids.
        const n = contract.labelle_component_batch_get_ids(names_json, names_json_len, out, out_cap);
        // A REFUSED / not-bound / malformed get is terminal — it never
        // reaches `stripIds`, so clear the stash HERE (parity with the
        // codec's clear-on-entry); otherwise a failed get would leave a
        // prior get's stale ids for the next set to mispair with. The
        // sizing-probe (out == null) and grow-retry (n > out_cap) legs are
        // NOT terminal — the caller retries the same query, and that
        // retry's `stripIds` must still see the pending stash to detect an
        // ambiguous interleave — so they pass through without clearing.
        if (n == contract.BATCH_INT_REFUSED or n == 0) {
            id_batch.invalidateStash();
            return n;
        }
        const buf = out orelse return n; // sizing probe: report raw required
        if (n > out_cap) return n; // grow-retry against the raw required size
        return id_batch.stripIds(names_json[0..names_json_len], buf[0..n], n);
    } else if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_batch_get(names_json, names_json_len, out, out_cap);
    }
    return 0;
}

/// Forward of the batched write (contract v1.3+). On an engine ≥ 2.7.0
/// this DEFAULTS to `_batch_set_ids`: `buf` is the pure positional f32
/// stream the native code packs (unchanged), and the shim re-attaches the
/// ids stashed by the paired `_batch_get` to apply BY ID (skipping
/// vanished/recycled entities). On a v1.3-only host it forwards the
/// positional `_batch_set`. On a pre-v1.3 host: -1 — belt only.
export fn labelle_scripting_bulk_batch_set(
    names_json: [*]const u8,
    names_json_len: usize,
    buf: ?[*]const u8,
    buf_len: usize,
) i32 {
    if (comptime contract.host_has_id_batch) {
        const stream: []const u8 = if (buf) |p| p[0..buf_len] else &.{};
        return id_batch.setWithIds(names_json[0..names_json_len], stream);
    } else if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_batch_set(names_json, names_json_len, buf, buf_len);
    }
    return -1;
}
