# declare_prelude.rb — the ruby half of the ruby declare-mode runner
# (labelle-declare-ruby; the lua runner's twin — see
# tools/declare/declare_prelude.lua for the reference semantics this file
# mirrors line for line where ruby can spell them).
#
# Declare mode is the build-time consumer of the component AND event DSLs:
# the SAME `Hunger = Labelle.component "Hunger", level: 0.875` line that
# hands a script a Component.ref-equivalent view class at runtime
# (src/ruby/prelude.rb) is, here, a schema declaration — and the SAME
# `HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id,
# amount: 0.5` line that returns the frozen event-name string at runtime
# is, here, an event-schema declaration (labelle-engine#772). Only
# `Labelle.component`, `Labelle.event` and `Labelle.id` are live; every
# other `Labelle.*` call — and every call INTO the runtime API's classes
# (`Labelle::Component.ref`, `Labelle::Entity.create`,
# `Labelle::FrameArray.new`, ...) — is a silent no-op returning
# NOOP_RESULT, an identity-checked sentinel that the recorders reject if
# it lands in a spec position (helpers-as-data must fail the build, never
# silently drop or misparse). `Labelle::Controller`
# exists as a bare subclassable class: controller definitions are CHUNK
# SCOPE in ruby (`class HungerController < Labelle::Controller`), so a
# declare pass that NameError'd on it could never scan a real game script.
# Hooks and controller methods are merely DEFINED by the chunk body, never
# called — only chunk-scope code executes, exactly where declarations sit.
#
# Isolation: where the lua runner builds a fresh stub `_ENV` per chunk,
# ruby has no chunk environments — top-level defs, constants and module
# mutations all land process-globally. The runner therefore gives each
# chunk a WHOLE FRESH INTERPRETER (tools/declare-ruby/extract.zig opens
# one mrb_state per script): a chunk redefining `Labelle.component`,
# monkey-patching core, or binding constants dies with its state and can
# never poison a later file's extraction. Cross-chunk recorder state is
# threaded through by the Zig side instead:
#   Labelle.__declare_seed(name, file)  — replay every already-declared
#                                         component before the chunk runs
#                                         (duplicate detection with
#                                         first-declared-in attribution)
#   Labelle.__declare_seed_event(name, file) — the event-namespace twin
#                                         (events and components are
#                                         SEPARATE namespaces: a Hunger
#                                         component and a hunger event
#                                         coexist)
#   Labelle.__declare_begin(file)       — stamp the chunk's path (the
#                                         lua __DECLARE_FILE twin)
#   Labelle.__declare_take              — after the chunk ran clean:
#                                         [name, fragment, ...] — this
#                                         chunk's declarations as
#                                         pre-formatted schema-JSON
#                                         component objects, declaration
#                                         order
#   Labelle.__declare_take_events       — the same flat shape for this
#                                         chunk's event declarations
#   Labelle.__declare_seed_const(name[, value])
#                                       — re-bind a top-level constant an
#                                         EARLIER file defined, so the
#                                         legal cross-file reference
#                                         (labelle-engine#772) resolves
#                                         in this fresh state: with a
#                                         value, the PRIMITIVE the
#                                         constant held, re-bound
#                                         verbatim; without one, the
#                                         inert sentinel (the
#                                         non-primitive rest)
#   Labelle.__declare_take_consts       — after the chunk ran clean: flat
#                                         [name, value, ...] pairs — the
#                                         top-level constants the chunk
#                                         itself defined (a baseline diff
#                                         of Object's constants — the
#                                         runtime prelude's METHOD
#                                         harvest, respelled for
#                                         constants), each value a
#                                         primitive traveling verbatim or
#                                         SENTINEL_TAG for the rest
# The Zig side accumulates fragments across chunks and emits
# {"components":[...]} — plus an "events":[...] array only when any event
# was declared — BYTE-compatible with the lua runner's __declare_emit
# (the cross-runner golden in tests/ pins it).
#
# Determinism: components emit in DECLARATION order (argv order, then
# top-to-bottom within a file); fields emit SORTED BY NAME. mruby hashes
# preserve insertion order, but the lua runner cannot recover field
# declaration order (pairs() is unspecified) and the CONTRACT is one
# schema for one logical declaration set, whatever the language — so ruby
# sorts too.
#
# Type inference (v1), the lua matrix in ruby types: true/false → bool;
# Integer → i32 (range-checked); Float → f32 (F32_MAX-gated: a finite
# double beyond f32 range would narrow to ±inf in the codegenned default);
# String → str; a Hash with exactly the keys { x:, y: }, both numbers →
# vec2. u32/entity stay schema-only (no ruby value expresses them), enums
# come later. Anything else is a hard error: a malformed declaration must
# fail the build, not ship a guessed schema.
#
# Error policy: validation raises ArgumentError from inside
# `Labelle.component`, so the exception's backtrace carries the SCRIPT's
# call-site frame ("<path>:<line>"); extract.zig walks the backtrace for
# the first frame in the chunk's file and formats the failure around it
# (ruby's spelling of lua's error(msg, 3) level trick).

