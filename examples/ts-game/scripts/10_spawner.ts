// scripts/10_spawner.ts — the plain lifecycle-hooks tier (each script is
// an ES module; init/update/deinit are its EXPORTS): seeds the world and
// commands a feeding over the engine bus. State lives in module-scope
// `let`s — module scope IS the isolation boundary, so unlike ruby there
// is no receiver-capture caveat; the `engine__tick` subscription happens
// in `init` anyway, mirroring the family layout (the third legal
// subscription site — top-level — is scripts/feed_watcher.ts's job).
//
// This file is a .ts SOURCE: at `labelle generate` the assembler's
// transpile phase (labelle-assembler#613, v0.86.0) TYPE-CHECKS it with
// the pinned tsc 7.0.2 native binary against contract/labelle.d.ts plus
// the GENERATED labelle-components.d.ts (built from this game's real
// component registry — see .labelle/<target>/scripts/ after a generate),
// then embeds the emitted plain-JS twin. Misspell `level` in the set
// below and generate FAILS with the tsc diagnostic, before anything
// builds.
//
// The `10_` prefix is the scripts/-dir ordering convention (the same
// structure Zig scripts use — labelle-engine#237): registration order is
// explicit — spawner, then 20_hunger_controller, then the unnumbered
// feed_watcher — and the prefix strips from the registered stem, so
// tracebacks and the generated main say "spawner".
//
// Each observable milestone logs ONE `TS_<TOKEN>` line so CI can
// `grep -oE '(TS|ZIG)_[A-Z0-9_.]+'` and diff the exact ordered sequence.
// This script's slice of the 5-frame timeline (LABELLE_NULL_FRAMES=5;
// scripts/20_hunger_controller.ts documents the full interleaving):
//
//   setup   TS_INIT              init(): Worker entity created, Hunger
//                                 written EXPLICITLY at 0.875 (no declare
//                                 mode for typescript — the typed write,
//                                 not a declared default, seeds the decay
//                                 chain)
//   tick 2  TS_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
//                                 (script updates run in registration
//                                 order, so this precedes tick 2's
//                                 TS_LEVEL_* token; the emit reaches
//                                 THREE subscribers off one bus — the
//                                 native hooks/feed_watcher.zig at this
//                                 frame's dispatchEvents, the controller
//                                 handler AND the pure-typescript
//                                 scripts/feed_watcher.ts on tick 3's
//                                 inbox)
//   tick 3  TS_ENGINE_TICK_SEEN  first engine__tick arrives (emitted by
//                                 g.tick AFTER the tick-1 drain, drained
//                                 at tick 2's boundary, inbox-dispatched
//                                 at tick 3 start)
//   deinit  TS_DEINIT            shutdown reached this script's deinit
//                                 (per-script deinits run in REGISTRATION
//                                 order — typescript has no controller
//                                 tier, so this precedes the controller
//                                 script's TS_CTRL_DONE: the one
//                                 deliberate tail delta vs ruby)
//
// Why the one-frame latencies: subscriptions activate at drain boundaries
// (no same-tick replay) and handlers run on the NEXT tick's inbox
// dispatch — see labelle-engine/src/script_contract.zig "Event tap
// semantics".

const START_LEVEL = 0.875; // 7/8 — exact in binary floating point
const FEED_AMOUNT = 0.5; // exact too — the token carries it verbatim

let worker: Entity | null = null;
// Entity ids are u64 on the host and live in scripts as BigInt (Number
// would silently round past 2^53) — the id travels the whole example as
// a bigint: created here, embedded in the emit payload below, rendered
// via labelle.u64str.
let workerId: bigint = 0n;
let tick = 0;
let engineTickSeen = false;

export function init(): void {
  // The worker the HungerController manages. `Entity.create()` is
  // `Entity | null` in the contract types — strict mode makes the guard
  // non-optional, which is exactly right for exemplar code.
  worker = Entity.create();
  if (worker === null) {
    labelle.log("TS_SPAWN_FAIL");
    return;
  }
  workerId = worker.id;

  // The TYPED write that seeds the decay chain: `set` is overloaded by
  // the GENERATED labelle-components.d.ts (`"Hunger"` is a
  // `keyof LabelleComponents` literal), so this object literal is
  // checked against the REAL registry shape from components/hunger.zig
  // — `{ levl: 0.875 }` would fail generate with a tsc diagnostic.
  // 0.875 (7/8) is exact in binary floating point at every width en
  // route; the component's declared default is 1.0, so tick 1's
  // TS_LEVEL_0.625 = 0.875 - 0.25 is reachable only through THIS write
  // having traveled the contract into the ECS.
  worker.set("Hunger", { level: START_LEVEL, starving: false });
  worker.set("Worker"); // bare set — the all-defaults `{}` write

  // Builtin-event consumption: an ENGINE event that fires every frame in
  // any game shape — proving the engine's own bus reaches typescript
  // handlers through the tap. Logged once; the frame number rides
  // OUTSIDE the token so the pinned sequence stays stable.
  labelle.on("engine__tick", (ev) => {
    if (!engineTickSeen) {
      engineTickSeen = true;
      labelle.log(`TS_ENGINE_TICK_SEEN frame=${ev.frame_number}`);
    }
  });

  labelle.log(`TS_INIT id=${labelle.u64str(workerId)}`);
}

export function update(dt: number): void {
  void dt; // decay is per-tick (see the controller's header), not dt-scaled
  tick += 1;

  // Command-as-event, CROSS-SCRIPT: this plain-hooks script commands the
  // controller (which subscribed in its init) to feed the worker. The
  // BigInt id and the exact f32 0.5 amount round-trip
  // events/hunger__feed.zig on the real engine bus; the handlers see
  // them on tick 3's inbox.
  if (tick === 2 && workerId !== 0n) {
    if (labelle.emit("hunger__feed", { entity: workerId, amount: FEED_AMOUNT })) {
      labelle.log("TS_FEED_SENT");
    } else {
      labelle.log("TS_FEED_EMIT_FAIL");
    }
  }
}

export function deinit(): void {
  labelle.log("TS_DEINIT");
}
