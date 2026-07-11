//! The `labelle` Rust module — the Script Runtime Contract binding for
//! game scripts written in Rust (labelle-engine#741, native-compiled
//! family).
//!
//! There is no bindings layer to generate: for native languages the
//! contract header (labelle-engine/contract/labelle_script.h) IS the
//! binding — the `extern "C"` block below mirrors it and the symbols
//! resolve at link time against the host game binary that exports them
//! (the labelle-engine#734 POC's finding #3, verbatim). The declared set
//! is exactly the v1 core surface labelle-scripting binds today
//! (src/contract.zig, SUPPORTED_CONTRACT_VERSION 1); the v1.1/v1.2
//! additive exports (plugin calls, input, entity find) are deliberately
//! absent — a native plugin discovers additions at link time, so this
//! module only names symbols every conforming host is known to export.
//!
//! Pointer spelling: the header's `const char *` is declared `*const u8`
//! (`*mut u8` for out-buffers) — byte-identical ABI, and Rust string
//! slices hand out `*const u8` without a cast. Strings are
//! (pointer, length) pairs, NOT NUL-terminated. Structured payloads are
//! UTF-8 JSON (encoding v1). Entity ids are u64 end to end; 0 is the
//! failure sentinel — no float ever touches an id in this module (a
//! bit-63 id would round).
//!
//! ## Allocation discipline (the RFC's Rust idiom)
//!
//! Every out-parameter wrapper takes a caller-owned `&mut Vec<u8>` (or
//! `&mut Vec<EntityId>`), `clear()`s it — which RETAINS capacity — and
//! grows it at most once per call via the contract's sizing convention.
//! A script that keeps its buffers in its struct fields reaches
//! steady-state after warm-up and never allocates again, however much
//! traffic flows (tests/rust/game/alloc_probe.rs pins this).
//!
//! ## Scripts
//!
//! Game code lives in the game's `rust/` dir, compiled into this crate
//! as the `game` module. Its `mod.rs` implements the one convention
//! entry point:
//!
//! ```ignore
//! pub fn register(scripts: &mut labelle::Scripts) {
//!     scripts.add("player", Box::new(Player::default()));
//! }
//! ```
//!
//! and each script is a plain struct implementing [`Script`]. The glue
//! (glue.rs, shipped beside this file) drives the trait from the plugin
//! Controller's C entry points and catches every panic at the FFI
//! boundary — see its module doc for the exact hook order and panic
//! semantics.

/// Entity id, exactly as the contract carries it. 0 is never a valid id
/// and doubles as the failure sentinel.
pub type EntityId = u64;

// ── The Script Runtime Contract, v1 core (labelle_script.h) ─────────────
//
// Signatures mirror the header 1:1; see src/contract.zig in
// labelle-scripting for the same set with the full per-function
// conventions. Safe wrappers below are the supported surface — the raw
// externs stay `pub` for escape hatches, but every call site owes the
// header's rules (main-thread only, borrowed pointers, sizing legs).
unsafe extern "C" {
    pub fn labelle_contract_version() -> u32;

    pub fn labelle_entity_create() -> EntityId;
    pub fn labelle_entity_destroy(id: EntityId);
    pub fn labelle_prefab_spawn(
        name: *const u8,
        name_len: usize,
        params_json: *const u8,
        params_len: usize,
    ) -> EntityId;

    pub fn labelle_component_set(
        id: EntityId,
        name: *const u8,
        name_len: usize,
        json: *const u8,
        json_len: usize,
    ) -> i32;
    /// Returns the bytes the COMPLETE JSON requires (snprintf-style);
    /// ALL-OR-NOTHING write — on overflow nothing is written.
    pub fn labelle_component_get(
        id: EntityId,
        name: *const u8,
        name_len: usize,
        out: *mut u8,
        out_cap: usize,
    ) -> usize;
    pub fn labelle_component_has(id: EntityId, name: *const u8, name_len: usize) -> i32;
    pub fn labelle_component_remove(id: EntityId, name: *const u8, name_len: usize) -> i32;

    /// Returns the bytes the COMPLETE result requires; an under-sized cap
    /// receives a truncated-at-the-last-whole-id, still-valid JSON prefix.
    pub fn labelle_query(
        names_json: *const u8,
        names_json_len: usize,
        out: *mut u8,
        out_cap: usize,
    ) -> usize;

    pub fn labelle_event_emit(
        name: *const u8,
        name_len: usize,
        json: *const u8,
        json_len: usize,
    ) -> i32;
    pub fn labelle_event_subscribe(name: *const u8, name_len: usize);
    /// Returns bytes WRITTEN (a real poll consumes its entry); the paired
    /// NULL/cap-0 probe returns the NEXT entry's size, consuming nothing.
    pub fn labelle_event_poll(out: *mut u8, out_cap: usize) -> usize;

    pub fn labelle_scene_change(name: *const u8, name_len: usize) -> i32;
    pub fn labelle_log(msg: *const u8, len: usize);
    pub fn labelle_time_dt() -> f32;
    /// Plugin-internal: the Zig Controller stamps the tick's dt before it
    /// runs the frame's scripts. Game scripts must not call it.
    pub fn labelle_time_dt_stamp(dt: f32);
}

