// prelude.js — the JavaScript-side half of labelle-scripting's typescript
// sub-module (plain JS at runtime; contract/labelle.d.ts is the TS face).
//
// bindings.zig installs the raw shims (`labelle.raw_*`, thin 1:1 bridges
// to the Script Runtime Contract, plus the Zig-side JSON codec) and then
// runs this chunk as a GLOBAL script. Everything is wrapped in one IIFE —
// the closure plays lua's `local` role, keeping internals (handlers,
// helpers) unreachable — and the public surface is exported explicitly
// onto globalThis at the bottom, where every module script sees it.
//
// Layering rule: everything below is pure sugar over `labelle.raw_*` /
// `labelle.json_*`. The raw shims stay reachable on purpose — when a
// script needs something the sugar doesn't cover, the contract is right
// there.
//
// Entity-id rule: ids are u64 on the host and live in JS as BigInt —
// created via the unsigned constructor, so `e.id` reads as the TRUE
// unsigned value (a bit-63 id prints as 9223372036854775809, no signed
// bitcast to explain away). Number cannot hold them: 2^53 truncation
// would silently address the wrong entity, which is why JSON.parse and
// JSON.stringify are the wrong codec for payloads — labelle.json_decode
// materializes big integer tokens as BigInt (small ones stay Numbers)
// and labelle.json_encode renders BigInt as unsigned decimals. Compare
// ids with `===` between BigInts; a Number-held small id from a payload
// compares equal via `==` or after `Entity.wrap(...)` normalization.
//
// Handler ownership: labelle.on records WHICH script registered each
// handler by reading __labelle_current_script — the global vm.zig stamps
// around every VM→script entry (module body, init/update/deinit), the
// VM-truth "whose code is running". NOT derived from the call site: a
// script-local helper closing over an alias of labelle.on gives the
// registration no visible home, and its handlers would dodge the
// eviction purge. When a script is evicted its handlers are purged
// through __labelle_purge_handlers, so nothing keeps firing into dead
// state.

