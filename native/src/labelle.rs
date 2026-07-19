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

// ── Bulk component access (contract v1.3, labelle-scripting#41/#44) ──────
//
// The packed per-component codec and the batched whole-query f32 stream,
// ported from the Ruby reference (src/ruby/bindings.zig + prelude.rb).
//
// CAPABILITY GATING — why these bind `labelle_scripting_bulk_*`, not the
// contract's own `labelle_component_*_packed`/`_batch_*`: those four
// symbols exist only on engine hosts >= 2.6.0, and this crate links
// against whatever host the game was built with — a direct extern would
// make every rust game UNLINKABLE against an older engine. The scripting
// plugin's Zig side therefore exports ALWAYS-PRESENT shims
// (labelle-scripting src/bulk_shims.zig), comptime-gated on the engine
// module: on a v1.3+ host they forward 1:1; on an older host they answer
// the ordinary absent/refused sentinels (so the packed paths degrade to
// JSON silently, exactly like ruby's) and `labelle_scripting_bulk_capability`
// answers 0 — which the batch wrappers check FIRST and surface as the
// loud `BatchError::Unsupported` ("needs labelle-engine >= 2.6.0"; there
// is no batch fallback — silently degrading a whole-query read would be
// data loss).
//
// 64-BIT POLICY: rust has real i64/u64, so the packed codec's
// two's-complement bitcast pair applies directly — a u64 field rides tag
// 3 bit-exact (no signed detour), and a record whose 64-bit tag mismatches
// the field's signedness lands via `as` bitcast (`PackedField::from_scalar`),
// the documented lossless pair.
//
// NON-FINITE POLICY (parity with this family's JSON route): rust scripts
// hand-write JSON, where NaN/Inf have no spelling — a hand-built
// `{"power":NaN}` is refused by the host parser (-1 → false). The packed
// fast path must not smuggle values the JSON route cannot carry, so
// `set_from` refuses a non-finite float field up front (false, nothing
// written) instead of encoding it.

unsafe extern "C" {
    /// Runtime capability query (plugin shim): 1 iff the host engine
    /// exports the contract v1.3 bulk-access symbols (engine >= 2.6.0).
    pub fn labelle_scripting_bulk_capability() -> u32;
    /// Probe-gated forwards of the v1.3 contract exports — see the
    /// section doc. Sizing/sentinel conventions are the contract's
    /// (labelle-scripting src/contract.zig).
    pub fn labelle_scripting_bulk_get_packed(
        id: EntityId,
        name: *const u8,
        name_len: usize,
        out: *mut u8,
        out_cap: usize,
    ) -> usize;
    pub fn labelle_scripting_bulk_set_packed(
        id: EntityId,
        name: *const u8,
        name_len: usize,
        buf: *const u8,
        buf_len: usize,
    ) -> i32;
    pub fn labelle_scripting_bulk_batch_get(
        names_json: *const u8,
        names_json_len: usize,
        out: *mut u8,
        out_cap: usize,
    ) -> usize;
    pub fn labelle_scripting_bulk_batch_set(
        names_json: *const u8,
        names_json_len: usize,
        buf: *const u8,
        buf_len: usize,
    ) -> i32;
}

/// `labelle_component_batch_get`'s int-field refusal sentinel — the
/// header's LABELLE_BATCH_INT_REFUSED, C's `(size_t)-2`. Checked BEFORE
/// treating the return as a required size.
pub const BATCH_INT_REFUSED: usize = usize::MAX - 1;

/// One packed-codec scalar, tagged exactly as the wire tags it
/// (0=f32, 1=i64, 2=bool, 3=u64).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Scalar {
    F32(f32),
    I64(i64),
    U64(u64),
    Bool(bool),
}

/// A rust field type that can ride the packed codec. Implemented for
/// f32 / bool / i32 / i64 / u64 — the schema vocabulary's scalar corner
/// (i32 rides the i64 tag; the host range-checks on SET and emits
/// in-range values on GET).
///
/// CROSS-CLASS COERCION (the JSON-fallback contract): the JSON route
/// types number tokens by SHAPE — `1` classifies as an int even when
/// the target field is f32, and both the host's serializer and our own
/// JSON-fallback encoder spell whole-number floats that way. So
/// `from_scalar` coerces across numeric classes exactly where the
/// host's own JSON parse would: int classes always land in an f32
/// field (same rounding as the host parsing the token into f32), and
/// a FLOAT class lands in an int field only when EXACT (finite,
/// integral, in range) — mirroring the packed SET refusal rules, skip
/// (None) otherwise. The 64-bit arms additionally accept the OTHER
/// 64-bit tag via two's-complement bitcast — the documented lossless
/// pair. None = the value cannot land in this field type (the caller
/// skips the field; the host is the authority on GET).
pub trait PackedField: Copy {
    fn to_scalar(self) -> Scalar;
    /// See the trait doc for the coercion matrix.
    fn from_scalar(v: Scalar) -> Option<Self>;
}

/// `v` as an exactly-representable integral f64, or None — the shared
/// "coerce only where exact" gate for float-class values landing in
/// int-typed fields (see [`PackedField`]).
fn exact_integral(v: f32) -> Option<f64> {
    if v.is_finite() && v.fract() == 0.0 {
        Some(v as f64)
    } else {
        None
    }
}

