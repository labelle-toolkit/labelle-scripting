// json_roundtrip.js — proves the Zig-side JSON codec (labelle.json_encode
// / labelle.json_decode) on the shapes component payloads actually take:
// nested objects, arrays, integral vs fractional numbers, BigInt id
// fields, escapes, \u escapes, booleans, null, empty containers. Codec
// properties assert inline (a failure evicts this script, which the Zig
// side notices as missing components); the byte-exact component JSON is
// asserted from Zig.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

export function init() {
  const original = {
    name: 'ship "X"\n\\end',
    hp: 42,
    ratio: 1.5,
    neg: -2.25,
    pos: { x: 1.5, y: -2 },
    tags: ["a", "b", "c"],
    flags: { active: true, dead: false },
    empty: {},
  };
  const d = labelle.json_decode(labelle.json_encode(original));
  assert(d.name === original.name, "string escapes");
  assert(d.hp === 42, "integer");
  assert(d.ratio === 1.5 && d.neg === -2.25, "floats");
  assert(d.pos.x === 1.5 && d.pos.y === -2, "nested object");
  assert(d.tags.length === 3 && d.tags[2] === "c", "array");
  assert(d.flags.active === true && d.flags.dead === false, "booleans");
  assert(typeof d.empty === "object" && Object.keys(d.empty).length === 0, "empty object");

  // Decode-only shapes a host may hand us: whitespace everywhere,
  // unicode escapes, null fields (null stays a PRESENT null value —
  // JS has null natively, unlike lua where it vanishes), nested empties.
  const extern_ = labelle.json_decode(
    ' { "u" : "\\u0041BC" , "gone" : null , "arr" : [ 1 , 2.5 , { "deep" : [ [ ] ] } ] } ',
  );
  assert(extern_.u === "ABC", "\\u escape");
  assert(extern_.gone === null && "gone" in extern_, "null field survives as null");
  assert(extern_.arr[0] === 1 && extern_.arr[1] === 2.5, "array numbers");
  assert(Array.isArray(extern_.arr[2].deep[0]), "nested empty array");

  // Deterministic (sorted-key) encoding is part of the codec's promise.
  assert(
    labelle.json_encode({ b: 1, a: 2, c: 3 }) === '{"a":2,"b":1,"c":3}',
    "sorted keys",
  );
  // Integral doubles render as integers — the other backends' int fields
  // must survive a JS round-trip byte-exact.
  assert(labelle.json_encode({ x: 50.0 }) === '{"x":50}', "integral double renders as int");
  // BigInt fields (entity ids) render as unsigned 64-bit decimals.
  assert(
    labelle.json_encode({ id: 0x8000000000000001n }) === '{"id":9223372036854775809}',
    "BigInt renders unsigned",
  );
  // JSON.stringify parity: undefined-valued properties are absent.
  assert(labelle.json_encode({ a: 1, b: undefined }) === '{"a":1}', "undefined props skipped");

  // Component round-trip through the host: set with both empties, get it
  // back, set it again UNTOUCHED — {} and [] must hold across both hops
  // (JS's native answer to lua's labelle.array marker).
  const e = Entity.create();
  e.set("Path", { waypoints: [], meta: {} });
  e.set("PathAgain", e.get("Path"));

  Entity.create().set("RoundTrip", { ok: true });
}
