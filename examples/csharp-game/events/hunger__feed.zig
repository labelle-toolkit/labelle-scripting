//! The command-as-event the HungerSystem subscribes to
//! (`Labelle.Subscribe("hunger__feed")` in scripts/HungerSystem.cs): any
//! code — Zig systems, other scripts, or (as in this example)
//! scripts/Spawner.cs — can command a feeding by emitting it. The C# emit
//! (`Labelle.Emit("hunger__feed", "{\"entity\":…,\"amount\":0.5}")`) crosses
//! the Script Runtime Contract as JSON and is parsed into this struct on
//! the REAL engine bus; the subscribe/poll drain hands it back to C# as a
//! `"<name> <json>"` inbox entry on the next tick's OnEvent dispatch.
pub const HungerFeed = struct {
    entity: u64 = 0,
    amount: f32 = 0.5,
};
