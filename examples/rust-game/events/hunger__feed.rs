// The command-as-event the HungerSystem subscribes to
// (`labelle::subscribe("hunger__feed")` in scripts/hunger.rs): any code — Zig
// systems, other scripts, or (as here) scripts/spawner.rs — can command a
// feeding by emitting it. A GAME-SHAPED `labelle::event!` declaration (no
// `use` lines — the assembler stages the prelude): its schema extracts into
// the generated scripting_events.zig's `HungerFeed` payload struct (fields
// sorted by name). The rust emit
// (`labelle::emit("hunger__feed", "{\"entity\":…,\"amount\":0.5}")`) crosses
// the Script Runtime Contract as JSON and is parsed into that struct on the
// REAL engine bus; the native game-root hook (hooks/feed_watcher.zig) and the
// rust `on_event` handler both consume it, one bus, no glue.
labelle::event! {
    hunger__feed {
        entity: u64 = 0,
        amount: f32 = 0.5,
    }
}