impl PackedField for f32 {
    fn to_scalar(self) -> Scalar {
        Scalar::F32(self)
    }
    fn from_scalar(v: Scalar) -> Option<f32> {
        match v {
            Scalar::F32(x) => Some(x),
            // JSON-fallback coercion: `1` classifies as an int — land it
            // here with the host parser's own rounding.
            Scalar::I64(x) => Some(x as f32),
            Scalar::U64(x) => Some(x as f32),
            Scalar::Bool(_) => None,
        }
    }
}
impl PackedField for bool {
    fn to_scalar(self) -> Scalar {
        Scalar::Bool(self)
    }
    fn from_scalar(v: Scalar) -> Option<bool> {
        match v {
            Scalar::Bool(x) => Some(x),
            _ => None,
        }
    }
}
impl PackedField for i64 {
    fn to_scalar(self) -> Scalar {
        Scalar::I64(self)
    }
    fn from_scalar(v: Scalar) -> Option<i64> {
        match v {
            Scalar::I64(x) => Some(x),
            Scalar::U64(x) => Some(x as i64), // the bitcast pair
            // Float class: coerce only where exact (see the trait doc).
            Scalar::F32(x) => match exact_integral(x) {
                Some(f)
                    if (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&f) =>
                {
                    Some(f as i64)
                }
                _ => None,
            },
            Scalar::Bool(_) => None,
        }
    }
}
impl PackedField for u64 {
    fn to_scalar(self) -> Scalar {
        Scalar::U64(self)
    }
    fn from_scalar(v: Scalar) -> Option<u64> {
        match v {
            Scalar::U64(x) => Some(x),
            Scalar::I64(x) => Some(x as u64), // the bitcast pair
            // Float class: coerce only where exact (see the trait doc).
            Scalar::F32(x) => match exact_integral(x) {
                Some(f) if (0.0..18_446_744_073_709_551_616.0).contains(&f) => Some(f as u64),
                _ => None,
            },
            Scalar::Bool(_) => None,
        }
    }
}
impl PackedField for i32 {
    fn to_scalar(self) -> Scalar {
        Scalar::I64(self as i64)
    }
    fn from_scalar(v: Scalar) -> Option<i32> {
        match v {
            Scalar::I64(x) => x.try_into().ok(),
            Scalar::U64(x) => x.try_into().ok(),
            // Float class: coerce only where exact (see the trait doc).
            Scalar::F32(x) => match exact_integral(x) {
                Some(f) if (-2_147_483_648.0..=2_147_483_647.0).contains(&f) => Some(f as i32),
                _ => None,
            },
            Scalar::Bool(_) => None,
        }
    }
}

