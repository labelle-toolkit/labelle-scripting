-- get_into.lua — e:get(name, into) refill semantics: the read fills a
-- caller-owned table (identity preserved), STALE keys from the previous
-- fill are cleared (decode_into is clear-all-then-fill), absent
-- components leave the table untouched, nested values are fresh per
-- read (the documented v1 rule), and both name spellings — string and
-- labelle.component ref — take the into form.

local Hunger = labelle.component("Hunger", { level = 1.0 })

function init()
  local e = Entity.new()

  -- Refill preserves identity and fills the fields.
  e:set("Cfg", { a = 1, b = 2 })
  local t = {}
  local r = e:get("Cfg", t)
  assert(rawequal(r, t), "get(name, into) must return the into table")
  assert(t.a == 1 and t.b == 2, "refill missed fields")

  -- THE stale-key pin: refill from a payload that lost a field — the
  -- dead field must not survive from the previous fill.
  e:set("Cfg", { a = 5 })
  e:get("Cfg", t)
  assert(t.a == 5, "refill missed the updated field")
  assert(t.b == nil, "stale key survived the refill")

  -- Caller-planted junk is cleared too — the fill starts from empty,
  -- not from whatever the table accumulated.
  t.z = 99
  e:get("Cfg", t)
  assert(t.z == nil, "pre-existing key survived the refill")
  assert(t.a == 5, "fill after junk-clear missed")

  -- Absent component: nil back, into untouched (the ruby get_into rule).
  t.keep = "me"
  assert(e:get("Nope", t) == nil, "absent component must return nil")
  assert(t.keep == "me" and t.a == 5, "absent read must not touch into")

  -- Ref spelling drives the same path.
  e:set(Hunger, { level = 0.25 })
  local h = {}
  assert(rawequal(e:get(Hunger, h), h), "ref + into must refill")
  assert(h.level == 0.25, "ref refill missed")

  -- Nested values are FRESH per read (v1: only the top level is
  -- reused); the previous read's sub-table is the caller's to keep and
  -- is not mutated by the next fill.
  e:set("Nest", { pos = { x = 1, y = 2 }, tag = "a" })
  local n = {}
  e:get("Nest", n)
  local first_pos = n.pos
  assert(first_pos.x == 1 and first_pos.y == 2, "nested fill missed")
  e:get("Nest", n)
  assert(not rawequal(n.pos, first_pos), "nested tables must be fresh per read")
  assert(first_pos.x == 1 and first_pos.y == 2, "old sub-table was mutated")

  -- A non-table into is a loud error, not a silent fresh-table fallback.
  assert(not pcall(function() e:get("Cfg", 5) end), "non-table into must raise")

  -- get without into keeps the classic fresh-table behavior.
  local fresh = e:get("Cfg")
  assert(not rawequal(fresh, t) and fresh.a == 5, "plain get must stay fresh")

  Entity.new():set("GetIntoOk", { ok = true })
end
