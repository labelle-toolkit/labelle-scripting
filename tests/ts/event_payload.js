// event_payload.js — the dispatch test: labelle.on handlers must fire
// once per drained event, in FIFO order, with the payload decoded to an
// object (nested structures included). Two handlers on one name prove
// fan-out. Findings go into the Seen component.

let state = null;

labelle.on("cargo__delivered", (ev) => {
  const s = state.get("Seen");
  s.count += 1;
  s.amount = ev.amount;
  s.nested_ok = ev.box.w === 2 && ev.box.tags[0] === "fragile";
  state.set("Seen", s);
});

// Second handler on the same event: fan-out in registration order.
labelle.on("cargo__delivered", (ev) => {
  const s = state.get("Seen");
  s.fanout = (s.fanout ?? 0) + 1;
  state.set("Seen", s);
});

export function init() {
  state = Entity.create();
  state.set("Seen", { count: 0, fanout: 0 });
}
