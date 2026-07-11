-- frame_array.lua — FrameArray unit semantics, the lua mirror of the
-- ruby suite's frame_array.rb: `clear` keeps the backing (n = 0, no
-- reallocation — `buf = {}` would re-shrink and re-grow every frame),
-- `push` appends in bounds, growth happens only on overflow (doubling,
-- counted), and reads outside the logical length are invisible whatever
-- the backing still holds. The steady-state no-growth-across-ticks
-- property is asserted by hot_loop.lua; this pins the unit behavior.

function init()
  -- Fresh: empty, at declared capacity.
  local fa = FrameArray.new(4)
  assert(fa:size() == 0 and fa:capacity() == 4, "fresh size/capacity")
  assert(fa:growth_count() == 0, "fresh growth_count")

  -- push chains; get is 1-based and nil outside the LOGICAL bounds —
  -- the preallocated backing beyond size() must not leak through.
  fa:push(1):push(2):push(3)
  assert(fa:size() == 3, "append size")
  assert(fa:get(1) == 1 and fa:get(3) == 3, "get")
  assert(fa:get(4) == nil and fa:get(0) == nil and fa:get(-1) == nil,
    "get outside logical bounds")

  -- each walks the logical contents in order.
  local sum = 0
  fa:each(function(v) sum = sum + v end)
  assert(sum == 6, "each")

  -- set overwrites existing slots only; extending is push's job.
  fa:set(2, 20)
  assert(fa:get(2) == 20, "set")
  assert(not pcall(function() fa:set(4, 9) end), "set past size must raise")

  -- clear: n = 0, capacity survives, nothing reallocated; the backing
  -- is reused by the next pushes.
  fa:clear()
  assert(fa:size() == 0 and fa:capacity() == 4 and fa:growth_count() == 0,
    "clear keeps capacity")
  assert(fa:get(1) == nil, "cleared contents are invisible")
  fa:push(9)
  assert(fa:get(1) == 9 and fa:size() == 1, "reuse after clear")

  -- Deliberate growth: the 5th push overflows cap 4 — ONE doubling,
  -- counted, contents intact.
  fa:clear()
  for i = 1, 5 do fa:push(i * 10) end
  assert(fa:size() == 5 and fa:capacity() == 8 and fa:growth_count() == 1,
    "growth doubles once and is counted")
  assert(fa:get(1) == 10 and fa:get(5) == 50, "contents after growth")

  -- Constructor validates: capacity is a positive integer.
  assert(not pcall(FrameArray.new, 0), "cap 0 must raise")
  assert(not pcall(FrameArray.new, 2.5), "float cap must raise")
  assert(not pcall(FrameArray.new, "8"), "string cap must raise")

  Entity.new():set("FrameArrayOk", { ok = true })
end
