// declare_prelude.js — the JavaScript half of the typescript declare-mode
// runner (labelle-declare-ts; the lua/ruby runners' twin — see
// tools/declare/declare_prelude.lua and tools/declare-ruby/declare_prelude.rb
// for the reference semantics this file mirrors).
//
// Declare mode is the build-time consumer of the component AND event DSLs:
// the SAME `export const Hunger = labelle.component("Hunger", { level: 0.875 })`
// line that hands a script a lightweight ref at runtime (src/ts/prelude.js)
// is, here, a schema declaration — and the SAME
// `export const HungerFeed = labelle.event("hunger__feed", { entity: labelle.id,
// amount: 0.5 })` line that returns the frozen event-name string at runtime
// is, here, an event-schema declaration. Only `labelle.component`,
// `labelle.event` and `labelle.id` are live; the DSL knows NOTHING about tsc
// (RFC-LANGUAGE-PLUGINS rev 20 option (b): the assembler transpiles the
// declaration files FIRST and hands this evaluator the EMITTED `.js`, so the
// tool is a pure embedded-VM evaluator, exactly like the lua/ruby runners).
//
// Isolation: where the lua runner builds a fresh stub `_ENV` per chunk and the
// ruby runner opens a fresh interpreter per chunk, TypeScript needs NEITHER —
// each declaration file is evaluated as its own ES MODULE (extract.zig,
// JS_EVAL_TYPE_MODULE), so top-level `const`/`let`/`function` are module-scoped
// and two files never collide. There is no cross-file constant ledger (the
// ruby softening for its one shared VM): modules cannot see each other's
// top-level bindings, and scripts reference declared components/events by NAME
// STRING (`e.set("Hunger", ...)`, `game.query("Hunger")`), never by a shared
// constant, so nothing has to travel between files. This prelude runs ONCE as
// a global chunk before any module; the recorder accumulates across modules on
// globalThis, which extract.zig reads after the last module ran.
//
// Determinism: components and events each emit in DECLARATION order (argv
// order, then top-to-bottom within a file); fields emit SORTED BY NAME (one
// schema for one logical declaration set, whatever the language — the lua
// runner cannot recover field declaration order, so every runner sorts). The
// Zig side (extract.zig) owns ALL byte formatting — float `%.14g` through the
// host libc's snprintf (byte-identical to the lua runner, which formats through
// the same libc), integer decimals, string escaping, the envelope — so this
// prelude only CLASSIFIES and stores raw values; it never renders a number.
//
// Type inference (v1), the lua/ruby matrix in JS types: `boolean` → bool;
// `number` → f32 (finite + f32-range-gated — JS has ONE Number type, so every
// Number is a float here); `bigint` → i32 (range-checked — the int arm, since
// this codebase's convention is "ids and integers are BigInt"); `string` → str;
// an object with EXACTLY the keys { x, y } (each a number or bigint) → vec2;
// the `labelle.id` marker → u64 with default 0 (the entity-id type no plain JS
// value can spell). Anything else is a hard error: a malformed declaration must
// fail the build, not ship a guessed schema.
//
// Error policy: validation throws from inside `labelle.component`/
// `labelle.event`, so the thrown Error's `.stack` carries the declaration's
// call-site frame ("<path>:<line>"); extract.zig formats the failure around it.

