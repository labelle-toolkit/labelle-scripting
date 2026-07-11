// payload_id_check.js — u64 fidelity in EVENT PAYLOAD decode: the host
// emits {"owner":9223372036854775809} (bit 63 set, beyond MAX_SAFE_INTEGER)
// and the Zig decoder must land it as a BigInt bit-exact with the id
// raw_entity_create handed out — JSON.parse would round it through a
// float and Entity.wrap(ev.owner) would address a wrong (or no) entity.
// The handler's set() writing to the RIGHT entity is what the Zig side
// asserts against the u64 id.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

let me = null;

labelle.on("owner__ping", (ev) => {
  assert(typeof ev.owner === "bigint", "payload id must decode as a BigInt");
  assert(ev.owner === me.id, "payload id must equal the created id bit-for-bit");
  const e = Entity.wrap(ev.owner);
  assert(e.has("Marker"), "wrapped payload id must address the created entity");
  const m = e.get("Marker");
  e.set("Owned", { seen: true, tag: m.tag });
});

export function init() {
  me = Entity.create(); // the mock hands out 0x8000000000000001
  me.set("Marker", { tag: 42 });
}
