// components/worker.ts — the tag component, typescript-declared: the
// second leg of the `game.query("Hunger", "Worker")` query in
// scripts/20_hunger_controller.ts (the labelle-engine#742 shape). The
// empty spec object is the zero-field TAG shape — a marker with no
// payload, good for set/has/remove and query legs. The declare phase emits
// it into the generated registry beside Hunger (`pub const Worker`, a
// field-less struct, in scripting_components.zig — CI greps it) and into
// labelle-components.d.ts as `"Worker": {}`, so the spawner's bare
// `worker.set("Worker")` typechecks.
//
// This file used to be Zig (components/worker.zig). It went typescript
// with rev 20 option (b) — every shipped language must be able to go 100%
// selected-language (labelle-engine#772) — so the example's ONLY remaining
// .zig is the OPTIONAL native escape hatch, hooks/feed_watcher.zig (CI
// deletes it in a scratch copy and the game still runs green).
export const Worker = labelle.component("Worker", {});
