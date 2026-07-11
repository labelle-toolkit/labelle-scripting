//! The command-as-event the HungerSystem subscribes to
//! (`labelle::subscribe("hunger__feed")` in rust/hunger.rs): any code —
//! Zig systems, other scripts, or (as in this example) rust/spawner.rs —
//! can command a feeding by emitting it. The rust emit
//! (`labelle::emit("hunger__feed", "{\"entity\":…,\"amount\":0.5}")`)
//! crosses the Script Runtime Contract as JSON and is parsed into this
//! struct on the REAL engine bus; the subscribe/poll drain hands it back
//! to rust as a `"<name> <json>"` inbox entry on the next tick's
//! `on_event` dispatch.
pub const HungerFeed = struct {
    entity: u64 = 0,
    amount: f32 = 0.5,
};
