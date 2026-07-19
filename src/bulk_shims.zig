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

/// Forward of `labelle_component_batch_get` (contract v1.3). On a
/// pre-v1.3 host: 0 (malformed/not-bound) — belt only; the binding
/// wrappers check `labelle_scripting_bulk_capability` first and raise
/// the loud unsupported error instead of ever reading this 0.
export fn labelle_scripting_bulk_batch_get(
    names_json: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_batch_get(names_json, names_json_len, out, out_cap);
    }
    return 0;
}

/// Forward of `labelle_component_batch_set` (contract v1.3). On a
/// pre-v1.3 host: -1 — belt only, like `..._batch_get`'s 0.
export fn labelle_scripting_bulk_batch_set(
    names_json: [*]const u8,
    names_json_len: usize,
    buf: ?[*]const u8,
    buf_len: usize,
) i32 {
    if (comptime contract.host_has_bulk_access) {
        return contract.labelle_component_batch_set(names_json, names_json_len, buf, buf_len);
    }
    return -1;
}
