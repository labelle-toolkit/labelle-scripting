// component_ref.js — the RUNTIME half of "one DSL, two consumers": the
// same module-scope labelle.component lines a future declare runner reads
// as schema evaluate, here, to lightweight refs that Entity methods and
// game.query accept interchangeably with name strings.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

const Hunger = labelle.component("Hunger", { level: 1.0, starving: false });
const Tag = labelle.component("Tag", { kind: "none" }, { persist: "transient" });

export function init() {
  assert(typeof Hunger === "object", "ref is not an object");
  assert(Hunger.__labelle_component === "Hunger", "ref carries the wrong name");

  const e = Entity.create();
  assert(e.set(Hunger, { level: 0.5, starving: false }), "set via ref refused");
  assert(e.has(Hunger), "has via ref is false");

  // Ref and string address the SAME component.
  const viaRef = e.get(Hunger);
  const viaName = e.get("Hunger");
  assert(viaRef.level === 0.5, "get via ref returned the wrong object");
  assert(viaName.level === 0.5, "ref and string disagree");

  // Refs work in queries, mixed with strings.
  e.set(Tag, { kind: "x" });
  assert(game.query(Hunger, "Tag").length === 1, "query via ref missed the entity");
  assert(game.query(Tag).length === 1, "query via ref alone missed");

  assert(e.remove(Tag), "remove via ref refused");
  assert(!e.has(Tag), "component survived remove via ref");

  // An object that is NOT a ref is rejected loudly, not treated as a name.
  let threw = false;
  try {
    e.get({});
  } catch {
    threw = true;
  }
  assert(threw, "a non-ref object was accepted as a component name");

  e.set("RefOk", { ok: true });
}
