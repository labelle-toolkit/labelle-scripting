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
--
-- Entity-id rule: ids are u64 on the host but live in Lua as the SIGNED
-- 64-bit bitcast (lua_pushinteger), so a bit-63 id looks negative. That is
-- lossless for math, table keys and every raw_* call (both ends bitcast) —
-- but embed entity ids in payloads via labelle.u64str(id): plain %d would
-- sign-flip bit-63 ids. The generic json.encode deliberately does NOT
-- special-case negative integers (they may be legitimate component values);
-- only values KNOWN to be ids get the unsigned rendering. The DECODE leg
-- needs no such opt-in: integer-looking payload tokens parse with wrapping
-- 64-bit arithmetic (see decode_number), so a u64 id arriving in an event
-- payload lands bit-exact on the same signed bitcast the raw shims use.
--
-- Array rule: an untagged empty Lua table is ambiguous and encodes as the
-- JSON object "{}" (the contract's "all defaults"). Wrap array-typed
-- values in labelle.array(t) to force array form — empty included — and
-- json.decode tags every array it produces, so get→set round-trips keep
-- arrayness without re-tagging.
--
-- Handler ownership: labelle.on records WHICH script registered each
-- handler by reading __labelle_current_script — the global vm.zig stamps
-- around every VM→script entry (chunk body, init/update/deinit), the
-- VM-truth "whose code is running". NOT derived from the caller's _ENV:
-- a script-local helper closing over an alias of labelle.on carries no
-- _ENV upvalue, so an upvalue walk would yield owner nil and exempt the
-- handler from purges. When a script is evicted its handlers are purged
-- through __labelle_purge_handlers, so nothing keeps firing into dead
-- state.

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

-- Marker metatable for EXPLICIT arrays (labelle.array): a tagged table
-- encodes in array form even when empty — an untagged empty table is
-- ambiguous in Lua and stays the JSON object "{}" — and json.decode tags
-- every array it produces so decoded arrays re-encode as arrays.
local ARRAY_MT = {}

-- A table encodes as an array iff it carries the labelle.array tag OR its
-- keys are exactly 1..#t. Untagged empty tables encode as {} — the
-- contract reads "{}" as "all defaults", which is the right meaning for
-- an empty component payload; pass labelle.array({}) to mean "[]".
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
  local tagged = getmetatable(t) == ARRAY_MT
  if not tagged and next(t) == nil then
    out[#out + 1] = "{}"
    return
  end
  if tagged or is_array(t) then
    -- Array form encodes the SEQUENCE 1..#t. The tag is an explicit
    -- override for the mixed edge cases too: a tagged table with stray
    -- non-sequence keys still emits as an array, the strays dropped.
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

-- Integer-looking tokens (all digits, optional leading '-'; no '.', 'e'
-- or 'E') build with WRAPPING integer arithmetic: acc*10+digit wraps mod
-- 2^64 on Lua 5.4 integers, so a token ≥ 2^63 (a bit-63 entity id in an
-- event payload, say) lands exactly on the SIGNED BITCAST the raw shims
-- use for ids — tonumber() would round it through a float and a wrapper
-- built from it would address the wrong entity. The wrapping is the
-- documented semantics for out-of-range integers (tokens beyond 20
-- digits keep wrapping mod 2^64 rather than saturating). True float
-- tokens (fractions, exponents) keep tonumber.
local function decode_number(s, i)
  local j = i
  while j <= #s and s:sub(j, j):match("[-+.eE%d]") do j = j + 1 end
  local tok = s:sub(i, j - 1)
  local digits = tok:match("^%-?(%d+)$")
  if digits then
    local acc = 0
    for k = 1, #digits do
      acc = acc * 10 + (digits:byte(k) - 48)
    end
    if tok:byte(1) == 45 then acc = -acc end -- '-': wrapping negate
    return acc, j
  end
  local n = tonumber(tok)
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
    -- Tagged at birth: a decoded array re-encodes as an array (empty
    -- included), so get→modify→set round-trips preserve arrayness.
    local arr = setmetatable({}, ARRAY_MT)
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

-- Parse the host's query response ("[1,42,...]", ids as unsigned decimals)
-- into an id array — the decode leg of the entity-id rule (see header).
-- Deliberately NOT the generic json.decode: its number path tonumber()s a
-- bit-63 id (> math.maxinteger) into an imprecise float and the wrappers
-- would then address the wrong entity. Building each digit run with
-- wrapping integer arithmetic (id * 10 + digit wraps mod 2^64 on Lua 5.4
-- integers) lands exactly on the signed bitcast raw_entity_create returns.
local function decode_id_array(s)
  local ids = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b >= 48 and b <= 57 then -- digit run → one id
      local id = 0
      repeat
        id = id * 10 + (b - 48)
        i = i + 1
        b = s:byte(i)
      until b == nil or b < 48 or b > 57
      ids[#ids + 1] = id
    else -- brackets, commas, whitespace
      i = i + 1
    end
  end
  return ids
end

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
  local ids = out ~= "" and decode_id_array(out) or {}
  local i = 0
  return function()
    i = i + 1
    local id = ids[i]
    if id == nil then return nil end
    return Entity.wrap(id)
  end
end

-- ── labelle sugar ────────────────────────────────────────────────────────

-- Decimal string of a Lua integer REINTERPRETED as unsigned 64-bit — the
-- encode leg of the entity-id rule (see header). Non-negative values (q==0
-- territory included: u < 10 can only reach this with bit 63 clear) are
-- plain %d; for negative v, Lua 5.4 semantics do the heavy lifting: >> is
-- a LOGICAL shift, so (v >> 1) // 5 is floor(u/10) — now non-negative and
-- %d-safe — and wrapping integer arithmetic makes v - q*10 the true last
-- digit 0..9.
local function u64tostr(v)
  if v >= 0 then return string.format("%d", v) end
  local q = (v >> 1) // 5
  local r = v - q * 10
  return string.format("%d%d", q, r)
end

--- Render an entity id as its unsigned decimal string. Use this to embed
--- ids in JSON payloads ({ owner = labelle.u64str(e.id) }); `e.id` itself
--- stays a plain integer for Lua-side math and raw_* calls.
function labelle.u64str(id)
  if math.type(id) ~= "integer" then
    error("labelle.u64str: expected an entity id (integer)", 2)
  end
  return u64tostr(id)
end

--- Tag `t` (or a fresh table when nil) as an EXPLICIT array for
--- json.encode: it emits in array form even when empty — an untagged {}
--- would encode as the JSON object "{}" and a slice-typed component
--- field would refuse it. The tag also forces array interpretation for
--- mixed tables (the sequence 1..#t encodes; stray keys are dropped).
--- json.decode tags the arrays it produces with the same marker, so a
--- get→modify→set round-trip needs no re-tagging:
---   e:set("Path", { waypoints = labelle.array({}) })
function labelle.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

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
-- any script's env. Entries are { fn = handler, owner = script name }:
-- ownership is what lets eviction pull a dead script's handlers back out
-- again (__labelle_purge_handlers below).
local handlers = {}

-- Captured at install time so a script replacing the `debug` global can't
-- break handler error reporting — the same paranoia vm.zig applies by
-- calling luaL_traceback instead of debug.traceback.
local debug_traceback = debug.traceback

-- xpcall message handler for handler dispatch: capture the traceback
-- BEFORE the stack unwinds (the vm.zig msghTraceback pattern — after the
-- unwind the frames are gone). Level 2 skips this handler's own frame.
local function handler_msgh(err)
  return debug_traceback(tostring(err), 2)
end

--- Subscribe `fn` to a game event by name. The payload arrives as a
--- decoded table ({} for empty payloads). Multiple handlers per name fan
--- out in registration order. The registering SCRIPT owns the handler —
--- __labelle_current_script, the VM's stamp of whose code is running
--- (nil for prelude/host-run code, which no purge ever matches): when a
--- script is evicted (chunk body or init() failure), its handlers are
--- purged with it and never fire again.
function labelle.on(name, fn)
  labelle.raw_event_subscribe(name)
  local hs = handlers[name]
  if hs == nil then
    hs = {}
    handlers[name] = hs
  end
  hs[#hs + 1] = { fn = fn, owner = __labelle_current_script }
end

--- Drain the event inbox, dispatching each entry to its handlers. The
--- Controller calls this once at tick start, BEFORE script updates, so
--- handlers observe last frame's events before this frame's logic runs.
--- Handlers are ISOLATED: each runs under its own xpcall, a throwing
--- handler is logged (event, owner, traceback) and the fan-out AND the
--- drain continue — one broken handler must not starve its siblings or
--- leave the rest of the inbox queued. Each handler runs with
--- __labelle_current_script set to its owner (and restored after), so a
--- handler that registers handlers attributes them correctly. Only
--- SURVIVING handlers run — an evicted script's were purged.
function labelle.dispatch_inbox()
  while true do
    local entry = labelle.raw_event_poll()
    if entry == "" then break end
    local name, payload = entry:match("^(%S+)%s*(.*)$")
    local hs = name and handlers[name]
    if hs then
      local tbl = (payload ~= nil and payload ~= "") and json.decode(payload) or {}
      for i = 1, #hs do
        local h = hs[i]
        local saved = __labelle_current_script
        __labelle_current_script = h.owner
        local ok, err = xpcall(h.fn, handler_msgh, tbl)
        __labelle_current_script = saved
        if not ok then
          labelle.raw_log(string.format("[lua] event '%s' handler (owner '%s') failed: %s",
            name, tostring(h.owner), tostring(err)))
        end
      end
    end
  end
end

-- Eviction hook — vm.zig calls this (load-fail and init-fail paths) with
-- the dead script's name: drop every handler that script registered, so
-- a chunk-scope labelle.on can't keep firing into evicted state.
-- Owner-less handlers (owner == nil) never match a purge.
function _G.__labelle_purge_handlers(name)
  if name == nil then return end
  for ev, hs in pairs(handlers) do
    for i = #hs, 1, -1 do
      if hs[i].owner == name then table.remove(hs, i) end
    end
    if #hs == 0 then handlers[ev] = nil end
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
