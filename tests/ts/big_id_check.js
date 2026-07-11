// big_id_check.js — round-trips a bit-63 entity id through the FULL query
// path. The Zig test forces the mock's next id to 0x8000000000000001, so
// raw_entity_create hands out that BigInt, the host's query response
// spells the id as its unsigned decimal (> Number.MAX_SAFE_INTEGER — any
// float leak in the query path would round it), and the raw_query parse
// must land it back on the exact same BigInt: get/set/has through the
// QUERIED wrapper then hit the right entity, which the Zig side proves by
// asserting components against the u64 id.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

export function init() {
  const e = Entity.create(); // the mock hands out 0x8000000000000001
  e.set("Marker", { tag: 1 });

  let found = null;
  let n = 0;
  for (const q of game.query("Marker")) {
    n += 1;
    found = q;
  }
  assert(n === 1, "query must match exactly the one marked entity");
  assert(typeof found.id === "bigint", "queried id must be a BigInt");
  assert(found.id === e.id, "parsed id must equal the created id bit-for-bit");
  assert(found.has("Marker"), "has() through the queried wrapper");

  const m = found.get("Marker"); // get through the queried wrapper
  m.tag += 41;
  found.set("Marker", m); // set lands on the same entity, or Zig's assert fails

  found.set("BigId", { idstr: labelle.u64str(found.id) });
}
