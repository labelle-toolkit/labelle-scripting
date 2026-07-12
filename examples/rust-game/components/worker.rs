// Tag component — the second leg of the `["Hunger","Worker"]` query in
// scripts/hunger.rs (the labelle-engine#742 HungerController shape, ported to
// the native family). A GAME-SHAPED zero-field `labelle::component!`
// declaration (no `use` lines — the assembler stages the prelude): its schema
// extracts into scripting_components.zig as an empty persistent struct.
labelle::component! {
    Worker {}
}
