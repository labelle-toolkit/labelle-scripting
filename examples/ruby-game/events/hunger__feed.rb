# events/hunger__feed.rb — the EVENT DECLARED IN RUBY: the command-as-
# event the whole example fans out over, and the file that closed this
# game's last mandatory-Zig gap (labelle-engine#772, live since
# labelle-assembler v0.87.0 + labelle-scripting v0.10.0's
# `Labelle.event`). The events/ dir is extension-keyed and
# mixed-language exactly like components/ — declaration files live
# where their kind lives.
#
# ONE line, two consumers:
#
#   - at `labelle generate` the declare phase runs this repo's ruby
#     extractor over this file and the assembler codegens the schema
#     into ONE generated file at the target root
#     (.labelle/<target>/scripting_events.zig — `pub const HungerFeed`
#     with `amount: f32 = 0.5, entity: u64 = 0`, fields sorted by name;
#     `Labelle.id` is the u64 entity-id marker no plain ruby value can
#     spell, `0.5` infers f32). The generated main's event-union row
#     (`hunger__feed: @import("scripting_events.zig").HungerFeed`)
#     comes out exactly as if events/hunger__feed.zig still existed —
#     same bus, same sidecars, same routing (CI greps the generated
#     file and the row). One documented consequence for NATIVE
#     consumers: a game-root hook spells the payload param `anytype`
#     instead of importing a per-event file (hooks/feed_watcher.zig —
#     field access unchanged);
#
#   - at RUNTIME this file is embedded and registered BETWEEN
#     components/ and scripts/ (components → events → scripts, pinned
#     by CI), and `Labelle.event` returns the FROZEN event-name string
#     — so `HungerFeed` is already defined, VM-global as every ruby
#     top-level constant is, when the script chunks load:
#     scripts/feed_watcher.rb subscribes with `Labelle.on(HungerFeed)`
#     while scripts/10_spawner.rb keeps emitting by plain string
#     ("hunger__feed") — the constant IS that string, both spellings
#     coexist deliberately.
#
# The event's job is unchanged: any code — scripts or Zig systems —
# commands a feeding by emitting it. The ruby emit crosses the Script
# Runtime Contract as JSON, is parsed into the generated struct on the
# REAL engine bus, and reaches THREE subscribers off one emit: the
# controller's handler, the pure-ruby watcher, and the native Zig hook.
HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
