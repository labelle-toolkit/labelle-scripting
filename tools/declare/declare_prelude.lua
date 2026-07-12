-- declare_prelude.lua — the Lua half of the declare-mode runner
-- (labelle-declare, RFC-LANGUAGE-PLUGINS revs 6-7, labelle-engine#237).
--
-- Declare mode is the build-time consumer of the component AND event DSLs:
-- the SAME `labelle.component("Hunger", { level = 1.0 })` line that hands a
-- script a lightweight component ref at runtime (src/lua/prelude.lua) is,
-- here, a schema declaration — and the SAME `labelle.event("hunger__feed",
-- { entity = labelle.id, amount = 0.5 })` line that returns the event-name
-- string at runtime is, here, an event-schema declaration
-- (labelle-engine#772). Each script chunk runs under a private _ENV whose
-- ONLY entry is its own FRESH stub `labelle` table — `component` and
-- `event` record declarations, `id` is the u64 field marker, `on` and
-- `emit` are no-ops that still validate the event NAME the way the
-- runtime bindings do (a component ref where an event name belongs must
-- fail at generate, not evict at runtime), every other `labelle.*` is a
-- silent no-op (returning a sentinel that the recorders reject if it
-- lands in a spec), and no other global (not even the stdlib) is
-- visible. Scripts' init/update are merely DEFINED by the chunk body,
-- never called, so only chunk-scope code executes — exactly where
-- declarations sit.
--
-- This prelude itself runs in the REAL globals (full stdlib) before any
-- script loads; extract.zig drives it through three seams:
--   __DECLARE_FILE    global — the path of the chunk about to run (error
--                     attribution; the vm.zig current-script pattern)
--   __declare_stub()  global — a FACTORY returning a fresh stub `labelle`
--                     table; extract.zig calls it once per chunk and
--                     plants the result into that chunk's private _ENV
--   __declare_emit()  global — returns the accumulated schema as one
--                     compact JSON line after every chunk ran
--
-- Determinism: components and events each emit in DECLARATION order (argv
-- order, then top-to-bottom within a file) — that order is observable.
-- Fields emit SORTED BY NAME: Lua's pairs() order over the spec table is
-- unspecified, so declaration order of fields is not recoverable; sorting
-- is the same fix the runtime prelude's json.encode applies to object keys.
--
-- Type inference (v1): boolean → bool; number → i32 when math.type is
-- "integer" (range-checked), f32 otherwise; string → str; a table with
-- exactly the keys {x=<number>, y=<number>} → vec2; the labelle.id marker
-- → u64 with default 0 (the entity-id type no plain Lua value can spell).
-- The schema vocabulary also carries u32/entity for richer runners — Lua
-- values cannot express them, so this runner never emits them. Enums come
-- LATER (rejected with a clear error by the assembler side). Anything else
-- is a hard error: a malformed declaration must fail the build, not ship a
-- guessed schema.

local decls = {} -- ordered: { name, persist, fields = { {name,type,json} } }
local by_name = {} -- component name -> file it was first declared in
local event_decls = {} -- ordered: { name, fields = { {name,type,json} } }
local events_by_name = {} -- event name -> file it was first declared in
-- (two maps on purpose: events and components are SEPARATE namespaces —
-- a Hunger component and a hunger event may coexist)

-- JSON string escaping for str defaults (component/field names are
-- identifier-checked, so this matters only for default values).
local escape_map = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    return escape_map[ch] or string.format("\\u%04x", string.byte(ch))
  end) .. '"'
end

-- One number as JSON. Integers print exact; floats print %.14g (enough to
-- round-trip every f32) and are forced to CARRY their floatness — "1.0",
-- not "1" — so the schema reads unambiguously (the "type" field is the
-- authority either way). Non-finite values were rejected by the caller.
local function number_json(v)
  if math.type(v) == "integer" then
    return string.format("%d", v)
  end
  local s = string.format("%.14g", v)
  if not s:find("[.eE]") then s = s .. ".0" end
  return s
end

local function is_identifier(s)
  return type(s) == "string" and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

-- Largest finite f32, as a Lua number (f64). Lua floats are doubles: a
-- FINITE value beyond this (1e100, say) would still narrow to ±inf in the
-- emitted f32 default — an impossible schema value, so classify rejects
-- it up front just like the non-finite it would become.
local F32_MAX = 3.4028235e38

-- The id FIELD marker (labelle-engine#772): `entity = labelle.id` in an
-- event or component spec classifies the field as {"type":"u64",
-- "default":0} — the schema's entity-id type, which no plain Lua value
-- can spell (a number would classify i32/f32). Recognition is by IDENTITY,
-- like the no-op sentinel — but this one is a LEGAL field value, so
-- classify accepts it where reject_noop would have fired. A function on
-- purpose (not a marker table): functions are immutable (the ruby runner's
-- frozen-Object twin), they fall through every table-shaped guard with the
-- right error already in place (`labelle.event("x", labelle.id)` lands on
-- "expects a spec table", a nested `{x = labelle.id, y = 0}` on the vec2
-- shape check — v1 ids are scalar-only), and CALLING it is the marker's
-- own pointed error: v1 has no id(value) constructor, id fields always
-- default 0. At runtime labelle.id is plain 0 (src/lua/prelude.lua), so
-- the same spec line evaluates clean in both modes.
local function id_sentinel()
  error("labelle.id is the id field marker itself, not a function " ..
    "(v1: id fields always default 0) — write entity = labelle.id", 2)
end

-- Classify one spec value into { type = <schema type>, json = <default as
-- JSON> }, or raise with `where` naming the declaration and field. Error
-- level 3 = classify(1) → declare_component/declare_event(2) → the
-- SCRIPT's labelle.component/event(...) line (3), so the position prefix
-- points at the declaration site.
local function classify(where, v)
  if rawequal(v, id_sentinel) then
    return { type = "u64", json = "0" }
  end
  local t = type(v)
  if t == "boolean" then
    return { type = "bool", json = v and "true" or "false" }
  end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error(where .. ": non-finite number default", 3)
    end
    if math.type(v) == "integer" then
      if v < -2147483648 or v > 2147483647 then
        error(where .. ": integer default out of i32 range", 3)
      end
      return { type = "i32", json = number_json(v) }
    end
    if v > F32_MAX or v < -F32_MAX then
      error(where .. ": float default out of f32 range (f32 max is 3.4028235e38)", 3)
    end
    return { type = "f32", json = number_json(v) }
  end
  if t == "string" then
    return { type = "str", json = quote(v) }
  end
  if t == "table" then
    -- vec2: EXACTLY the keys x and y, both finite numbers.
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == 2 and type(v.x) == "number" and type(v.y) == "number" then
      if v.x ~= v.x or v.y ~= v.y or v.x == math.huge or v.x == -math.huge
        or v.y == math.huge or v.y == -math.huge then
        error(where .. ": non-finite vec2 default", 3)
      end
      if v.x > F32_MAX or v.x < -F32_MAX or v.y > F32_MAX or v.y < -F32_MAX then
        error(where .. ": vec2 default out of f32 range (f32 max is 3.4028235e38)", 3)
      end
      return {
        type = "vec2",
        json = '{"x":' .. number_json(v.x) .. ',"y":' .. number_json(v.y) .. "}",
      }
    end
    error(where .. ": unsupported table default (only {x=<number>,y=<number>} vec2 tables are supported in v1)", 3)
  end
  error(where .. ": unsupported default of type " .. t ..
    " (v1 supports number, boolean, string, {x=,y=} vec2 tables, and labelle.id)", 3)
end

-- What every non-`component` labelle.* returns in declare mode. NOT nil:
-- in `labelle.component("Path", { waypoints = labelle.array({}) })` a
-- nil-returning no-op makes the table constructor silently DROP the key,
-- and the declaration would validate WITHOUT the field. Returning this
-- distinctive sentinel instead lets declare_component spot helper results
-- used as data and fail the build. (The marker key is for debuggability;
-- recognition is by identity, and a sentinel nested deeper inside a table
-- default still errors through classify's vec2-shape check.)
local noop_result = { ["labelle declare-mode no-op result"] = true }
local function noop() return noop_result end

-- The pointed rejection for a helper result where a literal belongs.
-- `kind` ("component", the default, or "event") names the calling DSL in
-- the message. Level 3: reject_noop(1) → declare_component/declare_event
-- (2) → the script's line (3).
local function reject_noop(v, ctx, kind)
  if rawequal(v, noop_result) then
    local k = kind or "component"
    error("labelle." .. k .. ": " .. ctx .. ": labelle.* helpers cannot be " ..
      "used in " .. k .. " specs — declare-mode fields are literals", 3)
  end
end

-- The declare-mode `labelle.component(name, spec[, opts])`. Validates,
-- records, and returns the SAME lightweight ref shape the runtime prelude
-- returns, so chunk-scope code like `local Hunger = labelle.component(...)`
-- sees one consistent value in both modes.
local function declare_component(name, spec, opts)
  local file = __DECLARE_FILE or "?"
  if type(name) ~= "string" or name == "" then
    error("labelle.component: expected a non-empty component name string", 2)
  end
  if not is_identifier(name) then
    error("labelle.component: component name '" .. name ..
      "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)", 2)
  end
  if type(spec) ~= "table" then
    error("labelle.component: component '" .. name ..
      "' expects a spec table of field defaults", 2)
  end
  reject_noop(spec, "component '" .. name .. "' spec")
  if by_name[name] ~= nil then
    error("labelle.component: duplicate component '" .. name ..
      "' (first declared in " .. by_name[name] .. ")", 2)
  end

  local persist = "persistent"
  if opts ~= nil then
    if type(opts) ~= "table" then
      error("labelle.component: component '" .. name ..
        "' options must be a table", 2)
    end
    reject_noop(opts, "component '" .. name .. "' options")
    for k, v in pairs(opts) do
      if k ~= "persist" then
        error("labelle.component: component '" .. name ..
          "' has an unknown option '" .. tostring(k) .. "' (v1 knows only persist)", 2)
      end
      if v ~= "persistent" and v ~= "transient" then
        error("labelle.component: component '" .. name ..
          "' has an invalid persist value '" .. tostring(v) ..
          "' (expected \"persistent\" or \"transient\")", 2)
      end
      persist = v
    end
  end

  local fields = {}
  for k, v in pairs(spec) do
    if not is_identifier(k) then
      error("labelle.component: component '" .. name .. "' field '" ..
        tostring(k) .. "' is not a valid identifier", 2)
    end
    reject_noop(v, "component '" .. name .. "' field '" .. k .. "'")
    local c = classify("component '" .. name .. "' field '" .. k .. "'", v)
    fields[#fields + 1] = { name = k, type = c.type, json = c.json }
  end
  table.sort(fields, function(a, b) return a.name < b.name end)

  decls[#decls + 1] = { name = name, persist = persist, fields = fields }
  by_name[name] = file

  return { __labelle_component = name }
end

-- Event payloads share the 32-field ceiling the ruby runner inherits from
-- its view fast path (MAX_VIEW_FIELDS in tools/declare-ruby): one schema,
-- whatever the language, so a wider event must fail HERE too, on its
-- declaration line, not only when the same file runs through the ruby
-- runner. tests/declare_ruby_tool.zig's drift pin reads this literal out
-- of the source alongside the three ruby-path spellings.
local MAX_EVENT_FIELDS = 32

-- The declare-mode `labelle.event(name, spec)` (labelle-engine#772):
-- the component recorder minus persistence — same identifier rules, same
-- classify vocabulary (labelle.id included), fields sorted by name, but NO
-- options argument (events are never saved) and a SEPARATE namespace (an
-- event may share a component's name; duplicates are checked per kind).
-- Returns the event-name string — the same value the runtime prelude
-- returns — so chunk-scope `local HungerFeed = labelle.event(...)` binds
-- one consistent value in both modes.
local function declare_event(name, spec, ...)
  local file = __DECLARE_FILE or "?"
  if type(name) ~= "string" or name == "" then
    error("labelle.event: expected a non-empty event name string", 2)
  end
  if not is_identifier(name) then
    error("labelle.event: event name '" .. name ..
      "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)", 2)
  end
  -- Vararg so a 4th+ argument can't slip past unseen (a fixed `extra`
  -- param would silently discard them). One EXPLICIT nil third arg stays
  -- legal — ruby's fixed-arity `opts = nil` signature cannot distinguish
  -- `event("x", {})` from `event("x", {}, nil)`, so rejecting it here
  -- would break cross-runner parity; ruby rejects 4+ args natively
  -- (wrong number of arguments), and this is the lua analog.
  local extra_n = select("#", ...)
  if extra_n > 1 or (extra_n == 1 and select(1, ...) ~= nil) then
    error("labelle.event: event '" .. name ..
      "' takes no options (events are not persisted)", 2)
  end
  if type(spec) ~= "table" then
    error("labelle.event: event '" .. name ..
      "' expects a spec table of field defaults ({} for a payloadless event)", 2)
  end
  reject_noop(spec, "event '" .. name .. "' spec", "event")
  if events_by_name[name] ~= nil then
    error("labelle.event: duplicate event '" .. name ..
      "' (first declared in " .. events_by_name[name] .. ")", 2)
  end

  local n = 0
  for _ in pairs(spec) do n = n + 1 end
  if n > MAX_EVENT_FIELDS then
    error("labelle.event: event '" .. name .. "' has " .. n ..
      " fields — event payloads support at most " .. MAX_EVENT_FIELDS ..
      " fields; split the event", 2)
  end

  local fields = {}
  for k, v in pairs(spec) do
    if not is_identifier(k) then
      error("labelle.event: event '" .. name .. "' field '" ..
        tostring(k) .. "' is not a valid identifier", 2)
    end
    reject_noop(v, "event '" .. name .. "' field '" .. k .. "'", "event")
    local c = classify("event '" .. name .. "' field '" .. k .. "'", v)
    fields[#fields + 1] = { name = k, type = c.type, json = c.json }
  end
  table.sort(fields, function(a, b) return a.name < b.name end)

  event_decls[#event_decls + 1] = { name = name, fields = fields }
  events_by_name[name] = file

  return name
end

-- Declare-mode labelle.on/labelle.emit: name-checked no-ops. Still
-- no-ops — nothing subscribes, handlers never run, extra arguments are
-- swallowed, and both return the spec-position-rejected sentinel like
-- every other stub call — but the event NAME is validated exactly the
-- way the RUNTIME bindings validate it: raw_event_subscribe/
-- raw_event_emit read the name through lua_tolstring
-- (src/lua/bindings.zig checkString), which accepts strings AND numbers
-- (Lua's own coercion) and raises for everything else. Without this
-- check a real constant of the WRONG KIND — a component ref where an
-- event name belongs, `labelle.on(Worker)` — passed generate as a blind
-- no-op and only died in the running game as a script eviction (the
-- same-file `local HungerFeed = labelle.event(...)` pattern passes by
-- construction: labelle.event returns the name string). Level 3:
-- check_event_name(1) → declare_on/declare_emit(2) → the script's
-- labelle.on/emit line (3).
local function check_event_name(callee, name)
  local t = type(name)
  if t == "string" or t == "number" then return end
  local got = t
  if rawequal(name, noop_result) then
    got = "a labelle.* helper result"
  elseif t == "table" and rawget(name, "__labelle_component") ~= nil then
    got = "the component '" .. tostring(rawget(name, "__labelle_component")) .. "'"
  end
  error("labelle." .. callee .. ": expected an event-name string — got " .. got ..
    " (events subscribe and emit by name; a component constant is not an event name)", 3)
end

local function declare_on(name, ...)
  check_event_name("on", name)
  return noop_result
end

local function declare_emit(name, ...)
  check_event_name("emit", name)
  return noop_result
end

-- The stub `labelle`: `component` and `event` are live, `id` is the u64
-- field marker, `on` and `emit` are the name-checked no-ops above, and
-- EVERY other key resolves to the shared sentinel-returning no-op —
-- `labelle.log`/`array`/... at chunk scope neither run nor error,
-- mirroring "only declarations matter at build time".
--
-- __declare_stub is a FACTORY, not one table: extract.zig calls it once
-- per chunk, so each chunk's env gets its OWN stub. With a single shared
-- table, one script assigning `labelle.component = nil` stripped the key
-- for every LATER file — whose declarations then fell through __index to
-- the no-op and vanished silently. Mutations now land on the mutating
-- chunk's private copy only. The recorder closure and the metatable stay
-- shared internally: declarations must accumulate across chunks, and
-- scripts cannot reach the metatable (their env has no stdlib — no
-- getmetatable/setmetatable/rawset).
local stub_mt = { __index = function() return noop end }
function _G.__declare_stub()
  return setmetatable(
    {
      component = declare_component,
      event = declare_event,
      id = id_sentinel,
      on = declare_on,
      emit = declare_emit,
    },
    stub_mt
  )
end

-- The schema, as one compact JSON line (the runner↔assembler contract):
-- {"components":[{"name":…,"persist":…,"fields":[{"name":…,"type":…,"default":…},…]},…]}
-- plus, ONLY when at least one event was declared, a trailing
-- "events":[{"name":…,"fields":[…]},…] array (no persist key — events are
-- never saved). Omitting the key when empty is compat-by-construction:
-- pre-events assemblers parse the schema as a JSON tree and read only
-- "components", so schemas from event-free projects stay byte-identical
-- to what those assemblers always saw.
function _G.__declare_emit()
  local out = {}
  out[#out + 1] = '{"components":['
  for i, d in ipairs(decls) do
    if i > 1 then out[#out + 1] = "," end
    out[#out + 1] = '{"name":' .. quote(d.name) .. ',"persist":"' .. d.persist .. '","fields":['
    for j, f in ipairs(d.fields) do
      if j > 1 then out[#out + 1] = "," end
      out[#out + 1] = '{"name":' .. quote(f.name) .. ',"type":"' .. f.type ..
        '","default":' .. f.json .. "}"
    end
    out[#out + 1] = "]}"
  end
  out[#out + 1] = "]"
  if #event_decls > 0 then
    out[#out + 1] = ',"events":['
    for i, d in ipairs(event_decls) do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = '{"name":' .. quote(d.name) .. ',"fields":['
      for j, f in ipairs(d.fields) do
        if j > 1 then out[#out + 1] = "," end
        out[#out + 1] = '{"name":' .. quote(f.name) .. ',"type":"' .. f.type ..
          '","default":' .. f.json .. "}"
      end
      out[#out + 1] = "]}"
    end
    out[#out + 1] = "]"
  end
  out[#out + 1] = "}"
  return table.concat(out)
end
