-- declare_prelude.lua — the Lua half of the declare-mode runner
-- (labelle-declare, RFC-LANGUAGE-PLUGINS revs 6-7, labelle-engine#237).
--
-- Declare mode is the build-time consumer of the component DSL: the SAME
-- `labelle.component("Hunger", { level = 1.0 })` line that hands a script a
-- lightweight component ref at runtime (src/lua/prelude.lua) is, here, a
-- schema declaration. Each script chunk runs under a private _ENV whose
-- ONLY entry is the stub `labelle` table below — `component` records the
-- declaration, every other `labelle.*` is a shared silent no-op, and no
-- other global (not even the stdlib) is visible. Scripts' init/update are
-- merely DEFINED by the chunk body, never called, so only chunk-scope code
-- executes — exactly where declarations sit.
--
-- This prelude itself runs in the REAL globals (full stdlib) before any
-- script loads; extract.zig drives it through three seams:
--   __DECLARE_FILE    global — the path of the chunk about to run (error
--                     attribution; the vm.zig current-script pattern)
--   __declare_stub    global — the stub `labelle` table extract.zig plants
--                     into each chunk's fresh private _ENV
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
    local c = classify("component '" .. name .. "' field '" .. k .. "'", v)
    fields[#fields + 1] = { name = k, type = c.type, json = c.json }
  end
  table.sort(fields, function(a, b) return a.name < b.name end)

  decls[#decls + 1] = { name = name, persist = persist, fields = fields }
  by_name[name] = file

  return { __labelle_component = name }
end

-- The stub `labelle`: `component` is live, EVERY other key resolves to one
-- shared silent no-op (returning nothing) — `labelle.on`/`log`/`emit`/...
-- at chunk scope neither run nor error, mirroring "only declarations
-- matter at build time".
local noop = function() end
_G.__declare_stub = setmetatable(
  { component = declare_component },
  { __index = function() return noop end }
)

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
