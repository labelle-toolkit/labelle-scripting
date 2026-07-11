//! The command-as-event the HungerController subscribes to
//! (`on("hunger__feed")` in ruby/20_hunger.rb): any code — Zig systems,
//! other scripts, or (as in this example) the controller itself — can
//! command a feeding by emitting it. The ruby emit
//! (`emit("hunger__feed", entity: e.id, amount: 0.125)`) crosses the
//! Script Runtime Contract as JSON and is parsed into this struct on the
//! REAL engine bus; the subscribe/poll drain hands it back to ruby as a
//! symbol-keyed Hash on the next tick's inbox dispatch.
pub const HungerFeed = struct {
    entity: u64 = 0,
    amount: f32 = 0.5,
};
