// scripts/feed_watcher.ts — the THIRD hunger__feed subscriber, and the
// typescript mirror of hooks/feed_watcher.zig: one `labelle.emit` in
// scripts/10_spawner.ts (tick 2) now demonstrably reaches
//
//   - the controller's `labelle.on("hunger__feed")` (feeds the worker),
//   - THIS pure-typescript watcher, and
//   - the native Zig hook (hooks/feed_watcher.zig),
//
// all off the same engine bus, no glue. The token carries the parsed
// payload amount (TS_WATCHER_SAW_0.5 — f32 0.5 is exact in binary
// floating point), so it proves the payload crossed intact, not just
// that a handler fired.
//
// Deliberately a TOP-LEVEL (module-scope) subscription — the third legal
// subscription site next to the spawner's init-time `on` and the
// controller's. Each script is an ES module, so unlike ruby there is no
// receiver caveat to dodge: module scope IS this file's private scope,
// and a stateless watcher is exactly the shape where load-time
// subscription shines — the handler exists from VM boot, before any
// init runs. (If the script is ever evicted — load or init failure —
// its handlers are purged with it.)
//
// No ordering prefix: unnumbered scripts register AFTER the numbered
// ones (10_spawner, 20_hunger_controller), alphabetically — this file
// demonstrates the two spellings coexisting in one scripts/ dir. Being
// a `.ts` source it still rides the same generate-time check+emit as
// the numbered ones.
//
// Timeline slice (scripts/20_hunger_controller.ts has the full
// interleaving): the emit rides tick 2, typescript handlers run on tick
// 3's inbox dispatch — TS_WATCHER_SAW_0.5 lands on tick 3, BEFORE the
// controller's TS_FED_LEVEL_0.875 (per-event handlers run in
// SUBSCRIPTION order, and this module-load sub happened before the
// controller's init-time `on` — inits only run after ALL module bodies),
// one tick after the native hook's ZIG_FEED_SEEN_0.5.
labelle.on("hunger__feed", (ev) => {
  labelle.log(`TS_WATCHER_SAW_${ev.amount}`);
});
