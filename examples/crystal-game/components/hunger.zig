//! The engine-side component the crystal scripts address by name over
//! the Script Runtime Contract (`Labelle.get_component_into(id,
//! "Hunger", …)` in crystal/hunger.cr). Crystal has no declare mode
//! (native-compiled splices skip the declare phase — there are no
//! embedded scripts to extract from), so the component is a real
//! `components/*.zig` file and every contract call resolves against it
//! at runtime by name.
//!
//! The default is deliberately NOT the 0.875 the spawner writes: the
//! decay chain starting at 0.875 proves the crystal-side write traveled,
//! not the declared default.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
