-- prelude.lua — the Lua-side half of labelle-scripting.
--
-- bindings.zig installs the raw C shims (`labelle.raw_*`, thin 1:1 bridges
-- to the Script Runtime Contract) and then runs this chunk in the REAL
-- globals, so everything defined here is visible to every registered
-- script through its private _ENV's `__index = _G` fallback.
--
-- Layering rule: everything below is pure sugar over `labelle.raw_*`. The
-- raw shims stay reachable on purpose — when a script needs something the
-- sugar doesn't cover (or the sugar has a bug), the contract is right
-- there.

-- ── json ─────────────────────────────────────────────────────────────────
-- Minimal pure-Lua JSON codec for component payloads (encoding v1):
-- objects / arrays / strings / numbers / booleans / null. Deliberately
-- self-contained — no C deps means the prelude works on every target the
-- VM does. Known, accepted limits (component tables never hit them):
-- \uXXXX escapes decode BMP-only (no surrogate pairs), and JSON null
-- decodes to Lua nil, so null object fields vanish and null array entries
-- collapse the sequence.

local json = {}

local escape_map = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_char(ch)
  return escape_map[ch] or string.format("\\u%04x", string.byte(ch))
end

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', escape_char) .. '"'
end

-- A table encodes as an array iff its keys are exactly 1..#t. Empty tables
-- encode as {} — the contract reads "{}" as "all defaults", which is the
-- right meaning for an empty component payload.
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
    n = n + 1
  end
  return n == #t
end

local encode_value -- forward declaration (encode_table recurses through it)

