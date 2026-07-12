// scripts/20_hunger_controller.ts — the structured tier: the
// labelle-engine#742 acceptance pattern typescript-spelled, against the
// REAL engine. TypeScript has no controller CLASS tier (that's ruby's) —
// the structure here is module discipline instead: module-scope cached
// state, init as setup, update as tick. What typescript adds is TYPES —
//
//   - every component access below is checked at `labelle generate`
//     against the GENERATED labelle-components.d.ts (labelle-assembler
//     v0.86.0, #613): the assembler parses this game's real registry
//     (components/hunger.zig et al.) into `interface LabelleComponents`
//     plus `keyof`-constrained Entity.get/set overloads — so
//     `e.get("Hunger", h)` types `h.level` as `number` and a typo'd
//     `h.levl` FAILS generate with a TS2551 ("Did you mean 'level'?" —
//     tsc's close-match variant of TS2339), before anything builds
//     (find the generated file at .labelle/<target>/scripts/
//     labelle-components.d.ts after a generate),
//   - the module caches ONE `into` object (`h`, annotated with the
//     generated `LabelleComponents["Hunger"]` shape) and refills it per
//     entity via `e.get("Hunger", h)` — the zero-allocation read — then
//     mutates fields and writes back with `e.set("Hunger", h)`,
//   - command-as-event feeding (`hunger__feed`, events/hunger__feed.zig)
//     subscribed in init — emitted by scripts/10_spawner.ts on tick 2,
//     so the cross-script round-trip over the engine bus is part of the
//     pinned transcript (subscribing in init, AFTER every module body
//     ran, keeps this handler behind scripts/feed_watcher.ts's top-level
//     subscription in dispatch order — same relative order as ruby),
//   - `labelle.FrameArray` is the per-frame HOT scratch (collect ids,
//     then process — whether `arr.length = 0` keeps a JS array's backing
//     is engine-internal, FrameArray never relies on it), asserted flat
//     via growthCount at tick 5,
//   - plain hooks coexist: scripts/10_spawner.ts seeds the worker,
//   - the SAME hunger__feed reaches two more subscribers off the same
//     bus: a NATIVE game-root Zig hook (hooks/feed_watcher.zig — the
//     two-layer interop) and a pure-typescript top-level watcher
//     (scripts/feed_watcher.ts).
//
// Tokens carry BEHAVIOR: every tick logs the freshly written level, so
// the pinned sequence encodes the whole decay-feed-decay sawtooth through
// the real ECS. All values are exact in binary floating point at every
// width en route (0.875 start, 0.25 steps, 0.5 feed), so the interpolated
// decimals are deterministic (JS number→string is shortest-round-trip:
// `${0.625}` is "0.625"). The 0.875 seed is the spawner's TYPED write
// (typescript has no declare mode — the component default is 1.0), so the
// chain also proves the script-side write traveled the contract into the
// real ECS. One deliberate delta from the #742 fixture: decay is 0.25 PER
// TICK, not `DECAY * dt` — the null backend's fixed dt is f32(1.0/60.0),
// which no decimal-exact multiple survives, and exact values in the
// tokens are the point.
//
// Frame-by-frame (LABELLE_NULL_FRAMES=5; per frame the plugin Controller
// runs: event inbox → script `update`s in registration order):
//
//   setup   TS_INIT             (spawner init: worker seeded at 0.875 by
//                                the typed write)
//           TS_CTRL_READY       this module's init ran (inits run in
//                                registration order, after ALL module
//                                bodies loaded)
//   tick 1  TS_LEVEL_0.625      0.875 - 0.25 decay, written back
//   tick 2  TS_FEED_SENT        (spawner update: emits hunger__feed)
//           TS_LEVEL_0.375      0.625 - 0.25 — tick 1's write PERSISTED
//           ZIG_FEED_SEEN_0.5   (hooks/feed_watcher.zig — the native
//                                subscriber, at THIS frame's
//                                dispatchEvents: frame end, after the
//                                script updates, one tick BEFORE the
//                                typescript handlers' inbox dispatch)
//   tick 3  TS_ENGINE_TICK_SEEN (spawner's builtin sub, same inbox)
//           TS_WATCHER_SAW_0.5  (scripts/feed_watcher.ts — the THIRD
//                                subscriber, same inbox dispatch;
//                                per-event handlers run in SUBSCRIPTION
//                                order and its top-level sub happened at
//                                module load, before this module's
//                                init-time `on`)
//           TS_FED_LEVEL_0.875  inbox: feed handler ran — id + exact
//                                f32 0.5 amount round-tripped the bus;
//                                0.375 + 0.5 re-read AFTER the write
//           TS_LEVEL_0.625      0.875 - 0.25 — decay resumes on the fed
//   tick 4  TS_LEVEL_0.375
//   tick 5  TS_LEVEL_0.125
//           TS_STARVING         0.125 <= 0.25 crossed the threshold
//           TS_FRAMEARRAY_OK    warmed hot scratch never grew
//                                (growthCount === 0 across all 5 ticks)
//   deinit  TS_DEINIT           (spawner deinit — registration order)
//           TS_CTRL_DONE        this module's deinit (typescript has no
//                                controller tier with LIFO teardown, so
//                                the tail is spawner-then-controller —
//                                the one deliberate delta from ruby's
//                                CTRL_DONE-then-DEINIT)

