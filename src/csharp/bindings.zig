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
