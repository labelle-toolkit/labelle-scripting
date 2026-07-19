# prelude.rb — the ruby-side half of labelle-scripting.
#
# bindings.zig installs the raw shims (`Labelle.raw_*`, thin 1:1 bridges to
# the Script Runtime Contract, plus the Zig-side JSON codec) and then runs
# this chunk, which builds the friendly API on top: Entity, Component.ref,
# Controller, FrameArray, events. Everything here is pure sugar over
# `Labelle.raw_*` — the raw shims stay reachable on purpose.
#
# Entity-id rule (same as lua): ids are u64 on the host but live in ruby
# as the SIGNED 64-bit bitcast (mrb_int). Lossless for math, Hash keys and
# every raw_* call — but embed ids in payloads via Labelle.u64str(id);
# plain interpolation would sign-flip bit-63 ids. The decode leg needs no
# opt-in: integer payload tokens parse (in Zig) with wrapping 64-bit
# arithmetic, landing bit-exact on the same signed bitcast.
#
# Method harvest: mruby has no lua-style per-chunk _ENV, so EVERY
# top-level `def` — the init/update/deinit hooks and any helper — lands as
# a private method on Object, shared by all scripts: same-named hooks
# would collide, and a later script's `def helper` would hijack an earlier
# script's harvested hooks (their receivers inherit from Object).
# __harvest (called by vm.zig after each chunk body) therefore moves ALL
# methods the body freshly defined — diffed against the install-time
# baseline of Object's own method set — onto the script's private record:
# each is aliased to a per-script name on Object, removed under its
# original name, and aliased BACK under the original name on the script's
# receiver's singleton class, so intra-script calls (`helper(...)` from
# `update`) keep working, invisibly to every other script. Hooks dispatch
# as receiver.send(aliased, ...); each script's @ivars live on its own
# receiver (set them in `init`, not at body scope — body-level self is
# `main`, which hooks do not run against). Known limit: REdefining a
# method that existed at baseline (a core method, say) is not harvested
# and leaks globally — don't.
#
# Ownership: Labelle.on and Controller subclassing record WHICH script
# registered them by reading $__labelle_current_script — the global vm.zig
# stamps (as a Symbol) around every VM→script entry, the VM-truth "whose
# code is running"; dispatch re-stamps around each handler / controller
# call. When a script is evicted (body or init failure), __evict_script
# purges its hooks, its handlers AND its controllers, so nothing keeps
# firing into dead state.

