//! The rust sub-module's bindings surface — deliberately empty.
//!
//! Embedded-VM backends install binding closures here (lua shims, mruby
//! module functions, quickjs host functions) that bridge the VM to the
//! contract symbols. Rust needs none of that: the crate's `labelle`
//! module (native/src/labelle.rs) declares the contract `extern "C"`
//! and links against the same binary — the header is the binding
//! (labelle-engine#734 POC finding #3). This file only satisfies the
//! backend shape src/root.zig's comptime switch expects.

const vm_mod = @import("vm.zig");

// Bulk-access shims (labelle-scripting#44): the crate's labelle module
// references the ALWAYS-PRESENT `labelle_scripting_bulk_*` exports
// instead of the v1.3 contract externs directly, so a game built
// against a pre-2.6.0 engine still links (the comptime probe gates the
// forwards Zig-side — see src/bulk_shims.zig). Referencing the file
// from this comptime block is what emits the exports into every
// `-Dlanguage=rust` binary.
comptime {
    _ = @import("../bulk_shims.zig");
}

/// Shape parity with the embedded backends' grow-only scratch counters
/// (`scripting.scratchGrowthCount()`): the Zig side of the rust arm owns
/// no scratch at all — buffers live in the crate (each script's own
/// `Vec`s plus the glue's inbox buffer), where Rust's capacity-retaining
/// `clear()` gives the reuse idiom for free — so this counter never
/// moves. The steady-state-allocation pin for rust lives crate-side
/// (tests/rust/game/alloc_probe.rs).
pub var scratch_growth_count: usize = 0;

/// Nothing to install (see module doc). The error union mirrors the
/// other backends' install signatures so the shared Controller's `try`
/// stays uniform.
pub fn install(vm: vm_mod.Vm) error{}!void {
    _ = vm;
}
