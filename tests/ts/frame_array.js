// frame_array.js — labelle.FrameArray semantics: `clear` keeps the
// backing (size = 0, no reallocation — whether `arr.length = 0` retains
// storage is engine-internal, so FrameArray never relies on it), `push`
// appends in bounds, growth only on overflow and counted. The
// steady-state no-growth-across-ticks property is asserted in
// steady_alloc.js; this pins the unit behavior.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

export function init() {
  const fa = new labelle.FrameArray(4);
  assert(fa.size === 0 && fa.isEmpty() && fa.capacity === 4, "fresh size");

  fa.push(1).push(2).push(3);
  assert(fa.size === 3 && !fa.isEmpty(), "push size");
  assert(fa.get(0) === 1 && fa.get(2) === 3, "get");
  assert(fa.get(3) === undefined && fa.get(-1) === undefined, "get out of logical bounds");

  let sum = 0;
  fa.forEach((v) => {
    sum += v;
  });
  assert(sum === 6, "forEach");

  fa.set(1, 20);
  assert(fa.get(1) === 20, "set");
  let setThrew = false;
  try {
    fa.set(3, 9); // beyond logical size
  } catch {
    setThrew = true;
  }
  assert(setThrew, "set out of bounds must throw");

  fa.clear();
  assert(fa.size === 0 && fa.capacity === 4 && fa.growthCount === 0, "clear keeps capacity");
  fa.push(9);
  assert(fa.get(0) === 9 && fa.size === 1, "reuse after clear");

  // Deliberate growth: the 5th push overflows cap 4 — ONE doubling,
  // counted, contents intact.
  fa.clear();
  for (let i = 0; i < 5; i++) fa.push(i);
  assert(fa.size === 5 && fa.growthCount === 1 && fa.capacity === 8, "growth");
  assert(fa.get(4) === 4 && fa.get(0) === 0, "content after growth");
  const arr = fa.toArray();
  assert(
    arr.length === 5 && arr.every((v, i) => v === i),
    "toArray",
  );

  Entity.create().set("FrameArrayOk", { ok: true });
}