// ── The script surface ───────────────────────────────────────────────────

/// One game script: a plain struct with per-frame state in its fields.
/// Every hook has a default empty body — implement what you need.
///
/// Hook order per frame (driven by the plugin Controller through the
/// glue): `on_event` for every drained inbox entry (FIFO, last frame's
/// events), then `update(dt)`. `init` runs once at plugin setup,
/// `deinit` at teardown (reverse registration order).
///
/// Panic policy (enforced by the glue, pinned by the suite): a panic in
/// `init` evicts the script — `update`/`deinit` never run on
/// half-initialized state; a panic in `update`/`on_event` is caught and
/// logged EVERY time and the script stays registered (its state is
/// intact and the author gets the report each tick until it's fixed);
/// siblings always keep running. No panic ever crosses the FFI boundary.
pub trait Script {
    /// Once, at plugin setup — create entities, subscribe to events.
    fn init(&mut self) {}
    /// Every frame, after the inbox drain. `dt` is the gameplay
    /// delta-time in seconds — the same scaled dt Zig scripts received.
    fn update(&mut self, _dt: f32) {}
    /// One drained inbox event: `name` is the subscription key, `payload`
    /// the event's JSON. The inbox is PLUGIN-wide — every subscription
    /// any script makes feeds the same drain, so filter on `name`.
    fn on_event(&mut self, _name: &str, _payload: &str) {}
    /// Once, at plugin teardown (the game is still alive — contract calls
    /// are valid here).
    fn deinit(&mut self) {}
}

/// The registration collector handed to the game's `register` entry
/// point. Names are diagnostics identity: panic reports read
/// "script '<name>' panicked in <hook>".
pub struct Scripts {
    pub(crate) entries: Vec<(String, Box<dyn Script>)>,
}

impl Scripts {
    pub(crate) fn new() -> Scripts {
        Scripts {
            entries: Vec::new(),
        }
    }

    /// Register one script. Registration order is hook order (`init`,
    /// per-event fan-out and `update` run in it; `deinit` runs reversed).
    pub fn add(&mut self, name: &str, script: Box<dyn Script>) {
        self.entries.push((name.to_owned(), script));
    }
}

// ── Safe wrappers ────────────────────────────────────────────────────────

/// Create an empty entity. Returns 0 when the host is not bound.
/// FFI-safe out-pointer for a Vec-backed buffer: an EMPTY Vec's
/// `as_mut_ptr()` is a non-null DANGLING pointer (alignment sentinel,
/// never allocated) — the contract's probe legs are specified as
/// NULL/cap-0, so hand the host a real NULL rather than a dangling value
/// it must promise never to touch.
fn ffi_out_ptr(v: &mut Vec<u8>) -> *mut u8 {
    if v.capacity() == 0 {
        std::ptr::null_mut()
    } else {
        v.as_mut_ptr()
    }
}

pub fn create_entity() -> EntityId {
    unsafe { labelle_entity_create() }
}

/// Destroy an entity (children cascade). Unknown / dead ids are ignored.
pub fn destroy_entity(id: EntityId) {
    unsafe { labelle_entity_destroy(id) }
}

/// Spawn a named prefab. `params_json` is an optional `{"x":…,"y":…}`
/// spawn position; `None` spawns at the origin. `None` result = failure
/// (unknown prefab, malformed params, not bound).
pub fn spawn_prefab(name: &str, params_json: Option<&str>) -> Option<EntityId> {
    let (p, l) = match params_json {
        Some(j) => (j.as_ptr(), j.len()),
        None => (core::ptr::null(), 0),
    };
    let id = unsafe { labelle_prefab_spawn(name.as_ptr(), name.len(), p, l) };
    if id == 0 {
        None
    } else {
        Some(id)
    }
}

/// Set component `name` on `id` from a whole-struct JSON object (REPLACE
/// semantics; absent fields take declared defaults). False = unknown
/// component / dead entity / parse error (entity untouched).
pub fn set_component(id: EntityId, name: &str, json: &str) -> bool {
    unsafe { labelle_component_set(id, name.as_ptr(), name.len(), json.as_ptr(), json.len()) == 0 }
}

/// Serialize component `name` of `id` into `out` (cleared first —
/// capacity is retained and reused). Grows `out` at most once via the
/// contract's required-size return. False = absent / unknown / dead.
pub fn get_component_into(id: EntityId, name: &str, out: &mut Vec<u8>) -> bool {
    out.clear();
    unsafe {
        // First leg: whatever capacity the buffer already has. The write
        // is all-or-nothing, so a too-small capacity costs nothing.
        let required = labelle_component_get(
            id,
            name.as_ptr(),
            name.len(),
            ffi_out_ptr(out),
            out.capacity(),
        );
        if required == 0 {
            return false;
        }
        if required <= out.capacity() {
            out.set_len(required);
            return true;
        }
        // Grow once, right-sized, and retry.
        out.reserve(required);
        let got = labelle_component_get(
            id,
            name.as_ptr(),
            name.len(),
            ffi_out_ptr(out),
            out.capacity(),
        );
        if got == 0 || got > out.capacity() {
            return false; // vanished or grew mid-frame; caller retries next tick
        }
        out.set_len(got);
        true
    }
}

