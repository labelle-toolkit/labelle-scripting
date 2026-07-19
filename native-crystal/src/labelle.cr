# The `Labelle` crystal module — the Script Runtime Contract binding for
# game scripts written in Crystal (labelle-engine#741, native-compiled
# family, rust's sibling).
#
# There is no bindings layer to generate: for native languages the
# contract header (labelle-engine/contract/labelle_script.h) IS the
# binding — the `lib LibLabelle` block below mirrors it and the symbols
# resolve at link time against the host game binary that exports them
# (the labelle-engine#734 POC's finding #3, verbatim). The declared set
# is exactly the v1 core surface labelle-scripting binds today
# (src/contract.zig, SUPPORTED_CONTRACT_VERSION 1).
#
# Pointer spelling: the header's `const char *` is declared `UInt8*` —
# byte-identical ABI, and crystal Strings hand out `UInt8*` via
# `to_unsafe` without a copy. Strings are (pointer, length) pairs, NOT
# NUL-terminated. Structured payloads are UTF-8 JSON (encoding v1).
# Entity ids are UInt64 END TO END; 0 is the failure sentinel — no
# float and no Int64 ever touches an id in this module (a bit-63 id
# would drift).
#
# ## Allocation discipline (the RFC's crystal idiom)
#
# Crystal Strings are immutable, so the reuse story splits in two:
# out-parameters ride [`Buffer`] — a caller-owned, grow-once byte
# buffer (`Bytes` + length; `clear` keeps capacity) that plays exactly
# the role of rust's `&mut Vec<u8>` — and scripts parse straight from
# `buffer.to_slice` (see the suite's Util) so the hot path never
# allocates a String at all. A script that keeps its Buffers in
# instance vars reaches steady state after warm-up and stops growing,
# however much traffic flows (tests/crystal/game/gc_churn.cr pins it,
# with a forced GC.collect every tick on top).
#
# ## Scripts
#
# Game code lives in the game's `crystal/` dir, compiled into this
# object as the `Game` module (src/game/game.cr is the module root the
# assembler stages the game's sources over). The convention is one
# entry point:
#
# ```
# module Game
#   def self.register(scripts : Labelle::Scripts)
#     scripts.add "player", Player.new
#   end
# end
# ```
#
# and each script is a class inheriting [`Labelle::Script`], state in
# instance vars. The glue (glue.cr, shipped beside this file) drives
# the class from the plugin Controller's C entry points and contains
# every raise at the FFI boundary — see its doc for hook order and
# raise semantics. One rule of the road: put ALL logic in the class
# bodies, never in top-level statements — the top level runs ONCE at
# runtime boot (before any world exists), not at script setup.

