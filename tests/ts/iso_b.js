// iso_b.js — the other half of the module-isolation pair (see iso_a.js):
// identical binding and hook names, different state and step size.

let e = null;
let n = 0;

export function update(dt) {
  if (e === null) e = Entity.create();
  n += 10;
  e.set("IsoB", { n });
}

export function deinit() {
  labelle.log("iso_b deinit");
}
