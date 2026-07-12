# The command-as-event the HungerSystem subscribes to
# (`Labelle.subscribe("hunger__feed")` in scripts/hunger.cr): any code — Zig
# systems, other scripts, or (as in this example) scripts/spawner.cr — can
# command a feeding by emitting it. A GAME-SHAPED `Labelle.event` declaration
# (no `require` line — the tool injects the prelude): its schema extracts into
# the generated scripting_events.zig's `HungerFeed` payload struct (fields
# sorted by name). The crystal emit
# (`Labelle.emit("hunger__feed", %({"entity":…,"amount":0.5}))`) crosses the
# Script Runtime Contract as JSON and is parsed into that struct on the REAL
# engine bus; the native game-root hook (hooks/feed_watcher.zig) and the crystal
# `on_event` handler both consume it, one bus, no glue.
Labelle.event "hunger__feed", {
  entity: {u64, 0},
  amount: {f32, 0.5},
}
