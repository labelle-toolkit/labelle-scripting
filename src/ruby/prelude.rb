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
# Hook harvest: mruby has no lua-style per-chunk _ENV, so top-level
# `def init/update/deinit` land as private methods on Object — shared, and
# two scripts would collide. __harvest (called by vm.zig after each chunk
# body) moves any freshly defined hook to a per-script aliased name,
# removes the original, and records it against a per-script receiver
# object. Hooks then dispatch as receiver.send(aliased, ...), so scripts
# never see each other's hooks and each script's @ivars live on its own
# receiver (set them in `init`, not at body scope — body-level self is
# `main`, which hooks do not run against).
#
# Ownership: Labelle.on and Controller subclassing record WHICH script
# registered them by reading $__labelle_current_script — the global vm.zig
# stamps (as a Symbol) around every VM→script entry, the VM-truth "whose
# code is running"; dispatch re-stamps around each handler / controller
# call. When a script is evicted (body or init failure), __evict_script
# purges its hooks, its handlers AND its controllers, so nothing keeps
# firing into dead state.

module Labelle
  HOOK_NAMES = [:init, :update, :deinit]

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

  # ── per-script hook harvest (called by vm.zig) ───────────────────────

  # After `name_sym`'s chunk body ran: move any top-level init/update/
  # deinit it defined onto its private record. Aliased copies keep unique
  # names, the originals leave Object — the next script starts clean.
  def self.__harvest(name_sym)
    @scripts ||= {}
    probe = Object.new
    rec = { r: Object.new, h: {} }
    i = 0
    while i < HOOK_NAMES.size
      h = HOOK_NAMES[i]
      i += 1
      next unless probe.respond_to?(h, true)
      aliased = :"__labelle_#{name_sym}_#{h}"
      Object.send(:alias_method, aliased, h)
      Object.send(:remove_method, h)
      rec[:h][h] = aliased
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

  # Eviction (body or init failure): drop the script's harvested hooks
  # (and their Object-level aliases), purge its event handlers, and drop
  # its controllers — registered classes and live instances both.
  def self.__evict_script(name_sym)
    if @scripts && (rec = @scripts[name_sym])
      rec[:h].each_value { |m| Object.send(:remove_method, m) }
      @scripts.delete(name_sym)
    end
    # A body that raised left its top-level defs sitting RAW on Object
    # (its harvest never ran). Strip them, or the NEXT script's harvest
    # would adopt them as its own — a dead script's deinit running under
    # a live script's name. Every properly loaded script's hooks were
    # already moved to aliased names, so raw names here can only be the
    # evictee's.
    probe = Object.new
    i = 0
    while i < HOOK_NAMES.size
      h = HOOK_NAMES[i]
      i += 1
      Object.send(:remove_method, h) if probe.respond_to?(h, true)
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
  # teardown) — its script and sibling controllers keep running.
  def self.__setup_controllers
    @controllers = []
    cs = @controller_classes || []
    i = 0
    while i < cs.size
      klass, owner = cs[i]
      i += 1
      saved = $__labelle_current_script
      $__labelle_current_script = owner
      begin
        inst = klass.new
        inst.setup
        @controllers << [inst, owner]
      rescue Exception => e
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
    # Build a VM-side view class for an engine component:
    #
    #   Hunger = Labelle::Component.ref("Hunger", :level, :starving)
    #   @h = Hunger.new                # once, in setup
    #   e.get(Hunger, into: @h)        # refill in place — zero alloc
    #   @h.level -= decay * dt
    #   e.set(@h)                      # writes back to THIS entity
    #
    # Struct-backed (mruby-struct): fields map positionally to the
    # component's JSON keys, with plain attribute accessors. Forward
    # compat: declare-mode component classes will arrive as auto-created
    # refs with this exact surface.
    def self.ref(name, *fields)
      raise ArgumentError, "Component.ref needs at least one field" if fields.empty?
      k = Struct.new(*fields)
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
