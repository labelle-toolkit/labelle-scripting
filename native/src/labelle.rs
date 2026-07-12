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
pub use crate::{__lbl_json, __lbl_ty, __lbl_tystr, component, event};

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
