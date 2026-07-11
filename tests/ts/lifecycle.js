// lifecycle.js — covers the hooks and contract corners no other test
// touches: deinit() (observable through a log + emit, since the VM is
// gone afterwards), prefab spawning, scene changes, and component
// remove/has.

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

let marker = null;

export function init() {
  marker = Entity.create();
  marker.set("Alive", {});

  // Prefab + scene, including the failure arms.
  const ship = labelle.spawn("ship", { x: 5, y: 10 });
  assert(ship !== null, "spawn refused");
  ship.set("Tag", { kind: "spawned" });
  assert(labelle.scene_change("menu"), "scene_change('menu') refused");
  assert(!labelle.scene_change("nope"), "unknown scene must be rejected");

  // Remove is idempotent; has flips accordingly.
  assert(marker.has("Alive"), "has() before remove");
  assert(marker.remove("Alive"), "remove refused");
  assert(!marker.has("Alive"), "has() after remove");
  assert(marker.remove("Alive"), "absent-but-known removes still ok");
}

export function deinit() {
  labelle.log("ts: lifecycle deinit ran");
  labelle.emit("shutdown_done", { from: marker.id });
}
