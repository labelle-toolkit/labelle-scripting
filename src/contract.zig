//! Script Runtime Contract bindings — the ONE place labelle-scripting
//! declares the host's C-ABI surface (labelle-engine/contract/
//! labelle_script.h, LABELLE_CONTRACT_VERSION 1).
//!
//! These are `extern` declarations, not imports: the host game
//! (assembler-generated, engine src/script_contract.zig) exports the
//! symbols **in the same binary** this plugin is compiled into, so they
//! resolve at link time with zero indirection — no vtable, no dlsym, no
//! Zig types crossing the seam. Tests provide a mock world instead: the
//! test root `export`s the same symbols (tests/mock_world.zig), which is
//! byte-for-byte the production linking model with a toy host behind it.
//!
//! Signatures mirror the header 1:1. Conventions that matter to callers:
//!   - strings are (pointer, length) pairs, NOT NUL-terminated;
//!   - structured payloads are UTF-8 JSON (encoding v1);
//!   - entity ids are u64, 0 = failure sentinel;
//!   - i32 returns: 0 = ok, -1 = failure (except `labelle_component_has`,
//!     a 1/0 boolean);
//!   - out-parameter sizing: `labelle_component_get` and `labelle_query`
//!     return the bytes the COMPLETE result requires, snprintf-style
//!     (required > cap = truncation, retry right-sized; NULL/cap-0 out =
//!     pure sizing probe; 0 keeps its absent/unknown/malformed sentinel).
//!     They differ under a too-small cap: the query writes a still-valid
//!     truncated id prefix, the get writes ALL-OR-NOTHING (a truncated
//!     JSON object prefix is useless). `labelle_event_poll` alone returns
//!     bytes WRITTEN — a real poll consumes its entry — and pairs with a
//!     NULL/cap-0 probe returning the NEXT entry's size, no consume;
//!   - main-thread only, valid during the plugin's tick;
//!   - before the host binds its game every call is a safe no-op.

/// The contract revision this plugin was written against. `Controller.setup`
/// compares it with `labelle_contract_version()` and refuses to start the VM
/// on mismatch — a version skew must fail loudly at boot, not as corrupted
/// JSON mid-game.
pub const SUPPORTED_CONTRACT_VERSION: u32 = 1;

/// Contract version the host binary was built with. Pure — callable before
/// anything else, including before the host binds its game.
pub extern fn labelle_contract_version() u32;

// ── Entities ─────────────────────────────────────────────────────────────

/// Create an empty entity. Returns its id, or 0 when the host is not bound.
pub extern fn labelle_entity_create() u64;

/// Destroy an entity (children cascade). Unknown / dead ids are ignored.
pub extern fn labelle_entity_destroy(id: u64) void;

/// Spawn a named prefab. `params_json` is optional (null/len 0 = origin,
/// or a {"x":…,"y":…} object). Returns the root entity id, 0 on failure.
pub extern fn labelle_prefab_spawn(
    name: [*]const u8,
    name_len: usize,
    params_json: ?[*]const u8,
    params_len: usize,
) u64;

// ── Components (by name, JSON payloads) ──────────────────────────────────

/// REPLACE semantics: json is the whole component struct, absent fields
/// take declared defaults, len 0 means "{}". 0 = ok, -1 = unknown component
/// / dead entity / parse error (entity untouched on -1).
pub extern fn labelle_component_set(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32;

/// Serialize the component to JSON into `out`. Returns the bytes the
/// COMPLETE JSON requires (snprintf-style, like the query); 0 = absent /
/// unknown name / dead entity. ALL-OR-NOTHING write: `out` is filled only
/// when required <= out_cap — on overflow nothing is written, retry with a
/// required-sized buffer. NULL/cap-0 out is a pure sizing probe.
pub extern fn labelle_component_get(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize;

/// 1 when the entity carries the component, else 0.
pub extern fn labelle_component_has(id: u64, name: [*]const u8, name_len: usize) i32;

/// Remove the component. Idempotent on the component. 0 = ok, -1 = unknown
/// component name / dead entity.
pub extern fn labelle_component_remove(id: u64, name: [*]const u8, name_len: usize) i32;

// ── Queries ──────────────────────────────────────────────────────────────

/// `names_json` is a JSON array of component names; the host writes the
/// matching entity ids as a JSON array into `out`. Returns the bytes the
/// COMPLETE result requires (snprintf-style — the contract's one sizing
/// exception; required > out_cap means the write truncated at the last
/// whole id but stayed valid JSON: retry with a required-sized buffer),
/// 0 = malformed input / not bound; unknown names yield "[]" (required
/// 2). Snapshot semantics: mutating entities while walking the result
/// is safe.
pub extern fn labelle_query(
    names_json: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize;

// ── Events (emit + subscribe/poll drain) ─────────────────────────────────

/// Emit a game event by union-tag name into the engine's buffered event
/// path. len 0 means "{}". 0 = ok, -1 = unknown name / parse failure /
/// the game declares no events.
pub extern fn labelle_event_emit(
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32;

/// Declare interest in an event name (dedup'd host-side); matching events
/// queue for `labelle_event_poll` from the next frame on.
pub extern fn labelle_event_subscribe(name: [*]const u8, name_len: usize) void;

/// Drain one pending "<name> <json>" entry (FIFO). Returns bytes WRITTEN,
/// 0 = inbox empty; a real read consumes the entry even when truncated.
/// NULL/cap-0 `out` is the paired no-consume SIZING PROBE: it returns the
/// NEXT entry's full size (0 = empty) and reads nothing — probe, size the
/// buffer, then poll. Drain in a `while (poll() > 0)` loop once per tick.
pub extern fn labelle_event_poll(out: ?[*]u8, out_cap: usize) usize;

// ── Scene / log / time ───────────────────────────────────────────────────

/// Switch to a registered scene by name. 0 = ok (including a deferred
/// swap), -1 = unknown scene / not bound.
pub extern fn labelle_scene_change(name: [*]const u8, name_len: usize) i32;

/// Log through the game's log sink at info level, "[script]"-prefixed.
pub extern fn labelle_log(msg: [*]const u8, len: usize) void;

/// The last tick's GAMEPLAY delta-time in seconds (scaled, 0 while paused
/// and before the first tick) — what `labelle.time_dt()` hands to scripts.
pub extern fn labelle_time_dt() f32;

/// Companion setter (engine#737 follow-up): the host's contract impl can't
/// see the plugin-tick dt on its own, so `Controller.tick` stamps the dt it
/// was handed at tick start and `labelle_time_dt` echoes it back to scripts.
pub extern fn labelle_time_dt_stamp(dt: f32) void;
