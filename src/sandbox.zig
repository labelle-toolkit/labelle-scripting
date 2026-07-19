//! Mod sandbox profile flag (labelle-engine#740).
//!
//! ONE comptime bool, read from the assembler-staged `plugin_params`
//! module (labelle-assembler#591): the project's
//! `.params = .{ .sandbox = true }` — validated against plugin.labelle's
//! `.params_schema` — resolves into `pub const sandbox: bool` in the
//! staged module, which the generated build.zig `overrideImport`s onto
//! this plugin's module under the fixed `plugin_params` name. Outside a
//! generated game (this repo's tests, manual consumers) the import
//! resolves to build.zig's default stub instead (no decl → profile off),
//! so `@hasDecl` is the graceful probe: absent means OFF, the current
//! behavior, always.
//!
//! What the profile MEANS per language (the mechanism lives with each
//! VM; this file is only the switch):
//!   - lua  — src/lua/vm.zig opens a SAFE-LIB subset instead of
//!     luaL_openlibs: no io, no os, no package/require, no debug, the
//!     base library's dofile/loadfile are removed, and `load` is
//!     rebound TEXT-ONLY (precompiled binary chunks would bypass the
//!     text-level sandbox — the undump path trusts its bytes).
//!     Build-level
//!     exclusion was considered and rejected: the lua stdlib compiles as
//!     one vendored set either way, and never *opening* a library is
//!     exactly as unreachable as never compiling it (the C entry points
//!     exist but no lua value references them), without forking the
//!     source list per profile.
//!   - ruby — sandboxed BY CONSTRUCTION, whatever this flag says: the
//!     vendored mruby gem selection (build.zig `mruby_sources`) has
//!     never included mruby-io/mruby-dir — File/IO/Dir simply do not
//!     exist in the VM. The flag is accepted for uniformity; the ruby
//!     suite pins the constants absent.
//!   - typescript — sandboxed BY CONSTRUCTION too: quickjs-libc (the
//!     os/std module layer) is deliberately not compiled (build.zig
//!     `quickjs_sources`), and the labelle prelude binds no filesystem
//!     API. The ts suite pins `os`/`std`/`require` undefined.
//!   - native (rust/crystal/csharp) — no sandbox story by design
//!     (RFC-LANGUAGE-PLUGINS: "full native performance, no VM, no
//!     sandbox"); compiled game code links the game binary itself.
//!
//! Default OFF: game scripts are first-party content and keep the full
//! stdlib they have today. The profile is the base for the future mods
//! tier (RFC phase 3), where untrusted content runs.

const plugin_params = @import("plugin_params");

/// Comptime-known: the whole sandbox path folds away when off.
pub const enabled: bool = @hasDecl(plugin_params, "sandbox") and plugin_params.sandbox;
