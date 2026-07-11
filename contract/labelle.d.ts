// labelle.d.ts — hand-authored TypeScript declarations for the
// labelle-scripting typescript sub-module's script API (the surface
// src/ts/bindings.zig + src/ts/prelude.js install into every script VM).
//
// Scripts run as plain JavaScript today (the TS→JS transpile arrives with
// the assembler build hook, labelle-assembler#586) — this file is what
// makes them TYPED today: point your editor at it and author either
//   - .js files with `// @ts-check` at the top, or
//   - .ts files checked by `tsc --noEmit`
// via a jsconfig.json/tsconfig.json whose "include" lists this file next
// to your scripts (or a `/// <reference path=".../labelle.d.ts" />`).
//
// This is a GLOBAL declaration file on purpose (no top-level import or
// export): every name below exists as a global inside the script VM.
//
// Script shape — each script is an ES module and its lifecycle hooks are
// its EXPORTS (an unexported `function update` is module-private and
// never called):
//
//   export function init(): void       // once, at Controller.setup
//   export function update(dt: number): void  // every tick
//   export function deinit(): void     // at Controller.deinit
//
// Entity-id rule: ids are u64 on the host and BigInt in scripts — Number
// would silently round ids past 2^53. `e.id` prints as the true unsigned
// value; compare ids with `===` between BigInts (a Number-held small id
// from a payload compares equal via `==`, or normalize it first with
// `Entity.wrap(x).id`). Payload fields holding BigInts encode as the
// contract's unsigned 64-bit decimals.

/** A u64 entity id, held as BigInt (Number cannot represent bit-63 ids). */
type EntityId = bigint;

/** Anything the id-taking APIs accept and normalize to an EntityId. */
type EntityIdLike = bigint | number | string;

/** The ref object `labelle.component(...)` returns. */
interface ComponentRef {
  readonly __labelle_component: string;
}

/** Every component-taking API accepts a name string or a ref. */
type ComponentName = string | ComponentRef;

/** JSON-representable payloads (BigInt allowed: ids encode unsigned). */
type JsonValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | JsonValue[]
  | { [key: string]: JsonValue | undefined };

/** Component and event payload shape. */
type Payload = { [key: string]: JsonValue | undefined };

/**
 * Thin wrapper over an entity id. Components go in and out as plain
 * objects; the JSON leg is hidden (and id-exact — see the header).
 */
declare class Entity {
  /** The wrapped id (BigInt; safe for ===, Map keys and payload fields). */
  id: EntityId;

  constructor(id: EntityIdLike);

  /** Wrap an existing entity id (e.g. one carried in an event payload). */
  static wrap(id: EntityIdLike): Entity;

  /** Create a fresh empty entity; null when the host refuses (not bound). */
  static create(): Entity | null;

  /** Component as a fresh object, or null when absent. */
  get<T extends object = Payload>(name: ComponentName): T | null;
  /**
   * REFILL `into` in place from the component and return it (null when
   * absent); fields absent from the component keep their previous value.
   * The zero-allocation read: scalar fields cross without creating any
   * JS object — pair with a long-lived `into` in hot loops.
   */
  get<T extends object>(name: ComponentName, into: T): T | null;

  /**
   * Set (REPLACE semantics) a component from an object; null/undefined
   * means "all declared defaults". Keys are encoded sorted;
   * undefined-valued keys are omitted. Returns true on success.
   */
  set(name: ComponentName, obj?: Payload | null): boolean;

  /** Whether the entity currently carries the component. */
  has(name: ComponentName): boolean;

  /** Remove the component (idempotent). Returns true on success. */
  remove(name: ComponentName): boolean;

  /** Destroy the entity (children cascade). */
  destroy(): void;
}

declare const game: {
  /**
   * Entities carrying ALL the named components, as an Array snapshot —
   * spawning/destroying while iterating is safe:
   *   for (const e of game.query("Hunger", Position)) { ... }
   */
  query(...names: ComponentName[]): Entity[];
};

/**
 * Per-frame scratch list — the clearRetainingCapacity idiom. `push` is
 * in-bounds index assignment, `clear` resets the LOGICAL length only
 * (whether `array.length = 0` keeps the backing storage is
 * engine-internal, so never rely on it), growth happens only when a push
 * overflows capacity and is visible through `growthCount` — a warmed hot
 * loop can assert it stays flat. For pure-numeric scratch, a reused
 * Float64Array is the other zero-allocation idiom (fixed capacity,
 * unboxed doubles).
 */
