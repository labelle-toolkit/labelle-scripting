//! The command-as-event the HungerController subscribes to
//! (`labelle.on("hunger__feed", …)` in scripts/20_hunger_controller.ts):
//! any code — Zig systems, other scripts, or (as in this example)
//! scripts/10_spawner.ts — can command a feeding by emitting it. The
//! typescript emit (`labelle.emit("hunger__feed", { entity: workerId,
//! amount: 0.5 })` — `workerId` a BigInt, encoded as the contract's
//! unsigned decimal) crosses the Script Runtime Contract as JSON and is
//! parsed into this struct on the REAL engine bus; the subscribe/poll
//! drain hands it back to typescript as a decoded payload object on the
//! next tick's inbox dispatch.
pub const HungerFeed = struct {
    entity: u64 = 0,
    amount: f32 = 0.5,
};
