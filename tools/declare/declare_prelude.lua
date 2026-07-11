-- declare_prelude.lua — the Lua half of the declare-mode runner
-- (labelle-declare, RFC-LANGUAGE-PLUGINS revs 6-7, labelle-engine#237).
--
-- Declare mode is the build-time consumer of the component DSL: the SAME
-- `labelle.component("Hunger", { level = 1.0 })` line that hands a script a
-- lightweight component ref at runtime (src/lua/prelude.lua) is, here, a
-- schema declaration. Each script chunk runs under a private _ENV whose
-- ONLY entry is its own FRESH stub `labelle` table — `component` records
-- the declaration, every other `labelle.*` is a silent no-op (returning a
-- sentinel that declare_component rejects if it lands in a spec), and no
-- other global (not even the stdlib) is visible. Scripts' init/update are
-- merely DEFINED by the chunk body, never called, so only chunk-scope code
-- executes — exactly where declarations sit.
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
-- Determinism: components emit in DECLARATION order (argv order, then
-- top-to-bottom within a file) — that order is observable. Fields emit
-- SORTED BY NAME: Lua's pairs() order over the spec table is unspecified,
-- so declaration order of fields is not recoverable; sorting is the same
-- fix the runtime prelude's json.encode applies to object keys.
--
-- Type inference (v1): boolean → bool; number → i32 when math.type is
-- "integer" (range-checked), f32 otherwise; string → str; a table with
-- exactly the keys {x=<number>, y=<number>} → vec2. The schema vocabulary
-- also carries u32/entity for richer runners — Lua values cannot express
-- them, so this runner never emits them. Enums come LATER (rejected with a
-- clear error by the assembler side). Anything else is a hard error: a
-- malformed declaration must fail the build, not ship a guessed schema.

local decls = {} -- ordered: { name, persist, fields = { {name,type,json} } }
local by_name = {} -- component name -> file it was first declared in

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

-- Classify one spec value into { type = <schema type>, json = <default as
-- JSON> }, or raise with `where` naming the component and field. Error
-- level 3 = classify(1) → declare_component(2) → the SCRIPT's
-- labelle.component(...) line (3), so the position prefix points at the
-- declaration site.
local function classify(where, v)
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
    " (v1 supports number, boolean, string, and {x=,y=} vec2 tables)", 3)
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
-- Level 3: reject_noop(1) → declare_component(2) → the script's line (3).
local function reject_noop(v, ctx)
  if rawequal(v, noop_result) then
    error("labelle.component: " .. ctx .. ": labelle.* helpers cannot be " ..
      "used in component specs — declare-mode fields are literals", 3)
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

-- The stub `labelle`: `component` is live, EVERY other key resolves to the
-- shared sentinel-returning no-op — `labelle.on`/`log`/`emit`/... at chunk
-- scope neither run nor error, mirroring "only declarations matter at
-- build time".
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
  return setmetatable({ component = declare_component }, stub_mt)
end

-- The schema, as one compact JSON line (the runner↔assembler contract):
-- {"components":[{"name":…,"persist":…,"fields":[{"name":…,"type":…,"default":…},…]},…]}
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
  out[#out + 1] = "]}"
  return table.concat(out)
end
