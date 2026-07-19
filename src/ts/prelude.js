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
     *
     * Plain objects route through `raw_component_set_from` — the packed
     * binary fast path on v1.3+ hosts, with the JSON encoder as its
     * internal fallback (non-scalar values, host refusals, pre-v1.3
     * engines), so the observable semantics are IDENTICAL either way
     * (including the canonical non-finite TypeError). Arrays and
     * primitives keep the explicit JSON leg (an array payload must reach
     * the host as a JSON array, never as a field record).
     */
    set(name, obj) {
      const nm = componentName(name);
      if (obj !== null && typeof obj === "object" && !Array.isArray(obj)) {
        return labelle.raw_component_set_from(this.id, nm, obj) === 0;
      }
      const payload = obj == null ? "" : labelle.json_encode(obj);
      return labelle.raw_component_set(this.id, nm, payload) === 0;
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

  /**
   * Declare a custom event — at BUILD time (the labelle-declare-ts runner
   * extracts `name` + the spec's inferred field schema and the assembler
   * generates a real GameEvents union row from it). At RUNTIME — here — the
   * same call is pure sugar: it validates nothing, declares nothing, and
   * returns the event-NAME string, so the declared constant feeds
   * `labelle.emit`/`labelle.on` directly:
   *
   *   export const HungerFeed = labelle.event("hunger__feed", {
   *     entity: labelle.id, amount: 0.5,
   *   });
   *   labelle.emit(HungerFeed, { entity: e.id, amount: 1.0 });
   *
   * One DSL, two consumers (RFC-LANGUAGE-PLUGINS rev 20): the spec object is
   * the build-time contract and deliberately ignored here — the runtime twin
   * of the lua/ruby preludes, which likewise return the name.
   */
  labelle.event = (name, _spec) => {
    if (typeof name !== "string" || name.length === 0)
      throw new TypeError("labelle.event: expected a non-empty event name string");
    return name;
  };

  /**
   * The entity-id field marker for declarations (`entity: labelle.id` in a
   * component/event spec ⇒ a u64 id field). At runtime it is plain 0 — specs
   * are ignored here, so the same declaration line evaluates clean in both
   * modes (the declare runner recognizes the marker; the game never reads it).
   */
  labelle.id = 0;

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

  // ── batched query (the whole-query fast path, contract v1.3) ───────────
  // `batch_get(names, arr)` fills `arr` with every matching entity's scalar
  // component data as a flat f32 array — [c0_f0, c0_f1, ..., c1_f0, ...]
  // per entity, components in `names` order, fields in declaration order —
  // and returns the entity COUNT (`arr` is trimmed to exactly
  // count*stride). ONE FFI crossing for the whole query instead of a get
  // per entity; reuse the SAME `arr` across ticks. `batch_set(names, arr,
  // n)` writes the mutated `arr` back in ONE crossing (the host re-queries
  // the same entities, same order). The caller owns the positional layout.
  //
  // Refusals are LOUD (contract v1.3):
  //   - a named component with an INT-typed field throws TypeError —
  //     i64/u64 cannot ride the f32 stream without silent corruption; keep
  //     such components on per-entity get/set (their packed codec is
  //     lossless);
  //   - do NOT spawn or destroy entities between a paired batch_get and
  //     batch_set: batch_set throws Error when the entity set no longer
  //     matches the buffer (re-run batch_get and recompute);
  //   - on a game built against a pre-v1.3 engine (labelle-engine < 2.6.0)
  //     BOTH calls throw Error ("host engine lacks batch support") — there
  //     is no batch fallback; use per-entity get/set there. The per-entity
  //     get-into/set fast paths degrade to JSON silently instead.

  const resolveNames = (names) => {
    const resolved = new Array(names.length);
    for (let i = 0; i < names.length; i++) resolved[i] = componentName(names[i]);
    return resolved;
  };

  labelle.batch_get = (names, arr) =>
    labelle.raw_batch_get(labelle.json_encode(resolveNames(names)), arr);

  labelle.batch_set = (names, arr, n) =>
    labelle.raw_batch_set(labelle.json_encode(resolveNames(names)), arr, n);

  // ── batch callback iterator (the ergonomic layer over batch_get/set) ───
  // `labelle.batch(names, (e) => { ... })` — ONE batch_get, the callback
  // runs once per matching entity against a single REUSED view object,
  // then ONE batch_set writes everything back. No per-entity FFI and no
  // per-entity allocation: the view is one object whose backing offset
  // moves between calls (stash values, never `e` itself — the object you
  // saved points at whatever entity was visited last).
  //
  //   labelle.batch(["Position", "Velocity"], (e) => {
  //     e.x += e.vx; e.y += e.vy;
  //     if (e.x < 0.0 || e.x > 800.0) e.vx = -e.vx;
  //   });
  //
  // Accessors are the components' FIELD NAMES in stream order (components
  // in `names` order, fields in declaration order — the same walk
  // batch_get lays the stream out with). Reads return Numbers (bools ride
  // as 0/1, like the raw stream); writes take numbers. `names` may be a
  // single name instead of an array; an empty names array is a TypeError.
  // Returns the entity count. An empty query returns 0 without touching
  // the callback. No field names are reserved: the view's base offset
  // lives in a closure, not on the object, so every field name is fair
  // game (`size`, `constructor`, whatever — accessors shadow the
  // prototype within the view). Writing a field the view does NOT have
  // (`e.xx = …`, a typo) throws a TypeError naming the field and the
  // known fields (#50) — a plain object would silently grow an ordinary
  // property and the commit would miss the write.
  //
  // Exit semantics — EARLY-RETURN COMMITS, THROW ABORTS (the JS mapping
  // of ruby's break-commits/raise-aborts):
  //   - a THROWING callback unwinds straight out of labelle.batch BEFORE
  //     the write — batch_set never runs, no entity is touched
  //     (all-or-nothing, safe to catch and retry);
  //   - the callback returning `false` (strictly — any other return value
  //     including undefined continues) is the iterator early-exit and
  //     COMMITS: every write made up to that point flushes through the
  //     one batch_set ("stop iterating, keep my edits"); entities not yet
  //     visited round-trip unchanged.
  //
  // The raw pairing rules apply to the callback form too: no
  // spawn/destroy inside the callback, and no nested labelle.batch over
  // the same names (it would refill the shared buffer mid-iteration).
  //
  // Layout discovery (the ruby stage-2 pattern): on first use per
  // names-set the field list derives from a JSON `raw_component_get` of
  // each named component on the first matched entity — the host
  // serializes struct fields in DECLARATION order (JS objects preserve
  // insertion order for identifier keys), the exact order the batch
  // stream walks, and non-scalar values are filtered out just as the
  // stream skips non-scalar fields. Any way the probe could disagree with
  // the stream is caught by a hard stride cross-check before the first
  // call — a mismatch throws, never mis-maps. The derived view is cached
  // per names-set: steady state is batch_get + N calls + batch_set.
  //
  // Refusals on top of batch_get/batch_set's own (which pass through
  // unchanged — int-typed fields, entity-set drift, pre-v1.3 hosts):
  //   - a field name duplicated across the named components throws
  //     TypeError (the accessors could not disambiguate);
  //   - a derived layout that does not match the stream's stride throws
  //     Error (use the raw batch_get/batch_set flat loop there);
  //   - the entity set vanishing between batch_get and first-use layout
  //     discovery (a mid-tick destroy race) throws Error — nothing was
  //     written; re-running next tick is fine.
  const batchIters = new Map(); // names key → { buf, view, stride, setBase }

  const buildBatchView = (st, resolved, namesJson, buf, count) => {
    const ids = labelle.raw_query(namesJson);
    if (ids.length === 0) {
      // batch_get saw entities but the discovery re-query sees none: an
      // entity was destroyed between the paired calls. Nothing was
      // written; calling again next tick is fine.
      throw new Error(
        `labelle: labelle.batch(${namesJson}): the entity set vanished between ` +
          "batch_get and layout discovery (an entity was destroyed mid-tick) — " +
          "nothing was written; re-run next tick",
      );
    }
    const first = ids[0];
    const fields = [];
    for (const nm of resolved) {
      const s = labelle.raw_component_get(first, nm);
      if (s === null) continue; // stride cross-check below catches any inconsistency
      const obj = labelle.json_decode(s);
      for (const k of Object.keys(obj)) {
        const v = obj[k];
        if (typeof v !== "number" && typeof v !== "boolean") continue;
        if (fields.includes(k)) {
          throw new TypeError(
            `labelle: labelle.batch(${namesJson}): field name '${k}' appears in ` +
              "more than one named component — the view cannot disambiguate; " +
              "use batch_get/batch_set with explicit offsets",
          );
        }
        fields.push(k);
      }
    }
    const stride = fields.length;
    if (buf.length !== count * stride) {
      throw new Error(
        `labelle: labelle.batch(${namesJson}): derived layout (${stride} fields ` +
          `per entity) does not match the host stream (${buf.length} floats / ` +
          `${count} entities) — a field the stream skips (non-scalar) confused ` +
          "the layout probe; use batch_get/batch_set with explicit offsets for " +
          "these components",
      );
    }
    let base = 0;
    const view = {};
    fields.forEach((f, off) => {
      Object.defineProperty(view, f, {
        get: () => buf[base + off],
        set: (v) => {
          buf[base + off] = v;
        },
        enumerable: true,
      });
    });
    // Unknown STRING-field WRITES throw (#50, the lua view's __newindex
    // parity): the bare object would happily grow a plain `xx` property
    // on a typo'd `e.xx = …` — the backing buffer untouched, the commit
    // silently missing the write. A Proxy set trap throws REGARDLESS of
    // the caller's strictness (Object.seal only throws under strict mode
    // — module scripts are strict by spec, but the console evals global
    // sloppy code), and names both the field and the view's known
    // fields. Known-field writes forward to the accessors unchanged;
    // reads take the ordinary [[Get]] on the target (no get trap — the
    // hot path stays accessor-direct).
    //
    // SYMBOL keys pass straight through to the target: runtimes, test
    // frameworks and debuggers legitimately stamp Symbol-keyed internal
    // props on any object (Symbol.iterator, inspector markers, …), and
    // those are never a field typo. Only an unknown STRING key is a
    // mis-spelled field write worth trapping.
    st.view = new Proxy(view, {
      set: (target, prop, value) => {
        if (typeof prop === "string" && !Object.prototype.hasOwnProperty.call(target, prop)) {
          throw new TypeError(
            `labelle.batch view: unknown field '${prop}' — known fields: ${fields.join(", ")}`,
          );
        }
        target[prop] = value;
        return true;
      },
    });
    st.stride = stride;
    st.setBase = (b) => {
      base = b;
    };
  };

  labelle.batch = (names, fn) => {
    if (typeof fn !== "function") throw new TypeError("labelle.batch requires a callback function");
    if (!Array.isArray(names)) names = [names];
    if (names.length === 0)
      throw new TypeError("labelle.batch: expected at least one component name");
    const resolved = resolveNames(names);
    const key = resolved.join(" ");
    let st = batchIters.get(key);
    if (st === undefined) {
      st = { buf: [], view: null, stride: 0, setBase: null };
      batchIters.set(key, st);
    }
    const namesJson = labelle.json_encode(resolved);
    const buf = st.buf;
    const count = labelle.raw_batch_get(namesJson, buf);
    if (count === 0) return 0;
    if (st.view === null) buildBatchView(st, resolved, namesJson, buf, count);
    const stride = st.stride;
    if (buf.length !== count * stride) {
      throw new Error(
        `labelle: labelle.batch(${namesJson}): derived layout (${stride} fields ` +
          `per entity) does not match the host stream (${buf.length} floats / ` +
          `${count} entities) — a field the stream skips (non-scalar) confused ` +
          "the layout probe; use batch_get/batch_set with explicit offsets for " +
          "these components",
      );
    }
    // A throw below unwinds past the batch_set — the all-or-nothing
    // abort needs no try/catch; only the two commit paths reach it.
    let base = 0;
    for (let i = 0; i < count; i++) {
      st.setBase(base);
      if (fn(st.view) === false) break; // early-exit → COMMIT below
      base += stride;
    }
    labelle.raw_batch_set(namesJson, buf, count);
    return count;
  };

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