local function encode_table(t, out)
  if next(t) == nil then
    out[#out + 1] = "{}"
    return
  end
  if is_array(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode_value(t[i], out)
    end
    out[#out + 1] = "]"
  else
    -- Sorted keys: pairs() order is nondeterministic per-run, and a stable
    -- encoding lets hosts and tests compare payloads byte-for-byte.
    local keys = {}
    for k in pairs(t) do
      if type(k) ~= "string" then
        error("json.encode: object keys must be strings, got " .. type(k))
      end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    out[#out + 1] = "{"
    for i = 1, #keys do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = encode_string(keys[i])
      out[#out + 1] = ":"
      encode_value(t[keys[i]], out)
    end
    out[#out + 1] = "}"
  end
end

encode_value = function(v, out)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("json.encode: non-finite number")
    end
    if math.type(v) == "integer" then
      out[#out + 1] = string.format("%d", v)
    else
      -- %.14g survives every f32 component field exactly and stays short.
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "table" then
    encode_table(v, out)
  else
    error("json.encode: cannot encode a " .. t)
  end
end

function json.encode(v)
  local out = {}
  encode_value(v, out)
  return table.concat(out)
end

local function decode_error(s, i, msg)
  error(string.format("json.decode: %s at byte %d", msg, i), 0)
end

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local decode_escapes = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function decode_string(s, i) -- i sits on the opening quote
  local out, j = {}, i + 1
  while true do
    local ch = s:sub(j, j)
    if ch == "" then decode_error(s, j, "unterminated string") end
    if ch == '"' then return table.concat(out), j + 1 end
    if ch == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local hex = s:sub(j + 2, j + 5)
        if not hex:match("^%x%x%x%x$") then decode_error(s, j, "bad \\u escape") end
        out[#out + 1] = utf8.char(tonumber(hex, 16))
        j = j + 6
      else
        local r = decode_escapes[e]
        if not r then decode_error(s, j, "bad escape") end
        out[#out + 1] = r
        j = j + 2
      end
    else
      out[#out + 1] = ch
      j = j + 1
    end
  end
end

local function decode_number(s, i)
  local j = i
  while j <= #s and s:sub(j, j):match("[-+.eE%d]") do j = j + 1 end
  local n = tonumber(s:sub(i, j - 1))
  if n == nil then decode_error(s, i, "bad number") end
  return n, j
end

local decode_value -- forward declaration (containers recurse through it)

decode_value = function(s, i)
  i = skip_ws(s, i)
  local ch = s:sub(i, i)
  if ch == "" then decode_error(s, i, "unexpected end of input") end
  if ch == "{" then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then decode_error(s, i, "expected object key") end
      local k
      k, i = decode_string(s, i)
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
      local v
      v, i = decode_value(s, i + 1)
      obj[k] = v
      i = skip_ws(s, i)
      local sep = s:sub(i, i)
      if sep == "," then
        i = skip_ws(s, i + 1)
      elseif sep == "}" then
        return obj, i + 1
      else
        decode_error(s, i, "expected ',' or '}'")
      end
    end
  elseif ch == "[" then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = decode_value(s, i)
      arr[#arr + 1] = v
      i = skip_ws(s, i)
      local sep = s:sub(i, i)
      if sep == "," then
        i = i + 1
      elseif sep == "]" then
        return arr, i + 1
      else
        decode_error(s, i, "expected ',' or ']'")
      end
    end
  elseif ch == '"' then
    return decode_string(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    return decode_number(s, i)
  end
end

function json.decode(s)
  if type(s) ~= "string" then
    error("json.decode: expected a string, got " .. type(s), 0)
  end
  local v, i = decode_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then decode_error(s, i, "trailing garbage") end
  return v
end

-- ── Entity ───────────────────────────────────────────────────────────────
-- Thin id wrapper: components in and out as plain Lua tables, the JSON leg
-- hidden. `e.id` stays public — events and raw calls speak ids.

local Entity = {}
Entity.__index = Entity

--- Wrap an existing entity id (e.g. one carried in an event payload).
function Entity.wrap(id)
  return setmetatable({ id = id }, Entity)
end

--- Create a fresh empty entity; nil when the host refuses (not bound).
function Entity.new()
  local id = labelle.raw_entity_create()
  if id == 0 then return nil end
  return Entity.wrap(id)
end

--- Component as a table, or nil when absent (unknown name / dead entity).
function Entity:get(name)
  local s = labelle.raw_component_get(self.id, name)
  if s == "" then return nil end
  return json.decode(s)
end

--- Set (REPLACE semantics) a component from a table; nil/{} means "all
--- defaults". Returns true on success.
function Entity:set(name, tbl)
  local payload = tbl == nil and "" or json.encode(tbl)
  return labelle.raw_component_set(self.id, name, payload) == 0
end

function Entity:has(name)
  return labelle.raw_component_has(self.id, name)
end

function Entity:remove(name)
  return labelle.raw_component_remove(self.id, name) == 0
end

function Entity:destroy()
  labelle.raw_entity_destroy(self.id)
end

-- ── game ─────────────────────────────────────────────────────────────────

local game = {}

--- Iterate entities carrying ALL the named components:
---   for e in game.query("CloudDrift", "Position") do ... end
--- Yields Entity wrappers over the contract's id-JSON snapshot, so spawning
--- or destroying entities inside the loop is safe.
function game.query(...)
  local names = {}
  for i = 1, select("#", ...) do
    names[i] = (select(i, ...))
  end
  local out = labelle.raw_query(json.encode(names))
  local ids = out ~= "" and json.decode(out) or {}
  local i = 0
  return function()
    i = i + 1
    local id = ids[i]
    if id == nil then return nil end
    return Entity.wrap(id)
  end
end

-- ── labelle sugar ────────────────────────────────────────────────────────

--- Log through the game's sink (stringifies for convenience).
function labelle.log(msg)
  labelle.raw_log(tostring(msg))
end

--- Last tick's gameplay dt in seconds (scaled; 0 while paused).
function labelle.time_dt()
  return labelle.raw_time_dt()
end

--- Emit a game event by union-tag name with a table payload (nil = all
--- defaults). Returns true when the host accepted it.
function labelle.emit(name, tbl)
  local payload = tbl == nil and "" or json.encode(tbl)
  return labelle.raw_event_emit(name, payload) == 0
end

--- Spawn a prefab; `params` is an optional {x=…,y=…} table. Returns an
--- Entity or nil on failure.
function labelle.spawn(prefab, params)
  local payload = params == nil and "" or json.encode(params)
  local id = labelle.raw_prefab_spawn(prefab, payload)
  if id == 0 then return nil end
  return Entity.wrap(id)
end

--- Switch scenes; returns true when the host accepted the name.
function labelle.scene_change(name)
  return labelle.raw_scene_change(name) == 0
end

-- Receive side. The contract is subscribe + poll-drain (one FIFO inbox for
-- the whole VM); callback dispatch is prelude sugar over that drain, shared
-- by every script — which is exactly why `handlers` lives here and not in
-- any script's env.
local handlers = {}

--- Subscribe `fn` to a game event by name. The payload arrives as a
--- decoded table ({} for empty payloads). Multiple handlers per name fan
--- out in registration order.
function labelle.on(name, fn)
  labelle.raw_event_subscribe(name)
  local hs = handlers[name]
  if hs == nil then
    hs = {}
    handlers[name] = hs
  end
  hs[#hs + 1] = fn
end

--- Drain the event inbox, dispatching each entry to its handlers. The
--- Controller calls this once at tick start, BEFORE script updates, so
--- handlers observe last frame's events before this frame's logic runs.
--- A handler that throws aborts this drain (the Zig side logs the trace
--- and the tick survives); undrained events stay queued for next tick.
function labelle.dispatch_inbox()
  while true do
    local entry = labelle.raw_event_poll()
    if entry == "" then break end
    local name, payload = entry:match("^(%S+)%s*(.*)$")
    local hs = name and handlers[name]
    if hs then
      local tbl = (payload ~= nil and payload ~= "") and json.decode(payload) or {}
      for i = 1, #hs do
        hs[i](tbl)
      end
    end
  end
end

-- ── exports ──────────────────────────────────────────────────────────────
-- One visible block: everything scripts can reach by name. `labelle` was
-- created by bindings.zig (raw shims) and extended in place above.

_G.json = json
_G.Entity = Entity
_G.game = game

-- name → private _ENV of each registered script; vm.zig fills it in
-- loadScript and reads it in callScriptHook.
_G.__labelle_scripts = {}
