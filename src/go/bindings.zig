//! The go sub-module's bindings surface — deliberately empty, rust's
//! exact twin.
//!
//! Embedded-VM backends install binding closures here that bridge the
//! VM to the contract symbols. Go needs none of that: the archive's
//! `labelle` package (native-go/labelle.go) declares the contract in
//! its cgo preamble and links against the same binary — the header is
//! the binding (labelle-engine#734 POC finding #3). This file only
//! satisfies the backend shape src/root.zig's comptime switch expects.

const vm_mod = @import("vm.zig");

// Bulk-access shims (labelle-scripting#44): the archive's batch tier
// (native-go/batch.go) references the ALWAYS-PRESENT
// `labelle_scripting_bulk_*` exports instead of the v1.3 contract
// externs directly, so a game built against a pre-2.6.0 engine still
// links (the comptime probe gates the forwards Zig-side — see
// src/bulk_shims.zig). Referencing the file from this comptime block
// is what emits the exports into every `-Dlanguage=go` binary.
comptime {
    _ = @import("../bulk_shims.zig");
}

/// Shape parity with the embedded backends' grow-only scratch counters
/// (`scripting.scratchGrowthCount()`): the Zig side of the go arm owns
/// no scratch at all — buffers live in the archive (each script's own
/// slices plus the package-level scratch, all `s = s[:0]` reuse by
/// construction) — so this counter never moves. The steady-state pin
/// for go lives archive-side (the go example's GO_BUFFERS_OK token).
pub var scratch_growth_count: usize = 0;

/// Nothing to install (see module doc). The error union mirrors the
/// other backends' install signatures so the shared Controller's `try`
/// stays uniform.
pub fn install(vm: vm_mod.Vm) error{}!void {
    _ = vm;
}
