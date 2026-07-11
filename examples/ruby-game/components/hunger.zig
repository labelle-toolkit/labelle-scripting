//! The engine-side component the ruby scripts view through
//! `Labelle::Component.ref("Hunger", :level, :starving)`. Ruby has no
//! declare mode yet (the assembler's declare phase is lua-only), so the
//! component is a real `components/*.zig` file and the ref resolves
//! against it at runtime by name — the forward-compat path the plugin
//! README documents.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
