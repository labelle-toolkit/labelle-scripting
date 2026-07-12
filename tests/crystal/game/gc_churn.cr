# THE ticket acceptance pin (labelle-engine#741: "Crystal GC runs with
# collections enabled") plus the steady-state buffer discipline, in one
# scenario:
#
#   - every tick allocates a fresh batch of heap Strings (garbage by
#     the next tick) and then FORCES a full collection (`GC.collect`) —
#     under a mis-registered host stack bdw-gc scans garbage and this
#     dies within a tick or two; under a correctly booted runtime the
#     live set (this script's fields, the registry, the buffers)
#     survives every collection and the world data — which lives HOST-
#     side, beyond the GC's reach — stays bit-exact;
#   - the boundary workload (query + get-into + mutate + set over 50
#     entities) runs through Buffers held in instance vars; after a
#     warm-up their capacities are recorded and 100 more ticks must not
#     move EITHER (grow-once wrappers + capacity-retaining clears — the
#     rust alloc_probe's pin, crystal-spelled; crystal's Array capacity
#     is not introspectable, so the Buffer pair carries the pin).
#
# The verdict lands as a component the Zig side matches byte-for-byte.

class GcChurn < Labelle::Script
  ENTITIES =  50
  WARMUP   =  10
  MEASURED = 100

  @verdict : Labelle::EntityId = 0_u64
  @ids = [] of Labelle::EntityId
  @scratch = Labelle::Buffer.new
  @comp = Labelle::Buffer.new
  @ticks = 0_i32
  @warm_caps : {Int32, Int32}?
  @grew = false
  @collects = 0_i32

  def init : Nil
    @verdict = Labelle.create_entity
    ENTITIES.times do
      id = Labelle.create_entity
      Labelle.set_component(id, "Hot", %({"count":0}))
    end
    # The other half of the idiom: size the payload buffer ONCE at init
    # with sane headroom, so a payload gaining a digit ("count":9 → 10)
    # never reads as growth (required-driven growth is big_query.cr's
    # pin; this script pins that a sized buffer never moves again).
    @comp.ensure_capacity(64)
  end

  def update(dt : Float32) : Nil
    @ticks += 1

    # Allocation churn: a batch of heap strings that turns to garbage
    # when this hook returns…
    churn = Array(String).new(32)
    32.times do |i|
      churn << "churn #{@ticks}/#{i} #{"x" * (i % 13)}"
    end
    # …then a FORCED full collection, every single tick. Runs only
    # because boot registered the host thread's stack with bdw-gc.
    GC.collect
    @collects += 1
    raise "gc lost live data" unless churn.size == 32 && churn[31].includes?("/31")

    # The boundary workload, all through reused buffers.
    raise "query failed" unless Labelle.query_into(%(["Hot"]), @ids, @scratch)
    raise "hot set changed" unless @ids.size == ENTITIES
    @ids.each do |id|
      raise "get failed" unless Labelle.get_component_into(id, "Hot", @comp)
      count = Util.i64_field(@comp.to_slice, %("count":)) || raise "count field missing"
      raise "a tick was lost" unless count + 1 == @ticks
      Labelle.set_component(id, "Hot", %({"count":#{@ticks}}))
    end

    caps = {@scratch.capacity, @comp.capacity}
    if @ticks == WARMUP
      @warm_caps = caps
    elsif (warm = @warm_caps) && caps != warm
      @grew = true
    end

    if @ticks == WARMUP + MEASURED
      Labelle.set_component(
        @verdict,
        "GcChurn",
        %({"collects":#{@collects},"settled":#{!@grew},"ticks":#{@ticks}})
      )
    end
  end
end
