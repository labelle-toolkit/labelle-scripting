# zero_alloc.rb — the per-frame allocation proof for the into: pattern
# and FrameArray, measured two ways:
#   - GC ARENA index, read at the same point of every update: per-tick
#     transient object count must be CONSTANT across 100 ticks (the RFC's
#     "arena index stable" acceptance);
#   - live-object count with the GC DISABLED: a strict allocation
#     counter — flat across 100 ticks means the hot loop creates
#     literally ZERO ruby objects.
# The loop uses the strict positional forms (get_into / set(instance) /
# FrameArray in-bounds appends) and no string, hash, array or block
# literals — the kwarg sugar `get(H, into: @h)` is exercised once in
# init, outside the measured window, because mruby materializes keyword
# args per call (~2 small objects — arena-reclaimed, but not zero).
# Verdict lands in ZeroAlloc for the Zig side.

H = Labelle::Component.ref("Hot", :level, :count)

def init
  @e = Labelle::Entity.create
  @e.set("Hot", level: 100.0, count: 0)
  @h = H.new
  @fa = Labelle::FrameArray.new(64)
  @ticks = 0
  @arena_ok = true
  @live_ok = true

  # The pinned sugar spelling refills the SAME cached instance.
  got = @e.get(H, into: @h)
  raise "into: sugar must return the cached instance" unless got.equal?(@h)
  raise "into: refill missed" unless @h.level == 100.0 && @h.count == 0
end

def update(dt)
  @ticks += 1

  # FrameArray reuse: clear keeps the backing, appends stay in bounds.
  @fa.clear
  i = 0
  while i < 48
    @fa << i
    i += 1
  end

  # The hot component loop: 10 refill→mutate→write rounds per tick.
  j = 0
  while j < 10
    @e.get_into(H, @h)
    @h.level -= 0.25
    @h.count += 1
    @e.set(@h)
    j += 1
  end

  arena = Labelle.raw_gc_arena
  live = Labelle.raw_gc_live
  if @ticks == 5
    # Warm-up done (symbols interned, scratch grown, call stacks sized):
    # freeze the GC and take baselines.
    Labelle.raw_gc_disable(true)
    @arena_base = arena
    @live_base = live
  elsif @ticks > 5
    @arena_ok = false if arena != @arena_base
    @live_ok = false if live != @live_base
  end

  if @ticks == 105
    Labelle.raw_gc_disable(false)
    @e.set("ZeroAlloc",
           ticks: @ticks,
           arena_ok: @arena_ok,
           live_ok: @live_ok,
           growth: @fa.growth_count,
           count: @h.count)
  end
end
