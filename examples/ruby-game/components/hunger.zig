//! The engine-side component the ruby scripts view through
//! `Labelle::Component.ref("Hunger", :level, :starving)`. Ruby has no
//! declare mode yet (the assembler's declare phase is lua-only and SKIPS
//! for ruby), so the component is a real `components/*.zig` file and the
//! ref resolves against it at runtime by name — the forward-compat path
//! the plugin README documents.
//!
//! The default is deliberately NOT the 0.875 the spawner writes: the
//! decay chain starting at 0.875 proves the ruby-side write traveled,
//! not the declared default.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
