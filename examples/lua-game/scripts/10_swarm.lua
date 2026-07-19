-- scripts/10_swarm.lua — the BATCHED tier against the real engine
-- (labelle-scripting#44, contract v1.3, labelle-engine >= 2.6.0 — the
-- project pin): the whole per-tick update crosses the Script Runtime
-- Contract exactly TWICE (one batch_get, one batch_set) no matter how
-- many entities match, where the per-entity tier would cross 2×N times.
-- `for d in labelle.batch("Dot") do ... end` is the ergonomic layer —
-- ONE reused view whose accessors are the component's field names,
-- layout derived host-side (declaration-order probe + stride
-- cross-check), COMMIT on normal exit/break/return, ABORT on error (the
-- generic-for closing value carries the semantics).
--
-- This is the permanent perf-shape regression net for the lua batch
-- port. Each observable milestone logs ONE `LUA_<TOKEN>` line so CI can
-- `grep -oE 'LUA_[A-Z0-9_.]+'` and diff the exact ordered sequence over
-- the 5-frame headless run (LABELLE_NULL_FRAMES=5):
--
--   setup   LUA_INIT            init(): three Dots spawned at x=100,
--                                vx=8 (all-float writes — exact at every
--                                width en route)
--   tick 1  LUA_BATCH_N_3       the batch saw all three entities
--   tick 5  LUA_BATCH_OK_140    100 + 5×8, re-read through the
--                                PER-ENTITY get — the value only lands
--                                if the batched write-back PERSISTED
--                                through the real ECS every tick
--   deinit  LUA_DEINIT          shutdown reached the script's deinit

local DOTS = 3
local first_id = nil
local tick = 0

function init()
  for _ = 1, DOTS do
    local e = Entity.new()
    if e == nil then
      labelle.log("LUA_SPAWN_FAIL")
      return
    end
    e:set("Dot", { x = 100, y = 0, vx = 8, vy = 0.5 })
    if first_id == nil then first_id = e.id end
  end
  labelle.log("LUA_INIT")
end

function update(dt)
  local _ = dt -- per-tick integration keeps the token chain exact
  tick = tick + 1

  -- The batched tier: one host crossing in, one out. `break` here would
  -- commit the writes made so far; an error would abort the whole
  -- write — this swarm always runs the full set.
  local n = 0
  for d in labelle.batch("Dot") do
    d.x = d.x + d.vx
    d.y = d.y + d.vy
    n = n + 1
  end

  if tick == 1 then
    labelle.log("LUA_BATCH_N_" .. n)
  end
  if tick == 5 and first_id ~= nil then
    -- Independent verification through the PER-ENTITY path.
    local d = Entity.wrap(first_id):get("Dot")
    if n == DOTS and d ~= nil and d.x == 140 then
      labelle.log("LUA_BATCH_OK_" .. d.x)
    else
      labelle.log("LUA_BATCH_MISMATCH n=" .. n .. " x=" .. tostring(d and d.x))
    end
  end
end

function deinit()
  labelle.log("LUA_DEINIT")
end
