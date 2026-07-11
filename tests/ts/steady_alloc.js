// steady_alloc.js — the per-frame allocation proof for the `get(name,
// into)` refill pattern and FrameArray, measured on QuickJS's LIVE malloc
// count (labelle.raw_gc_live → JS_ComputeMemoryUsage.malloc_count):
// refcounting frees acyclic garbage at the last reference, so a net-zero
// tick keeps the live count EXACTLY constant — the refcount-world
// equivalent of the ruby suite's disabled-GC live-object counter. The
// measured loop uses the strict forms: one caller-owned refill target
// (scalar fields cross as immediates — zero allocation), component
// writes through the same object, FrameArray in-bounds appends. Warm-up
// covers shapes, inline caches and scratch growth; one explicit
// labelle.raw_gc() at baseline settles any warm-up cycles so the 100
// measured ticks start from a clean heap. Verdict lands in SteadyAlloc
// for the Zig side.

let e = null;
let hot = null; // the caller-owned refill target
let fa = null;
let ticks = 0;
let base = -1;
let liveOk = true;

export function init() {
  e = Entity.create();
  e.set("Hot", { level: 100.0, count: 0 });
  hot = { level: 0, count: 0 };
  fa = new labelle.FrameArray(64);

  // The refill sugar returns the caller's own object, filled in place.
  const got = e.get("Hot", hot);
  if (got !== hot) throw new Error("into refill must return the caller's object");
  if (hot.level !== 100 || hot.count !== 0) throw new Error("into refill missed");
}

export function update(dt) {
  ticks += 1;

  // FrameArray reuse: clear keeps the backing, appends stay in bounds.
  fa.clear();
  for (let i = 0; i < 48; i++) fa.push(i);

  // The hot component loop: 10 refill→mutate→write rounds per tick.
  for (let j = 0; j < 10; j++) {
    e.get("Hot", hot);
    hot.level -= 0.25;
    hot.count += 1;
    e.set("Hot", hot);
  }

  if (ticks === 5) {
    // Warm-up done: collect any warm-up cycles, then freeze the baseline.
    labelle.raw_gc();
    base = labelle.raw_gc_live();
  } else if (ticks > 5) {
    if (labelle.raw_gc_live() !== base) liveOk = false;
  }

  if (ticks === 105) {
    e.set("SteadyAlloc", {
      ticks,
      count: hot.count,
      growth: fa.growthCount,
      live_ok: liveOk,
    });
  }
}