/// A typed per-component view over the packed codec — mint one with
/// [`crate::packed_view!`]. `NAME` is the component name; the two
/// methods are the mechanical field walk the macro generates.
pub trait PackedView: Default {
    const NAME: &'static str;
    /// Assign one decoded field by wire name. False = not a view field
    /// (skipped — same as ruby's unmatched record fields).
    fn set_field(&mut self, name: &[u8], v: Scalar) -> bool;
    /// Visit every field in DECLARATION order.
    fn each_field(&self, f: &mut dyn FnMut(&'static str, Scalar));
    /// Any non-finite f32 field? (The non-finite policy — see the
    /// section doc and `set_from`.)
    fn has_non_finite(&self) -> bool {
        let mut bad = false;
        self.each_field(&mut |_, v| {
            if let Scalar::F32(x) = v {
                if !x.is_finite() {
                    bad = true;
                }
            }
        });
        bad
    }
}

/// Refill `view` from component `T::NAME` of `id` — the per-component
/// FAST PATH. Tries the packed codec first (no JSON parse; scalars land
/// straight in the typed fields); a 0xFF first byte (non-scalar
/// component), an absent component, or a pre-v1.3 host drops to the
/// JSON route transparently (fields the JSON carries as scalars are
/// assigned by name; others keep their values). `scratch` is the reused
/// byte buffer (cleared, capacity retained, grown at most once per
/// leg). False = absent / unknown / dead.
pub fn get_into<T: PackedView>(id: EntityId, view: &mut T, scratch: &mut Vec<u8>) -> bool {
    scratch.clear();
    unsafe {
        let mut n = labelle_scripting_bulk_get_packed(
            id,
            T::NAME.as_ptr(),
            T::NAME.len(),
            ffi_out_ptr(scratch),
            scratch.capacity(),
        );
        if n > scratch.capacity() {
            scratch.reserve(n);
            n = labelle_scripting_bulk_get_packed(
                id,
                T::NAME.as_ptr(),
                T::NAME.len(),
                ffi_out_ptr(scratch),
                scratch.capacity(),
            );
        }
        if n >= 1 && n <= scratch.capacity() {
            scratch.set_len(n);
            if scratch[0] != 0xFF {
                decode_packed_into(scratch, view);
                return true;
            }
        }
        // n == 0 (absent / pre-v1.3 host) or 0xFF (non-scalar
        // component): the JSON route decides — absent stays false there
        // too, so the answer is identical on every host.
    }
    if !get_component_into(id, T::NAME, scratch) {
        return false;
    }
    json_scalar_fields(scratch, &mut |name, v| {
        let _ = view.set_field(name, v);
    });
    true
}

/// Write `view` to component `T::NAME` of `id` — the per-component FAST
/// PATH (REPLACE semantics, like `set_component`). Encodes the packed
/// record; a host refusal (-1: non-packable component, out-of-range
/// value, pre-v1.3 host) falls back to a sorted-key JSON encode of the
/// same fields — surfaced faithfully, exactly like ruby. A NON-FINITE
/// f32 field refuses up front (false, nothing written): JSON has no
/// NaN/Inf spelling, and the packed path must not smuggle what the
/// family's JSON route cannot carry. False = refused / unknown / dead.
pub fn set_from<T: PackedView>(id: EntityId, view: &T) -> bool {
    if view.has_non_finite() {
        return false;
    }
    // Generous stack record — real components sit far under this; an
    // over-wide view just takes the JSON path.
    let mut rec = [0u8; 2048];
    if let Some(len) = encode_packed(view, &mut rec) {
        let rc = unsafe {
            labelle_scripting_bulk_set_packed(
                id,
                T::NAME.as_ptr(),
                T::NAME.len(),
                rec.as_ptr(),
                len,
            )
        };
        if rc == 0 {
            return true;
        }
        // Refused — fall through to JSON, which represents the value
        // faithfully (or refuses loudly host-side).
    }
    // JSON fallback: deterministic sorted-key encode (the ruby
    // binding's convention). Cold path — allocates.
    let mut fields: Vec<(&'static str, Scalar)> = Vec::new();
    view.each_field(&mut |name, v| fields.push((name, v)));
    fields.sort_by(|a, b| a.0.cmp(b.0));
    let mut json = String::with_capacity(16 + fields.len() * 16);
    json.push('{');
    for (i, (name, v)) in fields.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        use std::fmt::Write as _;
        match v {
            Scalar::F32(x) => {
                let _ = write!(json, "\"{}\":{}", name, x);
            }
            Scalar::I64(x) => {
                let _ = write!(json, "\"{}\":{}", name, x);
            }
            Scalar::U64(x) => {
                let _ = write!(json, "\"{}\":{}", name, x);
            }
            Scalar::Bool(x) => {
                let _ = write!(json, "\"{}\":{}", name, x);
            }
        }
    }
    json.push('}');
    set_component(id, T::NAME, &json)
}

/// Decode a packed component record (the host's `_get_packed` wire
/// format) into the view: for each field record, assign by name. A
/// malformed record stops early (fields decoded so far stay applied) —
/// the host builds it, so this is belt-and-suspenders, like ruby's.
fn decode_packed_into<T: PackedView>(rec: &[u8], view: &mut T) {
    if rec.is_empty() {
        return;
    }
    let field_count = rec[0] as usize;
    let mut pos = 1usize;
    for _ in 0..field_count {
        if pos >= rec.len() {
            return;
        }
        let name_len = rec[pos] as usize;
        pos += 1;
        if pos + name_len > rec.len() {
            return;
        }
        let name_at = pos;
        pos += name_len;
        if pos >= rec.len() {
            return;
        }
        let tag = rec[pos];
        pos += 1;
        let v = match tag {
            0 => {
                if pos + 4 > rec.len() {
                    return;
                }
                let bits = u32::from_le_bytes(rec[pos..pos + 4].try_into().unwrap());
                pos += 4;
                Scalar::F32(f32::from_bits(bits))
            }
            1 => {
                if pos + 8 > rec.len() {
                    return;
                }
                let x = i64::from_le_bytes(rec[pos..pos + 8].try_into().unwrap());
                pos += 8;
                Scalar::I64(x)
            }
            2 => {
                if pos >= rec.len() {
                    return;
                }
                let x = rec[pos] != 0;
                pos += 1;
                Scalar::Bool(x)
            }
            3 => {
                if pos + 8 > rec.len() {
                    return;
                }
                let x = u64::from_le_bytes(rec[pos..pos + 8].try_into().unwrap());
                pos += 8;
                Scalar::U64(x)
            }
            _ => return,
        };
        let name_end = name_at + name_len;
        let _ = view.set_field(&rec[name_at..name_end], v);
    }
}

/// Encode the view as a packed record (the `_set_packed` wire format:
/// each field tagged by its rust type). None = doesn't fit `rec` (the
/// caller takes the JSON path).
fn encode_packed<T: PackedView>(view: &T, rec: &mut [u8]) -> Option<usize> {
    let mut w = 0usize;
    let mut count = 0usize;
    let mut overflow = false;
    // First byte patched after the walk (field count).
    w += 1;
    view.each_field(&mut |name, v| {
        if overflow {
            return;
        }
        let payload = match v {
            Scalar::F32(_) => 4,
            Scalar::Bool(_) => 1,
            Scalar::I64(_) | Scalar::U64(_) => 8,
        };
        if name.len() > 255 || w + 1 + name.len() + 1 + payload > rec.len() {
            overflow = true;
            return;
        }
        rec[w] = name.len() as u8;
        w += 1;
        rec[w..w + name.len()].copy_from_slice(name.as_bytes());
        w += name.len();
        match v {
            Scalar::F32(x) => {
                rec[w] = 0;
                rec[w + 1..w + 5].copy_from_slice(&x.to_bits().to_le_bytes());
                w += 5;
            }
            Scalar::I64(x) => {
                rec[w] = 1;
                rec[w + 1..w + 9].copy_from_slice(&x.to_le_bytes());
                w += 9;
            }
            Scalar::Bool(x) => {
                rec[w] = 2;
                rec[w + 1] = x as u8;
                w += 2;
            }
            Scalar::U64(x) => {
                rec[w] = 3;
                rec[w + 1..w + 9].copy_from_slice(&x.to_le_bytes());
                w += 9;
            }
        }
        count += 1;
    });
    if overflow || count > 255 {
        return None;
    }
    rec[0] = count as u8;
    Some(w)
}

/// Walk a FLAT JSON object's scalar members: for each top-level key
/// whose value is a number or bool, call `f(key_bytes, scalar)`.
/// Numbers type by token shape (fraction/exponent → f32; else i64 when
/// negative, u64 otherwise — the mock/engine convention). Nested
/// values, strings and null are skipped, exactly as the packed stream
/// skips non-scalar fields. The JSON-fallback decode half of
/// [`get_into`].
fn json_scalar_fields(json: &[u8], f: &mut dyn FnMut(&[u8], Scalar)) {
    let mut i = 0usize;
    let skip_ws = |json: &[u8], mut i: usize| {
        while i < json.len() && json[i].is_ascii_whitespace() {
            i += 1;
        }
        i
    };
    i = skip_ws(json, i);
    if i >= json.len() || json[i] != b'{' {
        return;
    }
    i += 1;
    loop {
        i = skip_ws(json, i);
        if i >= json.len() || json[i] == b'}' {
            return;
        }
        if json[i] != b'"' {
            return; // malformed — stop, like ruby's parser raise-out
        }
        i += 1;
        let key_start = i;
        while i < json.len() && json[i] != b'"' {
            i += 1; // field names are identifiers — no escapes
        }
        if i >= json.len() {
            return;
        }
        let key_end = i;
        i += 1;
        i = skip_ws(json, i);
        if i >= json.len() || json[i] != b':' {
            return;
        }
        i += 1;
        i = skip_ws(json, i);
        // Value: scalar → deliver; anything else → skip balanced.
        let start = i;
        match json.get(i) {
            Some(b'{') | Some(b'[') => {
                let mut depth = 0usize;
                let mut in_str = false;
                while i < json.len() {
                    let b = json[i];
                    if in_str {
                        if b == b'\\' {
                            i += 1;
                        } else if b == b'"' {
                            in_str = false;
                        }
                    } else {
                        match b {
                            b'"' => in_str = true,
                            b'{' | b'[' => depth += 1,
                            b'}' | b']' => {
                                depth -= 1;
                                if depth == 0 {
                                    i += 1;
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                    i += 1;
                }
            }
            Some(b'"') => {
                i += 1;
                while i < json.len() {
                    if json[i] == b'\\' {
                        i += 1;
                    } else if json[i] == b'"' {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            }
            _ => {
                while i < json.len() && json[i] != b',' && json[i] != b'}' {
                    i += 1;
                }
                let tok = trim_ascii(&json[start..i]);
                if let Some(v) = classify_token(tok) {
                    f(&json[key_start..key_end], v);
                }
            }
        }
        i = skip_ws(json, i);
        match json.get(i) {
            Some(b',') => i += 1,
            Some(b'}') | None => return,
            _ => return,
        }
    }
}

fn trim_ascii(mut s: &[u8]) -> &[u8] {
    while let Some((f, rest)) = s.split_first() {
        if f.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }
    while let Some((l, rest)) = s.split_last() {
        if l.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }
    s
}

fn classify_token(tok: &[u8]) -> Option<Scalar> {
    if tok.is_empty() {
        return None;
    }
    if tok == b"true" {
        return Some(Scalar::Bool(true));
    }
    if tok == b"false" {
        return Some(Scalar::Bool(false));
    }
    let text = core::str::from_utf8(tok).ok()?;
    let fractional = tok.iter().any(|&b| matches!(b, b'.' | b'e' | b'E'));
    if !fractional {
        if tok[0] == b'-' {
            if let Ok(v) = text.parse::<i64>() {
                return Some(Scalar::I64(v));
            }
        } else if let Ok(v) = text.parse::<u64>() {
            return Some(Scalar::U64(v));
        }
    }
    text.parse::<f32>().ok().map(Scalar::F32)
}

// ── Batched query (the whole-query fast path) ────────────────────────────

/// Why a batch call refused. Every variant is LOUD on purpose — there
/// is no batch fallback (see the section doc).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BatchError {
    /// The host engine lacks batch support (script contract v1.3 needs
    /// labelle-engine >= 2.6.0) — use per-entity get/set on this
    /// engine. The runtime answer of `labelle_scripting_bulk_capability`.
    Unsupported,
    /// A named component has an int-typed field (i64/u64 cannot ride
    /// the f32 batch stream) — keep that component on per-entity
    /// get/set (the packed codec carries ints losslessly).
    IntRefused,
    /// `batch_set`'s exact-size positional-coupling guard fired: the
    /// entity set changed between the paired calls (spawn/destroy is
    /// forbidden between them), or the names were malformed / the host
    /// not bound. NOTHING was applied — re-run `batch_get` and
    /// recompute.
    EntitySetChanged,
    /// (Closure tier only.) The typed views' declared stride does not
    /// match the host stream — a field the stream skips (non-scalar)
    /// disagrees with the view layout. Use the raw
    /// `batch_get`/`batch_set` flat loop for these components.
    LayoutMismatch,
    /// (Closure tier only.) The same component named more than once:
    /// the stream would carry two copies of its fields per entity and
    /// the positional write-back would let the unchanged second copy
    /// OVERWRITE the first's writes — silent write loss, refused up
    /// front (the ruby block tier's duplicate-name refusal, one level
    /// up). The raw tier deliberately stays script-owned.
    DuplicateComponent,
}

impl std::fmt::Display for BatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BatchError::Unsupported => write!(
                f,
                "labelle: batch — the host engine lacks batch support (script contract v1.3 \
                 needs labelle-engine >= 2.6.0); use per-entity get/set on this engine"
            ),
            BatchError::IntRefused => write!(
                f,
                "labelle: batch refused: a named component has an int-typed field (i64/u64 \
                 cannot ride the f32 batch stream) — keep that component on per-entity \
                 get/set (the packed codec carries ints losslessly)"
            ),
            BatchError::EntitySetChanged => write!(
                f,
                "labelle: batch_set refused: the entity set changed between batch_get and \
                 batch_set (spawn/destroy between the paired calls — the buffer was computed \
                 against a stale set; re-run batch_get and recompute), or the names were \
                 malformed / the host not bound"
            ),
            BatchError::LayoutMismatch => write!(
                f,
                "labelle: batch: the typed views' stride does not match the host stream (a \
                 non-scalar field the stream skips confused the layout) — use the raw \
                 batch_get/batch_set flat loop for these components"
            ),
            BatchError::DuplicateComponent => write!(
                f,
                "labelle: batch: the same component is named more than once — the stream \
                 would carry two copies per entity and the positional write-back would let \
                 the unchanged copy overwrite the other's writes; batch each component once"
            ),
        }
    }
}

/// ONE contract crossing fills `out` with every matching entity's
/// scalar component data as a flat f32 stream ([c0_f0, c0_f1, …] per
/// entity, components in `names_json` order, fields in declaration
/// order) and returns the entity COUNT; `out` is trimmed to exactly
/// count×stride (a shrinking set never leaves stale trailing floats
/// for `batch_set`'s exact-size guard to trip on). `scratch` carries
/// the raw byte stream; both reuse capacity, growing at most once.
/// Ok(0) = empty query (also malformed names / not bound — the ruby
/// convention). The raw tier: the script owns the positional layout.
pub fn batch_get(
    names_json: &str,
    out: &mut Vec<f32>,
    scratch: &mut Vec<u8>,
) -> Result<u32, BatchError> {
    out.clear();
    scratch.clear();
    if unsafe { labelle_scripting_bulk_capability() } == 0 {
        return Err(BatchError::Unsupported);
    }
    unsafe {
        let mut n = labelle_scripting_bulk_batch_get(
            names_json.as_ptr(),
            names_json.len(),
            ffi_out_ptr(scratch),
            scratch.capacity(),
        );
        // The refusal sentinel is (size_t)-2 — check BEFORE reading the
        // return as a required size.
        if n == BATCH_INT_REFUSED {
            return Err(BatchError::IntRefused);
        }
        if n == 0 {
            return Ok(0);
        }
        if n > scratch.capacity() {
            scratch.reserve(n);
            n = labelle_scripting_bulk_batch_get(
                names_json.as_ptr(),
                names_json.len(),
                ffi_out_ptr(scratch),
                scratch.capacity(),
            );
            if n == 0 || n > scratch.capacity() {
                return Ok(0); // belt — mirrors the ruby binding
            }
        }
        if n < 4 {
            return Ok(0);
        }
        scratch.set_len(n);
    }
    let count = u32::from_le_bytes(scratch[0..4].try_into().unwrap());
    let nfloats = (scratch.len() - 4) / 4;
    out.reserve(nfloats);
    for i in 0..nfloats {
        let at = 4 + i * 4;
        let bits = u32::from_le_bytes(scratch[at..at + 4].try_into().unwrap());
        out.push(f32::from_bits(bits));
    }
    Ok(count)
}

/// ONE contract crossing writes the whole stream back: the host
/// re-queries the same entities in the same order and applies `buf`
/// positionally, read-modify-write per component (only stream-carried
/// scalar fields move). `buf` is exactly what `batch_get` filled and
/// trimmed, mutated in place. `scratch` carries the encoded bytes.
/// Refusals are Err — both mean the write would corrupt data and both
/// are loud (see [`BatchError`]).
pub fn batch_set(names_json: &str, buf: &[f32], scratch: &mut Vec<u8>) -> Result<(), BatchError> {
    if unsafe { labelle_scripting_bulk_capability() } == 0 {
        return Err(BatchError::Unsupported);
    }
    scratch.clear();
    scratch.reserve(buf.len() * 4);
    for &v in buf {
        scratch.extend_from_slice(&v.to_bits().to_le_bytes());
    }
    let rc = unsafe {
        labelle_scripting_bulk_batch_set(
            names_json.as_ptr(),
            names_json.len(),
            scratch.as_ptr(),
            scratch.len(),
        )
    };
    match rc {
        0 => Ok(()),
        -2 => Err(BatchError::IntRefused),
        _ => Err(BatchError::EntitySetChanged),
    }
}

/// A stream-eligible field type: f32 rides raw, bool as 0/1 — the same
/// two the host stream carries (int fields are refused host-side).
pub trait BatchScalar: Copy {
    fn from_stream(v: f32) -> Self;
    fn to_stream(self) -> f32;
}
impl BatchScalar for f32 {
    fn from_stream(v: f32) -> f32 {
        v
    }
    fn to_stream(self) -> f32 {
        self
    }
}
impl BatchScalar for bool {
    fn from_stream(v: f32) -> bool {
        v != 0.0
    }
    fn to_stream(self) -> f32 {
        if self {
            1.0
        } else {
            0.0
        }
    }
}

/// A typed per-entity view over the batch stream — mint one with
/// [`crate::batch_view!`]. The struct's declared fields ARE the layout
/// authority (declaration order, one stream float each), cross-checked
/// against the host stream's real stride before the first closure call
/// — a mismatch is `BatchError::LayoutMismatch`, never a mis-map.
pub trait BatchView: Default {
    const NAME: &'static str;
    const STRIDE: usize;
    fn load(&mut self, row: &[f32]);
    fn store(&self, row: &mut [f32]);
}

// The reused closure-tier buffers: one float stream + one byte scratch
// + one names string, shared by every `batch`/`batch2` call (grow once,
// steady state allocates nothing). thread_local like the glue registry
// — the contract is main-thread-only. A NESTED batch call would alias
// the shared stream mid-iteration, so `try_borrow_mut` turns it into a
// pointed panic instead of silent corruption (the ruby doc's "no
// nested Labelle.batch" rule, enforced).
thread_local! {
    #[allow(clippy::type_complexity)]
    static BATCH_SCRATCH: std::cell::RefCell<(Vec<f32>, Vec<u8>, String)> =
        const { std::cell::RefCell::new((Vec::new(), Vec::new(), String::new())) };
}

/// The ergonomic tier over one component — `batch::<Pos>(|p| { … })`:
/// ONE `batch_get`, the closure runs once per matching entity against
/// typed views loaded from the stream (writes stored back after each
/// call), then ONE `batch_set` commits everything. Returns the entity
/// count; an empty query returns Ok(0) without calling the closure.
///
/// EXIT SEMANTICS (the ruby contract, rust spelling):
///   - completing the closure for every row COMMITS via the one
///     `batch_set`;
///   - early exit is [`batch_while`] (a `false` return) and COMMITS
///     the writes made so far — including the current row's — while
///     not-yet-visited rows round-trip unchanged;
///   - a PANIC in the closure aborts the whole write: it unwinds out
///     of this call before `batch_set` ever runs (all-or-nothing; the
///     glue contains it at the hook boundary like any script panic).
///
/// In a JIT'd runtime this closure inlines; in rust it is compiled —
/// expect flat-loop speed (the RFC's "JIT languages get both from the
/// closure" holds trivially here).
pub fn batch<A: BatchView>(mut f: impl FnMut(&mut A)) -> Result<u32, BatchError> {
    batch_while::<A>(|a| {
        f(a);
        true
    })
}

/// [`batch`] with early exit: return `false` to stop iterating — the
/// writes made so far (current row included) still COMMIT through the
/// one `batch_set`.
pub fn batch_while<A: BatchView>(mut f: impl FnMut(&mut A) -> bool) -> Result<u32, BatchError> {
    batch_core(&[A::NAME], A::STRIDE, &mut |row| {
        let mut a = A::default();
        a.load(&row[..A::STRIDE]);
        let keep_going = f(&mut a);
        a.store(&mut row[..A::STRIDE]);
        keep_going
    })
}

/// The ergonomic tier over two components (the RFC's headline shape) —
/// `batch2::<Pos, Vel>(|p, v| { … })`. Semantics of [`batch`].
pub fn batch2<A: BatchView, B: BatchView>(
    mut f: impl FnMut(&mut A, &mut B),
) -> Result<u32, BatchError> {
    batch2_while::<A, B>(|a, b| {
        f(a, b);
        true
    })
}

/// [`batch2`] with early exit — `false` stops iterating and COMMITS
/// the writes made so far.
pub fn batch2_while<A: BatchView, B: BatchView>(
    mut f: impl FnMut(&mut A, &mut B) -> bool,
) -> Result<u32, BatchError> {
    batch_core(&[A::NAME, B::NAME], A::STRIDE + B::STRIDE, &mut |row| {
        let mut a = A::default();
        let mut b = B::default();
        a.load(&row[..A::STRIDE]);
        b.load(&row[A::STRIDE..]);
        let keep_going = f(&mut a, &mut b);
        a.store(&mut row[..A::STRIDE]);
        b.store(&mut row[A::STRIDE..]);
        keep_going
    })
}

fn batch_core(
    names: &[&str],
    stride: usize,
    row_fn: &mut dyn FnMut(&mut [f32]) -> bool,
) -> Result<u32, BatchError> {
    // Duplicate component names would put two copies of the same fields
    // in every row — refuse before any host call (see the variant doc).
    for i in 0..names.len() {
        for j in i + 1..names.len() {
            if names[i] == names[j] {
                return Err(BatchError::DuplicateComponent);
            }
        }
    }
    BATCH_SCRATCH.with(|cell| {
        let mut guard = cell.try_borrow_mut().unwrap_or_else(|_| {
            panic!(
                "labelle::batch: nested batch calls are not supported (the shared stream \
                 buffer would alias mid-iteration) — restructure into sequential batches"
            )
        });
        let (floats, scratch, names_json) = &mut *guard;
        names_json.clear();
        names_json.push('[');
        for (i, n) in names.iter().enumerate() {
            if i > 0 {
                names_json.push(',');
            }
            names_json.push('"');
            names_json.push_str(n);
            names_json.push('"');
        }
        names_json.push(']');
        let count = batch_get(names_json, floats, scratch)?;
        if count == 0 {
            return Ok(0);
        }
        if floats.len() != count as usize * stride {
            return Err(BatchError::LayoutMismatch);
        }
        for row in floats.chunks_exact_mut(stride) {
            if !row_fn(row) {
                break; // early exit COMMITS — fall through to batch_set
            }
        }
        batch_set(names_json, floats, scratch)?;
        Ok(count)
    })
}

// ── Declarations: labelle::component! / labelle::event! (labelle-engine#774) ─
//
// The rust spelling of the declare contract (RFC-LANGUAGE-PLUGINS §"The
// declare contract"). ONE macro, TWO consumers — the "compile-and-run probe"
// route settled on #774:
//
//   * ALWAYS: `component! { Hunger { level: f32 = 0.875 } }` expands to a real
//     typed struct `pub struct Hunger { pub level: f32 }` with a `Default`
//     carrying the declared defaults — rust gets TYPED component access, and
//     layout-parity with the Zig side comes by construction (both sides codegen
//     from one schema).
//   * UNDER `cfg(feature = "declare")`: the same macro ALSO registers a schema
//     declaration; the declare probe's `main` prints the accumulated schema
//     JSON — byte-identical to what the lua/ruby declare tools emit for the
//     equivalent declarations (tests/declare_cross_golden.zig pins it).
//
// The shipped staticlib is built with NO features (native/Cargo.toml's zero-dep,
// offline-build property holds): `inventory` is an OPTIONAL dependency the
// `declare` feature turns on, so it is compiled ONLY into the generate-time
// probe, never into the game binary.
//
// The field-type vocabulary is the schema's: f32 / bool / i32 / u64 / vec2 /
// str. `u64` is the entity-id type (the lua/ruby `labelle.id` marker's rust
// twin — spelled as the real type here since rust is typed); ids default 0.

/// A `vec2` component/event field's value — the typed struct field for a
/// `vec2`-typed declared field.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}

/// `vec2` literal helper for declarations: `home: vec2 = vec2(-0.5, 7.0)`.
/// Takes f64 so a `vec2` default's schema JSON formats from the AS-WRITTEN
/// value (no f32 narrowing before %.14g); the struct field narrows to f32.
pub const fn vec2(x: f64, y: f64) -> Vec2 {
    Vec2 {
        x: x as f32,
        y: y as f32,
    }
}

// ── %.14g, pure Rust (byte-parity with the lua/ruby runners) ─────────────────
// The lua declare tool formats floats through host libc `printf %.14g`; ruby
// through mruby's vendored `fmt_fp` — the cross-runner golden proves those
// agree byte-for-byte, i.e. %.14g is the portable pin. We reproduce C's `%g`
// with precision 14 in pure Rust (no libc FFI — UCRT exposes no linkable
// `snprintf`, and a pure-Rust emitter makes the schema platform-independent):
// 14 significant digits, %e vs %f chosen by exponent, trailing zeros stripped,
// exponent >= 2 digits with sign. Fuzzed against C printf over 200k random
// doubles: zero mismatches.

/// `%.14g` of a finite double, byte-identical to C's `printf`.
#[cfg(feature = "declare")]
pub fn g14(v: f64) -> String {
    debug_assert!(v.is_finite());
    if v == 0.0 {
        return "0".to_string(); // our declared values are never -0.0
    }
    let neg = v < 0.0;
    let a = v.abs();
    // Scientific with p-1 fractional digits => p=14 significant digits, rounded
    // exactly as C rounds the 14th digit (both round half-to-even).
    let sci = format!("{:.*e}", 13, a);
    let (mant, exp) = sci.split_once('e').expect("scientific form");
    let x: i32 = exp.parse().expect("exponent");
    let mut out = if x < -4 || x >= 14 {
        let m = strip_trailing_zeros(mant);
        let sign = if x < 0 { '-' } else { '+' };
        format!("{}e{}{:02}", m, sign, x.abs())
    } else {
        let frac = (13 - x).max(0) as usize;
        strip_trailing_zeros(&format!("{:.*}", frac, a))
    };
    if neg {
        out.insert(0, '-');
    }
    out
}

#[cfg(feature = "declare")]
fn strip_trailing_zeros(s: &str) -> String {
    if !s.contains('.') {
        return s.to_string();
    }
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// f32 default JSON: %.14g, then FORCE floatness ("1" -> "1.0") so the schema
/// reads unambiguously — the lua/ruby `number_json` rule.
#[cfg(feature = "declare")]
pub fn fmt_f32(v: f64) -> String {
    let mut s = g14(v);
    if !s.contains(['.', 'e', 'E']) {
        s.push_str(".0");
    }
    s
}

/// JSON string escaping, byte-for-byte the lua `quote()` / ruby `__quote`:
/// named escapes for `"` `\` `\b` `\f` `\n` `\r` `\t`; `\u%04x` for other
/// control bytes (<0x20 and 0x7f); every other byte passes through raw.
#[cfg(feature = "declare")]
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for &b in s.as_bytes() {
        match b {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            0x08 => out.push_str("\\b"),
            0x0c => out.push_str("\\f"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            b if b < 0x20 || b == 0x7f => out.push_str(&format!("\\u{:04x}", b)),
            b => out.push(b as char),
        }
    }
    out.push('"');
    out
}

// ── the declaration registry (declare mode only) ────────────────────────────

/// Which array a declaration lands in — components and events are separate
/// namespaces (a `Hunger` component and a `hunger` event may coexist).
#[cfg(feature = "declare")]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Component,
    Event,
}

/// One declaration, submitted by a `component!`/`event!` invocation.
/// `fragment` returns this declaration's fully-formed schema JSON object
/// (fields already sorted + formatted). `file`/`line` recover DECLARATION
/// order per kind — inventory's collection order is unspecified, so the
/// emitter sorts on source position (the assembler controls cross-file order
/// via the probe's module list; within a file it is source order).
#[cfg(feature = "declare")]
pub struct Declaration {
    pub kind: Kind,
    pub name: &'static str,
    pub file: &'static str,
    pub line: u32,
    pub fragment: fn() -> String,
}

#[cfg(feature = "declare")]
inventory::collect!(Declaration);

/// One field's schema triple; the macro classifies, the emitter sorts + joins.
#[cfg(feature = "declare")]
pub struct FieldSpec {
    pub name: &'static str,
    pub ty: &'static str,
    pub json: String,
}

/// `{"name":..,"persist":..,"fields":[..]}` — fields sorted by name.
#[cfg(feature = "declare")]
pub fn component_fragment(name: &str, persist: &str, mut fields: Vec<FieldSpec>) -> String {
    fields.sort_by(|a, b| a.name.cmp(b.name));
    let mut out = format!(
        "{{\"name\":{},\"persist\":\"{}\",\"fields\":[",
        quote(name),
        persist
    );
    for (i, f) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        push_field(&mut out, f);
    }
    out.push_str("]}");
    out
}

/// `{"name":..,"fields":[..]}` — no persist key (events are never saved).
#[cfg(feature = "declare")]
pub fn event_fragment(name: &str, mut fields: Vec<FieldSpec>) -> String {
    fields.sort_by(|a, b| a.name.cmp(b.name));
    let mut out = format!("{{\"name\":{},\"fields\":[", quote(name));
    for (i, f) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        push_field(&mut out, f);
    }
    out.push_str("]}");
    out
}

#[cfg(feature = "declare")]
fn push_field(out: &mut String, f: &FieldSpec) {
    out.push_str(&format!(
        "{{\"name\":{},\"type\":\"{}\",\"default\":{}}}",
        quote(f.name),
        f.ty,
        f.json
    ));
}

/// Assemble the whole schema line, exactly as the lua `__declare_emit`:
/// `{"components":[...]}` + (`,"events":[...]` ONLY when non-empty) + `}`.
#[cfg(feature = "declare")]
pub fn emit_schema() -> String {
    let mut comps: Vec<&'static Declaration> = inventory::iter::<Declaration>
        .into_iter()
        .filter(|d| d.kind == Kind::Component)
        .collect();
    let mut evts: Vec<&'static Declaration> = inventory::iter::<Declaration>
        .into_iter()
        .filter(|d| d.kind == Kind::Event)
        .collect();
    comps.sort_by(|a, b| a.file.cmp(b.file).then(a.line.cmp(&b.line)));
    evts.sort_by(|a, b| a.file.cmp(b.file).then(a.line.cmp(&b.line)));

    let mut out = String::from("{\"components\":[");
    for (i, d) in comps.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&(d.fragment)());
    }
    out.push(']');
    if !evts.is_empty() {
        out.push_str(",\"events\":[");
        for (i, d) in evts.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&(d.fragment)());
        }
        out.push(']');
    }
    out.push('}');
    out
}

