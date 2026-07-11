-- component_ref.lua — the RUNTIME half of "one DSL, two consumers": the
-- same chunk-scope labelle.component lines the declare runner reads as
-- schema evaluate, here, to lightweight refs that Entity methods and
-- game.query accept interchangeably with name strings.

local Hunger = labelle.component("Hunger", { level = 1.0, starving = false })
local Tag = labelle.component("Tag", { kind = "none" }, { persist = "transient" })

function init()
  assert(type(Hunger) == "table", "ref is not a table")
  assert(Hunger.__labelle_component == "Hunger", "ref carries the wrong name")

  local e = Entity.new()
  assert(e:set(Hunger, { level = 0.5, starving = false }), "set via ref refused")
  assert(e:has(Hunger), "has via ref is false")

  -- Ref and string address the SAME component.
  local via_ref = e:get(Hunger)
  local via_name = e:get("Hunger")
  assert(via_ref.level == 0.5, "get via ref returned the wrong table")
  assert(via_name.level == 0.5, "ref and string disagree")

  -- Refs work in queries, mixed with strings.
  e:set(Tag, { kind = "x" })
  local n = 0
  for _ in game.query(Hunger, "Tag") do n = n + 1 end
  assert(n == 1, "query via ref missed the entity")
  local m = 0
  for _ in game.query(Tag) do m = m + 1 end
  assert(m == 1, "query via ref alone missed")

  assert(e:remove(Tag), "remove via ref refused")
  assert(not e:has(Tag), "component survived remove via ref")

  -- A table that is NOT a ref is rejected loudly, not treated as a name.
  local ok = pcall(function() e:get({}) end)
  assert(not ok, "a non-ref table was accepted as a component name")

  e:set("RefOk", { ok = true })
end
