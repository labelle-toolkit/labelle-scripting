// counter.js — the "innocent bystander" script for the error-isolation
// tests: registered AFTER scripts that fail, it proves the Controller
// keeps ticking the rest. Also records labelle.time_dt() so the test can
// assert the dt stamp reached script-land.

let e = null;

export function init() {
  e = Entity.create();
  e.set("Counter", { n: 0, dt: 0 });
}

export function update(dt) {
  const c = e.get("Counter");
  c.n += 1;
  c.dt = labelle.time_dt();
  e.set("Counter", c);
}
