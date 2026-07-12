// events/hunger__feed.ts — the EVENT DECLARED IN TYPESCRIPT (rev 20
// option (b), labelle-engine#773): the command-as-event the whole example
// fans out over, and the file that closed this game's last mandatory-Zig
// gap for events. The events/ dir is extension-keyed and mixed-language
// exactly like components/.
//
// ONE line, two consumers:
//
//   - at `labelle generate` the assembler transpiles this file FIRST, the
//     labelle-declare-ts runner evals the emitted .js, and the assembler
//     codegens the schema into ONE generated file at the target root
//     (.labelle/<target>/scripting_events.zig — `pub const HungerFeed`
//     with `amount: f32 = 0.5, entity: u64 = 0`, fields sorted by name;
//     `labelle.id` is the u64 entity-id marker no plain JS value can spell,
//     `0.5` infers f32). The generated main's event-union row
//     (`hunger__feed: @import("scripting_events.zig").HungerFeed`) comes
//     out exactly as if events/hunger__feed.zig still existed — same bus,
//     same sidecars, same routing (CI greps the generated file and the
//     row);
//
//   - at RUNTIME the emitted .js is embedded and registered BETWEEN
//     components/ and scripts/, and `labelle.event` returns the frozen
//     event-name string.
//
// The event's job is unchanged: any code — scripts or Zig systems —
// commands a feeding by emitting it. The typescript emit crosses the
// Script Runtime Contract as JSON, is parsed into the generated struct on
// the REAL engine bus, and reaches THREE subscribers off one emit: the
// controller's handler, the pure-typescript watcher, and the native Zig
// hook (hooks/feed_watcher.zig).
export const HungerFeed = labelle.event("hunger__feed", { entity: labelle.id, amount: 0.5 });
