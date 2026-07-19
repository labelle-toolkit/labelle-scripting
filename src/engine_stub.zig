//! Stand-in for the generated game's real `labelle-engine` module in this
//! repo's own TEST binaries only — deliberately NOT wired into the
//! exported `labelle_scripting` module (see build.zig: the assembler's
//! `overrideImport` installs the real engine there, and a consumer that
//! bypassed that wiring must fail loudly, not compile bulk-capable
//! against an unknown host).
//!
//! Production games get the REAL engine module as a dep of the scripting
//! module (the assembler's `-Mscripting … --dep labelle-engine` wiring);
//! `src/contract.zig`'s `host_has_bulk_access` comptime probe `@hasDecl`s
//! into it. Tests build engine-free against the mock world, so this stub
//! answers the probe instead — carrying the v1.3 bulk-access marker
//! (`script_contract.batch_int_refused`, the decl labelle-engine gained in
//! 2.6.0 alongside the four exports), which turns the probe ON: exactly
//! right, because tests/mock_world.zig DOES export the four symbols, so
//! probe-true == link-truth here just as it does in a generated game.
//! Deleting the decl below would flip every fast path to the JSON route
//! and fail the packed/batch suites — the stub is deliberately minimal so
//! it can't drift into "a fake engine".

pub const script_contract = struct {
    /// The v1.3 marker decl (mirrors labelle-engine's
    /// `script_contract.batch_int_refused`, C's `(size_t)-2`).
    pub const batch_int_refused: usize = @import("std").math.maxInt(usize) - 1;

    /// The v1.4 marker decl (mirrors labelle-engine's
    /// `script_contract.batch_id_row_prefix`, 8) — turns
    /// `contract.host_has_id_batch` TRUE, so the test binaries default to
    /// the id-tagged batch path, matching the mock world's `_ids` exports.
    pub const batch_id_row_prefix: usize = 8;
};