const DECAY_PER_TICK = 0.25; // exact in binary fp — see the header
const STARVE_AT = 0.25;
const FEED_DEFAULT = 0.5;

// The cached zero-alloc view, typed by the GENERATED declarations: this
// annotation is `labelle-components.d.ts`'s `LabelleComponents["Hunger"]`
// — the real `{ level: number; starving: boolean }` shape parsed out of
// components/hunger.zig at generate. One instance, refilled per entity.
const h: LabelleComponents["Hunger"] = { level: 0, starving: false };

// Hot per-frame scratch for entity IDS (stash e.id, never e — snapshots
// are wrappers, ids are the stable currency). Typed: pushes are bigint.
const fa = new labelle.FrameArray<bigint>(8);

let tick = 0;
let wasStarving = false;

/**
 * Shared threshold logic — its parameter is annotated with the GENERATED
 * component type, so this signature breaks at generate (not at runtime)
 * if components/hunger.zig ever renames a field.
 */
function updateStarving(hunger: LabelleComponents["Hunger"]): void {
  hunger.starving = hunger.level <= STARVE_AT;
}

export function init(): void {
  // Guard the payload: event payload fields are `JsonValue | undefined`
  // by type — narrow before use (a malformed hunger__feed without
  // `entity` is skipped, not thrown). The typeof narrowing doubles as
  // the BigInt story: small ids decode as Number, bit-63 ids as BigInt;
  // `Entity.wrap` normalizes either.
  labelle.on("hunger__feed", (ev) => {
    if (typeof ev.entity !== "bigint" && typeof ev.entity !== "number") return;
    feed(ev.entity, typeof ev.amount === "number" ? ev.amount : FEED_DEFAULT);
  });
  labelle.log("TS_CTRL_READY");
}

export function update(dt: number): void {
  void dt; // per-tick decay — see the header
  tick += 1;

  // The FrameArray idiom in the hot path: clear keeps the backing,
  // collect this tick's ids, then process.
  fa.clear();
  for (const e of game.query("Hunger", "Worker")) fa.push(e.id);

  for (let i = 0; i < fa.size; i++) {
    const id = fa.get(i);
    if (id === undefined) continue; // out-of-bounds guard `get` types in
    const e = Entity.wrap(id);
    // get returns null when the component vanished between the query and
    // this read (entity destroyed / component removed mid-tick) — guard
    // it, or a stale `h` from the PREVIOUS iteration would be written to
    // THIS entity. The refill types `h.level` as `number` through the
    // generated d.ts.
    if (e.get("Hunger", h) === null) continue;
    h.level -= DECAY_PER_TICK;
    updateStarving(h);
    e.set("Hunger", h); // REPLACE semantics — writes to THIS entity

    // The token carries the written value — each tick's number is only
    // reachable through the PREVIOUS tick's persisted write, so the
    // sequence pins ECS persistence transitively.
    labelle.log(`TS_LEVEL_${h.level}`);

    if (h.starving && !wasStarving) {
      wasStarving = true;
      labelle.log("TS_STARVING");
    }
  }

  // growthCount === 0 baked into the token: 5 warmed ticks over a
  // capacity-8 scratch must never reallocate.
  if (tick === 5) {
    if (fa.growthCount === 0 && fa.size === 1) {
      labelle.log("TS_FRAMEARRAY_OK");
    } else {
      labelle.log(`TS_FRAMEARRAY_GREW_${fa.growthCount}_SIZE_${fa.size}`);
    }
  }
}

/** Same-VM public API for other typescript code (the command handler above). */
function feed(id: bigint | number, amount: number): void {
  const e = Entity.wrap(id); // normalizes to the BigInt id
  if (e.get("Hunger", h) === null) {
    labelle.log("TS_FEED_TARGET_MISSING");
    return;
  }
  h.level += amount;
  updateStarving(h);
  e.set("Hunger", h);
  // Re-read AFTER the write: the token carries what actually PERSISTED
  // in the ECS, not the in-memory instance.
  e.get("Hunger", h);
  labelle.log(`TS_FED_LEVEL_${h.level}`);
}

export function deinit(): void {
  labelle.log("TS_CTRL_DONE");
}