# The Script Runtime Contract, v1 core (labelle_script.h). Signatures
# mirror the header 1:1; see src/contract.zig in labelle-scripting for
# the same set with the full per-function conventions. The safe
# wrappers in `Labelle` are the supported surface — the raw lib stays
# reachable as an escape hatch, but every call site owes the header's
# rules (main-thread only, borrowed pointers, sizing legs).
lib LibLabelle
  fun labelle_contract_version : UInt32

  fun labelle_entity_create : UInt64
  fun labelle_entity_destroy(id : UInt64)
  fun labelle_prefab_spawn(name : UInt8*, name_len : LibC::SizeT, params_json : UInt8*, params_len : LibC::SizeT) : UInt64

  fun labelle_component_set(id : UInt64, name : UInt8*, name_len : LibC::SizeT, json : UInt8*, json_len : LibC::SizeT) : Int32
  # Returns the bytes the COMPLETE JSON requires (snprintf-style);
  # ALL-OR-NOTHING write — on overflow nothing is written.
  fun labelle_component_get(id : UInt64, name : UInt8*, name_len : LibC::SizeT, out_buf : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT
  fun labelle_component_has(id : UInt64, name : UInt8*, name_len : LibC::SizeT) : Int32
  fun labelle_component_remove(id : UInt64, name : UInt8*, name_len : LibC::SizeT) : Int32

  # Returns the bytes the COMPLETE result requires; an under-sized cap
  # receives a truncated-at-the-last-whole-id, still-valid JSON prefix.
  fun labelle_query(names_json : UInt8*, names_json_len : LibC::SizeT, out_buf : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT

  fun labelle_event_emit(name : UInt8*, name_len : LibC::SizeT, json : UInt8*, json_len : LibC::SizeT) : Int32
  fun labelle_event_subscribe(name : UInt8*, name_len : LibC::SizeT)
  # Returns bytes WRITTEN (a real poll consumes its entry); the paired
  # NULL/cap-0 probe returns the NEXT entry's size, consuming nothing.
  fun labelle_event_poll(out_buf : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT

  fun labelle_scene_change(name : UInt8*, name_len : LibC::SizeT) : Int32
  fun labelle_log(msg : UInt8*, len : LibC::SizeT)
  fun labelle_time_dt : Float32
  # Plugin-internal: the Zig Controller stamps the tick's dt before it
  # runs the frame's scripts. Game scripts must not call it.
  fun labelle_time_dt_stamp(dt : Float32)
end

# Bulk component access (contract v1.3, labelle-scripting#41/#44) —
# these bind the scripting plugin's ALWAYS-PRESENT Zig-side shims
# (labelle-scripting src/bulk_shims.zig), NOT the contract's own
# `labelle_component_*_packed`/`_batch_*` exports: those four symbols
# exist only on engine hosts >= 2.6.0, and a direct reference would make
# every crystal game UNLINKABLE against an older engine. The shims are
# comptime-gated plugin-side — on a v1.3+ host they forward 1:1, on an
# older host they answer the ordinary absent/refused sentinels (packed
# paths degrade to JSON silently) and `labelle_scripting_bulk_capability`
# answers 0, which the batch wrappers check FIRST and surface as the
# loud "needs labelle-engine >= 2.6.0" raise (no batch fallback —
# silently degrading a whole-query read would be data loss).
lib LibLabelleBulk
  fun labelle_scripting_bulk_capability : UInt32
  fun labelle_scripting_bulk_get_packed(id : UInt64, name : UInt8*, name_len : LibC::SizeT, out_buf : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT
  fun labelle_scripting_bulk_set_packed(id : UInt64, name : UInt8*, name_len : LibC::SizeT, buf : UInt8*, buf_len : LibC::SizeT) : Int32
  fun labelle_scripting_bulk_batch_get(names_json : UInt8*, names_json_len : LibC::SizeT, out_buf : UInt8*, out_cap : LibC::SizeT) : LibC::SizeT
  fun labelle_scripting_bulk_batch_set(names_json : UInt8*, names_json_len : LibC::SizeT, buf : UInt8*, buf_len : LibC::SizeT) : Int32
end

module Labelle
  # Entity id, exactly as the contract carries it. 0 is never a valid
  # id and doubles as the failure sentinel.
  alias EntityId = UInt64

  # A caller-owned, grow-once byte buffer — the crystal spelling of
  # rust's reused `Vec<u8>`. `ensure_capacity` grows (never shrinks),
  # so a Buffer held in a script's instance var settles at the
  # workload's high-water mark and then never allocates again.
  class Buffer
    @bytes : Bytes
    @len : Int32 = 0

    def initialize(capacity : Int32 = 0)
      @bytes = capacity > 0 ? Bytes.new(capacity) : Bytes.empty
    end

    # Grow-only. Never called by wrappers except through the contract's
    # required-size legs — at most one growth per call.
    def ensure_capacity(n : Int32) : Nil
      return if n <= @bytes.size
      @bytes = Bytes.new(n)
    end

    def capacity : Int32
      @bytes.size
    end

    # :nodoc: raw pointer for the FFI legs. NULL when unallocated so the
    # host's NULL/cap-0 probe convention is honored exactly.
    def to_unsafe : UInt8*
      @bytes.size == 0 ? Pointer(UInt8).null : @bytes.to_unsafe
    end

    # :nodoc: set by the wrappers after a successful read.
    def len=(n : Int32)
      @len = n
    end

    def len : Int32
      @len
    end

    # The valid bytes of the last read — parse from this (see the
    # module doc's allocation discipline) instead of `to_s` on hot
    # paths.
    def to_slice : Bytes
      @bytes[0, @len]
    end

    # Copies into a fresh String — fine for logs and cold paths.
    def to_s : String
      String.new(to_slice)
    end
  end

  # One game script: a class with per-frame state in instance vars.
  # Every hook has a default empty body — override what you need.
  #
  # Hook order per frame (driven by the plugin Controller through the
  # glue): `on_event` for every drained inbox entry (FIFO, last frame's
  # events), then `update(dt)`. `init` runs once at plugin setup,
  # `deinit` at teardown (reverse registration order).
  #
  # Raise policy (enforced by the glue, pinned by the suite): a raise in
  # `init` evicts the script — `update`/`deinit` never run on
  # half-initialized state; a raise in `update`/`on_event` is rescued
  # and logged EVERY time and the script stays registered (its state is
  # intact and the author gets the report each tick until it's fixed);
  # siblings always keep running. No exception ever crosses the FFI
  # boundary — an escape would kill the whole game process.
  abstract class Script
    # Once, at plugin setup — create entities, subscribe to events.
    def init : Nil
    end

    # Every frame, after the inbox drain. `dt` is the gameplay
    # delta-time in seconds — the same scaled dt Zig scripts received.
    def update(dt : Float32) : Nil
    end

    # One drained inbox event: `name` is the subscription key, `payload`
    # the event's JSON. The inbox is PLUGIN-wide — every subscription
    # any script makes feeds the same drain, so filter on `name`.
    def on_event(name : String, payload : String) : Nil
    end

    # Once, at plugin teardown (the game is still alive — contract calls
    # are valid here).
    def deinit : Nil
    end
  end

  # The registration collector handed to `Game.register`. Names are
  # diagnostics identity: raise reports read "script '<name>' in <hook>
  # raised: …".
  class Scripts
    getter entries : Array({String, Script}) = [] of {String, Script}

    # Register one script. Registration order is hook order (`init`,
    # per-event fan-out and `update` run in it; `deinit` runs reversed).
    def add(name : String, script : Script) : Nil
      @entries << {name, script}
    end
  end

  # ── Safe wrappers ──────────────────────────────────────────────────

  # Create an empty entity. Returns 0 when the host is not bound.
  def self.create_entity : EntityId
    LibLabelle.labelle_entity_create
  end

  # Destroy an entity (children cascade). Unknown / dead ids are ignored.
  def self.destroy_entity(id : EntityId) : Nil
    LibLabelle.labelle_entity_destroy(id)
  end

  # Spawn a named prefab. `params_json` is an optional `{"x":…,"y":…}`
  # spawn position; nil spawns at the origin. nil result = failure
  # (unknown prefab, malformed params, not bound).
  def self.spawn_prefab(name : String, params_json : String? = nil) : EntityId?
    id = if params = params_json
           LibLabelle.labelle_prefab_spawn(name.to_unsafe, name.bytesize, params.to_unsafe, params.bytesize)
         else
           LibLabelle.labelle_prefab_spawn(name.to_unsafe, name.bytesize, Pointer(UInt8).null, 0)
         end
    id == 0 ? nil : id
  end

  # Set component `name` on `id` from a whole-struct JSON object
  # (REPLACE semantics; absent fields take declared defaults). False =
  # unknown component / dead entity / parse error (entity untouched).
  def self.set_component(id : EntityId, name : String, json : String) : Bool
    LibLabelle.labelle_component_set(id, name.to_unsafe, name.bytesize, json.to_unsafe, json.bytesize) == 0
  end

  # Serialize component `name` of `id` into `buf` (grow-once; capacity
  # is retained and reused). False = absent / unknown / dead.
  def self.get_component_into(id : EntityId, name : String, buf : Buffer) : Bool
    buf.len = 0
    # First leg: whatever capacity the buffer already has. The write is
    # all-or-nothing, so a too-small capacity costs nothing.
    required = LibLabelle.labelle_component_get(id, name.to_unsafe, name.bytesize, buf.to_unsafe, buf.capacity)
    return false if required == 0
    if required <= buf.capacity
      buf.len = required.to_i32
      return true
    end
    # Grow once, right-sized, and retry.
    buf.ensure_capacity(required.to_i32)
    got = LibLabelle.labelle_component_get(id, name.to_unsafe, name.bytesize, buf.to_unsafe, buf.capacity)
    return false if got == 0 || got > buf.capacity # vanished or grew mid-frame
    buf.len = got.to_i32
    true
  end

  # True when the entity carries the component.
  def self.component_has(id : EntityId, name : String) : Bool
    LibLabelle.labelle_component_has(id, name.to_unsafe, name.bytesize) == 1
  end

  # Remove component `name` from `id`. Idempotent on the component.
  # False = unknown component name / dead entity.
  def self.remove_component(id : EntityId, name : String) : Bool
    LibLabelle.labelle_component_remove(id, name.to_unsafe, name.bytesize) == 0
  end

  # Query entity ids by component names. `names_json` is the contract's
  # JSON array of component names — pass a literal (`%(["Marker"])`)
  # for the zero-allocation path. Matching ids land in `ids`, `scratch`
  # carries the host's JSON between the sizing legs; both are cleared
  # (capacity retained — crystal's `Array#clear` keeps its backing
  # store) and grown at most once. False = malformed input / not bound;
  # unknown names yield an empty result (true, no ids).
  def self.query_into(names_json : String, ids : Array(EntityId), scratch : Buffer) : Bool
    ids.clear
    scratch.len = 0
    required = LibLabelle.labelle_query(names_json.to_unsafe, names_json.bytesize, scratch.to_unsafe, scratch.capacity)
    return false if required == 0
    if required > scratch.capacity
      # The written prefix is valid JSON but truncated — grow once
      # right-sized and re-query for the full set.
      scratch.ensure_capacity(required.to_i32)
      got = LibLabelle.labelle_query(names_json.to_unsafe, names_json.bytesize, scratch.to_unsafe, scratch.capacity)
      return false if got == 0
      scratch.len = Math.min(got, scratch.capacity.to_u64).to_i32
    else
      scratch.len = required.to_i32
    end
    parse_ids(scratch.to_slice, ids)
    true
  end

  # Parse a contract id-array (`[3,7,12]`) into `ids` (cleared first).
  # Pure UInt64 arithmetic — a bit-63 id survives exactly; no float and
  # no Int64, ever.
  def self.parse_ids(json : Bytes, ids : Array(EntityId)) : Nil
    ids.clear
    cur = 0_u64
    in_num = false
    json.each do |b|
      if 48 <= b <= 57
        cur = cur &* 10 &+ (b - 48)
        in_num = true
      elsif in_num
        ids << cur
        cur = 0_u64
        in_num = false
      end
    end
    ids << cur if in_num
  end

  # Emit a game event by union-tag name. Empty `json` means `{}` (all
  # defaults). False = unknown event name / parse failure / the game
  # declares no events.
  def self.emit(name : String, json : String) : Bool
    LibLabelle.labelle_event_emit(name.to_unsafe, name.bytesize, json.to_unsafe, json.bytesize) == 0
  end

  # Declare interest in an event name (dedup'd host-side). Delivery
  # starts with the next tick's events, through `Script#on_event` — the
  # glue owns the drain loop.
  def self.subscribe(name : String) : Nil
    LibLabelle.labelle_event_subscribe(name.to_unsafe, name.bytesize)
  end

  # Drain one pending `"<name> <json>"` inbox entry into `buf`
  # (grow-once via the no-consume probe). False = inbox empty.
  #
  # The glue calls this once per entry per tick and fans out to
  # `Script#on_event` — scripts normally never call it themselves (a
  # script-side poll would STEAL entries from every other script's
  # dispatch).
  def self.poll_into(buf : Buffer) : Bool
    buf.len = 0
    # No-consume sizing probe (NULL/cap-0), then the real read.
    next_size = LibLabelle.labelle_event_poll(Pointer(UInt8).null, 0)
    return false if next_size == 0
    buf.ensure_capacity(next_size.to_i32)
    written = LibLabelle.labelle_event_poll(buf.to_unsafe, buf.capacity)
    return false if written == 0 || written > buf.capacity
    buf.len = written.to_i32
    true
  end

  # Switch to a registered scene by name. False = unknown scene (the
  # running scene is untouched) / not bound.
  def self.change_scene(name : String) : Bool
    LibLabelle.labelle_scene_change(name.to_unsafe, name.bytesize) == 0
  end

  # The tick's gameplay delta-time in seconds — the same scaled dt Zig
  # scripts received (0 while paused and before the first tick).
  def self.dt : Float32
    LibLabelle.labelle_time_dt
  end

  # Log through the game's log sink at info level, "[script]"-prefixed.
  def self.log(msg : String) : Nil
    LibLabelle.labelle_log(msg.to_unsafe, msg.bytesize)
  end

  # ── Bulk component access (contract v1.3, labelle-scripting#41/#44) ──
  #
  # The packed per-component codec and the batched whole-query f32
  # stream, ported from the Ruby reference (src/ruby/bindings.zig +
  # prelude.rb). Capability gating rides the plugin's Zig-side shims —
  # see the `lib LibLabelleBulk` doc above.
  #
  # 64-BIT POLICY: crystal has real Int64/UInt64, so the packed codec's
  # two's-complement bitcast pair applies directly — a UInt64 field
  # rides tag 3 bit-exact, and a record whose 64-bit tag mismatches the
  # field's signedness lands via `to_u64!`/`to_i64!` bitcast (the
  # documented lossless pair).
  #
  # NON-FINITE POLICY (parity with this family's JSON route): crystal
  # scripts hand-write JSON, where NaN/Inf have no spelling — a
  # hand-built `{"power":NaN}` is refused by the host parser (-1 →
  # false). The packed fast path must not smuggle values the JSON route
  # cannot carry, so `set_from` refuses a non-finite Float32 field up
  # front (false, nothing written).

  # `labelle_component_batch_get`'s int-field refusal sentinel — the
  # header's LABELLE_BATCH_INT_REFUSED, C's `(size_t)-2`. Checked
  # BEFORE treating the return as a required size.
  BATCH_INT_REFUSED = LibC::SizeT::MAX - 1

  # One packed-codec scalar — the wire's tag vocabulary as a crystal
  # union (0=Float32, 1=Int64, 2=Bool, 3=UInt64).
  alias Scalar = Float32 | Int64 | UInt64 | Bool

  # A batch call refused. Every refusal is LOUD on purpose — there is
  # no batch fallback (silently degrading a whole-query read would be
  # data loss). Int-typed-field refusals raise ArgumentError instead,
  # mirroring the ruby binding's class split.
  class BatchError < Exception
  end

  # True when the host engine exports the contract v1.3 bulk-access
  # symbols (labelle-engine >= 2.6.0) — the runtime spelling of the
  # Zig-side comptime probe. The batch wrappers check it themselves;
  # exposed for scripts that want to feature-gate.
  def self.bulk_access? : Bool
    LibLabelleBulk.labelle_scripting_bulk_capability == 1
  end

  private def self.raise_batch_unsupported : NoReturn
    raise BatchError.new(
      "labelle: batch — the host engine lacks batch support (script contract v1.3 " \
      "needs labelle-engine >= 2.6.0); use per-entity get/set on this engine")
  end

  private def self.raise_batch_int_refused(names_json : String) : NoReturn
    raise ArgumentError.new(
      "labelle: batch refused for #{names_json}: a named component has an int-typed " \
      "field (i64/u64 cannot ride the f32 batch stream) — keep that component on " \
      "per-entity get/set (the packed codec carries ints losslessly)")
  end

  # ONE contract crossing fills `arr` with every matching entity's
  # scalar component data as a flat Float32 stream ([c0_f0, c0_f1, …]
  # per entity, components in `names_json` order, fields in declaration
  # order) and returns the entity COUNT; `arr` is trimmed to exactly
  # count×stride (a shrinking set never leaves stale trailing floats
  # for batch_set's exact-size guard). `scratch` carries the raw byte
  # stream; both reuse capacity, growing at most once. 0 = empty query
  # (also malformed names / not bound — the ruby convention). The raw
  # tier: the script owns the positional layout. Raises ArgumentError
  # on an int-carrying named component, BatchError on a pre-v1.3 host.
  def self.batch_get(names_json : String, arr : Array(Float32), scratch : Buffer) : Int32
    arr.clear
    scratch.len = 0
    raise_batch_unsupported unless bulk_access?
    n = LibLabelleBulk.labelle_scripting_bulk_batch_get(
      names_json.to_unsafe, names_json.bytesize, scratch.to_unsafe, scratch.capacity)
    # The refusal sentinel is (size_t)-2 — check BEFORE reading the
    # return as a required size.
    raise_batch_int_refused(names_json) if n == BATCH_INT_REFUSED
    return 0 if n == 0
    if n > scratch.capacity
      scratch.ensure_capacity(n.to_i32)
      n = LibLabelleBulk.labelle_scripting_bulk_batch_get(
        names_json.to_unsafe, names_json.bytesize, scratch.to_unsafe, scratch.capacity)
      return 0 if n == 0 || n > scratch.capacity # belt — mirrors ruby
    end
    return 0 if n < 4
    scratch.len = n.to_i32
    bytes = scratch.to_slice
    count = (bytes[0].to_u32 | (bytes[1].to_u32 << 8) | (bytes[2].to_u32 << 16) | (bytes[3].to_u32 << 24)).to_i32
    nfloats = (bytes.size - 4) // 4
    i = 0
    while i < nfloats
      at = 4 + i * 4
      bits = bytes[at].to_u32 | (bytes[at + 1].to_u32 << 8) | (bytes[at + 2].to_u32 << 16) | (bytes[at + 3].to_u32 << 24)
      f = bits.unsafe_as(Float32)
      if i < arr.size
        arr[i] = f
      else
        arr << f
      end
      i += 1
    end
    arr.truncate(0, nfloats)
    count
  end

  # ONE contract crossing writes the whole stream back: the host
  # re-queries the same entities in the same order and applies `arr`
  # positionally, read-modify-write per component. `count` is the
  # caller's entity count (API symmetry with ruby); the array length is
  # the authoritative float count. Raises ArgumentError on int-typed
  # fields, BatchError when the entity set changed since the paired
  # batch_get (NOTHING was applied — re-run batch_get and recompute)
  # or on a pre-v1.3 host.
  def self.batch_set(names_json : String, arr : Array(Float32), count : Int32, scratch : Buffer) : Nil
    raise_batch_unsupported unless bulk_access?
    bytes = arr.size * 4
    scratch.ensure_capacity(Math.max(bytes, 1))
    p = scratch.to_unsafe
    arr.each_with_index do |f, i|
      bits = f.unsafe_as(UInt32)
      p[i * 4] = (bits & 0xFF).to_u8!
      p[i * 4 + 1] = ((bits >> 8) & 0xFF).to_u8!
      p[i * 4 + 2] = ((bits >> 16) & 0xFF).to_u8!
      p[i * 4 + 3] = ((bits >> 24) & 0xFF).to_u8!
    end
    rc = LibLabelleBulk.labelle_scripting_bulk_batch_set(names_json.to_unsafe, names_json.bytesize, p, bytes)
    raise_batch_int_refused(names_json) if rc == -2
    if rc != 0
      raise BatchError.new(
        "labelle: batch_set refused for #{names_json}: the entity set changed between " \
        "batch_get and batch_set (spawn/destroy between the paired calls — the buffer " \
        "was computed against a stale set; re-run batch_get and recompute), or the " \
        "names were malformed / the host not bound")
    end
  end

  # Refill `view` (a `Labelle.packed_view` instance) from its component
  # on `id` — the per-component FAST PATH. Tries the packed codec first
  # (scalars land straight in the typed properties, no JSON parse); a
  # 0xFF first byte (non-scalar component), an absent component, or a
  # pre-v1.3 host drops to the JSON route transparently. `buf` is the
  # reused byte Buffer (grow-once). False = absent / unknown / dead.
  def self.get_into(id : EntityId, view, buf : Buffer) : Bool
    name = view.class.labelle_component_name
    buf.len = 0
    n = LibLabelleBulk.labelle_scripting_bulk_get_packed(
      id, name.to_unsafe, name.bytesize, buf.to_unsafe, buf.capacity)
    if n > buf.capacity
      buf.ensure_capacity(n.to_i32)
      n = LibLabelleBulk.labelle_scripting_bulk_get_packed(
        id, name.to_unsafe, name.bytesize, buf.to_unsafe, buf.capacity)
    end
    if n >= 1 && n <= buf.capacity
      buf.len = n.to_i32
      rec = buf.to_slice
      if rec[0] != 0xFF
        decode_packed_into(rec, view)
        return true
      end
    end
    # n == 0 (absent / pre-v1.3 host) or 0xFF (non-scalar component):
    # the JSON route decides — absent stays false there too.
    return false unless get_component_into(id, name, buf)
    json_scalar_fields(buf.to_slice) do |key, v|
      view.__labelle_set_field(key, v)
    end
    true
  end

  # Write `view` to its component on `id` — the per-component FAST PATH
  # (REPLACE semantics). Encodes the packed record (each field tagged by
  # its crystal type); a host refusal (-1: non-packable component,
  # out-of-range value, pre-v1.3 host) falls back to a sorted-key JSON
  # encode of the same fields. A NON-FINITE Float32 field refuses up
  # front (false, nothing written) — see the section doc. False =
  # refused / unknown / dead.
  def self.set_from(id : EntityId, view) : Bool
    name = view.class.labelle_component_name
    nonfinite = false
    view.__labelle_each_field do |_fname, v|
      nonfinite = true if v.is_a?(Float32) && !v.finite?
    end
    return false if nonfinite
    rec = uninitialized UInt8[2048]
    if len = encode_packed(view, rec.to_slice)
      rc = LibLabelleBulk.labelle_scripting_bulk_set_packed(
        id, name.to_unsafe, name.bytesize, rec.to_unsafe, len)
      return true if rc == 0
      # Refused — fall through to JSON, which represents the value
      # faithfully (or refuses loudly host-side).
    end
    # JSON fallback: deterministic sorted-key encode (the ruby
    # binding's convention). Cold path — allocates.
    fields = [] of Tuple(String, Scalar)
    view.__labelle_each_field { |fname, v| fields << {fname, v} }
    json = String.build do |io|
      io << '{'
      fields.sort_by(&.[0]).each_with_index do |(fname, v), i|
        io << ',' if i > 0
        io << '"' << fname << "\":"
        io << v
      end
      io << '}'
    end
    set_component(id, name, json)
  end

  # Decode a packed component record (the host's `_get_packed` wire
  # format) into the view: for each field record, assign by name. A
  # malformed record stops early (fields decoded so far stay applied) —
  # the host builds it, so this is belt-and-suspenders, like ruby's.
  private def self.decode_packed_into(rec : Bytes, view) : Nil
    return if rec.empty?
    field_count = rec[0].to_i
    pos = 1
    field_count.times do
      return if pos >= rec.size
      name_len = rec[pos].to_i
      pos += 1
      return if pos + name_len > rec.size
      fname = rec[pos, name_len]
      pos += name_len
      return if pos >= rec.size
      tag = rec[pos]
      pos += 1
      v : Scalar = case tag
      when 0_u8
        return if pos + 4 > rec.size
        bits = rec[pos].to_u32 | (rec[pos + 1].to_u32 << 8) | (rec[pos + 2].to_u32 << 16) | (rec[pos + 3].to_u32 << 24)
        pos += 4
        bits.unsafe_as(Float32)
      when 1_u8
        return if pos + 8 > rec.size
        x = read_u64_le(rec, pos)
        pos += 8
        x.to_i64!
      when 2_u8
        return if pos >= rec.size
        b = rec[pos] != 0
        pos += 1
        b
      when 3_u8
        return if pos + 8 > rec.size
        x = read_u64_le(rec, pos)
        pos += 8
        x
      else
        return
      end
      view.__labelle_set_field(fname, v)
    end
  end

  private def self.read_u64_le(rec : Bytes, pos : Int32) : UInt64
    x = 0_u64
    8.times { |i| x |= rec[pos + i].to_u64 << (8 * i) }
    x
  end

  # Encode the view as a packed record (the `_set_packed` wire format:
  # each field tagged by its crystal type). Nil = doesn't fit `rec`
  # (the caller takes the JSON path).
  private def self.encode_packed(view, rec : Bytes) : Int32?
    w = 1 # first byte patched after the walk (field count)
    count = 0
    overflow = false
    view.__labelle_each_field do |fname, v|
      next if overflow
      payload =
        case v
        in Float32 then 4
        in Bool    then 1
        in Int64   then 8
        in UInt64  then 8
        end
      if fname.bytesize > 255 || w + 1 + fname.bytesize + 1 + payload > rec.size
        overflow = true
        next
      end
      rec[w] = fname.bytesize.to_u8!
      w += 1
      fname.to_slice.copy_to(rec[w, fname.bytesize])
      w += fname.bytesize
      case v
      in Float32
        rec[w] = 0_u8
        write_u32_le(rec, w + 1, v.unsafe_as(UInt32))
        w += 5
      in Int64
        rec[w] = 1_u8
        write_u64_le(rec, w + 1, v.to_u64!)
        w += 9
      in Bool
        rec[w] = 2_u8
        rec[w + 1] = v ? 1_u8 : 0_u8
        w += 2
      in UInt64
        rec[w] = 3_u8
        write_u64_le(rec, w + 1, v)
        w += 9
      end
      count += 1
    end
    return nil if overflow || count > 255
    rec[0] = count.to_u8!
    w
  end

  private def self.write_u32_le(rec : Bytes, pos : Int32, bits : UInt32) : Nil
    4.times { |i| rec[pos + i] = ((bits >> (8 * i)) & 0xFF).to_u8! }
  end

  private def self.write_u64_le(rec : Bytes, pos : Int32, bits : UInt64) : Nil
    8.times { |i| rec[pos + i] = ((bits >> (8 * i)) & 0xFF).to_u8! }
  end

  # Walk a FLAT JSON object's scalar members: for each top-level key
  # whose value is a number or bool, yield (key_bytes, scalar). Numbers
  # type by token shape (fraction/exponent → Float32; else Int64 when
  # negative, UInt64 otherwise — the mock/engine convention). Nested
  # values, strings and null are skipped, exactly as the packed stream
  # skips non-scalar fields. The JSON-fallback decode half of
  # `get_into`.
  private def self.json_scalar_fields(json : Bytes, & : Bytes, Scalar -> Nil) : Nil
    i = skip_ws(json, 0)
    return if i >= json.size || json[i] != 0x7B # '{'
    i += 1
    loop do
      i = skip_ws(json, i)
      return if i >= json.size || json[i] == 0x7D # '}'
      return if json[i] != 0x22                   # '"'
      i += 1
      key_start = i
      while i < json.size && json[i] != 0x22
        i += 1 # field names are identifiers — no escapes
      end
      return if i >= json.size
      key = json[key_start, i - key_start]
      i += 1
      i = skip_ws(json, i)
      return if i >= json.size || json[i] != 0x3A # ':'
      i += 1
      i = skip_ws(json, i)
      case json[i]?
      when 0x7B, 0x5B # '{' '[' — skip balanced
        depth = 0
        in_str = false
        while i < json.size
          b = json[i]
          if in_str
            if b == 0x5C # '\'
              i += 1
            elsif b == 0x22
              in_str = false
            end
          else
            case b
            when 0x22       then in_str = true
            when 0x7B, 0x5B then depth += 1
            when 0x7D, 0x5D
              depth -= 1
              if depth == 0
                i += 1
                break
              end
            end
          end
          i += 1
        end
      when 0x22 # string — skip
        i += 1
        while i < json.size
          if json[i] == 0x5C
            i += 1
          elsif json[i] == 0x22
            i += 1
            break
          end
          i += 1
        end
      else
        start = i
        while i < json.size && json[i] != 0x2C && json[i] != 0x7D # ',' '}'
          i += 1
        end
        tok = String.new(json[start, i - start]).strip
        if v = classify_token(tok)
          yield key, v
        end
      end
      i = skip_ws(json, i)
      case json[i]?
      when 0x2C then i += 1
      else           return
      end
    end
  end

  private def self.skip_ws(json : Bytes, i : Int32) : Int32
    while i < json.size && (json[i] == 0x20 || json[i] == 0x09 || json[i] == 0x0A || json[i] == 0x0D)
      i += 1
    end
    i
  end

  private def self.classify_token(tok : String) : Scalar?
    return nil if tok.empty?
    return true if tok == "true"
    return false if tok == "false"
    fractional = tok.includes?('.') || tok.includes?('e') || tok.includes?('E')
    unless fractional
      if tok.starts_with?('-')
        if v = tok.to_i64?
          return v
        end
      elsif v = tok.to_u64?
        return v
      end
    end
    tok.to_f32?
  end

  # ── the typed batch iterator (the ergonomic tier, #44) ───────────────
  #
  # `Labelle.batch(PosView, VelView) do |p, v| … end` — ONE batch_get,
  # the block runs once per matching entity against WRITE-THROUGH typed
  # views (accessors read/write the shared stream at a moving base
  # offset — ruby's view mechanics with crystal types), then ONE
  # batch_set commits everything. Returns the entity count; an empty
  # query returns 0 without touching the block.
  #
  # EXIT SEMANTICS (the ruby contract, verbatim — the block is inlined
  # `yield`, so crystal's `break`/`next` behave exactly like ruby's):
  #   - a RAISING block abandons the whole write — batch_set never
  #     runs, no entity is touched (all-or-nothing, safe to rescue and
  #     retry);
  #   - `break` is the normal iterator early-exit and COMMITS every
  #     write made up to that point (write-through views: the current
  #     entity's pre-break writes included); entities not yet yielded
  #     round-trip unchanged. `break value` becomes the call's value.
  #
  # The raw pairing rules apply: no spawn/destroy inside the block, and
  # no NESTED Labelle.batch (it would alias the shared stream buffer —
  # enforced with a raise). Views are minted per call (two small
  # allocations — the FFI batching is the win); stash values, never the
  # view itself.
  #
  # The views' declared fields ARE the layout authority (declaration
  # order, one stream float each), cross-checked against the host
  # stream's real stride before the first yield — a mismatch raises
  # BatchError, never mis-maps (use the raw batch_get/batch_set flat
  # loop for such components).
  @@batch_floats = [] of Float32
  @@batch_scratch = Buffer.new
  @@batch_active = false

  def self.batch(a : T.class, & : T -> _) forall T
    batch_impl(%(["#{T.labelle_component_name}"]), T.labelle_stride) do |base|
      view = T.new(@@batch_floats)
      view.__labelle_base = base
      yield view
    end
  end

  def self.batch(a : T.class, b : U.class, & : T, U -> _) forall T, U
    # Duplicate component names would put two copies of the same fields
    # in every row and let the unchanged copy overwrite the other's
    # writes on the positional write-back — refuse before any host call
    # (the ruby block tier's duplicate-name refusal, one level up).
    if T.labelle_component_name == U.labelle_component_name
      raise ArgumentError.new(
        "labelle: Labelle.batch: component '#{T.labelle_component_name}' is named by " \
        "both views — the stream would carry two copies per entity and the write-back " \
        "would silently lose one's writes; batch each component once")
    end
    batch_impl(
      %(["#{T.labelle_component_name}","#{U.labelle_component_name}"]),
      T.labelle_stride + U.labelle_stride) do |base|
      va = T.new(@@batch_floats)
      vb = U.new(@@batch_floats)
      va.__labelle_base = base
      vb.__labelle_base = base + T.labelle_stride
      yield va, vb
    end
  end

  private def self.batch_impl(names_json : String, stride : Int32, & : Int32 -> _) : Int32
    raise BatchError.new(
      "labelle: nested Labelle.batch calls are not supported (the shared stream " \
      "buffer would alias mid-iteration) — restructure into sequential batches") if @@batch_active
    @@batch_active = true
    begin
      count = batch_get(names_json, @@batch_floats, @@batch_scratch)
      return 0 if count == 0
      unless @@batch_floats.size == count * stride
        raise BatchError.new(
          "labelle: Labelle.batch(#{names_json}): the typed views' stride (#{stride} " \
          "fields per entity) does not match the host stream (#{@@batch_floats.size} " \
          "floats / #{count} entities) — a field the stream skips (non-scalar) " \
          "disagrees with the view layout; use batch_get/batch_set with explicit " \
          "offsets for these components")
      end
      aborted = false
      begin
        base = 0
        i = 0
        while i < count
          yield base
          base += stride
          i += 1
        end
      rescue ex
        aborted = true
        raise ex
      ensure
        # break/next bypass rescue but run ensure — early exit COMMITS,
        # a raise keeps the all-or-nothing abort (the ruby pattern).
        batch_set(names_json, @@batch_floats, count, @@batch_scratch) unless aborted
      end
      count
    ensure
      @@batch_active = false
    end
  end

  # ── cross-class scalar coercion (the JSON-fallback contract) ─────────
  # The JSON route types number tokens by SHAPE — `1` classifies as an
  # int even when the target field is f32, and both the host's
  # serializer and our own JSON-fallback encoder spell whole-number
  # floats that way. The generated `__labelle_set_field` arms therefore
  # coerce across numeric classes exactly where the host's own JSON
  # parse would: int classes always land in an f32 field (the host
  # parser's rounding), and a FLOAT class lands in an int field only
  # when EXACT (finite, integral, in range — mirroring the packed SET
  # refusal rules; skipped otherwise).

  # :nodoc: exact-integral gate for float-class values landing in
  # int-typed fields. Nil = not exactly representable (the field is
  # skipped, keeping its value).
  def self.coerce_f32_i64(v : Float32) : Int64?
    return nil unless v.finite? && v == v.trunc
    return nil unless v >= -9223372036854775808.0_f32 && v < 9223372036854775808.0_f32
    v.to_i64
  end

  # :nodoc:
  def self.coerce_f32_u64(v : Float32) : UInt64?
    return nil unless v.finite? && v == v.trunc
    return nil unless v >= 0.0_f32 && v < 18446744073709551616.0_f32
    v.to_u64
  end

  # :nodoc:
  def self.coerce_f32_i32(v : Float32) : Int32?
    return nil unless v.finite? && v == v.trunc
    return nil unless v >= -2147483648.0_f32 && v <= 2147483520.0_f32 # last f32 below i32 max
    v.to_i32
  end

  # `Labelle.packed_view StatsView, "Stats", {power: f32, score: i64,
  # alive: bool, seed: u64}` — mint the typed per-component view class
  # `Labelle.get_into`/`Labelle.set_from` refill/write over the packed
  # codec (JSON fallback included). Field types are the codec's scalar
  # vocabulary: f32 / i64 / u64 / i32 / bool (i32 rides the i64 tag with
  # host-side range checks). Field names must match the component's;
  # order is free (the record is self-describing by name). Instantiate
  # once, hold in an instance var, refill per use — the reuse idiom.
  macro packed_view(name, component, fields)
    class {{name.id}}
      def self.labelle_component_name : String
        {{component}}
      end

      {% for fname, ftype in fields %}
        {% t = ftype.stringify %}
        {% if t == "f32" %}
          property {{fname.id}} : Float32 = 0.0_f32
        {% elsif t == "i64" %}
          property {{fname.id}} : Int64 = 0_i64
        {% elsif t == "u64" %}
          property {{fname.id}} : UInt64 = 0_u64
        {% elsif t == "i32" %}
          property {{fname.id}} : Int32 = 0_i32
        {% elsif t == "bool" %}
          property {{fname.id}} : Bool = false
        {% else %}
          {% raise "Labelle.packed_view: unknown field type #{t} (expected f32/i64/u64/i32/bool)" %}
        {% end %}
      {% end %}

      # :nodoc: assign one decoded field by wire name (type-directed;
      # the 64-bit arms accept the OTHER 64-bit tag via bitcast — the
      # documented lossless pair). False = not a view field (skipped).
      def __labelle_set_field(fname : Bytes, v : ::Labelle::Scalar) : Bool
        {% for fname2, ftype in fields %}
          {% t = ftype.stringify %}
          if fname == {{fname2.id.stringify}}.to_slice
            {% if t == "f32" %}
              # JSON-fallback coercion: `1` classifies as an int-class
              # token — land it here with the host parser's rounding.
              case v
              when Float32 then @{{fname2.id}} = v
              when Int64   then @{{fname2.id}} = v.to_f32
              when UInt64  then @{{fname2.id}} = v.to_f32
              end
            {% elsif t == "i64" %}
              case v
              when Int64  then @{{fname2.id}} = v
              when UInt64 then @{{fname2.id}} = v.to_i64! # the bitcast pair
              when Float32
                # Float class: coerce only where exact (see the module's
                # coercion doc).
                if x = ::Labelle.coerce_f32_i64(v)
                  @{{fname2.id}} = x
                end
              end
            {% elsif t == "u64" %}
              case v
              when UInt64 then @{{fname2.id}} = v
              when Int64  then @{{fname2.id}} = v.to_u64! # the bitcast pair
              when Float32
                if x = ::Labelle.coerce_f32_u64(v)
                  @{{fname2.id}} = x
                end
              end
            {% elsif t == "i32" %}
              case v
              when Int64 then @{{fname2.id}} = v.to_i32!
              when Float32
                if x = ::Labelle.coerce_f32_i32(v)
                  @{{fname2.id}} = x
                end
              end
            {% elsif t == "bool" %}
              @{{fname2.id}} = v if v.is_a?(Bool)
            {% end %}
            return true
          end
        {% end %}
        false
      end

      # :nodoc: visit every field in DECLARATION order.
      def __labelle_each_field(& : String, ::Labelle::Scalar -> Nil) : Nil
        {% for fname2, ftype in fields %}
          {% t = ftype.stringify %}
          {% if t == "i32" %}
            # The explicit union upcast (.as(Scalar)) sidesteps a crystal
            # 1.17 codegen bug: yielding a CONCRETE value where the block
            # restriction is the union ("BUG: trying to downcast … <-
            # Float32") — upcasting first hands codegen a real union value.
            yield {{fname2.id.stringify}}, @{{fname2.id}}.to_i64.as(::Labelle::Scalar)
          {% else %}
            yield {{fname2.id.stringify}}, @{{fname2.id}}.as(::Labelle::Scalar)
          {% end %}
        {% end %}
      end
    end
  end

  # `Labelle.batch_view PosView, "BatchPos", {x: f32, y: f32}` — mint
  # the typed per-entity view class `Labelle.batch` yields. Views are
  # WRITE-THROUGH: accessors read/write the shared stream at a moving
  # base offset (ruby's view mechanics with crystal types), so a write
  # made before a `break` is already committed to the buffer. Fields
  # must mirror the component's declaration (same names, DECLARATION
  # order — the order the host stream walks), which the stride
  # cross-check enforces before the first yield. Field types: f32
  # rides raw, bool as 0/1 — an int-typed field fails to COMPILE, the
  # macro spelling of the host's batch int-refusal.
  macro batch_view(name, component, fields)
    {% if fields.empty? %}
      {% raise "Labelle.batch_view: at least one field is required (a zero-field marker view has nothing to iterate and a zero stride cannot walk the rows — filter marker components through the raw batch_get names instead)" %}
    {% end %}
    class {{name.id}}
      def self.labelle_component_name : String
        {{component}}
      end

      def self.labelle_stride : Int32
        {{fields.size}}
      end

      # :nodoc:
      def initialize(@__labelle_buf : Array(Float32))
        @__labelle_base = 0
      end

      # :nodoc:
      def __labelle_base=(b : Int32)
        @__labelle_base = b
      end

      {% i = 0 %}
      {% for fname, ftype in fields %}
        {% t = ftype.stringify %}
        {% if t == "f32" %}
          def {{fname.id}} : Float32
            @__labelle_buf[@__labelle_base + {{i}}]
          end

          def {{fname.id}}=(v : Float32)
            @__labelle_buf[@__labelle_base + {{i}}] = v
          end
        {% elsif t == "bool" %}
          def {{fname.id}} : Bool
            @__labelle_buf[@__labelle_base + {{i}}] != 0.0_f32
          end

          def {{fname.id}}=(v : Bool)
            @__labelle_buf[@__labelle_base + {{i}}] = v ? 1.0_f32 : 0.0_f32
          end
        {% else %}
          {% raise "Labelle.batch_view: field type #{t} cannot ride the f32 batch stream (only f32/bool; int-carrying components are refused host-side — keep them on the packed per-entity paths)" %}
        {% end %}
        {% i = i + 1 %}
      {% end %}
    end
  end

  # ── Declarations: Labelle.component / Labelle.event (labelle-engine#775) ──
  #
  # The crystal spelling of the declare contract (RFC-LANGUAGE-PLUGINS §4,
  # "Crystal: annotated struct, schema dumped by a declare-mode compile") —
  # the native TWIN of rust's `labelle::component!`/`event!` (#774), sharing
  # its "compile-and-run probe" extraction: `labelle-declare-crystal` stages
  # THIS module + the game's declaration files, `crystal build -Ddeclare`s
  # them, runs the probe, and relays the schema JSON — byte-identical to what
  # the lua/ruby/rust runners emit (tests/declare_cross_golden.zig pins it).
  #
  # ONE difference from rust's macro: rust's `component!` ALWAYS expands to a
  # typed `struct` (usable at runtime), gated by `#[cfg(feature="declare")]`
  # only for the schema registration. Crystal's cannot mirror that — crystal
  # type names must be Capitalized, so a lowercase event (`hunger__feed`)
  # cannot back a struct — and it need not: declaration files carry ONLY
  # schema (extracted at generate; nothing embeds or compiles into the game
  # binary, exactly as rust-game's `.rs` declarations don't), and the runtime
  # component/event surface is by-NAME over the contract
  # (`Labelle.get_component_into(id, "Hunger", buf)`). So the macros expand to
  # the schema registration UNDER `-Ddeclare` and to NOTHING in a game build —
  # the whole declare machinery below is compiled only into the probe.
  #
  # Field types are the schema vocabulary: f32 / i32 / u64 / bool / vec2 /
  # str. `u64` is the entity-id type (the lua/ruby `labelle.id` marker's
  # crystal twin — spelled as a type keyword here; ids always default 0).

  {% if flag?(:declare) %}
    # One field's schema triple; the macro classifies + formats, the emitter
    # sorts by name and joins.
    struct FieldSpec
      getter name : String
      getter type : String
      getter json : String

      def initialize(@name : String, @type : String, @json : String)
      end
    end

    # The declaration registry (declare mode only). Insertion order IS
    # declaration order: the probe `require`s the game's declaration files in
    # argv order and crystal runs their top-level `component`/`event` calls in
    # that order, so — unlike rust, which sorts on (file, line) because
    # inventory's collection order is unspecified — no position sort is needed.
    # Components and events are separate namespaces (a `Hunger` component and a
    # `hunger` event may coexist).
    module DeclareRegistry
      @@components = [] of Tuple(String, String, Array(FieldSpec))
      @@events = [] of Tuple(String, Array(FieldSpec))

      def self.add_component(name : String, persist : String, fields : Array(FieldSpec)) : Nil
        @@components << {name, persist, fields}
      end

      def self.add_event(name : String, fields : Array(FieldSpec)) : Nil
        @@events << {name, fields}
      end

      def self.components : Array(Tuple(String, String, Array(FieldSpec)))
        @@components
      end

      def self.events : Array(Tuple(String, Array(FieldSpec)))
        @@events
      end
    end

    # `%.14g` of a finite double — byte-identical to C `printf`, the portable
    # pin the lua/ruby/rust runners all agree on (tests/declare_cross_golden).
    # crystal's `sprintf` routes `%e`/`%f`/`%g` float conversions through
    # `LibC.snprintf`, so this IS the host libc's `%.14g` — the very formatter
    # the lua tool goes through. Our declared values are never -0.0.
    #
    # One portability fix on top: the exponent is normalized to C99's
    # minimum-2-digit form. glibc/BSD already emit two (`3.4e+38`), which the
    # golden pins; MSVC's `printf` pads to three (`3.4e+038`), so a windows
    # crystal dev would drift — the strip keeps the schema platform-independent
    # (rust's pure-Rust `%.14g` had the same goal) and is a no-op on the CI
    # (linux/macos) that pins the golden.
    def self.g14(v : Float64) : String
      return "0" if v == 0.0
      s = sprintf("%.14g", v)
      if e = s.index('e')
        mant = s[0...e]
        rest = s[(e + 1)..] # sign + digits, e.g. "+038" / "-05"
        sign = rest[0]
        digits = rest[1..].lstrip('0')
        digits = "0" if digits.empty?
        digits = "0" + digits if digits.size < 2
        s = "#{mant}e#{sign}#{digits}"
      end
      s
    end

    # f32 default JSON: `%.14g`, then FORCE floatness ("1" -> "1.0") so the
    # schema reads unambiguously — the lua/ruby `number_json` rule.
    def self.fmt_f32(v : Float64) : String
      s = g14(v)
      s += ".0" unless s.includes?('.') || s.includes?('e') || s.includes?('E')
      s
    end

    # vec2 default JSON — each component through `g14` (NOT `fmt_f32`: a vec2
    # field formats AS-WRITTEN, so `7.0` renders `7`, matching the lua/ruby
    # table form and rust's `Vec2` emitter).
    def self.vec2_json(x : Float64, y : Float64) : String
      "{\"x\":#{g14(x)},\"y\":#{g14(y)}}"
    end

    # JSON string escaping, byte-for-byte the lua `quote()` / ruby `__quote` /
    # rust `quote`: named escapes for `"` `\` `\b` `\f` `\n` `\r` `\t`;
    # `\u%04x` for other control bytes (<0x20 and 0x7f); every other byte
    # passes through raw.
    def self.quote(s : String) : String
      String.build do |io|
        io << '"'
        s.each_byte do |b|
          case b
          when 0x22             then io << "\\\""
          when 0x5c             then io << "\\\\"
          when 0x08             then io << "\\b"
          when 0x0c             then io << "\\f"
          when 0x0a             then io << "\\n"
          when 0x0d             then io << "\\r"
          when 0x09             then io << "\\t"
          when 0x00..0x1f, 0x7f then io << ("\\u%04x" % b)
          else                       io.write_byte(b)
          end
        end
        io << '"'
      end
    end

    private def self.push_field(io : IO, f : FieldSpec) : Nil
      io << "{\"name\":" << quote(f.name) << ",\"type\":\"" << f.type << "\",\"default\":" << f.json << "}"
    end

    # `{"name":..,"persist":..,"fields":[..]}` — fields sorted by name.
    def self.component_fragment(name : String, persist : String, fields : Array(FieldSpec)) : String
      String.build do |io|
        io << "{\"name\":" << quote(name) << ",\"persist\":\"" << persist << "\",\"fields\":["
        fields.sort_by(&.name).each_with_index do |f, i|
          io << ',' if i > 0
          push_field(io, f)
        end
        io << "]}"
      end
    end

    # `{"name":..,"fields":[..]}` — no persist key (events are never saved).
    def self.event_fragment(name : String, fields : Array(FieldSpec)) : String
      String.build do |io|
        io << "{\"name\":" << quote(name) << ",\"fields\":["
        fields.sort_by(&.name).each_with_index do |f, i|
          io << ',' if i > 0
          push_field(io, f)
        end
        io << "]}"
      end
    end

    # Assemble the whole schema line, exactly as the lua `__declare_emit`:
    # `{"components":[...]}` + (`,"events":[...]` ONLY when non-empty) + `}`.
    def self.emit_schema : String
      String.build do |io|
        io << "{\"components\":["
        DeclareRegistry.components.each_with_index do |(name, persist, fields), i|
          io << ',' if i > 0
          io << component_fragment(name, persist, fields)
        end
        io << ']'
        events = DeclareRegistry.events
        unless events.empty?
          io << ",\"events\":["
          events.each_with_index do |(name, fields), i|
            io << ',' if i > 0
            io << event_fragment(name, fields)
          end
          io << ']'
        end
        io << '}'
      end
    end
  {% end %}

  # `Labelle.component "Name", { field: {type, default}, ... }` (optional
  # `persist: "transient"`) and `Labelle.event "name", { field: {type,
  # default}, ... }`. Each `{type, default}` pairs a type keyword (bare
  # `f32`/`i32`/`u64`/`bool`/`vec2`/`str` — never evaluated, only read as
  # macro AST) with its default expr; a vec2 default is a `{x, y}` tuple.
  # Omit the fields hash for a zero-field declaration (`Labelle.component
  # "Worker"`, `Labelle.event "wave__spawned"`).
  #
  # Under `-Ddeclare` this registers a schema declaration; a normal build
  # expands it to NOTHING (see the section doc — declaration files are never
  # compiled into the game). The registration body references the declare-only
  # `DeclareRegistry`/`FieldSpec`, so it is emitted only inside the flag guard.
  macro component(name, fields = nil, persist = "persistent")
    {% if flag?(:declare) %}
      ::Labelle::DeclareRegistry.add_component({{name}}, {{persist}}, [
        {% if fields %}{% for fname, fspec in fields %}{% t = fspec[0].stringify %}
          ::Labelle::FieldSpec.new({{fname.id.stringify}}, {{t}},
            {% if t == "f32" %}::Labelle.fmt_f32(({{fspec[1]}}).to_f64){% elsif t == "i32" %}({{fspec[1]}}).to_i32.to_s{% elsif t == "u64" %}"0"{% elsif t == "bool" %}(({{fspec[1]}}) ? "true" : "false"){% elsif t == "str" %}::Labelle.quote({{fspec[1]}}){% elsif t == "vec2" %}::Labelle.vec2_json(({{fspec[1]}})[0].to_f64, ({{fspec[1]}})[1].to_f64){% else %}{% raise "labelle: unknown declared field type #{t} (expected f32/i32/u64/bool/vec2/str)" %}{% end %}),
        {% end %}{% end %}
      ] of ::Labelle::FieldSpec)
    {% end %}
  end

  macro event(name, fields = nil)
    {% if flag?(:declare) %}
      ::Labelle::DeclareRegistry.add_event({{name}}, [
        {% if fields %}{% for fname, fspec in fields %}{% t = fspec[0].stringify %}
          ::Labelle::FieldSpec.new({{fname.id.stringify}}, {{t}},
            {% if t == "f32" %}::Labelle.fmt_f32(({{fspec[1]}}).to_f64){% elsif t == "i32" %}({{fspec[1]}}).to_i32.to_s{% elsif t == "u64" %}"0"{% elsif t == "bool" %}(({{fspec[1]}}) ? "true" : "false"){% elsif t == "str" %}::Labelle.quote({{fspec[1]}}){% elsif t == "vec2" %}::Labelle.vec2_json(({{fspec[1]}})[0].to_f64, ({{fspec[1]}})[1].to_f64){% else %}{% raise "labelle: unknown declared field type #{t} (expected f32/i32/u64/bool/vec2/str)" %}{% end %}),
        {% end %}{% end %}
      ] of ::Labelle::FieldSpec)
    {% end %}
  end
end
