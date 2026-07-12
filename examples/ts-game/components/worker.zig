//! Tag component — the second leg of the `game.query("Hunger", "Worker")`
//! query in scripts/20_hunger_controller.ts (the labelle-engine#742
//! HungerController shape, typescript-spelled). In the generated
//! labelle-components.d.ts it lands as the empty shape (`"Worker": {};`),
//! so the spawner's bare `worker.set("Worker")` typechecks.
pub const Worker = struct {};
