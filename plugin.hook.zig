//! Plugin native build hook (labelle-assembler#518) — staged next to the
//! generated build.zig as `plugin_scripting_build_hook.zig` and called via
//! `postWire` AFTER the game artifact is assembled.
//!
//! It exports the game binary's dynamic symbols (`rdynamic` = `-rdynamic` /
//! `--export-dynamic` on ELF, an export table on PE/COFF). The csharp
//! (CoreCLR-hosted) sub-module needs this: at runtime the managed assembly's
//! `[LibraryImport]` resolver binds the `labelle_*` Script Runtime Contract
//! against the HOST PROCESS via `NativeLibrary.GetMainProgramHandle()` — a
//! `dlsym` on the game binary — which only sees symbols in the dynamic symbol
//! table. Without this the C# P/Invokes resolve to null and the runtime fails
//! to boot (the csharp test binary sets `tests.rdynamic = true` for the same
//! reason). Harmless for the other languages: lua/ruby/ts embed a VM and
//! rust/crystal resolve the contract at link time, so the extra dynamic
//! exports are never consulted and runtime behavior is unchanged.
const std = @import("std");

pub fn postWire(b: *std.Build, ctx: anytype) void {
    _ = b;
    ctx.artifact.rdynamic = true;
}
