//! The engine-side component the C# scripts address by name over the
//! Script Runtime Contract (`Labelle.GetComponentInto(id, "Hunger", …)` in
//! scripts/HungerSystem.cs). C# has no declare mode (the assembly is
//! compiled, there are no embedded source scripts to extract from), so the
//! component is a real `components/*.zig` file and every contract call
//! resolves against it at runtime by name.
//!
//! The default is deliberately NOT the 0.875 the spawner writes: the decay
//! chain starting at 0.875 proves the C#-side write traveled, not the
//! declared default.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
