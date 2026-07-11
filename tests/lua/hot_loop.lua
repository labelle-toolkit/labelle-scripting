-- hot_loop.lua — the per-frame allocation acceptance (ticket #2, RFC
-- revs 14-15): 1k entities with a FLAT component, and every tick the
-- full boundary workload — game.query, e:get(Hot, into) per entity,
-- mutate, e:set back — plus a FrameArray fill/clear. Steady-state memory
-- must hold flat, measured three ways with collectgarbage("count").
--
-- What "count" includes: gettotalbytes/1024 — EVERY live-or-not-yet-
-- collected byte the Lua allocator currently holds (tables, strings,
-- closures, userdata — the bindings' scratch included), as a float KB.
-- It moves up on allocation and down as the collector sweeps, which is
-- exactly what makes the three pins below meaningful:
--
--   read_ok   — the razor. The collector is STOPPED around the pure
--               get-into loop (and restarted right after), so count()
--               moves only by allocation and the delta IS the loop's
--               own allocation — the ruby zero_alloc.rb discipline.
--               1k refills of a flat component must stay ~0 KB: keys
--               and repeated value strings intern, the into table is
--               reused, nothing else is built. One fresh table per
--               read (the pre-#2 behavior) measures ~102 KB right here
--               — without the stop, Lua's own incremental steps fire
--               mid-loop once per-tick garbage outgrows the post-cycle
--               credit and quietly collect the evidence.
--   tick_ok   — per-tick stability. Sampled at the same phase every
--               tick (update start), the distance from the post-warmup
--               post-collect floor stays bounded: garbage never
--               outruns the budgeted collection.
--   growth_ok — no leak. After the measured window, a forced full
--               collect must land back at the floor (≈ 0 growth); a
--               FrameArray that grew or reads that pinned tables would
--               land above it.
--
-- The GC-step seam is asserted alongside: exactly one budgeted step per
-- tick ran across the window (raw_gc_stats delta), cycles kept
-- completing INSIDE those steps (incremental progress, no full-collect
-- spike — the budget caps each step at one tick's garbage), and the
-- collector is still in its normal running state at the end.

local ENTITIES = 1000
local WARMUP = 10 -- interning, scratch growth, table shapes settle
local MEASURED = 100

-- Bounds, from measuring THIS test (the HotLoopStats log line carries
-- each run's numbers): healthy max read delta = 0.45 KB (interning of
-- the tick's new value strings); with one fresh table per read
-- reintroduced it measures ~102 KB — the bound sits ~35x above healthy,
-- ~6x below broken. Healthy max tick delta = 0.0 KB (the budgeted
-- boundary step completes a cycle every tick, so the update-start
-- sample never rises above the floor — the bound is pure headroom for
-- collection falling behind). Healthy end growth ≈ 0.2-0.6 KB.
local READ_KB_MAX = 16
local TICK_KB_MAX = 2048
local GROWTH_KB_MAX = 64

local Hot = labelle.component("Hot", { level = 1000.0, count = 0 })

local verdict, fa, probe, into
local prev_budget
local ticks = 0
local base_kb, steps_base, cycles_base
local max_read_kb, max_tick_kb = 0, 0
local id_sum = 0
local function add_id(e) id_sum = id_sum + e.id end -- hoisted each() fn

function init()
  verdict = Entity.new() -- id 1: carries the verdict components
  for _ = 1, ENTITIES do -- ids 2..1001
    local e = Entity.new()
    assert(e ~= nil, "mock world refused an entity — MAX_ENTITIES too small?")
    e:set(Hot, { level = 1000.0, count = 0 })
  end
  probe = {}
  into = {}
  fa = FrameArray.new(ENTITIES)
  -- Cover the whole tick's allocation so collection happens ONLY in the
  -- end-of-tick budgeted step (quiet mid-tick = honest razor); restored
  -- after the verdict.
  prev_budget = labelle.raw_gc_set_step_budget(1024)
end

function update(dt)
  ticks = ticks + 1

  -- Fixed-phase stability sample: update start, i.e. right after the
  -- previous tick's boundary GC step.
  if base_kb ~= nil and ticks <= WARMUP + MEASURED then
    local d = collectgarbage("count") - base_kb
    if d > max_tick_kb then max_tick_kb = d end
  end

  -- FrameArray fill/clear: the per-frame snapshot of this tick's
  -- entities, capacity never outgrown (pinned via fa_growth below).
  fa:clear()
  for e in game.query(Hot) do fa:push(e) end
  assert(fa:size() == ENTITIES, "query lost entities")
  id_sum = 0
  fa:each(add_id)
  assert(id_sum == (2 + ENTITIES + 1) * ENTITIES // 2, "each() id sum")

  -- The razor: 1k pure get-into refills with the collector stopped, so
  -- the count() delta is exactly what the reads allocated.
  collectgarbage("stop")
  local kb0 = collectgarbage("count")
  for i = 1, ENTITIES do
    fa:get(i):get(Hot, probe)
  end
  local read_kb = collectgarbage("count") - kb0
  collectgarbage("restart")
  if base_kb ~= nil and ticks <= WARMUP + MEASURED and read_kb > max_read_kb then
    max_read_kb = read_kb
  end

  -- The prescribed workload: refill → mutate → write back, per entity.
  for i = 1, ENTITIES do
    local e = fa:get(i)
    local h = e:get(Hot, into)
    h.level = h.level - 0.25
    h.count = h.count + 1
    e:set(Hot, h)
  end

  if ticks == WARMUP then
    -- Warmed up: take the post-collect floor and the GC-seam baselines.
    collectgarbage("collect")
    base_kb = collectgarbage("count")
    steps_base, cycles_base = labelle.raw_gc_stats()
  elseif ticks == WARMUP + MEASURED then
    local steps, cycles = labelle.raw_gc_stats()
    local step_delta = steps - steps_base -- boundary steps of ticks 10..109
    local cycle_delta = cycles - cycles_base
    local running = collectgarbage("isrunning")
    collectgarbage("collect")
    local growth_kb = collectgarbage("count") - base_kb
    if growth_kb < 0 then growth_kb = -growth_kb end

    labelle.log(string.format(
      "HotLoopStats read=%.2fKB tick=%.1fKB growth=%.2fKB steps=%d cycles=%d",
      max_read_kb, max_tick_kb, growth_kb, step_delta, cycle_delta))

    verdict:set("HotLoop", {
      ticks = ticks,
      fa_growth = fa:growth_count(),
      read_ok = max_read_kb < READ_KB_MAX,
      tick_ok = max_tick_kb < TICK_KB_MAX,
      growth_ok = growth_kb < GROWTH_KB_MAX,
      steps_ok = step_delta == MEASURED,
      cycles_ok = cycle_delta >= 1,
      running_ok = running == true,
    })
    labelle.raw_gc_set_step_budget(prev_budget)
  end
end
