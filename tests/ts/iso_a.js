// iso_a.js — half of the module-isolation pair: same module-scope
// binding names and same exported hook names as iso_b.js. ES-module
// scoping must keep the two fully apart (the lua-_ENV / ruby-harvest
// equivalent, provided by the engine itself).

let e = null;
let n = 0;

export function update(dt) {
  if (e === null) e = Entity.create();
  n += 1;
  e.set("IsoA", { n });
}

export function deinit() {
  labelle.log("iso_a deinit");
}
