// big_query_check.js — the grow-and-retry path: 420 entities with
// 20-digit ids serialize to ~8.8 KB of id JSON, past the 4 KiB initial
// scratch. The contract's snprintf-style return makes the overflow
// detectable and the shim must retry right-sized, so game.query yields
// ALL ids — a silent prefix would fail the count or the id-set checks
// below (a throw evicts this script and leaves BigQuery unset for the
// Zig side to catch). The created-id set is a Map keyed by BigInt —
// SameValueZero keying makes BigInt keys exact.

const N = 420;

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

export function init() {
  const created = new Map();
  for (let i = 1; i <= N; i++) {
    const e = Entity.create();
    assert(e !== null, `mock refused entity ${i} — raise MAX_ENTITIES?`);
    e.set("Marker", { i });
    created.set(e.id, true);
  }

  let n = 0;
  for (const q of game.query("Marker")) {
    n += 1;
    assert(created.has(q.id), "query yielded an id that was never created");
    created.delete(q.id); // each id exactly once
  }
  assert(n === N, `query must yield ALL ids after the retry, got ${n}`);
  assert(created.size === 0, "every created id must appear in the result");

  const r = Entity.create();
  r.set("BigQuery", { count: n });
}
