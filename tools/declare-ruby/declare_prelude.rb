# declare_prelude.rb — the ruby half of the ruby declare-mode runner
# (labelle-declare-ruby; the lua runner's twin — see
# tools/declare/declare_prelude.lua for the reference semantics this file
# mirrors line for line where ruby can spell them).
#
# Declare mode is the build-time consumer of the component DSL: the SAME
# `Hunger = Labelle.component "Hunger", level: 0.875, starving: false`
# line that hands a script a Component.ref-equivalent view class at
# runtime (src/ruby/prelude.rb) is, here, a schema declaration. Only
# `Labelle.component` is live; every other `Labelle.*` call — and every
# call INTO the runtime API's classes (`Labelle::Component.ref`,
# `Labelle::Entity.create`, `Labelle::FrameArray.new`, ...) — is a silent
# no-op returning NOOP_RESULT, an identity-checked sentinel that
# `component` rejects if it lands in a spec position (helpers-as-data must
# fail the build, never silently drop or misparse). `Labelle::Controller`
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
#   Labelle.__declare_begin(file)       — stamp the chunk's path (the
#                                         lua __DECLARE_FILE twin)
#   Labelle.__declare_take              — after the chunk ran clean:
#                                         [name, fragment, ...] — this
#                                         chunk's declarations as
#                                         pre-formatted schema-JSON
#                                         component objects, declaration
#                                         order
# The Zig side accumulates fragments across chunks and emits
# {"components":[...]} — BYTE-compatible with the lua runner's
# __declare_emit (the cross-runner golden in tests/ pins it).
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
  # What every no-op returns. NOT nil: `Labelle.component("Path", {},
  # Labelle.array([]))` with a nil-returning no-op would silently declare
  # Path WITHOUT its intended options (nil opts == no opts), and a nil
  # field default would misreport as "unsupported default of type
  # NilClass" instead of naming the real mistake. Recognition is by
  # IDENTITY (equal?); the sentinel is deliberately inert — no
  # method_missing — so deeper chunk-scope use of a no-op result fails
  # loudly, mirroring the lua sentinel table's nil-on-index behavior.
  NOOP_RESULT = Object.new.freeze

  @decls = []     # [[name, fragment], ...] — THIS chunk's, declaration order
  @by_name = {}   # component name => file first declared in (seeded + local)
  @file = "?"

  # Largest finite f32, as a ruby Float (a double — same value the lua
  # prelude pins). INF is computed, not Float::INFINITY, to keep the
  # prelude independent of which constants the vendored gem set defines.
  F32_MAX = 3.4028235e38
  INF = 1.0 / 0.0

  # ── the Zig driver's three seams (extract.zig) ───────────────────────

  def self.__declare_seed(name, file)
    @by_name[name] = file
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
  # raise with `where` naming the component and field. The raise happens
  # inside the Labelle.component call chain, so the backtrace's script
  # frame is the declaration site.
  def self.__classify(where, v)
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
                         " (v1 supports number, boolean, string, and { x:, y: } vec2 hashes)"
  end

  # The pointed rejection for a helper result where a literal belongs.
  def self.__reject_noop(v, ctx)
    if v.equal?(NOOP_RESULT)
      raise ArgumentError, "Labelle.component: " + ctx + ": Labelle.* helpers cannot be used " \
                           "in component specs — declare-mode fields are literals"
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

    fields = []      # [[name, type, default-json], ...] — sorted below
    view_fields = [] # symbols, spec insertion order (the runtime view's order)
    spec.each do |k, v|
      ks = k.is_a?(Symbol) ? k.to_s : k
      unless __identifier?(ks)
        raise ArgumentError, "Labelle.component: component '" + name + "' field '" + k.to_s +
                             "' is not a valid identifier"
      end
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

  # Every OTHER Labelle.* module call — on/log/emit/array/u64str/spawn/
  # each/... — resolves here: neither runs nor errors ("only declarations
  # matter at build time"), and the sentinel it returns is rejected in
  # spec positions.
  def self.method_missing(_m, *_args, &_blk)
    NOOP_RESULT
  end

  def self.respond_to_missing?(_m, _priv = false)
    true
  end

  # ── the runtime API's classes, stubbed ───────────────────────────────
  # These are the names real game scripts touch at CHUNK SCOPE (the code
  # declare mode executes): `Labelle::Component.ref(...)` constant
  # bindings, `class Foo < Labelle::Controller` definitions. Class-level
  # calls no-op to the sentinel (`new` must be overridden explicitly — it
  # exists on every Class, so method_missing alone would never see it);
  # anything DEEPER fails loudly, like every other name outside the stub
  # surface (unknown constants included: no const_missing on purpose).

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
