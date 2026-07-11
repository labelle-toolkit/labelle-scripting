// behavior.js — the POC behavior (labelle-engine poc/language-plugins,
// scripts/behavior.lua), ported to the typescript sub-module's surface:
// ES-module hooks (exported init/update), Entity wrappers, labelle.on
// instead of a hand-rolled poll loop, object payloads instead of
// hand-built JSON. Same observable behavior as the lua/ruby ports: +10 x
// per tick, bullet + emit on the third tick, react to host tick 4 by
// writing TickLog. Note `{ owner: player.id }` — the id is a BigInt and
// the encoder renders it as the contract's unsigned integer, byte-exact
// with the other suites' pins.

let player = null;

// Receive side: handler sugar over the contract's subscribe + poll-drain.
// Registered at module scope (before init), fired from the Controller's
// inbox dispatch at the top of each tick.
labelle.on("tick_started", (ev) => {
  if (ev.n === 4) {
    player.set("TickLog", { last: 4 });
    labelle.log("ts: saw tick 4");
  }
});

export function init() {
  player = Entity.create();
  player.set("Position", { x: 0, y: 0 });
  labelle.log(`ts: player ${player.id} ready`);
}

export function update(dt) {
  const pos = player.get("Position");
  pos.x += 10;
  player.set("Position", pos);

  // On the third tick: spawn a bullet and tell the world about it.
  if (pos.x === 30) {
    const bullet = Entity.create();
    bullet.set("Bullet", { vx: 0, vy: -500 });
    labelle.emit("bullet_spawned", { owner: player.id });
    labelle.log("ts: bullet away");
  }
}