module Labelle
  # ── logging / time / scene / spawn sugar ─────────────────────────────

  def self.log(msg)
    raw_log(msg.to_s)
  end

  def self.time_dt
    raw_time_dt
  end

  def self.scene_change(name)
    raw_scene_change(name) == 0
  end

  # Render an entity id as its unsigned decimal string — use this to embed
  # ids in payloads ({ owner: Labelle.u64str(e.id) }); `e.id` itself stays
  # a plain Integer for math and raw_* calls.
  def self.u64str(id)
    raise ArgumentError, "Labelle.u64str: expected an entity id (Integer)" unless id.is_a?(Integer)
    raw_u64str(id)
  end

  def self.json_encode_payload(payload)
    payload.nil? ? "" : json_encode(payload)
  end

  # ── one DSL, two consumers (the lua component-ref rule, ruby spelling) ─
  # `Hunger = Labelle.component "Hunger", level: 0.875, starving: false`
  # is a SCHEMA DECLARATION at build time — the labelle-declare-ruby
  # runner (tools/declare-ruby) extracts it at `labelle generate` and the
  # assembler codegens a real Zig registry component — and, at runtime,
  # evaluates to a Component.ref-EQUIVALENT view class built from the
  # spec's KEYS (field order = spec insertion order; a spec-less or
  # empty-spec call yields a zero-field marker view for set/has?/remove).
  # The spec's VALUES and the opts hash are the build-time contract and
  # are deliberately ignored here: the component already exists in the
  # game's registry (fields, defaults, persist policy) because the build
  # saw the same line. Options ride a separate trailing hash, exactly like
  # lua's third argument:
  #   Tag = Labelle.component "Tag", { kind: "none" }, persist: "transient"
  # Component.ref (below) stays the explicit-fields spelling of the same
  # view class — `Labelle.component "H", level: 0.0` and
  # `Labelle::Component.ref("H", :level)` return interchangeable classes.
  def self.component(name, spec = nil, opts = nil)
    unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "Labelle.component: expected a non-empty component name string"
    end
    _ = opts # build-time contract; unused at runtime
    fields = []
    spec.each_key { |k| fields << k.to_sym } if spec.is_a?(Hash)
    Component.__view(name, fields)
  end

  # Declare a game EVENT (one DSL, two consumers — the Labelle.component
  # rule for the event bus, labelle-engine#772):
  #   HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
  # is a SCHEMA DECLARATION at build time — `labelle generate` runs the
  # declare runner over the game's events/*.rb files (and scripts) and
  # the assembler (v0.87.0+) codegens the extracted schema into one
  # generated scripting_events.zig at the target root, backing a real
  # event-union row. At RUNTIME — here — the same call validates the
  # name and returns it as a FROZEN String, so the one constant drives
  # both legs of the bus: Labelle.emit(HungerFeed, entity: id) and
  # Labelle.on(HungerFeed) (both take event-name strings; a frozen one is
  # just a string that can't be mutated out from under the subscription).
  # The spec — and anything after it — is the build-time contract and is
  # deliberately ignored: the generated event already exists in the
  # game's event union by the time this line runs. Events are never
  # persisted, so there is no options argument (the declare runner
  # rejects a third argument outright).
  def self.event(name, _spec = nil, *_rest)
    unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "Labelle.event: expected a non-empty event name string"
    end
    name.freeze
  end

  # The id FIELD marker for event/component specs: at build time
  # `entity: Labelle.id` classifies the field as u64 (the entity-id type)
  # with default 0; at runtime it returns plain 0 so the same spec line
  # evaluates clean in both modes. v1: id fields always default 0 — there
  # is no id(value) constructor, so arguments are an error here exactly
  # as they are at declare time.
  def self.id(*args)
    unless args.empty?
      raise ArgumentError, "Labelle.id: takes no arguments (v1: id fields always default 0)"
    end
    0
  end

  # Spawn a prefab; params is an optional {x:, y:} Hash. Returns an Entity
  # or nil on failure.
  def self.spawn(prefab, params = nil)
    id = raw_prefab_spawn(prefab, json_encode_payload(params))
    id == 0 ? nil : Entity.wrap(id)
  end

  # Emit a game event by union-tag name. Payload is a Hash argument or
  # kwargs — `Labelle.emit("fired", turret: id)` — nil/empty means "all
  # defaults". Returns true when the host accepted it.
  def self.emit(name, payload = nil, **kw)
    payload = kw if payload.nil? && !kw.empty?
    raw_event_emit(name, json_encode_payload(payload)) == 0
  end

  # ── events: subscribe + dispatch ─────────────────────────────────────

  # Subscribe a block to a game event by name. The payload arrives as a
  # symbol-keyed Hash ({} for empty payloads). Multiple handlers per name
  # fan out in registration order. The registering SCRIPT owns the handler
  # (see the ownership note above): when it is evicted, its handlers are
  # purged and never fire again.
  def self.on(name, &blk)
    raise ArgumentError, "Labelle.on requires a block" unless blk
    raw_event_subscribe(name)
    @handlers ||= {}
    (@handlers[name] ||= []) << [blk, $__labelle_current_script]
  end

  # Drain the event inbox, dispatching each entry to its handlers. The
  # shared Controller calls this once at tick start, BEFORE script updates.
  # Handlers are ISOLATED: each runs under its own rescue — a raising
  # handler is logged (event, owner, backtrace) and the fan-out AND the
  # drain continue. Each handler runs with $__labelle_current_script set
  # to its owner (and restored), so a handler that registers handlers
  # attributes them correctly.
  def self.dispatch_inbox
    while (entry = raw_event_poll)
      name = entry[0]
      hs = @handlers && @handlers[name]
      next unless hs
      payload = entry[1]
      i = 0
      while i < hs.size
        h = hs[i]
        saved = $__labelle_current_script
        $__labelle_current_script = h[1]
        begin
          h[0].call(payload)
        rescue Exception => e
          raw_log("[ruby] event '#{name}' handler (owner '#{h[1]}') failed: #{e.class}: #{e.message}\n  backtrace: #{(e.backtrace || []).join(' | ')}")
        end
        $__labelle_current_script = saved
        i += 1
      end
    end
  end

  # ── queries ──────────────────────────────────────────────────────────

  # Yield an Entity for every entity carrying ALL the named components:
  #   each("Hunger", "Worker") { |e| ... }
  # Snapshot semantics: the id list is captured up front, so spawning or
  # destroying entities inside the block is safe. The SAME wrapper object
  # is reused across iterations (stash e.id, never e itself).
  def self.each(*names)
    ids = raw_query(json_encode(names))
    e = Entity.wrap(0)
    i = 0
    while i < ids.size
      e.id = ids[i]
      yield e
      i += 1
    end
    nil
  end

  # ── batched query (the whole-query fast path) ────────────────────────
  # `batch_get(names, arr)` fills `arr` with every matching entity's scalar
  # component data as a flat f32 array — [c0_f0, c0_f1, ..., c1_f0, ...] per
  # entity, components in `names` order, fields in declaration order — and
  # returns the entity COUNT (`arr` is trimmed to exactly count*stride).
  # ONE FFI crossing for the whole query instead of a get per entity. Reuse
  # the SAME `arr` across ticks (it grows once, keeps its capacity).
  # `batch_set(names, arr, n)` writes the mutated `arr` back in ONE crossing
  # (the host re-queries the same entities, same order). The caller owns the
  # positional layout: the stride (fields-per-entity) must match how the
  # host walks the named components.
  #
  # Refusals are LOUD (contract v1.3):
  #   - a named component with an INT-typed field raises ArgumentError —
  #     i64/u64 cannot ride the f32 stream without silent corruption; keep
  #     such components on per-entity get/set (their packed codec is
  #     lossless).
  #   - do NOT spawn or destroy entities between a paired batch_get and
  #     batch_set: batch_set raises RuntimeError when the entity set no
  #     longer matches the buffer (re-run batch_get and recompute).
  #   - on a game built against a pre-v1.3 engine (labelle-engine < 2.6.0)
  #     BOTH calls raise RuntimeError ("host engine lacks batch support")
  #     — there is no batch fallback; use per-entity get/set there. The
  #     per-entity into:/set fast paths degrade to JSON silently instead.
  def self.batch_get(names, arr)
    raw_batch_get(json_encode(names), arr)
  end

  def self.batch_set(names, arr, n)
    raw_batch_set(json_encode(names), arr, n)
  end

  # ── batch block iterator (the ergonomic layer over batch_get/set) ────
  # `Labelle.batch(names) { |e| ... }` — ONE batch_get, the block runs
  # once per matching entity against a single REUSED view object, then
  # ONE batch_set writes everything back. No per-entity FFI and no
  # per-entity allocation: the view is one object whose backing offset
  # moves between yields (stash values, never `e` itself — the object
  # you saved points at whatever entity was yielded last).
  #
  #   Labelle.batch(["Position", "Velocity"]) do |e|
  #     e.x += e.vx; e.y += e.vy
  #     e.vx = -e.vx if e.x < 0.0 || e.x > 800.0
  #   end
  #
  # Accessors are the components' FIELD NAMES in stream order (components
  # in `names` order, fields in declaration order — the same walk
  # batch_get lays the stream out with). Reads return Floats (bools ride
  # as 0.0/1.0, like the raw stream); writes take numbers. Returns the
  # entity count. An empty query returns 0 without touching the block. A
  # RAISING block abandons the whole write — batch_set never runs, no
  # entity is touched (all-or-nothing, safe to rescue and retry). The raw
  # pairing rules apply to the block form too: no spawn/destroy inside
  # the block, and no nested Labelle.batch over the same names (it would
  # refill the shared buffer mid-iteration).
  #
  # How the view learns the layout (stage-2 design decision): the field
  # list is derived ON FIRST USE per names-set, in pure ruby, from a JSON
  # `raw_component_get` of each named component on the first matched
  # entity — the host serializes struct fields in DECLARATION order, the
  # exact order the batch stream walks, and non-scalar values (strings /
  # objects / arrays / nil) are filtered out just as the stream skips
  # non-scalar fields. No extra contract surface, and any way the probe
  # could disagree with the stream (an optional field, say) is caught by
  # a hard cross-check against the stream's real stride before the first
  # yield — a mismatch raises, never mis-maps. The derived view class is
  # cached per names-set: steady state is batch_get + N yields +
  # batch_set, nothing else.
  #
  # Refusals (on top of batch_get/batch_set's own, which pass through
  # unchanged — int-typed fields, entity-set drift, pre-v1.3 hosts):
  #   - a field name duplicated across the named components raises
  #     ArgumentError (the accessors could not disambiguate);
  #   - a derived layout that does not match the stream's stride raises
  #     RuntimeError (use the raw batch_get/batch_set flat loop there).
  #
  # WHEN TO USE (measured, 2000-entity integrate+bounce, ReleaseFast,
  # engine 2.6.0): the block form costs ~1.9× the raw flat loop
  # (1.25 ms/tick = 624 ns/entity vs 0.64 ms/tick = 321 ns/entity — the
  # per-entity yield + accessor dispatch, unavoidable in an interpreter)
  # but stays ~4.3× faster than naive per-entity get/set (5.37 ms/tick).
  # Reach for the block by default; drop to the batch_get/batch_set flat
  # loop for the hottest loops; never per-entity get/set over thousands.
  #
  # Stage-3 porters (lua/js/…): copy this shape — derive the field walk
  # from one per-component get of the first matched entity, cross-check
  # the stride, cache a reused view keyed by the names-set, yield it with
  # a moving base offset, write back once. JIT'd runtimes can expect the
  # closure to inline and approach flat-loop speed.
  def self.batch(names)
    raise ArgumentError, "Labelle.batch requires a block" unless block_given?
    st = ((@batch_iters ||= {})[names.join("\x00")] ||= [[], nil, 0])
    buf = st[0]
    count = batch_get(names, buf)
    return 0 if count == 0
    view = st[1]
    unless view
      view, st[2] = __batch_view(names, buf, count)
      st[1] = view
    end
    stride = st[2]
    unless buf.size == count * stride
      raise RuntimeError, "labelle: Labelle.batch(#{names.inspect}): derived layout " \
                          "(#{stride} fields per entity) does not match the host stream " \
                          "(#{buf.size} floats / #{count} entities) — a field the stream " \
                          "skips (non-scalar) confused the layout probe; use " \
                          "batch_get/batch_set with explicit offsets for these components"
    end
    b = 0
    i = 0
    while i < count
      view.__labelle_base = b
      yield view
      b += stride
      i += 1
    end
    batch_set(names, buf, count)
    count
  end

  # Build the reused per-entity view for a names-set: derive the field
  # walk (first-entity JSON probe, scalar values only — see the design
  # note on Labelle.batch), cross-check it against the stream stride,
  # then mint a class whose accessors read/write `buf` at a moving base
  # offset. Runs once per names-set; the load-time allocations are fine.
  def self.__batch_view(names, buf, count)
    ids = raw_query(json_encode(names))
    first = ids[0]
    fields = []
    i = 0
    while i < names.size
      nm = names[i].to_s
      i += 1
      s = raw_component_get(first, nm)
      next if s.nil? # cross-check below catches any inconsistency
      json_decode(s).each do |k, v|
        next unless v.is_a?(Float) || v.is_a?(Integer) || true == v || false == v
        if k.to_s.start_with?("__labelle")
          raise ArgumentError, "labelle: Labelle.batch(#{names.inspect}): field name " \
                               "'#{k}' collides with the view's internals — use " \
                               "batch_get/batch_set with explicit offsets"
        end
        if fields.include?(k)
          raise ArgumentError, "labelle: Labelle.batch(#{names.inspect}): field name " \
                               "'#{k}' appears in more than one named component — the " \
                               "block view cannot disambiguate; use batch_get/batch_set " \
                               "with explicit offsets"
        end
        fields << k
      end
    end
    stride = fields.size
    unless buf.size == count * stride
      raise RuntimeError, "labelle: Labelle.batch(#{names.inspect}): derived layout " \
                          "(#{stride} fields: #{fields.inspect}) does not match the host " \
                          "stream (#{buf.size} floats / #{count} entities) — a field the " \
                          "stream skips (non-scalar) confused the layout probe; use " \
                          "batch_get/batch_set with explicit offsets for these components"
    end
    klass = Class.new
    klass.send(:attr_writer, :__labelle_base)
    fields.each_with_index do |f, off|
      # each_with_index (not while) on purpose: each iteration gets a
      # fresh environment, so every accessor pair captures ITS f/off.
      klass.send(:define_method, f) { buf[@__labelle_base + off] }
      klass.send(:define_method, :"#{f}=") { |v| buf[@__labelle_base + off] = v }
    end
    view = klass.new
    view.__labelle_base = 0
    [view, stride]
  end

  # ── per-script method harvest (called by vm.zig) ─────────────────────

  # Baseline of Object's OWN (public + private) instance methods, taken
  # once at the end of the prelude chunk (and extended with each alias
  # __harvest mints). The harvest/evict invariant — every load ends with
  # all freshly defined methods moved off (or stripped from) Object —
  # keeps this baseline valid for the whole VM lifetime, so "what did
  # this body define?" is a plain set diff.
  def self.__record_baseline
    @baseline_methods = {}
    ms = Object.private_instance_methods(false) + Object.instance_methods(false)
    i = 0
    while i < ms.size
      @baseline_methods[ms[i]] = true
      i += 1
    end
    nil
  end

  # Object's own methods that are NOT in the baseline — i.e. whatever the
  # chunk body just defined at top level (load-time only, so the
  # allocations are fine).
  def self.__new_object_methods
    now = Object.private_instance_methods(false) + Object.instance_methods(false)
    added = []
    i = 0
    while i < now.size
      m = now[i]
      added << m unless @baseline_methods[m]
      i += 1
    end
    added
  end

  # After `name_sym`'s chunk body ran: move EVERY top-level method it
  # defined (hooks and helpers alike) onto its private record. The aliased
  # copy on Object keeps a unique per-script name (how dispatch and
  # eviction reach it), the original name leaves Object (the next script
  # starts clean), and the receiver's singleton class gets the original
  # name back (how the script's own code keeps calling its helpers).
  def self.__harvest(name_sym)
    @scripts ||= {}
    rec = { r: Object.new, h: {} }
    added = __new_object_methods
    i = 0
    while i < added.size
      m = added[i]
      i += 1
      aliased = :"__labelle_#{name_sym}_#{m}"
      Object.send(:alias_method, aliased, m)
      Object.send(:remove_method, m)
      rec[:r].singleton_class.send(:alias_method, m, aliased)
      rec[:h][m] = aliased
      # The alias itself is a NEW Object method — fold it into the
      # baseline immediately, or the NEXT script's diff would see it as
      # freshly defined and harvest it away from this script (dead alias
      # entries after an eviction are harmless: the diff only tests
      # membership of methods that currently exist).
      @baseline_methods[aliased] = true
    end
    @scripts[name_sym] = rec
    nil
  end

  # Dispatch one hook of one script. :missing (not a failure) when the
  # script or hook is unknown — the Controller treats only a RAISE as
  # failure, and that surfaces through mrb->exc at the funcall boundary.
  # Steady-state cost: two Hash lookups and a send — no allocation.
  def self.__call_hook(name_sym, hook_sym, dt)
    rec = @scripts && @scripts[name_sym]
    return :missing unless rec
    m = rec[:h][hook_sym]
    return :missing unless m
    if dt.nil?
      rec[:r].send(m)
    else
      rec[:r].send(m, dt)
    end
    :ok
  end

  # Eviction (body or init failure): drop the script's harvested methods
  # (their Object-level aliases), purge its event handlers, and drop its
  # controllers — registered classes and live instances both.
  def self.__evict_script(name_sym)
    if @scripts && (rec = @scripts[name_sym])
      rec[:h].each_value { |m| Object.send(:remove_method, m) }
      @scripts.delete(name_sym)
    end
    # A body that raised left its top-level defs sitting RAW on Object
    # (its harvest never ran). Strip everything off-baseline, or the NEXT
    # script's harvest would adopt the leftovers as its own — a dead
    # script's deinit running under a live script's name. Every properly
    # loaded script's methods were already moved to aliased names, so
    # off-baseline names here can only be the evictee's.
    leftovers = __new_object_methods
    i = 0
    while i < leftovers.size
      Object.send(:remove_method, leftovers[i])
      i += 1
    end
    __purge_handlers(name_sym)
    @controller_classes = __reject_owned(@controller_classes, name_sym)
    @controllers = __reject_owned(@controllers, name_sym)
    nil
  end

  # Drop every event handler `name_sym` registered. Owner-less handlers
  # (owner nil — prelude/host-registered) never match a purge.
  def self.__purge_handlers(name_sym)
    return if name_sym.nil? || @handlers.nil?
    @handlers.each_value do |hs|
      i = hs.size - 1
      while i >= 0
        hs.delete_at(i) if hs[i][1] == name_sym
        i -= 1
      end
    end
    nil
  end

  def self.__reject_owned(list, name_sym)
    return list if list.nil?
    kept = []
    i = 0
    while i < list.size
      kept << list[i] unless list[i][1] == name_sym
      i += 1
    end
    kept
  end

  # Per-event-name handler counts — the rollback point a controller setup
  # is bracketed by. Finer than script ownership on purpose: a failed
  # setup must take out exactly the handlers IT registered, not its
  # script's other handlers (init-registered ones, or a sibling
  # controller's from the same script).
  def self.__handlers_snapshot
    snap = {}
    if @handlers
      keys = @handlers.keys
      i = 0
      while i < keys.size
        k = keys[i]
        snap[k] = @handlers[k].size
        i += 1
      end
    end
    snap
  end

  # Drop every handler registered since `snap` was taken. Registration
  # only ever APPENDS (Labelle.on), so truncating each list back to its
  # snapshot length — and deleting lists that didn't exist — is exact.
  def self.__handlers_rollback(snap)
    return if @handlers.nil?
    keys = @handlers.keys
    i = 0
    while i < keys.size
      k = keys[i]
      i += 1
      hs = @handlers[k]
      before = snap[k] || 0
      hs.pop while hs.size > before
      @handlers.delete(k) if hs.empty?
    end
    nil
  end

  # ── controllers (the structured tier) ────────────────────────────────

  # Subclassing Labelle::Controller registers the class (convention over
  # config — ruby's `inherited` hook), owned by the defining script.
  # Registration order = script load order = the file-prefix order the
  # generated registerScript calls arrive in.
  def self.__register_controller(klass)
    (@controller_classes ||= []) << [klass, $__labelle_current_script]
  end

  # Instantiate + set up every registered controller, registration order.
  # A raising initialize/setup evicts that CONTROLLER (logged; no tick, no
  # teardown) — its script and sibling controllers keep running — and
  # rolls back any `on(...)` handlers the failed setup registered before
  # raising: without the rollback they would keep firing into the dead
  # instance on every later dispatch.
  def self.__setup_controllers
    @controllers = []
    cs = @controller_classes || []
    i = 0
    while i < cs.size
      klass, owner = cs[i]
      i += 1
      saved = $__labelle_current_script
      $__labelle_current_script = owner
      snap = __handlers_snapshot
      begin
        inst = klass.new
        inst.setup
        @controllers << [inst, owner]
      rescue Exception => e
        __handlers_rollback(snap)
        raw_log("[ruby] controller #{klass} setup failed — controller evicted: #{e.class}: #{e.message}\n  backtrace: #{(e.backtrace || []).join(' | ')}")
      end
      $__labelle_current_script = saved
    end
    nil
  end

  # Tick controllers in registration order, after per-script updates. A
  # raising tick is logged and does NOT evict (state is intact; the author
  # gets the error every tick until it's fixed — the update-hook policy).
  def self.__tick_controllers(dt)
    cs = @controllers
    return unless cs
    i = 0
    while i < cs.size
      inst, owner = cs[i]
      i += 1
      saved = $__labelle_current_script
      $__labelle_current_script = owner
      begin
        inst.tick(dt)
      rescue Exception => e
        raw_log("[ruby] controller #{inst.class} tick failed: #{e.class}: #{e.message}\n  backtrace: #{(e.backtrace || []).join(' | ')}")
      end
      $__labelle_current_script = saved
    end
    nil
  end

  # Teardown in REVERSE registration order (LIFO), rescue-isolated, before
  # the per-script deinit hooks run.
  def self.__teardown_controllers
    cs = @controllers
    return unless cs
    i = cs.size - 1
    while i >= 0
      inst, owner = cs[i]
      i -= 1
      saved = $__labelle_current_script
      $__labelle_current_script = owner
      begin
        inst.teardown
      rescue Exception => e
        raw_log("[ruby] controller #{inst.class} teardown failed: #{e.class}: #{e.message}\n  backtrace: #{(e.backtrace || []).join(' | ')}")
      end
      $__labelle_current_script = saved
    end
    @controllers = nil
  end