module Labelle
  # What every no-op returns — and what the driver re-binds earlier
  # files' harvested NON-PRIMITIVE constants to (the constant-ledger
  # seams below; primitives re-bind verbatim). NOT
  # nil: `Labelle.component("Path", {}, Labelle.array([]))` with a
  # nil-returning no-op would silently declare Path WITHOUT its intended
  # options (nil opts == no opts), and a nil field default would
  # misreport as "unsupported default of type NilClass" instead of
  # naming the real mistake. Recognition is by IDENTITY (equal?); the
  # sentinel is deliberately inert — no method_missing — so deeper
  # chunk-scope use of a no-op result fails loudly, mirroring the lua
  # sentinel table's nil-on-index behavior.
  NOOP_RESULT = Object.new.freeze

  # The id FIELD marker (labelle-engine#772): `entity: Labelle.id` in an
  # event or component spec classifies the field as {"type":"u64",
  # "default":0} — the schema's entity-id type, which no plain ruby value
  # can spell (an Integer would classify i32). Recognition is by IDENTITY,
  # like NOOP_RESULT — but this one is a LEGAL field value, so __classify
  # accepts it where __reject_noop would have fired. A bare frozen Object
  # (not a Hash) so every structural guard rejects it with the right error
  # already in place: `Labelle.event("x", Labelle.id)` lands on "expects a
  # spec Hash", a nested `{ x: Labelle.id, y: 0 }` on the vec2 shape check
  # (v1 ids are scalar-only). At runtime Labelle.id returns plain 0
  # (src/ruby/prelude.rb), so the same spec line evaluates clean in both
  # modes.
  ID_SENTINEL = Object.new.freeze

  @decls = []     # [[name, fragment], ...] — THIS chunk's, declaration order
  @by_name = {}   # component name => file first declared in (seeded + local)
  @event_decls = []     # the event twins of the two above — separate
  @events_by_name = {}  # namespace: Hunger component + hunger event coexist
  @seeded_consts = {}   # constant name (String) => true — driver-seeded,
  #                       excluded from this chunk's own constant harvest
  @file = "?"

  # Largest finite f32, as a ruby Float (a double — same value the lua
  # prelude pins). INF is computed, not Float::INFINITY, to keep the
  # prelude independent of which constants the vendored gem set defines.
  F32_MAX = 3.4028235e38
  INF = 1.0 / 0.0

  # The ruby view fast path's field cap — MUST equal MAX_REF_FIELDS in
  # src/ruby/bindings.zig (raw_component_get_into/set_from size their
  # per-call field buffers by it) and the runtime prelude's twin literal
  # (src/ruby/prelude.rb, the construction-time check). Declare mode
  # enforces it too, so an over-wide component fails ON ITS DECLARATION
  # LINE at build time, never as a late get/set raise at runtime — the
  # dual-consumer contract must not split-brain. Different languages, so
  # no shared source: tests/declare_ruby_tool.zig's drift pin reads all
  # three literals out of their sources and asserts equality.
  MAX_VIEW_FIELDS = 32

  # ── the Zig driver's three seams (extract.zig) ───────────────────────

  def self.__declare_seed(name, file)
    @by_name[name] = file
    nil
  end

  def self.__declare_seed_event(name, file)
    @events_by_name[name] = file
    nil
  end

  def self.__declare_begin(file)
    @file = file
    nil
  end

  def self.__declare_take
    flat = []
    i = 0
    while i < @decls.size
      flat << @decls[i][0]
      flat << @decls[i][1]
      i += 1
    end
    flat
  end

  def self.__declare_take_events
    flat = []
    i = 0
    while i < @event_decls.size
      flat << @event_decls[i][0]
      flat << @event_decls[i][1]
      i += 1
    end
    flat
  end

  # ── the constant ledger (cross-file constants, labelle-engine#772) ───
  # The runtime prelude's METHOD harvest (src/ruby/prelude.rb
  # __record_baseline/__new_object_methods), respelled for CONSTANTS: at
  # runtime ONE shared VM registers components → events → scripts, so a
  # later file legally references an earlier file's top-level constants
  # at chunk scope (`Labelle.on(HungerFeed)` with HungerFeed bound by
  # events/hunger__feed.rb). This runner's fresh-state-per-chunk
  # isolation would NameError that reference, so the driver re-creates
  # exactly the runtime's visibility, no more: after each clean chunk it
  # takes the constants the chunk defined (__declare_take_consts — a
  # baseline diff of Object's constants, everything the interpreter and
  # this prelude booted with excluded) WITH their values, degraded to a
  # tag — a PRIMITIVE (String, Integer, Float, true, false, nil) travels
  # verbatim, everything else (classes incl. the component view stubs,
  # arrays, hashes, procs) becomes the sentinel — and re-binds them into
  # every LATER chunk's state (__declare_seed_const). Primitives
  # re-binding verbatim is what mirrors the runtime: a cross-file EVENT
  # constant arrives at the on/emit shims as the real name string
  # (Labelle.event returns it), where a cross-file COMPONENT constant
  # arrives as the sentinel and fails the name check — and a shared
  # primitive default (`level: SHARED_DEFAULT`) classifies exactly as
  # the runtime VM would resolve it. A constant NO earlier file defined
  # stays unresolved and NameErrors at extract with the chunk's
  # file:line — a typo'd constant fails at generate, never extracts
  # silently — and a reference to a LATER file's constant fails exactly
  # like the runtime, where file-scope code runs before later files
  # load. Seeded sentinels answer no methods (chunk isolation is intact)
  # and are rejected in spec positions (__reject_noop).

  # The value channel's non-primitive tag. A Symbol on purpose: Symbol
  # is not in the primitive travel set, so a real constant value never
  # crosses the seam as one — the driver recognizes the tag by TYPE
  # (tt == symbol, no name matching), and nothing a chunk binds can
  # collide with it.
  SENTINEL_TAG = :__labelle_declare_nonprimitive__

  def self.__record_const_baseline
    @baseline_consts = {}
    cs = Object.constants
    i = 0
    while i < cs.size
      @baseline_consts[cs[i]] = true
      i += 1
    end
    nil
  end

  # With `value`: an earlier file's PRIMITIVE constant, re-bound
  # verbatim (the runtime's shared VM makes it genuinely visible there).
  # Without: the non-primitive rest, re-bound as the inert sentinel —
  # resolvable in call positions, rejected in spec positions, answering
  # no methods.
  def self.__declare_seed_const(name, value = NOOP_RESULT)
    Object.const_set(name, value)
    @seeded_consts[name] = true
    nil
  end

  # One harvested constant's ledger value: primitives verbatim,
  # SENTINEL_TAG for everything else.
  def self.__const_ledger_value(v)
    if v.nil? || true.equal?(v) || false.equal?(v) ||
       v.is_a?(Integer) || v.is_a?(Float) || v.is_a?(String)
      v
    else
      SENTINEL_TAG
    end
  end

  def self.__declare_take_consts
    added = []
    cs = Object.constants
    i = 0
    while i < cs.size
      sym = cs[i]
      unless @baseline_consts[sym] || @seeded_consts[sym.to_s]
        added << sym.to_s
        added << __const_ledger_value(Object.const_get(sym))
      end
      i += 1
    end
    added
  end

  # ── validation + JSON formatting helpers ─────────────────────────────
  # Byte-parity notes vs the lua prelude: __quote mirrors quote()'s escape
  # set exactly (named escapes, \u%04x for other control bytes, raw
  # passthrough above 0x1f so UTF-8 sequences survive); __number_json
  # mirrors number_json() — integers exact, floats %.14g with forced
  # floatness ("1.0", not "1"). No Regexp anywhere: the vendored gem set
  # has none, so identifier and escape scans walk bytes.

  def self.__identifier?(s)
    return false unless s.is_a?(String) && !s.empty?
    b = s.getbyte(0)
    return false unless (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
    i = 1
    n = s.bytesize
    while i < n
      b = s.getbyte(i)
      unless (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 95
        return false
      end
      i += 1
    end
    true
  end

  def self.__quote(s)
    out = '"'
    i = 0
    n = s.bytesize
    while i < n
      b = s.getbyte(i)
      if b == 34
        out << "\\\""
      elsif b == 92
        out << "\\\\"
      elsif b == 8
        out << "\\b"
      elsif b == 12
        out << "\\f"
      elsif b == 10
        out << "\\n"
      elsif b == 13
        out << "\\r"
      elsif b == 9
        out << "\\t"
      elsif b < 32 || b == 127
        out << format("\\u%04x", b)
      else
        out << b.chr
      end
      i += 1
    end
    out << '"'
    out
  end

  def self.__number_json(v)
    return v.to_s if v.is_a?(Integer)
    s = format("%.14g", v)
    s << ".0" unless s.include?(".") || s.include?("e") || s.include?("E")
    s
  end

  def self.__non_finite?(v)
    v.is_a?(Float) && (v != v || v == INF || v == -INF)
  end

  # Classify one spec value into [<schema type>, <default as JSON>], or
  # raise with `where` naming the declaration and field. The raise happens
  # inside the Labelle.component/Labelle.event call chain, so the
  # backtrace's script frame is the declaration site.
  def self.__classify(where, v)
    if v.equal?(ID_SENTINEL)
      return ["u64", "0"]
    end
    if true.equal?(v) || false.equal?(v)
      return ["bool", v ? "true" : "false"]
    end
    if v.is_a?(Integer)
      if v < -2147483648 || v > 2147483647
        raise ArgumentError, where + ": integer default out of i32 range"
      end
      return ["i32", v.to_s]
    end
    if v.is_a?(Float)
      if __non_finite?(v)
        raise ArgumentError, where + ": non-finite number default"
      end
      if v > F32_MAX || v < -F32_MAX
        raise ArgumentError, where + ": float default out of f32 range (f32 max is 3.4028235e38)"
      end
      return ["f32", __number_json(v)]
    end
    if v.is_a?(String)
      return ["str", __quote(v)]
    end
    if v.is_a?(Hash)
      # vec2: EXACTLY the keys x and y, both finite numbers. (A sentinel
      # nested here is not Numeric and lands on the shape error, like the
      # lua vec2 check.)
      if v.size == 2 && v.key?(:x) && v.key?(:y) && v[:x].is_a?(Numeric) && v[:y].is_a?(Numeric)
        x = v[:x]
        y = v[:y]
        if __non_finite?(x) || __non_finite?(y)
          raise ArgumentError, where + ": non-finite vec2 default"
        end
        if x > F32_MAX || x < -F32_MAX || y > F32_MAX || y < -F32_MAX
          raise ArgumentError, where + ": vec2 default out of f32 range (f32 max is 3.4028235e38)"
        end
        return ["vec2", '{"x":' + __number_json(x) + ',"y":' + __number_json(y) + "}"]
      end
      raise ArgumentError, where + ": unsupported Hash default (only { x:, y: } vec2 hashes are supported in v1)"
    end
    raise ArgumentError, where + ": unsupported default of type " + v.class.to_s +
                         " (v1 supports number, boolean, string, { x:, y: } vec2 hashes, and Labelle.id)"
  end

  # The pointed rejection for a sentinel where a literal belongs. The
  # sentinel has two sources — Labelle.* helper results and NON-PRIMITIVE
  # cross-file constants (view classes, collections, procs an earlier
  # file bound, re-bound as the sentinel by the driver through
  # __declare_seed_const; PRIMITIVE cross-file constants re-bind verbatim
  # and classify like the literals they hold) — and the message names
  # both. `kind` ("component", the default, or "event") names the
  # calling DSL in the message.
  def self.__reject_noop(v, ctx, kind = "component")
    if v.equal?(NOOP_RESULT)
      raise ArgumentError, "Labelle." + kind + ": " + ctx + ": Labelle.* helpers and non-primitive " \
                           "cross-file constants cannot be used in " + kind + " specs — " \
                           "declare-mode fields are literals"
    end
    nil
  end

  # ── the live call: Labelle.component(name, spec[, opts]) ─────────────
  # Ruby's trailing-hash sugar makes the RFC line read bare:
  #   Hunger = Labelle.component "Hunger", level: 0.875, starving: false
  # (the keywords collapse into the spec hash); with options the spec
  # hash is braced and the opts hash trails:
  #   Tag = Labelle.component "Tag", { kind: "none" }, persist: "transient"
  # Validates, records, and returns the SAME view class shape the runtime
  # prelude returns (Struct-backed, component_name/component_fields), so
  # chunk-scope `Hunger = Labelle.component(...)` binds one consistent
  # value in both modes.
  def self.component(name, spec = nil, opts = nil)
    unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "Labelle.component: expected a non-empty component name string"
    end
    unless __identifier?(name)
      raise ArgumentError, "Labelle.component: component name '" + name +
                           "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)"
    end
    __reject_noop(spec, "component '" + name + "' spec")
    unless spec.is_a?(Hash)
      raise ArgumentError, "Labelle.component: component '" + name +
                           "' expects a spec Hash of field defaults"
    end
    if @by_name.key?(name)
      raise ArgumentError, "Labelle.component: duplicate component '" + name +
                           "' (first declared in " + @by_name[name] + ")"
    end

    persist = "persistent"
    unless opts.nil?
      __reject_noop(opts, "component '" + name + "' options")
      unless opts.is_a?(Hash)
        raise ArgumentError, "Labelle.component: component '" + name + "' options must be a Hash"
      end
      opts.each do |k, v|
        ks = k.is_a?(Symbol) ? k.to_s : k
        unless ks == "persist"
          raise ArgumentError, "Labelle.component: component '" + name + "' has an unknown option '" +
                               k.to_s + "' (v1 knows only persist)"
        end
        vs = v.is_a?(Symbol) ? v.to_s : v
        unless vs == "persistent" || vs == "transient"
          raise ArgumentError, "Labelle.component: component '" + name + "' has an invalid persist value '" +
                               v.to_s + "' (expected \"persistent\" or \"transient\")"
        end
        persist = vs
      end
    end

    # The view fast path's cap, enforced where the failure can name the
    # declaration: past it, the SAME line's runtime half would construct a
    # view whose every get_into/set raises (bindings.zig MAX_REF_FIELDS).
    if spec.size > MAX_VIEW_FIELDS
      raise ArgumentError, "Labelle.component: component '" + name + "' has " + spec.size.to_s +
                           " fields — the ruby view fast path supports at most " +
                           MAX_VIEW_FIELDS.to_s + " fields; split the component"
    end

    fields = []      # [[name, type, default-json], ...] — sorted below
    view_fields = [] # symbols, spec insertion order (the runtime view's order)
    seen = {}        # symbol and string keys normalize to one field name
    spec.each do |k, v|
      ks = k.is_a?(Symbol) ? k.to_s : k
      unless __identifier?(ks)
        raise ArgumentError, "Labelle.component: component '" + name + "' field '" + k.to_s +
                             "' is not a valid identifier"
      end
      if seen.key?(ks)
        raise ArgumentError, "Labelle.component: component '" + name + "' field '" + ks +
                             "' is declared twice (a symbol and a string key normalize to the same field)"
      end
      seen[ks] = true
      __reject_noop(v, "component '" + name + "' field '" + ks + "'")
      t, j = __classify("component '" + name + "' field '" + ks + "'", v)
      fields << [ks, t, j]
      view_fields << ks.to_sym
    end
    fields.sort! { |a, b| a[0] <=> b[0] }

    frag = '{"name":' + __quote(name) + ',"persist":"' + persist + '","fields":['
    i = 0
    while i < fields.size
      f = fields[i]
      frag << "," if i > 0
      frag << '{"name":' << __quote(f[0]) << ',"type":"' << f[1] << '","default":' << f[2] << "}"
      i += 1
    end
    frag << "]}"

    @decls << [name, frag]
    @by_name[name] = @file

    __view_class(name, view_fields)
  end

  # ── the live call: Labelle.event(name, spec) ─────────────────────────
  # The component recorder minus persistence (labelle-engine#772). Ruby's
  # trailing-hash sugar makes the RFC line read bare:
  #   HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
  # Same identifier rules, same __classify vocabulary (Labelle.id
  # included), fields sorted by name — but NO options argument (events are
  # never saved: a third arg is a pointed error, not a persist knob) and a
  # SEPARATE namespace (an event may share a component's name; duplicates
  # are checked per kind). Returns the frozen event-name string — the same
  # value the runtime prelude returns — so the chunk-scope constant binds
  # one consistent value in both modes.
  def self.event(name, spec = nil, opts = nil)
    unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "Labelle.event: expected a non-empty event name string"
    end
    unless __identifier?(name)
      raise ArgumentError, "Labelle.event: event name '" + name +
                           "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)"
    end
    unless opts.nil?
      raise ArgumentError, "Labelle.event: event '" + name +
                           "' takes no options (events are not persisted)"
    end
    __reject_noop(spec, "event '" + name + "' spec", "event")
    unless spec.is_a?(Hash)
      raise ArgumentError, "Labelle.event: event '" + name +
                           "' expects a spec Hash of field defaults ({} for a payloadless event)"
    end
    if @events_by_name.key?(name)
      raise ArgumentError, "Labelle.event: duplicate event '" + name +
                           "' (first declared in " + @events_by_name[name] + ")"
    end

    # Event payloads share the view fast path's field ceiling — one
    # schema, whatever the language (the lua runner enforces the same 32
    # through its MAX_EVENT_FIELDS twin literal).
    if spec.size > MAX_VIEW_FIELDS
      raise ArgumentError, "Labelle.event: event '" + name + "' has " + spec.size.to_s +
                           " fields — event payloads support at most " +
                           MAX_VIEW_FIELDS.to_s + " fields; split the event"
    end

    fields = [] # [[name, type, default-json], ...] — sorted below
    seen = {}   # symbol and string keys normalize to one field name
    spec.each do |k, v|
      ks = k.is_a?(Symbol) ? k.to_s : k
      unless __identifier?(ks)
        raise ArgumentError, "Labelle.event: event '" + name + "' field '" + k.to_s +
                             "' is not a valid identifier"
      end
      if seen.key?(ks)
        raise ArgumentError, "Labelle.event: event '" + name + "' field '" + ks +
                             "' is declared twice (a symbol and a string key normalize to the same field)"
      end
      seen[ks] = true
      __reject_noop(v, "event '" + name + "' field '" + ks + "'", "event")
      t, j = __classify("event '" + name + "' field '" + ks + "'", v)
      fields << [ks, t, j]
    end
    fields.sort! { |a, b| a[0] <=> b[0] }

    # No "persist" key on purpose — the schema shape is the contract, and
    # events carry none.
    frag = '{"name":' + __quote(name) + ',"fields":['
    i = 0
    while i < fields.size
      f = fields[i]
      frag << "," if i > 0
      frag << '{"name":' << __quote(f[0]) << ',"type":"' << f[1] << '","default":' << f[2] << "}"
      i += 1
    end
    frag << "]}"

    @event_decls << [name, frag]
    @events_by_name[name] = @file

    name.freeze
  end

  # The id field marker's accessor (see ID_SENTINEL above). No-arg only:
  # v1 has no id(value) constructor — id fields always default 0, so an
  # argument is a declaration mistake worth naming.
  def self.id(*args)
    unless args.empty?
      raise ArgumentError, "Labelle.id: takes no arguments (v1: id fields always default 0)"
    end
    ID_SENTINEL
  end

  # ── declare-mode Labelle.on / Labelle.emit: name-checked no-ops ──────
  # Explicit defs (method_missing never sees them) that still subscribe
  # and emit NOTHING — extra arguments are swallowed, blocks are ignored
  # and never called, and both return the spec-position-rejected sentinel
  # like every other no-op — but the event NAME is validated the way the
  # RUNTIME bindings validate it: raw_event_subscribe/raw_event_emit read
  # the name as an mruby String (src/ruby/bindings.zig, mrb_get_args
  # "s"), so a non-String there raises and EVICTS the script at runtime.
  # Without this check a real constant of the WRONG KIND — a component
  # where an event was meant, `Labelle.on(Worker)` — extracted clean and
  # only died in the running game. Event constants pass by construction:
  # Labelle.event returns the name STRING and the driver's ledger seeds
  # primitive constants verbatim, so a cross-file `Labelle.on(HungerFeed)`
  # arrives here as the real name.
  def self.__require_event_name(callee, name)
    return if name.is_a?(String)
    # (component_name must BE a string: the NoopCalls-stubbed classes
    # answer respond_to? for everything and would hand back the
    # sentinel.)
    got = if name.equal?(NOOP_RESULT)
            "a Labelle.* helper result or non-primitive cross-file constant"
          elsif name.is_a?(Class) && name.respond_to?(:component_name) &&
                name.component_name.is_a?(String)
            "the component '" + name.component_name + "'"
          else
            name.class.to_s
          end
    raise ArgumentError, "Labelle." + callee + ": expected an event-name String — got " + got +
                         " (events subscribe and emit by name; a component constant is not " \
                         "an event name)"
  end

  def self.on(name, *_rest, **_kw, &_blk)
    __require_event_name("on", name)
    NOOP_RESULT
  end

  def self.emit(name, *_rest, **_kw, &_blk)
    __require_event_name("emit", name)
    NOOP_RESULT
  end

  # Every OTHER Labelle.* module call — log/array/u64str/spawn/each/...
  # — resolves here: neither runs nor errors ("only declarations matter
  # at build time"), and the sentinel it returns is rejected in spec
  # positions.
  def self.method_missing(_m, *_args, &_blk)
    NOOP_RESULT
  end

  def self.respond_to_missing?(_m, _priv = false)
    true
  end

  # ── the runtime API's classes, stubbed ───────────────────────────────
  # These are the names real game scripts touch at CHUNK SCOPE (the code
  # declare mode executes): `Labelle::Component.ref(...)` constant
  # bindings, `class Foo < Labelle::Controller` definitions, and — since
  # labelle-engine#772 — constants OTHER declaration files bind
  # (`Labelle.on(HungerFeed)` at file scope, `HungerFeed` declared in
  # events/hunger__feed.rb: at runtime ONE VM registers components →
  # events → scripts and top-level constants are VM-global, but this
  # runner evaluates every chunk in a FRESH state, so a cross-file
  # constant cannot resolve by itself). Class-level calls no-op to the
  # sentinel (`new` must be overridden explicitly — it exists on every
  # Class, so method_missing alone would never see it); cross-file
  # constants resolve because the driver re-binds every EARLIER file's
  # harvested constants into this chunk's state (the constant-ledger
  # seams above) — primitives verbatim (event-name strings included),
  # everything else as the inert sentinel, tolerated in call positions
  # and rejected in spec positions. A constant NO earlier file defined
  # stays a plain NameError at extract (typos fail at generate), and
  # anything DEEPER than a call position fails loudly.

  module NoopCalls
    def method_missing(_m, *_args, &_blk)
      NOOP_RESULT
    end

    def respond_to_missing?(_m, _priv = false)
      true
    end

    def new(*_args, &_blk)
      NOOP_RESULT
    end
  end

  class Component
    extend NoopCalls
  end

  class Entity
    extend NoopCalls
  end

  class FrameArray
    extend NoopCalls
  end

  # Subclassable for real (chunk bodies DEFINE controller classes; nothing
  # ever instantiates or ticks them here — Class#inherited's default is a
  # no-op, so registration simply doesn't happen).
  class Controller
  end

  # ── the view class the live call returns ─────────────────────────────
  # The runtime return's mimic (src/ruby/prelude.rb Component.__view):
  # Struct-backed with component_name/component_fields, a plain marker
  # class when the spec is empty — so chunk-scope code holding the result
  # sees the same shape in both modes.

  module ComponentInstance
    def component_name
      self.class.component_name
    end
  end

  module ComponentClass
    def component_name
      instance_variable_get(:@__labelle_component_name)
    end

    def component_fields
      instance_variable_get(:@__labelle_component_fields)
    end
  end

  def self.__view_class(name, fields)
    k = fields.empty? ? Class.new : Struct.new(*fields)
    k.send(:include, ComponentInstance)
    k.extend(ComponentClass)
    k.instance_variable_set(:@__labelle_component_name, name)
    k.instance_variable_set(:@__labelle_component_fields, fields.freeze)
    k
  end
end

# Baseline snapshot AFTER the whole stub is defined: every constant on
# Object right now (the interpreter's boot set plus `Labelle` itself) is
# prelude-owned; whatever a chunk body adds beyond it is the chunk's own
# — the harvest set the driver replays into later chunks (the
# constant-ledger seams above). NO global Module#const_missing on
# purpose: an interim revision resolved EVERY unresolved constant to the
# sentinel, which made a TYPO'd constant (`Labelle.on(HngerFeed)`)
# extract silently and only fail at RUNTIME as a script eviction. With
# the ledger, only constants an earlier file really defined resolve
# (primitives to their real values, the rest to the inert sentinel);
# a genuinely unknown constant NameErrors at extract with the chunk's
# file:line, exactly like the runtime VM.
Labelle.__record_const_baseline
