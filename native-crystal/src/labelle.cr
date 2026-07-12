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
    def self.g14(v : Float64) : String
      return "0" if v == 0.0
      sprintf("%.14g", v)
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
          when 0x22 then io << "\\\""
          when 0x5c then io << "\\\\"
          when 0x08 then io << "\\b"
          when 0x0c then io << "\\f"
          when 0x0a then io << "\\n"
          when 0x0d then io << "\\r"
          when 0x09 then io << "\\t"
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