declare class LabelleFrameArray<T = unknown> {
  constructor(capacity: number);
  /** Logical element count (≤ capacity). */
  readonly size: number;
  /** Current backing capacity. */
  readonly capacity: number;
  /** How many times the backing grew — flat once warmed. */
  readonly growthCount: number;
  /** Append; grows (doubling, counted) only when size === capacity. */
  push(v: T): this;
  /** size = 0; the backing storage survives for reuse. */
  clear(): this;
  /** Element at logical index i, or undefined out of bounds. */
  get(i: number): T | undefined;
  /** Overwrite an element WITHIN the logical size (throws out of bounds). */
  set(i: number, v: T): void;
  forEach(fn: (v: T, i: number) => void): this;
  isEmpty(): boolean;
  /** Copy of the logical contents (allocates — not for hot loops). */
  toArray(): T[];
}

declare const labelle: {
  // ── sugar (start here) ──────────────────────────────────────────────

  /** Log through the game's sink (stringifies for convenience). */
  log(msg: unknown): void;

  /** Last tick's gameplay dt in seconds (scaled; 0 while paused). */
  time_dt(): number;

  /**
   * Subscribe to a game event by union-tag name. The payload arrives
   * decoded ({} when empty; integer id fields past 2^53 as BigInt).
   * Handlers fan out in registration order; a throwing handler is logged
   * and isolated. The registering SCRIPT owns the handler: if the script
   * is evicted (load/init failure), its handlers are purged with it.
   */
  on(name: string, fn: (ev: Payload) => void): void;

  /**
   * Emit a game event by union-tag name (null/undefined payload = all
   * defaults). BigInt id fields encode as unsigned decimals. Returns
   * true when the host accepted it.
   */
  emit(name: string, payload?: Payload | null): boolean;

  /** Spawn a prefab ({x, y} params optional); Entity or null on failure. */
  spawn(prefab: string, params?: { x?: number; y?: number } | null): Entity | null;

  /** Switch scenes; true when the host accepted the name. */
  scene_change(name: string): boolean;

  /**
   * Declare a component (build-time schema for the declare runner; a
   * lightweight ref at runtime, accepted anywhere a name string is):
   *   const Hunger = labelle.component("Hunger", { level: 1.0 });
   */
  component(name: string, spec?: object, opts?: object): ComponentRef;

  /**
   * An id's unsigned decimal string. BigInt ids already print unsigned
   * (`${e.id}`) — this ships for cross-language payload parity and for
   * Number-held ids.
   */
  u64str(id: bigint | number): string;

  /** Per-frame scratch list (see the class doc). */
  FrameArray: typeof LabelleFrameArray;

  // ── events drained by the plugin each tick (called by the host) ─────

  /** Drain + dispatch the event inbox. The Controller calls this. */
  dispatch_inbox(): void;

  // ── Zig-side JSON codec (id-exact; sorted keys) ─────────────────────

  /** Encode with sorted keys, BigInt-as-unsigned, integral-float-as-int. */
  json_encode(value: JsonValue | undefined): string;

  /** Decode; integer tokens past 2^53 become BigInt (id fidelity). */
  json_decode(text: string): JsonValue;

  // ── raw contract shims (1:1 with labelle_script.h; sugar's substrate) ─

  raw_entity_create(): EntityId;
  raw_entity_destroy(id: EntityIdLike): void;
  raw_prefab_spawn(name: string, paramsJson: string): EntityId;
  raw_component_set(id: EntityIdLike, name: string, json: string): number;
  raw_component_get(id: EntityIdLike, name: string): string | null;
  raw_component_get_into(id: EntityIdLike, name: string, into: object): boolean;
  raw_component_has(id: EntityIdLike, name: string): boolean;
  raw_component_remove(id: EntityIdLike, name: string): number;
  raw_query(namesJson: string): EntityId[];
  raw_event_emit(name: string, json: string): number;
  raw_event_subscribe(name: string): void;
  raw_event_poll(): [name: string, payload: Payload] | null;
  raw_scene_change(name: string): number;
  raw_log(msg: string): void;
  raw_time_dt(): number;
  raw_u64str(id: EntityIdLike): string;

  // ── diagnostics (test seams; raw_gc_live walks the heap — not for
  //    hot loops) ────────────────────────────────────────────────────────

  /** Run a full GC cycle collection. */
  raw_gc(): void;
  /** Live malloc count (JS_ComputeMemoryUsage.malloc_count). */
  raw_gc_live(): number;
};