// Re-export inventory so `$crate::labelle::inventory::submit!` resolves in the
// generated probe and in games (the macros expand to it under `declare`).
#[cfg(feature = "declare")]
#[doc(hidden)]
pub use inventory;

// The macros are `#[macro_export]` (crate root); re-export them here so game
// code spells them `labelle::component!` / `labelle::event!` — the module path
// the RFC uses — whether `labelle` is this crate's module or a `#[path]`-
// recomposed one (tests/rust, the declare probe).
#[doc(hidden)]
pub use crate::{__lbl_bv_ty, __lbl_json, __lbl_pv_ty, __lbl_ty, __lbl_tystr, component, event};
#[doc(hidden)]
pub use crate::{batch_view, packed_view};

/// Rust struct field type for a declared field-type keyword.
#[macro_export]
#[doc(hidden)]
macro_rules! __lbl_ty {
    (f32) => { f32 };
    (bool) => { bool };
    (i32) => { i32 };
    (u64) => { u64 };
    (vec2) => { $crate::labelle::Vec2 };
    (str) => { &'static str };
}

/// Schema type string for a declared field-type keyword.
#[macro_export]
#[doc(hidden)]
macro_rules! __lbl_tystr {
    (f32) => {
        "f32"
    };
    (bool) => {
        "bool"
    };
    (i32) => {
        "i32"
    };
    (u64) => {
        "u64"
    };
    (vec2) => {
        "vec2"
    };
    (str) => {
        "str"
    };
}

/// Schema default JSON for a field of the given type keyword + default expr.
/// Numeric literals are bound to a definite type first: f32 defaults format
/// from the AS-WRITTEN f64 (no narrowing before %.14g); i32 binds so
/// `-2147483648` (i32::MIN) does not overflow literal inference; u64 (the
/// entity-id type) always emits 0.
#[macro_export]
#[doc(hidden)]
macro_rules! __lbl_json {
    (f32, $d:expr) => {{
        let v: f64 = $d;
        $crate::labelle::fmt_f32(v)
    }};
    (bool, $d:expr) => {{
        let v: bool = $d;
        (if v { "true" } else { "false" }).to_string()
    }};
    (i32, $d:expr) => {{
        let v: i32 = $d;
        format!("{}", v)
    }};
    (u64, $d:expr) => {{
        let _v: u64 = $d;
        "0".to_string()
    }};
    (str, $d:expr) => {
        $crate::labelle::quote($d)
    };
    (vec2, $d:expr) => {{
        let v: $crate::labelle::Vec2 = $d;
        format!(
            "{{\"x\":{},\"y\":{}}}",
            $crate::labelle::g14(v.x as f64),
            $crate::labelle::g14(v.y as f64)
        )
    }};
}

/// `labelle::component! { [persistent|transient] Name { field: type = default, ... } }`
#[macro_export]
macro_rules! component {
    ($name:ident { $($fname:ident : $fty:ident = $fdef:expr),* $(,)? }) => {
        $crate::component!(@build persistent $name { $($fname : $fty = $fdef),* });
    };
    (persistent $name:ident { $($fname:ident : $fty:ident = $fdef:expr),* $(,)? }) => {
        $crate::component!(@build persistent $name { $($fname : $fty = $fdef),* });
    };
    (transient $name:ident { $($fname:ident : $fty:ident = $fdef:expr),* $(,)? }) => {
        $crate::component!(@build transient $name { $($fname : $fty = $fdef),* });
    };
    (@build $persist:ident $name:ident { $($fname:ident : $fty:ident = $fdef:expr),* }) => {
        // The typed component struct + its declared defaults (always).
        #[derive(Clone, Copy, Debug, PartialEq)]
        pub struct $name {
            $(pub $fname: $crate::__lbl_ty!($fty),)*
        }
        impl Default for $name {
            fn default() -> Self {
                Self { $($fname: $fdef,)* }
            }
        }
        // Schema registration (declare mode only).
        #[cfg(feature = "declare")]
        $crate::labelle::inventory::submit! {
            $crate::labelle::Declaration {
                kind: $crate::labelle::Kind::Component,
                name: stringify!($name),
                file: file!(),
                line: line!(),
                fragment: || {
                    let fields: Vec<$crate::labelle::FieldSpec> = vec![
                        $($crate::labelle::FieldSpec {
                            name: stringify!($fname),
                            ty: $crate::__lbl_tystr!($fty),
                            json: $crate::__lbl_json!($fty, $fdef),
                        }),*
                    ];
                    $crate::labelle::component_fragment(
                        stringify!($name),
                        stringify!($persist),
                        fields,
                    )
                },
            }
        }
    };
}

/// Stream-eligible rust field type for a batch-view field-type keyword.
/// ONLY f32 and bool have arms — an int-typed field fails to COMPILE,
/// the rust spelling of the host's batch int-refusal (i64/u64 cannot
/// ride the f32 stream; keep such components on the packed per-entity
/// paths).
#[macro_export]
#[doc(hidden)]
macro_rules! __lbl_bv_ty {
    (f32) => {
        f32
    };
    (bool) => {
        bool
    };
}

/// `labelle::batch_view! { Name { field: f32|bool = default, ... } }` —
/// mint the typed per-entity view [`crate::labelle::BatchView`] the
/// `batch`/`batch2` closure tier iterates. The struct name is the
/// component name; fields must mirror the component's declaration
/// (same names, DECLARATION order — the order the host stream walks),
/// which the stride cross-check enforces before the first closure call.
/// AT LEAST ONE field is required — the macro has no zero-field arm
/// (same mechanism as the no-int-type arm): a marker component
/// contributes nothing to the stream and has nothing to iterate, and a
/// zero stride cannot chunk the row walk. Filter marker components
/// through the raw `batch_get` names instead.
#[macro_export]
macro_rules! batch_view {
    ($name:ident { $($fname:ident : $fty:ident = $fdef:expr),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, PartialEq)]
        pub struct $name {
            $(pub $fname: $crate::__lbl_bv_ty!($fty),)*
        }
        impl Default for $name {
            fn default() -> Self {
                Self { $($fname: $fdef,)* }
            }
        }
        impl $crate::labelle::BatchView for $name {
            const NAME: &'static str = stringify!($name);
            const STRIDE: usize = 0 $(+ { stringify!($fname); 1 })*;
            fn load(&mut self, row: &[f32]) {
                let mut i = 0usize;
                $(
                    self.$fname = $crate::labelle::BatchScalar::from_stream(row[i]);
                    i += 1;
                )*
                let _ = i;
            }
            fn store(&self, row: &mut [f32]) {
                let mut i = 0usize;
                $(
                    row[i] = $crate::labelle::BatchScalar::to_stream(self.$fname);
                    i += 1;
                )*
                let _ = i;
            }
        }
    };
}

