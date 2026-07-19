//! The command-as-event the HungerSystem subscribes to
//! (`labelle.Subscribe("hunger__feed")` in scripts/hunger.go): any code
//! — Zig systems, other scripts, or (as here) scripts/spawner.go — can
//! command a feeding by emitting it. Zig-authored (go ships no declare
//! tool in v1 — see components/hunger.zig's header); the go emit
//! (`labelle.Emit("hunger__feed", "{\"entity\":…,\"amount\":0.5}")`)
//! crosses the Script Runtime Contract as JSON and is parsed into this
//! struct on the REAL engine bus. Both the native game-root hook
//! (hooks/feed_watcher.zig) and the go `OnEvent` handler consume it —
//! one bus, no glue.
pub const HungerFeed = struct {
    entity: u64 = 0,
    amount: f32 = 0.5,
};
