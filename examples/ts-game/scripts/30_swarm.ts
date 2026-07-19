// scripts/30_swarm.ts — the BATCHED tier against the real engine
// (labelle-scripting#44, contract v1.3, labelle-engine >= 2.6.0 — the
// project pin): the whole per-tick update crosses the Script Runtime
// Contract exactly TWICE (one batch_get, one batch_set) no matter how
// many entities match, where the per-entity tier would cross 2×N times.
// `labelle.batch` is the ergonomic layer — ONE reused view whose
// accessors are the component's field names, layout derived host-side
// (declaration-order probe + stride cross-check), commit on
// return/normal exit, abort on throw.
//
// This is the permanent perf-shape regression net for the typescript
// batch port: three Dot entities integrate x += vx / y += vy for the
// run's 5 frames, and tick 5 re-reads the first entity through the
// per-entity JSON path — the value only lands if the batched writes
// PERSISTED through the real ECS every tick.
//
//   setup   (three Dots spawned at x=100, vx=8)
//   tick 5  TS_BATCH_OK_140     100 + 5×8, re-read via e.get after the
//                                fifth batched write-back (an exact
//                                binary float chain, so the token is
//                                deterministic)
//
// Registration order: `30_` slots this after 20_hunger_controller (its
// tokens stay in front each tick) and before the unnumbered
// feed_watcher.

const DOTS = 3;

let first: Entity | null = null;
let tick = 0;

export function init(): void {
  for (let i = 0; i < DOTS; i++) {
    const e = Entity.create();
    if (e === null) {
      labelle.log("TS_BATCH_SPAWN_FAIL");
      return;
    }
    // All-float writes — exact at every width (100, 8, 0.5).
    e.set("Dot", { x: 100, y: 0, vx: 8, vy: 0.5 });
    if (first === null) first = e;
  }
}

export function update(dt: number): void {
  void dt; // per-tick integration keeps the token chain exact
  tick += 1;

  // The batched tier: one host crossing in, one out. Early `return
  // false` would commit the writes made so far; a throw would abort the
  // whole write — this swarm always runs the full set.
  const n = labelle.batch("Dot", (d) => {
    d.x += d.vx;
    d.y += d.vy;
  });

  if (tick === 5 && first !== null) {
    // Independent verification through the PER-ENTITY path: the batched
    // writes must be visible to a plain get on the real ECS.
    const d = first.get("Dot");
    if (n === DOTS && d !== null && d.x === 140) {
      labelle.log(`TS_BATCH_OK_${d.x}`);
    } else {
      labelle.log(`TS_BATCH_MISMATCH n=${n} x=${d === null ? "null" : d.x}`);
    }
  }
}
