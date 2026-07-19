//! The csharp sub-module's bindings surface — deliberately empty, rust's
//! and crystal's twin.
//!
//! Embedded-VM backends install binding closures here that bridge the VM
//! to the contract symbols. C# needs none of that: the managed assembly's
//! `Labelle` class (native-csharp/src/Labelle.cs) declares the contract
//! via `[LibraryImport]` and resolves it against the HOST PROCESS with a
//! `DllImportResolver` — the P/Invoke declarations ARE the binding
//! (labelle-engine#734 POC finding #3, the CoreCLR spelling). This file
//! only satisfies the backend shape src/root.zig's comptime switch expects.

const vm_mod = @import("vm.zig");

// Bulk-access shims (labelle-scripting#44): the managed assembly's
// `[LibraryImport]`s bind the ALWAYS-PRESENT `labelle_scripting_bulk_*`
// exports instead of the v1.3 contract symbols directly, so the
// resolver never faults against a pre-2.6.0 engine host (the comptime
// probe gates the forwards Zig-side — see src/bulk_shims.zig).
// Referencing the file from this comptime block is what emits the
// exports into every `-Dlanguage=csharp` binary (they reach the
// managed side through the same rdynamic/GetMainProgramHandle route as
// the contract symbols).
comptime {
    _ = @import("../bulk_shims.zig");
}

/// Shape parity with the embedded backends' grow-only scratch counters
/// (`scripting.scratchGrowthCount()`): the Zig side of the csharp arm owns
/// no scratch at all — buffers live in the managed assembly (each script's
/// own `byte[]`/`List` plus the glue's inbox buffer), so this counter never
/// moves. The steady-state allocation story for C# is managed-side (GC),
/// pinned by the example game's buffer-reuse discipline.
pub var scratch_growth_count: usize = 0;

/// Nothing to install (see module doc). The error union mirrors the other
/// backends' install signatures so the shared Controller's `try` stays
/// uniform.
pub fn install(vm: vm_mod.Vm) error{}!void {
    _ = vm;
}