end

module Labelle
  # ── Entity ───────────────────────────────────────────────────────────
  # Thin id wrapper: components in and out as Hashes or Component.ref
  # instances, the JSON leg hidden. `e.id` stays public — events and raw
  # calls speak ids.
  class Entity
    attr_accessor :id

    def initialize(id)
      @id = id
    end

    # Wrap an existing entity id (e.g. one carried in an event payload).
    def self.wrap(id)
      new(id)
    end

    # Create a fresh empty entity; nil when the host refuses (not bound).
    def self.create
      id = Labelle.raw_entity_create
      id == 0 ? nil : new(id)
    end

    # Component read.
    #   get("Hunger")            → symbol-keyed Hash (nil when absent)
    #   get(Hunger)              → fresh Hunger ref instance (nil when absent)
    #   get(Hunger, into: @h)    → REFILLS @h in place and returns it
    def get(spec, into: nil)
      if spec.is_a?(Class)
        get_into(spec, into || spec.new)
      else
        s = Labelle.raw_component_get(@id, spec)
        s.nil? ? nil : Labelle.json_decode(s)
      end
    end

    # The positional spelling of `get(Klass, into: inst)` — refill `inst`
    # (a Component.ref instance) in place; nil when the component is
    # absent. This is the strict zero-allocation form: mruby materializes
    # keyword arguments per call, so the kwarg sugar above costs ~2 small
    # objects per read (arena-reclaimed each tick, but visible to a strict
    # allocation counter) while this one costs none — scalar field values
    # cross as immediates, and the component name is the ref class's own
    # stored string, so a hot loop touches no literals.
    def get_into(klass, inst)
      found = Labelle.raw_component_get_into(@id, klass.component_name, inst, klass.component_fields)
      found ? inst : nil
    end

    # Component write (REPLACE semantics; absent fields take declared
    # defaults).
    #   set("Hunger", level: 0.5)  — name + Hash (trailing keywords bundle)
    #   set("Hunger")              — all defaults ("{}")
    #   set(@h)                    — a Component.ref instance knows its
    #                                own component name and fields; the
    #                                allocation-free write twin of get_into
    # Returns true on success.
    def set(a, b = nil)
      if a.is_a?(String) || a.is_a?(Symbol)
        if b.is_a?(ComponentInstance)
          Labelle.raw_component_set_from(@id, a.to_s, b, b.class.component_fields) == 0
        else
          Labelle.raw_component_set(@id, a.to_s, Labelle.json_encode_payload(b)) == 0
        end
      elsif a.is_a?(ComponentInstance)
        Labelle.raw_component_set_from(@id, a.class.component_name, a, a.class.component_fields) == 0
      else
        raise ArgumentError, "Entity#set: expected a component name or a Component.ref instance"
      end
    end

    def has?(name)
      Labelle.raw_component_has(@id, name)
    end

    def remove(name)
      Labelle.raw_component_remove(@id, name) == 0
    end

    def destroy
      Labelle.raw_entity_destroy(@id)
    end
  end

  # ── Component views ──────────────────────────────────────────────────

  # Marker mixin carried by every Component.ref class — how Entity#set
  # recognizes instances that know their own component name.
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

  class Component
    # The view fast path's field cap — MUST equal MAX_REF_FIELDS in
    # src/ruby/bindings.zig (raw_component_get_into/set_from size their
    # per-call field buffers by it) and the declare prelude's twin literal
    # (tools/declare-ruby/declare_prelude.rb). Enforced at CONSTRUCTION so
    # an over-wide view fails on its defining line, not as a late raise
    # inside every get/set; the declare runner rejects the same
    # declaration at build time. Different languages, so no shared source:
    # tests/declare_ruby_tool.zig's drift pin reads all three literals out
    # of their sources and asserts equality.
    MAX_VIEW_FIELDS = 32

    # Build a VM-side view class for an engine component:
    #
    #   Hunger = Labelle::Component.ref("Hunger", :level, :starving)
    #   @h = Hunger.new                # once, in setup
    #   e.get(Hunger, into: @h)        # refill in place — zero alloc
    #   @h.level -= decay * dt
    #   e.set(@h)                      # writes back to THIS entity
    #
    # Struct-backed (mruby-struct): fields map positionally to the
    # component's JSON keys, with plain attribute accessors. This is the
    # v0.2 explicit-fields API; `Labelle.component` (the declare-mode DSL's
    # runtime leg) derives the fields from its spec hash and builds the
    # SAME class through __view below.
    def self.ref(name, *fields)
      raise ArgumentError, "Component.ref needs at least one field" if fields.empty?
      __view(name, fields)
    end

    # The shared builder behind both spellings. Zero fields (a marker
    # component — Labelle.component with an empty/absent spec; ref refuses
    # the case) yields a plain class: `new` still mints instances that
    # know their component (set/has?/remove), and the get/set fast paths
    # simply have no fields to move.
    def self.__view(name, fields)
      if fields.size > MAX_VIEW_FIELDS
        raise ArgumentError, "labelle: component '#{name}' has #{fields.size} fields — " \
                             "the ruby view fast path supports at most #{MAX_VIEW_FIELDS} fields; " \
                             "split the component"
      end
      k = fields.empty? ? Class.new : Struct.new(*fields)
      k.send(:include, ComponentInstance)
      k.extend(ComponentClass)
      k.instance_variable_set(:@__labelle_component_name, name)
      k.instance_variable_set(:@__labelle_component_fields, fields.freeze)
      k
    end
  end

  # ── Controller ───────────────────────────────────────────────────────
  # The structured tier on top of plain per-script hooks: subclass, and
  # the class auto-registers (instances are created in file-prefix order
  # at the end of setup). Lifecycle: setup (subscriptions land here) /
  # tick(dt) / teardown (reverse order). All dispatch is rescue-isolated.
  class Controller
    def self.inherited(sub)
      Labelle.__register_controller(sub)
    end

    # Instance-side sugar so controller bodies read like the RFC:
    #   on("hunger__feed") { |ev| ... }
    #   each("Hunger", "Worker") { |e| ... }
    def on(name, &blk)
      Labelle.on(name, &blk)
    end

    def each(*names, &blk)
      Labelle.each(*names, &blk)
    end

    def batch(names, &blk)
      Labelle.batch(names, &blk)
    end

    def emit(name, payload = nil, **kw)
      Labelle.emit(name, payload, **kw)
    end

    def log(msg)
      Labelle.log(msg)
    end

    def entity(id)
      Entity.wrap(id)
    end

    # Default no-op lifecycle — override what you need.
    def setup; end

    def tick(dt); end

    def teardown; end
  end

  # ── FrameArray ───────────────────────────────────────────────────────
  # Per-frame scratch list, the clearRetainingCapacity idiom — shipped
  # because the naive port silently fails: mruby's Array#clear FREES the
  # heap buffer (resets to the embedded representation, unlike CRuby), so
  # a scratch array cleared with .clear reallocates every frame.
  # FrameArray keeps a preallocated backing plus a logical length:
  # `<<` is in-bounds index assignment (never reallocates), `clear` is
  # `len = 0` (the backing survives), and growth only happens when an
  # append overflows capacity — visible through growth_count, so a warmed
  # hot loop can assert it stays flat.
  class FrameArray
    attr_reader :size, :capacity, :growth_count

    def initialize(capacity)
      raise ArgumentError, "FrameArray capacity must be positive" unless capacity.is_a?(Integer) && capacity > 0
      @buf = Array.new(capacity)
      @capacity = capacity
      @size = 0
      @growth_count = 0
    end

    def <<(v)
      if @size == @capacity
        # Deliberate growth: double the backing (one reallocation), count
        # it. Steady-state reuse never comes back here.
        @capacity *= 2
        @buf[@capacity - 1] = nil
        @growth_count += 1
      end
      @buf[@size] = v
      @size += 1
      self
    end

    def push(v)
      self << v
    end

    def clear
      @size = 0
      self
    end

    def [](i)
      return nil if i.nil? || i < 0 || i >= @size
      @buf[i]
    end

    def []=(i, v)
      raise IndexError, "FrameArray index #{i} out of bounds (size #{@size})" if i < 0 || i >= @size
      @buf[i] = v
    end

    def each
      i = 0
      while i < @size
        yield @buf[i]
        i += 1
      end
      self
    end

    def empty?
      @size == 0
    end

    def to_a
      out = Array.new(@size)
      i = 0
      while i < @size
        out[i] = @buf[i]
        i += 1
      end
      out
    end
  end
end

# The harvest baseline — taken LAST, so it captures Object's method set
# exactly as scripts will first see it.
Labelle.__record_baseline
