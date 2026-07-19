//! The crystal sub-module's bindings surface — deliberately empty,
//! rust's exact twin.
//!
//! Embedded-VM backends install binding closures here that bridge the
//! VM to the contract symbols. Crystal needs none of that: the object's
//! `Labelle` module (native-crystal/src/labelle.cr) declares the
//! contract in a `lib LibLabelle` block and links against the same
//! binary — the header is the binding (labelle-engine#734 POC finding
//! #3). This file only satisfies the backend shape src/root.zig's
//! comptime switch expects.

const vm_mod = @import("vm.zig");

// Bulk-access shims (labelle-scripting#44): the crystal object's
// LibLabelle bindings reference the ALWAYS-PRESENT
// `labelle_scripting_bulk_*` exports instead of the v1.3 contract
// externs directly, so a game built against a pre-2.6.0 engine still
// links (the comptime probe gates the forwards Zig-side — see
// src/bulk_shims.zig). Referencing the file from this comptime block
// is what emits the exports into every `-Dlanguage=crystal` binary.
comptime {
    _ = @import("../bulk_shims.zig");
}

/// Shape parity with the embedded backends' grow-only scratch counters
/// (`scripting.scratchGrowthCount()`): the Zig side of the crystal arm
/// owns no scratch at all — buffers live in the object (each script's
/// own `Labelle::Buffer`s plus the glue's inbox buffer, all grow-once
/// by construction) — so this counter never moves. The steady-state
/// pin for crystal lives object-side (tests/crystal/game/gc_churn.cr).
pub var scratch_growth_count: usize = 0;

/// Nothing to install (see module doc). The error union mirrors the
/// other backends' install signatures so the shared Controller's `try`
/// stays uniform.
pub fn install(vm: vm_mod.Vm) error{}!void {
    _ = vm;
}