(() => {
  "use strict";

  // ── error formatting (handler dispatch) ────────────────────────────────
  // String(err) is "<Name>: <message>" for Error objects; the stack is
  // flattened to one log line (the vm.zig treatment, same format).
  const formatError = (err) => {
    let text;
    try {
      text = String(err);
    } catch {
      text = "(unprintable error)";
    }
    if (err instanceof Error && typeof err.stack === "string") {
      const stack = err.stack.trim();
      if (stack.length > 0) text += "\n  stack: " + stack.replace(/\n/g, " | ");
    }
    return text;
  };

  // ── ids and component refs ─────────────────────────────────────────────

  // Normalize an id to BigInt. Numbers must be integers (BigInt(1.5)
  // throws — loud); strings are accepted for u64str round-trips.
  const toId = (id) => {
    switch (typeof id) {
      case "bigint":
        return id;
      case "number":
      case "string":
        return BigInt(id);
      default:
        throw new TypeError("labelle: expected an entity id (BigInt, number or decimal string)");
    }
  };

  // A ref is `{ __labelle_component: "<Name>" }` — what labelle.component
  // returns. `componentName` normalizes ref-or-string at every site that
  // accepts a component name (Entity methods, game.query).
  const componentName = (spec) => {
    if (typeof spec === "string") return spec;
    if (spec !== null && typeof spec === "object" && typeof spec.__labelle_component === "string")
      return spec.__labelle_component;
    throw new TypeError("labelle: expected a component name or labelle.component ref");
  };

  const currentScript = () => {
    const name = globalThis.__labelle_current_script;
    return typeof name === "string" ? name : null;
  };

  // ── Entity ─────────────────────────────────────────────────────────────
  // Thin id wrapper: components in and out as plain objects, the JSON leg
  // hidden. `e.id` stays public (a BigInt) — events and raw calls speak
  // ids. Component name parameters accept a string or a component ref.
  class Entity {
    constructor(id) {
      this.id = toId(id);
    }

    /** Wrap an existing entity id (e.g. one carried in an event payload). */
    static wrap(id) {
      return new Entity(id);
    }

    /** Create a fresh empty entity; null when the host refuses (not bound). */
    static create() {
      const id = labelle.raw_entity_create();
      return id === 0n ? null : new Entity(id);
    }

    /**
     * Component read. `get(name)` → fresh object (null when absent);
     * `get(name, into)` REFILLS the caller-owned object in place and
     * returns it (null when absent) — fields absent from the component
     * keep their previous value. The refill is the zero-allocation form:
     * scalar fields cross as immediates, no fresh object per read.
     */
    get(name, into) {
      if (into == null) {
        const s = labelle.raw_component_get(this.id, componentName(name));
        return s === null ? null : labelle.json_decode(s);
      }
      return labelle.raw_component_get_into(this.id, componentName(name), into) ? into : null;
    }

    /**
     * Set (REPLACE semantics) a component from an object; null/undefined
     * means "all defaults". Returns true on success.
     */
    set(name, obj) {
      const payload = obj == null ? "" : labelle.json_encode(obj);
      return labelle.raw_component_set(this.id, componentName(name), payload) === 0;
    }

    has(name) {
      return labelle.raw_component_has(this.id, componentName(name));
    }

    remove(name) {
      return labelle.raw_component_remove(this.id, componentName(name)) === 0;
    }

    destroy() {
      labelle.raw_entity_destroy(this.id);
    }
  }

  // ── game ───────────────────────────────────────────────────────────────

  const game = {
    /**
     * Entities carrying ALL the named components (strings or
     * labelle.component refs, freely mixed), as an Array of Entity
     * wrappers over the contract's id snapshot:
     *   for (const e of game.query("CloudDrift", Position)) { ... }
     * Snapshot semantics: spawning or destroying entities while walking
     * the result is safe.
     */
    query(...names) {
      const encoded = new Array(names.length);
      for (let i = 0; i < names.length; i++) encoded[i] = componentName(names[i]);
      const ids = labelle.raw_query(labelle.json_encode(encoded));
      // Reuse the id array as the result array — ids in, entities out.
      for (let i = 0; i < ids.length; i++) ids[i] = new Entity(ids[i]);
      return ids;
    },
  };

  // ── labelle sugar ──────────────────────────────────────────────────────
  // All defined as `this`-free closures ON PURPOSE: scripts may alias
  // them (`const on = labelle.on`) and call through helpers without
  // breaking anything — ownership comes from the VM stamp, not the call.

  /**
   * Render an entity id as its unsigned decimal string. BigInt ids
   * already print unsigned in JS (`${e.id}`), so unlike lua/ruby this is
   * convenience, not survival — it ships for cross-language payload
   * parity and for Number-held ids.
   */
  labelle.u64str = (id) => {
    if (typeof id !== "bigint" && !(typeof id === "number" && Number.isInteger(id)))
      throw new TypeError("labelle.u64str: expected an entity id (BigInt or integer number)");
    return labelle.raw_u64str(id);
  };

  /**
   * Declare a component — at BUILD time (the labelle-declare runner
   * extracts `name` + the spec's inferred field schema and the assembler
   * generates a real registry component from it). At RUNTIME — here —
   * the same call is pure sugar: it validates nothing, declares nothing,
   * and returns a lightweight ref usable anywhere a component-name
   * string is:
   *
   *   const Hunger = labelle.component("Hunger", { level: 1.0 });
   *   export function update(dt) {
   *     for (const e of game.query(Hunger)) {
   *       const h = e.get(Hunger);
   *       h.level -= dt * 0.01;
   *       e.set(Hunger, h);
   *     }
   *   }
   *
   * One DSL, two consumers (RFC-LANGUAGE-PLUGINS): the spec/opts objects
   * are the build-time contract and deliberately ignored here.
   */
  labelle.component = (name, _spec, _opts) => {
    if (typeof name !== "string" || name.length === 0)
      throw new TypeError("labelle.component: expected a non-empty component name string");
    return { __labelle_component: name };
  };

  /** Log through the game's sink (stringifies for convenience). */
  labelle.log = (msg) => {
    labelle.raw_log(String(msg));
  };

  /** Last tick's gameplay dt in seconds (scaled; 0 while paused). */
  labelle.time_dt = () => labelle.raw_time_dt();

  /**
   * Emit a game event by union-tag name with an object payload
   * (null/undefined = all defaults). Entity ids in the payload may be
   * BigInts directly ({ owner: e.id }) — the encoder renders them as the
   * contract's unsigned decimals. Returns true when the host accepted it.
   */
  labelle.emit = (name, payload) => {
    const json = payload == null ? "" : labelle.json_encode(payload);
    return labelle.raw_event_emit(name, json) === 0;
  };

  /**
   * Spawn a prefab; `params` is an optional {x, y} object. Returns an
   * Entity or null on failure.
   */
  labelle.spawn = (prefab, params) => {
    const json = params == null ? "" : labelle.json_encode(params);
    const id = labelle.raw_prefab_spawn(prefab, json);
    return id === 0n ? null : Entity.wrap(id);
  };

  /** Switch scenes; returns true when the host accepted the name. */
  labelle.scene_change = (name) => labelle.raw_scene_change(name) === 0;

  // ── events: subscribe + dispatch ───────────────────────────────────────
  // The contract is subscribe + poll-drain (one FIFO inbox for the whole
  // VM); callback dispatch is prelude sugar over that drain, shared by
  // every script — which is exactly why `handlers` lives in this closure
  // and not in any script's module scope. Entries are { fn, owner }:
  // ownership is what lets eviction pull a dead script's handlers back
  // out again (__labelle_purge_handlers below).
  const handlers = new Map(); // event name → [{ fn, owner }]

  /**
   * Subscribe `fn` to a game event by name. The payload arrives as a
   * decoded object ({} for empty payloads; big integer id fields as
   * BigInt). Multiple handlers per name fan out in registration order.
   * The registering SCRIPT owns the handler — __labelle_current_script,
   * the VM's stamp of whose code is running (null for prelude/host-run
   * code, which no purge ever matches): when a script is evicted (module
   * body or init() failure), its handlers are purged with it and never
   * fire again.
   */
  labelle.on = (name, fn) => {
    if (typeof fn !== "function") throw new TypeError("labelle.on requires a function");
    labelle.raw_event_subscribe(name);
    let hs = handlers.get(name);
    if (hs === undefined) {
      hs = [];
      handlers.set(name, hs);
    }
    hs.push({ fn, owner: currentScript() });
  };

  /**
   * Drain the event inbox, dispatching each entry to its handlers. The
   * Controller calls this once at tick start, BEFORE script updates, so
   * handlers observe last frame's events before this frame's logic runs.
   * Handlers are ISOLATED: each runs under its own try/catch — a throwing
   * handler is logged (event, owner, stack) and the fan-out AND the drain
   * continue. Each handler runs with __labelle_current_script set to its
   * owner (and restored after), so a handler that registers handlers
   * attributes them correctly. Only SURVIVING handlers run — an evicted
   * script's were purged.
   */
  labelle.dispatch_inbox = () => {
    for (;;) {
      const entry = labelle.raw_event_poll();
      if (entry === null) break;
      const hs = handlers.get(entry[0]);
      if (hs === undefined) continue;
      const payload = entry[1];
      const fanout = hs.length; // registrations during dispatch fire next event
      for (let i = 0; i < fanout; i++) {
        const h = hs[i];
        const saved = globalThis.__labelle_current_script;
        globalThis.__labelle_current_script = h.owner === null ? undefined : h.owner;
        try {
          h.fn(payload);
        } catch (err) {
          labelle.raw_log(
            `[ts] event '${entry[0]}' handler (owner '${h.owner}') failed: ${formatError(err)}`,
          );
        }
        globalThis.__labelle_current_script = saved;
      }
    }
  };

  // Eviction hook — vm.zig calls this (load-fail and init-fail paths)
  // with the dead script's name: drop every handler that script
  // registered, so a module-scope labelle.on can't keep firing into
  // evicted state. Owner-less handlers (owner null) never match a purge.
  globalThis.__labelle_purge_handlers = (name) => {
    if (typeof name !== "string") return;
    for (const [ev, hs] of handlers) {
      for (let i = hs.length - 1; i >= 0; i--) {
        if (hs[i].owner === name) hs.splice(i, 1);
      }
      if (hs.length === 0) handlers.delete(ev);
    }
  };

  // ── FrameArray ─────────────────────────────────────────────────────────
  // Per-frame scratch list, the clearRetainingCapacity idiom — shipped
  // because the naive ports are traps: whether `arr.length = 0` keeps the
  // backing storage is ENGINE-INTERNAL (QuickJS may shrink or convert the
  // array's representation), so a scratch array cleared that way can
  // reallocate every frame. FrameArray keeps a preallocated dense backing
  // plus a logical length: `push` is in-bounds index assignment (never
  // reallocates), `clear` is `size = 0` (the backing survives), and
  // growth only happens when a push overflows capacity — visible through
  // growthCount, so a warmed hot loop can assert it stays flat.
  //
  // For pure-numeric scratch, a reused Float64Array is the other
  // zero-allocation idiom: fixed capacity by construction, elements are
  // raw doubles (no boxing at all) — see the README.
  class FrameArray {
    constructor(capacity) {
      if (typeof capacity !== "number" || !Number.isInteger(capacity) || capacity <= 0)
        throw new TypeError("FrameArray capacity must be a positive integer");
      this._buf = new Array(capacity).fill(null); // fill → dense storage
      this._size = 0;
      this._growth = 0;
    }

    get size() {
      return this._size;
    }

    get capacity() {
      return this._buf.length;
    }

    get growthCount() {
      return this._growth;
    }

    push(v) {
      if (this._size === this._buf.length) {
        // Deliberate growth: double the backing by dense appends (one
        // amortized reallocation), count it. Steady-state reuse never
        // comes back here.
        let add = this._buf.length;
        while (add-- > 0) this._buf.push(null);
        this._growth += 1;
      }
      this._buf[this._size++] = v;
      return this;
    }

    clear() {
      this._size = 0; // logical length; the backing survives
      return this;
    }

    get(i) {
      if (typeof i !== "number" || i < 0 || i >= this._size) return undefined;
      return this._buf[i];
    }

    set(i, v) {
      if (typeof i !== "number" || i < 0 || i >= this._size)
        throw new RangeError(`FrameArray index ${i} out of bounds (size ${this._size})`);
      this._buf[i] = v;
    }

    forEach(fn) {
      for (let i = 0; i < this._size; i++) fn(this._buf[i], i);
      return this;
    }

    isEmpty() {
      return this._size === 0;
    }

    toArray() {
      return this._buf.slice(0, this._size);
    }
  }

  labelle.FrameArray = FrameArray;

  // ── exports ────────────────────────────────────────────────────────────
  // One visible block: everything scripts can reach by name. `labelle`
  // was created by bindings.zig (raw shims) and extended in place above.

  globalThis.Entity = Entity;
  globalThis.game = game;

  // name → module namespace of each registered script; vm.zig fills it in
  // loadScript and reads it in callScriptHook. Null-prototyped: script
  // names must never collide with Object.prototype keys.
  globalThis.__labelle_scripts = Object.create(null);
})();