/// Packed-codec rust field type for a packed-view field-type keyword —
/// the codec's scalar vocabulary (f32 / i64 / u64 / bool, plus i32
/// riding the i64 tag with host-side range checks).
#[macro_export]
#[doc(hidden)]
macro_rules! __lbl_pv_ty {
    (f32) => {
        f32
    };
    (bool) => {
        bool
    };
    (i32) => {
        i32
    };
    (i64) => {
        i64
    };
    (u64) => {
        u64
    };
}

/// `labelle::packed_view! { Name { field: type = default, ... } }` —
/// mint the typed per-component view [`crate::labelle::PackedView`]
/// that `get_into`/`set_from` refill/write over the packed codec (JSON
/// fallback included). Field names must match the component's; order
/// is free (the record is self-describing by name).
#[macro_export]
macro_rules! packed_view {
    ($name:ident { $($fname:ident : $fty:ident = $fdef:expr),* $(,)? }) => {
        #[derive(Clone, Copy, Debug, PartialEq)]
        pub struct $name {
            $(pub $fname: $crate::__lbl_pv_ty!($fty),)*
        }
        impl Default for $name {
            fn default() -> Self {
                Self { $($fname: $fdef,)* }
            }
        }
        impl $crate::labelle::PackedView for $name {
            const NAME: &'static str = stringify!($name);
            fn set_field(&mut self, name: &[u8], v: $crate::labelle::Scalar) -> bool {
                $(
                    if name == stringify!($fname).as_bytes() {
                        if let Some(x) = $crate::labelle::PackedField::from_scalar(v) {
                            self.$fname = x;
                        }
                        return true;
                    }
                )*
                let _ = &v;
                false
            }
            fn each_field(
                &self,
                f: &mut dyn FnMut(&'static str, $crate::labelle::Scalar),
            ) {
                $(
                    f(stringify!($fname), $crate::labelle::PackedField::to_scalar(self.$fname));
                )*
                let _ = f;
            }
        }
    };
}

/// `labelle::event! { name { field: type = default, ... } }`
#[macro_export]
macro_rules! event {
    ($name:ident { $($fname:ident : $fty:ident = $fdef:expr),* $(,)? }) => {
        #[derive(Clone, Copy, Debug, PartialEq)]
        #[allow(non_camel_case_types)]
        pub struct $name {
            $(pub $fname: $crate::__lbl_ty!($fty),)*
        }
        impl Default for $name {
            fn default() -> Self {
                Self { $($fname: $fdef,)* }
            }
        }
        #[cfg(feature = "declare")]
        $crate::labelle::inventory::submit! {
            $crate::labelle::Declaration {
                kind: $crate::labelle::Kind::Event,
                name: stringify!($name),
                file: file!(),
                line: line!(),
                fragment: || {
                    let fields: Vec<$crate::labelle::FieldSpec> = vec![
                        $($crate::labelle::FieldSpec {
                            name: stringify!($fname),
                            ty: $crate::__lbl_tystr!($fty),
                            json: $crate::__lbl_json!($fty, $fdef),
                        }),*
                    ];
                    $crate::labelle::event_fragment(stringify!($name), fields)
                },
            }
        }
    };
}