/// True when the entity carries the component.
pub fn component_has(id: EntityId, name: &str) -> bool {
    unsafe { labelle_component_has(id, name.as_ptr(), name.len()) == 1 }
}

/// Remove component `name` from `id`. Idempotent on the component.
/// False = unknown component name / dead entity.
pub fn remove_component(id: EntityId, name: &str) -> bool {
    unsafe { labelle_component_remove(id, name.as_ptr(), name.len()) == 0 }
}

/// Query entity ids by component names. `names_json` is the contract's
/// JSON array of component names — pass a literal (`r#"["Marker"]"#`)
/// for the zero-allocation path. Matching ids land in `ids`, `scratch`
/// carries the host's JSON between the sizing legs; both are cleared
/// (capacity retained) and grown at most once. False = malformed input /
/// not bound; unknown names yield an empty result (true, no ids).
pub fn query_into(names_json: &str, ids: &mut Vec<EntityId>, scratch: &mut Vec<u8>) -> bool {
    ids.clear();
    scratch.clear();
    unsafe {
        let required = labelle_query(
            names_json.as_ptr(),
            names_json.len(),
            ffi_out_ptr(scratch),
            scratch.capacity(),
        );
        if required == 0 {
            return false;
        }
        if required > scratch.capacity() {
            // The written prefix is valid JSON but truncated — grow once
            // right-sized and re-query for the full set.
            scratch.reserve(required);
            let got = labelle_query(
                names_json.as_ptr(),
                names_json.len(),
                ffi_out_ptr(scratch),
                scratch.capacity(),
            );
            if got == 0 {
                return false;
            }
            scratch.set_len(got.min(scratch.capacity()));
        } else {
            scratch.set_len(required);
        }
    }
    parse_ids(scratch, ids);
    true
}

/// Parse a contract id-array (`[3,7,12]`) into `ids` (cleared first).
/// Pure u64 arithmetic — a bit-63 id survives exactly; no float, ever.
pub fn parse_ids(json: &[u8], ids: &mut Vec<EntityId>) {
    ids.clear();
    let mut cur: u64 = 0;
    let mut in_num = false;
    for &b in json {
        if b.is_ascii_digit() {
            cur = cur.wrapping_mul(10).wrapping_add((b - b'0') as u64);
            in_num = true;
        } else if in_num {
            ids.push(cur);
            cur = 0;
            in_num = false;
        }
    }
    if in_num {
        ids.push(cur);
    }
}

/// Emit a game event by union-tag name. Empty `json` means `{}` (all
/// defaults). False = unknown event name / parse failure / the game
/// declares no events.
pub fn emit(name: &str, json: &str) -> bool {
    unsafe { labelle_event_emit(name.as_ptr(), name.len(), json.as_ptr(), json.len()) == 0 }
}

/// Declare interest in an event name (dedup'd host-side). Delivery
/// starts with the next tick's events, through [`Script::on_event`] —
/// the glue owns the drain loop.
pub fn subscribe(name: &str) {
    unsafe { labelle_event_subscribe(name.as_ptr(), name.len()) }
}

/// Drain one pending `"<name> <json>"` inbox entry into `out` (cleared
/// first, capacity retained, grown at most once via the no-consume
/// probe). False = inbox empty.
///
/// The glue calls this once per entry per tick and fans out to
/// [`Script::on_event`] — scripts normally never call it themselves (a
/// script-side poll would STEAL entries from every other script's
/// dispatch).
pub fn poll_into(out: &mut Vec<u8>) -> bool {
    out.clear();
    unsafe {
        // No-consume sizing probe (NULL/cap-0), then the real read.
        let next = labelle_event_poll(core::ptr::null_mut(), 0);
        if next == 0 {
            return false;
        }
        if next > out.capacity() {
            out.reserve(next);
        }
        let written = labelle_event_poll(ffi_out_ptr(out), out.capacity());
        if written == 0 || written > out.capacity() {
            return false;
        }
        out.set_len(written);
        true
    }
}

/// Switch to a registered scene by name. False = unknown scene (the
/// running scene is untouched) / not bound.
pub fn change_scene(name: &str) -> bool {
    unsafe { labelle_scene_change(name.as_ptr(), name.len()) == 0 }
}

/// The tick's gameplay delta-time in seconds — the same scaled dt Zig
/// scripts received (0 while paused and before the first tick).
pub fn dt() -> f32 {
    unsafe { labelle_time_dt() }
}

/// Log through the game's log sink at info level, "[script]"-prefixed.
pub fn log(msg: &str) {
    unsafe { labelle_log(msg.as_ptr(), msg.len()) }
}
