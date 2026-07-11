// query_check.js — exercises game.query end to end: prelude → raw_query
// shim → contract → mock host id-JSON → Entity wrappers. Note `sum`
// starts as 0n: entity ids are BigInt, and mixing them into Number
// arithmetic is a TypeError by design — the id sum is BigInt math.
// Findings land in a QueryResult component for the Zig side.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

export function init() {
  for (let i = 1; i <= 3; i++) {
    const e = Entity.create();
    e.set("Marker", { i });
    if (i === 2) e.set("Extra", {});
  }
  Entity.create(); // bare entity: must be invisible to every query below

  let count = 0;
  let sum = 0n;
  for (const e of game.query("Marker")) {
    count += 1;
    sum += e.id;
    assert(e.has("Marker"), "queried wrapper must carry Marker");
  }

  let both = 0;
  for (const e of game.query("Marker", "Extra")) {
    both += 1;
    assert(e.get("Marker").i === 2, "the multi-name filter found the wrong one");
  }

  let none = 0;
  for (const _ of game.query("Nope")) none += 1;

  const r = Entity.create();
  r.set("QueryResult", { count, sum, both, none });
}
