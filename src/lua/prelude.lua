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
-- Per-frame allocation rule (RFC-LANGUAGE-PLUGINS revs 14-15): the
-- component boundary is the real per-frame allocator — a fresh table per
-- e:get times a thousand entities times sixty frames is the garbage that
-- matters, not script-local temporaries. Two idioms remove it:
-- `e:get(name, into)` refills a caller-owned table (json.decode_into
-- backs it), and FrameArray is the reusable per-frame list (Lua 5.4 has
-- no table.clear; `t = {}` per frame allocates). What garbage remains is
-- collected on a budget: labelle.__tick_controllers drives one
-- incremental GC step per Controller tick (vm.zig owns the budget).
--
-- Component-ref rule (RFC-LANGUAGE-PLUGINS revs 6-7, "one DSL, two
-- consumers"): `local Hunger = labelle.component("Hunger", { level = 1.0 })`
-- is a SCHEMA DECLARATION at build time (the labelle-declare runner
-- extracts it and the assembler codegens a real Zig component) and, at
-- runtime, evaluates to a lightweight REF — a table carrying the name —
-- accepted anywhere a component-name string is (Entity get/set/has/remove,
-- game.query). The runtime call declares NOTHING; the component already
-- exists in the game's registry because the build saw the same line.
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
  -- Fast path: no escape before the closing quote → one substring, no
  -- per-character builder table. Component keys and short values live
  -- here, and Lua interns short strings (≤ 40 bytes), so a steady-state
  -- loop re-reading the same keys every tick allocates NOTHING new for
  -- them — the decode-into zero-allocation story depends on this.
  local q = s:find('"', i + 1, true)
  if q == nil then decode_error(s, i, "unterminated string") end
  local bs = s:find("\\", i + 1, true)
  if bs == nil or bs > q then
    return s:sub(i + 1, q - 1), q + 1
  end
  -- Slow path (an escape sits inside): the per-character builder.
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

-- Object fields decoded into `obj` — the caller picks the table, which
-- is what lets decode_into aim the top level at a REUSED table while
-- decode_value keeps handing it a fresh one. `i` sits on the '{'.
local function decode_object(s, i, obj)
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
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local ch = s:sub(i, i)
  if ch == "" then decode_error(s, i, "unexpected end of input") end
  if ch == "{" then
    return decode_object(s, i, {})
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

--- Decode a top-level JSON OBJECT into `into`, reusing the caller's
--- table instead of allocating a fresh one per decode — the leg backing
--- `Entity:get(name, into)`, where the component boundary is the real
--- per-frame allocator. Returns `into`.
---
--- Stale keys are handled clear-all-then-fill: every existing key of
--- `into` is nilled first (a plain pairs walk assigning nil — it
--- allocates nothing, and refilling the SAME keys right after revives
--- their hash slots without a rehash), then the object's fields are
--- written in. The alternative — mark-and-sweep of unseen keys — would
--- need a per-call "seen" set, i.e. exactly the allocation this exists
--- to remove.
---
--- NESTED tables (object or array values) still allocate fresh on every
--- decode — v1 by design: the boundary win is the top-level per-entity
--- read, so keep hot components FLAT. Anything non-object at the top
--- level is an error, as is a decode error mid-way — in which case the
--- contents of `into` are unspecified.
function json.decode_into(s, into)
  if type(s) ~= "string" then
    error("json.decode_into: expected a string, got " .. type(s), 0)
  end
  if type(into) ~= "table" then
    error("json.decode_into: expected a table to fill, got " .. type(into), 0)
  end
  local i = skip_ws(s, 1)
  if s:sub(i, i) ~= "{" then
    decode_error(s, i, "decode_into needs a top-level object")
  end
  for k in pairs(into) do
    into[k] = nil
  end
  local _, j = decode_object(s, i, into)
  j = skip_ws(s, j)
  if j <= #s then decode_error(s, j, "trailing garbage") end
  return into
end

-- ── component refs ───────────────────────────────────────────────────────
-- A ref is `{ __labelle_component = "<Name>" }` — what labelle.component
-- returns in BOTH modes (see the header's component-ref rule; the declare
-- runner's stub returns the same shape so chunk-scope `local H =
-- labelle.component(...)` behaves identically). `component_name`
-- normalizes ref-or-string at every site that accepts a component name.

local function component_name(name)
  if type(name) == "table" then
    local ref = name.__labelle_component
    if type(ref) ~= "string" then
      -- Level 3: component_name(1) → the Entity method / query (2) → the
      -- script's call site (3).
      error("labelle: expected a component name or labelle.component ref", 3)
    end
    return ref
  end
  return name
end

-- ── Entity ───────────────────────────────────────────────────────────────
-- Thin id wrapper: components in and out as plain Lua tables, the JSON leg
-- hidden. `e.id` stays public — events and raw calls speak ids. Component
-- name parameters accept a string or a labelle.component ref.

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
--- With `into`, the read REFILLS that caller-owned table and returns it
--- instead of allocating a fresh one — the hot-loop form (`name` may be
--- a string or a labelle.component ref in both spellings):
---
---   local h = {}                      -- once, in init()
---   for e in game.query(Hunger) do
---     e:get(Hunger, h)                -- refill: no per-read table
---     h.level = h.level - dt * 0.01
---     e:set(Hunger, h)
---   end
---
--- Top-level fields are set and stale keys from the previous fill are
--- cleared; NESTED values still allocate fresh per read (keep hot
--- components flat — see json.decode_into for both rules). When the
--- component is absent the call returns nil and leaves `into` untouched,
--- mirroring the ruby sub-module's get_into.
function Entity:get(name, into)
  local s = labelle.raw_component_get(self.id, component_name(name))
  if s == "" then return nil end
  if into == nil then return json.decode(s) end
  return json.decode_into(s, into)
end

--- Set (REPLACE semantics) a component from a table; nil/{} means "all
--- defaults". Returns true on success.
function Entity:set(name, tbl)
  local payload = tbl == nil and "" or json.encode(tbl)
  return labelle.raw_component_set(self.id, component_name(name), payload) == 0
end

function Entity:has(name)
  return labelle.raw_component_has(self.id, component_name(name))
end

function Entity:remove(name)
  return labelle.raw_component_remove(self.id, component_name(name)) == 0
end

function Entity:destroy()
  labelle.raw_entity_destroy(self.id)
end

-- ── FrameArray ───────────────────────────────────────────────────────────
-- Per-frame scratch list — Zig's clearRetainingCapacity idiom made
-- first-class for scripts (RFC-LANGUAGE-PLUGINS revs 14-15). Lua 5.4 has
-- no table.clear, and a fresh `t = {}` every frame is exactly the
-- per-frame allocation this exists to remove. A FrameArray preallocates
-- its backing table once and tracks a LOGICAL length: `push` is an
-- in-bounds array-part store (no rehash, no allocation), `clear` resets
-- the length only (the storage — and any object references parked in it —
-- survive until the next frame's pushes overwrite them), and growth
-- happens ONLY when a push overflows capacity: the backing doubles, one
-- deliberate reallocation, visible through growth_count() so a warmed
-- loop can assert it stays flat. Mirrors the ruby sub-module's
-- Labelle::FrameArray (same push-past-cap policy: double and count).
--
--   local fa                 -- construct in init(), not at chunk scope:
--   function init()          -- chunk scope also runs in declare mode,
--     fa = FrameArray.new(64)-- where only the labelle stub exists
--   end
--   function update(dt)
--     fa:clear()
--     for e in game.query("Enemy") do fa:push(e) end
--     for i = 1, fa:size() do attack(fa:get(i)) end
--   end

local FrameArray = {}
FrameArray.__index = FrameArray

--- A FrameArray with room for `cap` values (a positive integer). The
--- backing is filled with `false` up front — that one-time fill is what
--- sizes the table's array part, so in-bounds pushes never reallocate.
function FrameArray.new(cap)
  if math.type(cap) ~= "integer" or cap < 1 then
    error("FrameArray.new: capacity must be a positive integer", 2)
  end
  local buf = {}
  for i = 1, cap do buf[i] = false end
  return setmetatable({ buf = buf, n = 0, cap = cap, growths = 0 }, FrameArray)
end

--- Append `v`. In bounds this is a plain store into the preallocated
--- backing; a push past capacity first DOUBLES the backing (one
--- deliberate reallocation, counted — the ruby FrameArray's policy).
--- Returns the FrameArray, so pushes chain.
function FrameArray:push(v)
  local n = self.n + 1
  if n > self.cap then
    local newcap = self.cap * 2
    local buf = self.buf
    for i = self.cap + 1, newcap do buf[i] = false end
    self.cap = newcap
    self.growths = self.growths + 1
  end
  self.buf[n] = v
  self.n = n
  return self
end

--- Logical length back to zero; capacity and backing survive — O(1),
--- allocation-free, and the whole point (`buf = {}` would re-shrink).
function FrameArray:clear()
  self.n = 0
  return self
end

function FrameArray:size()
  return self.n
end

function FrameArray:capacity()
  return self.cap
end

--- How many pushes had to grow the backing. A warmed per-frame loop
--- asserts this stays flat: growth means the capacity guess was wrong,
--- and the point of a FrameArray is that steady state never reallocates.
function FrameArray:growth_count()
  return self.growths
end

--- Value at 1-based logical index `i`; nil outside 1..size() (the
--- backing beyond the logical length is invisible, whatever it holds).
function FrameArray:get(i)
  if i == nil or i < 1 or i > self.n then return nil end
  return self.buf[i]
end

--- Overwrite an EXISTING slot (1..size()); raises out of logical
--- bounds — extending is push's job.
function FrameArray:set(i, v)
  if i == nil or i < 1 or i > self.n then
    error("FrameArray:set: index out of bounds", 2)
  end
  self.buf[i] = v
end

--- fn(value) over the logical contents, in order. Hoist `fn` out of the
--- frame loop — a fresh closure per frame is itself the per-frame
--- allocation this class exists to avoid.
function FrameArray:each(fn)
  local buf, n = self.buf, self.n
  for i = 1, n do fn(buf[i]) end
  return self
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

--- Iterate entities carrying ALL the named components (strings or
--- labelle.component refs, freely mixed):
---   for e in game.query("CloudDrift", Position) do ... end
--- Yields Entity wrappers over the contract's id-JSON snapshot, so spawning
--- or destroying entities inside the loop is safe.
function game.query(...)
  local names = {}
  for i = 1, select("#", ...) do
    names[i] = component_name((select(i, ...)))
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

--- Declare a component — at BUILD time (the labelle-declare runner
--- extracts `name` + the spec's inferred field schema and the assembler
--- generates a real registry component from it). At RUNTIME — here — the
--- same call is pure sugar: it validates nothing, declares nothing, and
--- returns a lightweight ref usable anywhere a component-name string is:
---
---   local Hunger = labelle.component("Hunger", { level = 1.0 })
---   function update(dt)
---     for e in game.query(Hunger) do
---       local h = e:get(Hunger)
---       h.level = h.level - dt * 0.01
---       e:set(Hunger, h)
---     end
---   end
---
--- One DSL, two consumers (RFC-LANGUAGE-PLUGINS): the spec/opts tables are
--- the build-time contract and are deliberately ignored here — the
--- generated component (fields, defaults, persist policy) already lives in
--- the game's registry by the time this line runs.
function labelle.component(name, spec, opts)
  if type(name) ~= "string" or name == "" then
    error("labelle.component: expected a non-empty component name string", 2)
  end
  local _, _ = spec, opts -- build-time contract; unused at runtime
  return { __labelle_component = name }
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

-- ── per-tick housekeeping ────────────────────────────────────────────────
-- The Controller's once-per-tick prelude entry, called at the END of
-- every tick after all script update(dt)s (on the ruby backend this same
-- slot drives the controller tier; this backend has none, so it does VM
-- housekeeping instead). One budgeted GC step per tick smears collection
-- cost across frames — the frame's garbage is collected right after the
-- frame produces it, instead of debt piling into a mid-frame pause. The
-- budget model (and its interaction with Lua 5.4's own incremental
-- pacing, which stays on as the backstop) lives with vm.zig's
-- gc_step_budget_kb; labelle.raw_gc_set_step_budget tunes it.
function labelle.__tick_controllers(dt)
  local _ = dt -- housekeeping is time-independent today
  labelle.raw_gc_step()
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
_G.FrameArray = FrameArray

-- name → private _ENV of each registered script; vm.zig fills it in
-- loadScript and reads it in callScriptHook.
_G.__labelle_scripts = {}
