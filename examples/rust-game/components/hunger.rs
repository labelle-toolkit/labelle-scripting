// The engine-side component the rust scripts address by name over the
// Script Runtime Contract (`labelle::get_component_into(id, "Hunger", …)` in
// scripts/hunger.rs). Since labelle-engine#772 / assembler v0.88.0 the
// NATIVE family declares too: this is a GAME-SHAPED `components/*.rs`
// declaration — bare `labelle::component!` with NO `use` lines (the assembler
// stages the `use crate::labelle;` prelude and its declare tool
// `labelle-declare-rs` extracts the schema into the generated
// scripting_components.zig). It is NOT embedded or compiled into the game —
// only its schema travels — so the component registers by name and every
// contract call resolves against it at runtime, exactly as the former
// components/hunger.zig did.
//
// The default is deliberately NOT the 0.875 the spawner writes: the decay
// chain starting at 0.875 proves the rust-side write traveled, not the
// declared default.
labelle::component! {
    Hunger {
        level: f32 = 1.0,
        starving: bool = false,
    }
}