"use strict";
(() => {
  // Largest finite f32, as a JS number (a double — the same value the lua and
  // ruby preludes pin). A finite double beyond it would narrow to ±inf in the
  // codegenned f32 default, so classify rejects it up front.
  const F32_MAX = 3.4028235e38;

  // The id FIELD marker: `owner: labelle.id` in a spec classifies the field as
  // { "type": "u64", "default": 0 } — the entity-id type no plain JS value can
  // spell (a Number would classify f32, a BigInt i32). A unique Symbol so
  // recognition is by identity and it falls through every structural guard
  // with the right error (a bare `labelle.event("x", labelle.id)` lands on
  // "expects a spec object"; a nested `{ x: labelle.id, y: 0 }` on the vec2
  // shape check — v1 ids are scalar-only). At runtime labelle.id is plain 0
  // (src/ts/prelude.js), so the same spec line evaluates clean in both modes.
  const ID_MARKER = Symbol("labelle.id");

  // name → file first declared in (per kind: events and components are
  // SEPARATE namespaces — a Hunger component and a hunger event coexist). The
  // recorder arrays live on globalThis so extract.zig reads them after every
  // module ran; the by-name maps stay closure-private (scripts cannot reach
  // them — module scope has no handle to this IIFE's locals).
  const componentsByName = new Map();
  const eventsByName = new Map();

  // The accumulator extract.zig harvests. Each entry:
  //   { name, persist, fields: [{ name, type, value }] }   (components)
  //   { name,          fields: [{ name, type, value }] }   (events)
  // where `value` is the RAW default (Number for f32, BigInt for i32, boolean,
  // string, or { x, y } for vec2; irrelevant for u64) — Zig formats it.
  globalThis.__labelle_components = [];
  globalThis.__labelle_events = [];

  // ── validation + classification helpers ──────────────────────────────────

  const isIdentifier = (s) => {
    if (typeof s !== "string" || s.length === 0) return false;
    const c0 = s.charCodeAt(0);
    if (!((c0 >= 65 && c0 <= 90) || (c0 >= 97 && c0 <= 122) || c0 === 95)) return false;
    for (let i = 1; i < s.length; i++) {
      const ch = s.charCodeAt(i);
      if (!((ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || (ch >= 48 && ch <= 57) || ch === 95))
        return false;
    }
    return true;
  };

  const isNumberish = (v) => typeof v === "number" || typeof v === "bigint";

  // Classify one spec value into { type, value } (value = the raw default Zig
  // will render), or throw with `where` naming the declaration and field.
  const classify = (where, v) => {
    if (typeof v === "symbol") {
      if (v === ID_MARKER) return { type: "u64", value: null };
      throw new TypeError(where + ": a Symbol is not a schema value (did you mean labelle.id?)");
    }
    if (typeof v === "boolean") return { type: "bool", value: v };
    if (typeof v === "bigint") {
      if (v < -2147483648n || v > 2147483647n)
        throw new RangeError(where + ": integer default out of i32 range");
      return { type: "i32", value: v };
    }
    if (typeof v === "number") {
      if (!Number.isFinite(v)) throw new RangeError(where + ": non-finite number default");
      if (v > F32_MAX || v < -F32_MAX)
        throw new RangeError(where + ": float default out of f32 range (f32 max is 3.4028235e38)");
      return { type: "f32", value: v };
    }
    if (typeof v === "string") return { type: "str", value: v };
    if (v !== null && typeof v === "object" && !Array.isArray(v)) {
      // vec2: EXACTLY the keys x and y, both finite numbers (Number or BigInt).
      const keys = Object.keys(v);
      if (
        keys.length === 2 &&
        Object.prototype.hasOwnProperty.call(v, "x") &&
        Object.prototype.hasOwnProperty.call(v, "y") &&
        isNumberish(v.x) &&
        isNumberish(v.y)
      ) {
        for (const a of [v.x, v.y]) {
          // Range-check as a Number, never as a mixed BigInt/Number `<`:
          // quickjs mis-evaluates `-2n < -F32_MAX` (a negative BigInt vs a
          // negative Number) as true, which would falsely reject small
          // negative integer axes. Number(bigint) is exact for the axes any
          // real vec2 carries; a genuinely huge BigInt overflows to ±inf and
          // the finite check catches it.
          const n = typeof a === "bigint" ? Number(a) : a;
          if (!Number.isFinite(n))
            throw new RangeError(where + ": non-finite vec2 default");
          if (n > F32_MAX || n < -F32_MAX)
            throw new RangeError(where + ": vec2 default out of f32 range (f32 max is 3.4028235e38)");
        }
        return { type: "vec2", value: { x: v.x, y: v.y } };
      }
      throw new TypeError(
        where + ": unsupported object default (only { x, y } vec2 objects are supported in v1)",
      );
    }
    throw new TypeError(
      where +
        ": unsupported default (v1 supports number, bigint, boolean, string, { x, y } vec2, and labelle.id)",
    );
  };

  // Validate a spec object and return its fields sorted by name. `kind`
  // ("component" | "event") names the DSL in error messages.
  const buildFields = (kind, name, spec) => {
    if (spec === null || typeof spec !== "object" || Array.isArray(spec))
      throw new TypeError(
        "labelle." + kind + ": " + kind + " '" + name + "' expects a spec object of field defaults",
      );
    const fields = [];
    const seen = new Set();
    for (const k of Object.keys(spec)) {
      if (!isIdentifier(k))
        throw new TypeError(
          "labelle." + kind + ": " + kind + " '" + name + "' field '" + k + "' is not a valid identifier",
        );
      if (seen.has(k))
        throw new TypeError(
          "labelle." + kind + ": " + kind + " '" + name + "' field '" + k + "' is declared twice",
        );
      seen.add(k);
      const c = classify("labelle." + kind + ": " + kind + " '" + name + "' field '" + k + "'", spec[k]);
      fields.push({ name: k, type: c.type, value: c.value });
    }
    fields.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return fields;
  };

  const currentFile = () =>
    typeof globalThis.__labelle_declare_file === "string" ? globalThis.__labelle_declare_file : "?";

  // ── the live DSL: labelle.component / labelle.event / labelle.id ──────────

  const labelle = {
    // Declare a component. Validates, records, and returns the SAME ref shape
    // the runtime prelude returns ({ __labelle_component: name }), so module
    // scope holding `export const Hunger = labelle.component(...)` binds one
    // consistent value in both modes.
    component(name, spec, opts) {
      if (typeof name !== "string" || name.length === 0)
        throw new TypeError("labelle.component: expected a non-empty component name string");
      if (!isIdentifier(name))
        throw new TypeError(
          "labelle.component: component name '" +
            name +
            "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)",
        );
      if (componentsByName.has(name))
        throw new TypeError(
          "labelle.component: duplicate component '" +
            name +
            "' (first declared in " +
            componentsByName.get(name) +
            ")",
        );

      let persist = "persistent";
      if (opts !== undefined && opts !== null) {
        if (typeof opts !== "object" || Array.isArray(opts))
          throw new TypeError("labelle.component: component '" + name + "' options must be an object");
        for (const k of Object.keys(opts)) {
          if (k !== "persist")
            throw new TypeError(
              "labelle.component: component '" + name + "' has an unknown option '" + k + "' (v1 knows only persist)",
            );
          const pv = opts[k];
          if (pv !== "persistent" && pv !== "transient")
            throw new TypeError(
              "labelle.component: component '" +
                name +
                "' has an invalid persist value '" +
                String(pv) +
                '\' (expected "persistent" or "transient")',
            );
          persist = pv;
        }
      }

      const fields = buildFields("component", name, spec);
      globalThis.__labelle_components.push({ name, persist, fields });
      componentsByName.set(name, currentFile());
      return { __labelle_component: name };
    },

    // Declare an event — the component recorder minus persistence. NO options
    // argument (events are never saved: a 3rd arg is a pointed error), and a
    // SEPARATE namespace (an event may share a component's name). Returns the
    // name string — the runtime prelude's return — so module scope binds one
    // consistent value in both modes.
    event(name, spec, ...rest) {
      if (typeof name !== "string" || name.length === 0)
        throw new TypeError("labelle.event: expected a non-empty event name string");
      if (!isIdentifier(name))
        throw new TypeError(
          "labelle.event: event name '" + name + "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)",
        );
      if (rest.length > 0)
        throw new TypeError(
          "labelle.event: event '" + name + "' takes no options (events are not persisted)",
        );
      if (eventsByName.has(name))
        throw new TypeError(
          "labelle.event: duplicate event '" +
            name +
            "' (first declared in " +
            eventsByName.get(name) +
            ")",
        );

      const fields = buildFields("event", name, spec);
      globalThis.__labelle_events.push({ name, fields });
      eventsByName.set(name, currentFile());
      return name;
    },

    // The id field marker (see ID_MARKER). A value, not a function — v1 has no
    // id(value) constructor (ids always default 0).
    id: ID_MARKER,
  };

  globalThis.labelle = labelle;
})();
