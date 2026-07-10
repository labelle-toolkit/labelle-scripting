//! Mock host world — the test-side implementation of the Script Runtime
//! Contract (labelle_script.h v1).
//!
//! In production the assembler-generated game binary exports the
//! `labelle_*` symbols and the plugin's externs resolve against them at
//! link time. Tests reproduce that model exactly: this file `export`s the
//! same symbols into the test binary, backed by a toy world (a rework of
//! the engine's poc/language-plugins spike host, extended to the full v1
//! surface: rc conventions, remove, query, prefab, scene, dt stamping).
//! What the tests assert is therefore the REAL seam — same symbols, same
//! ABI, same JSON-in/JSON-out conventions — with a host small enough to
//! inspect from Zig.
//!
//! POC-style shortcuts (fine for a mock, wrong for an engine): fixed-size
//! arrays, JSON stored as opaque strings (only `query` inspects names),
//! single script inbox, main-thread only.

const std = @import("std");

const NAME_CAP = 48;
const JSON_CAP = 512;
const EVENT_CAP = NAME_CAP + JSON_CAP;
const LOG_CAP = 2048; // must hold a full Lua traceback line
// Big enough that a query over 20-digit ids can outgrow the Lua shim's
// fixed QUERY_BUF_CAP (8 KiB ÷ 21 bytes/id ≈ 390) — the grow-and-retry
// test needs the mock to actually overflow it.
const MAX_ENTITIES = 512;
const MAX_COMPONENTS = 8;
const MAX_EVENTS = 64;
const MAX_SUBS = 16;
const MAX_LOGS = 64;

const Component = struct {
    name: [NAME_CAP]u8 = undefined,
    name_len: usize = 0,
    json: [JSON_CAP]u8 = undefined,
    json_len: usize = 0,

    fn nameSlice(self: *const Component) []const u8 {
        return self.name[0..self.name_len];
    }
    fn jsonSlice(self: *const Component) []const u8 {
        return self.json[0..self.json_len];
    }
};

const Entity = struct {
    id: u64 = 0,
    alive: bool = false,
    comps: [MAX_COMPONENTS]Component = undefined,
    comp_count: usize = 0,
};

const Text = struct {
    buf: [EVENT_CAP]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

const LogLine = struct {
    buf: [LOG_CAP]u8 = undefined,
    len: usize = 0,
};

const World = struct {
    next_id: u64 = 1,
    entities: [MAX_ENTITIES]Entity = undefined,
    entity_count: usize = 0,

    /// Script → host emissions (labelle_event_emit), in order.
    events: [MAX_EVENTS]Text = undefined,
    event_count: usize = 0,

    /// Receive side: subscriptions + the FIFO inbox drained via poll.
    subs: [MAX_SUBS]Text = undefined,
    sub_count: usize = 0,
    inbox: [MAX_EVENTS]Text = undefined,
    inbox_head: usize = 0,
    inbox_count: usize = 0,

    logs: [MAX_LOGS]LogLine = undefined,
    log_count: usize = 0,

    scene: [NAME_CAP]u8 = undefined,
    scene_len: usize = 0,

    /// What labelle_time_dt reports; 0 until the plugin's first stamp —
    /// mirroring the contract's "0 before the first tick".
    dt: f32 = 0,

    fn find(self: *World, id: u64) ?*Entity {
        for (self.entities[0..self.entity_count]) |*e| {
            if (e.alive and e.id == id) return e;
        }
        return null;
    }
};

pub var world: World = .{};

/// Fresh world between tests — global state demands explicit resets.
pub fn reset() void {
    world = .{};
}

// ── contract exports: version ────────────────────────────────────────────

export fn labelle_contract_version() u32 {
    return 1;
}

// ── contract exports: entities ───────────────────────────────────────────

export fn labelle_entity_create() u64 {
    if (world.entity_count >= MAX_ENTITIES) return 0;
    const e = &world.entities[world.entity_count];
    e.* = .{ .id = world.next_id, .alive = true };
    world.next_id += 1;
    world.entity_count += 1;
    return e.id;
}

export fn labelle_entity_destroy(id: u64) void {
    if (world.find(id)) |e| e.alive = false;
}

export fn labelle_prefab_spawn(
    name: [*]const u8,
    name_len: usize,
    params_json: ?[*]const u8,
    params_len: usize,
) u64 {
    const id = labelle_entity_create();
    if (id == 0) return 0;
    // Record the prefab identity as a component so tests can assert on it,
    // and honor the {"x":…,"y":…} params as the spawn Position.
    var buf: [JSON_CAP]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{{\"name\":\"{s}\"}}", .{name[0..name_len]}) catch return 0;
    setComponent(id, "Prefab", w.buffered());
    if (params_json != null and params_len > 0) {
        setComponent(id, "Position", params_json.?[0..params_len]);
    } else {
        setComponent(id, "Position", "{\"x\":0,\"y\":0}");
    }
    return id;
}

// ── contract exports: components ─────────────────────────────────────────

/// Shared store path (also used by prefab_spawn). Update-in-place when the
/// component exists — the common per-tick path.
fn setComponent(id: u64, name: []const u8, json: []const u8) void {
    const e = world.find(id) orelse return;
    const n = name[0..@min(name.len, NAME_CAP)];
    const j = json[0..@min(json.len, JSON_CAP)];
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            @memcpy(comp.json[0..j.len], j);
            comp.json_len = j.len;
            return;
        }
    }
    if (e.comp_count >= MAX_COMPONENTS) return;
    const comp = &e.comps[e.comp_count];
    @memcpy(comp.name[0..n.len], n);
    comp.name_len = n.len;
    @memcpy(comp.json[0..j.len], j);
    comp.json_len = j.len;
    e.comp_count += 1;
}

fn entityHas(e: *const Entity, name: []const u8) bool {
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), name)) return true;
    }
    return false;
}

export fn labelle_component_set(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32 {
    if (world.find(id) == null) return -1; // unknown-or-dead entity
    setComponent(id, name[0..name_len], json[0..json_len]);
    return 0;
}

export fn labelle_component_get(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    out: [*]u8,
    out_cap: usize,
) usize {
    const e = world.find(id) orelse return 0;
    const n = name[0..@min(name_len, NAME_CAP)];
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            if (comp.json_len > out_cap) return 0; // "doesn't fit" convention
            @memcpy(out[0..comp.json_len], comp.jsonSlice());
            return comp.json_len;
        }
    }
    return 0;
}

export fn labelle_component_has(id: u64, name: [*]const u8, name_len: usize) i32 {
    const e = world.find(id) orelse return 0;
    return if (entityHas(e, name[0..name_len])) 1 else 0;
}

export fn labelle_component_remove(id: u64, name: [*]const u8, name_len: usize) i32 {
    const e = world.find(id) orelse return -1;
    const n = name[0..name_len];
    for (e.comps[0..e.comp_count], 0..) |*comp, i| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            // Swap-remove: component order is not part of the contract.
            e.comps[i] = e.comps[e.comp_count - 1];
            e.comp_count -= 1;
            return 0;
        }
    }
    return 0; // absent-but-known removes are ok (idempotent)
}

// ── contract exports: queries ────────────────────────────────────────────

export fn labelle_query(
    names_json: [*]const u8,
    names_json_len: usize,
    out: [*]u8,
    out_cap: usize,
) usize {
    const input = names_json[0..names_json_len];
    if (std.mem.indexOfScalar(u8, input, '[') == null) return 0; // malformed
    // Component names are identifiers, so tokenizing on JSON punctuation
    // is a faithful-enough parse for a mock.
    var names: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, input, "[]\", \t");
    while (it.next()) |tok| {
        if (n >= names.len) break;
        names[n] = tok;
        n += 1;
    }
    if (n == 0) return 0;
    // Contract v1 snprintf-style sizing (the query is the contract's one
    // required-size op): RETURN the bytes the complete result needs;
    // WRITE only up to `out_cap`, truncated at the last whole id with
    // the closing `]` reserved so the written prefix stays valid JSON.
    const buf = out[0..out_cap];
    var cur: usize = 0;
    var required: usize = 2; // "[]" — the brackets, matches or not
    var writing = out_cap >= 2;
    if (writing) {
        buf[0] = '[';
        cur = 1;
    }
    var first = true;
    outer: for (world.entities[0..world.entity_count]) |*e| {
        if (!e.alive) continue;
        for (names[0..n]) |nm| {
            if (!entityHas(e, nm)) continue :outer;
        }
        var tmp: [21]u8 = undefined; // u64 max = 20 digits, +1 comma
        var w = std.Io.Writer.fixed(&tmp);
        if (!first) w.writeByte(',') catch unreachable;
        w.print("{d}", .{e.id}) catch unreachable;
        const frag = w.buffered();
        required += frag.len;
        // Reserve one byte for `]`; a fragment that doesn't fit flips to
        // pure counting (rollback-at-last-whole-id semantics).
        if (writing and cur + frag.len <= buf.len - 1) {
            @memcpy(buf[cur..][0..frag.len], frag);
            cur += frag.len;
        } else {
            writing = false;
        }
        first = false;
    }
    if (out_cap >= 2) buf[cur] = ']';
    return required;
}

// ── contract exports: events ─────────────────────────────────────────────

export fn labelle_event_emit(
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32 {
    if (world.event_count >= MAX_EVENTS) return -1;
    const ev = &world.events[world.event_count];
    var w = std.Io.Writer.fixed(&ev.buf);
    w.print("{s} {s}", .{ name[0..name_len], json[0..json_len] }) catch return -1;
    ev.len = w.buffered().len;
    world.event_count += 1;
    return 0;
}

export fn labelle_event_subscribe(name: [*]const u8, name_len: usize) void {
    const n = name[0..@min(name_len, EVENT_CAP)];
    // Dedup per the contract ("duplicates are deduped").
    for (world.subs[0..world.sub_count]) |*s| {
        if (std.mem.eql(u8, s.slice(), n)) return;
    }
    if (world.sub_count >= MAX_SUBS) return;
    const s = &world.subs[world.sub_count];
    @memcpy(s.buf[0..n.len], n);
    s.len = n.len;
    world.sub_count += 1;
}

export fn labelle_event_poll(out: [*]u8, out_cap: usize) usize {
    if (world.inbox_count == 0) return 0;
    const ev = &world.inbox[world.inbox_head];
    world.inbox_head = (world.inbox_head + 1) % MAX_EVENTS;
    world.inbox_count -= 1;
    const len = @min(ev.len, out_cap);
    @memcpy(out[0..len], ev.buf[0..len]);
    return len;
}

// ── contract exports: scene / log / time ─────────────────────────────────

export fn labelle_scene_change(name: [*]const u8, name_len: usize) i32 {
    const n = name[0..name_len];
    // "nope" plays the unknown-scene role so tests can exercise the -1 arm.
    if (n.len == 0 or std.mem.eql(u8, n, "nope")) return -1;
    const len = @min(n.len, NAME_CAP);
    @memcpy(world.scene[0..len], n[0..len]);
    world.scene_len = len;
    return 0;
}

export fn labelle_log(msg: [*]const u8, len: usize) void {
    if (world.log_count >= MAX_LOGS) return;
    const l = &world.logs[world.log_count];
    const n = @min(len, LOG_CAP);
    @memcpy(l.buf[0..n], msg[0..n]);
    l.len = n;
    world.log_count += 1;
}

export fn labelle_time_dt() f32 {
    return world.dt;
}

export fn labelle_time_dt_stamp(dt: f32) void {
    world.dt = dt;
}

// ── host-side test helpers (not part of the contract) ───────────────────

/// Force the id the next `labelle_entity_create` hands out — how tests
/// mint bit-63 u64 ids without burning through 2^63 creates first.
pub fn setNextEntityId(id: u64) void {
    world.next_id = id;
}

/// Emit toward scripts: queued into the inbox only when subscribed — the
/// engine analog of GameEvents dispatch fanning out to script subscribers.
pub fn hostEmit(name: []const u8, json: []const u8) void {
    var subscribed = false;
    for (world.subs[0..world.sub_count]) |*s| {
        if (std.mem.eql(u8, s.slice(), name)) subscribed = true;
    }
    if (!subscribed or world.inbox_count >= MAX_EVENTS) return;
    const slot = (world.inbox_head + world.inbox_count) % MAX_EVENTS;
    const ev = &world.inbox[slot];
    var w = std.Io.Writer.fixed(&ev.buf);
    w.print("{s} {s}", .{ name, json }) catch return;
    ev.len = w.buffered().len;
    world.inbox_count += 1;
}

/// The stored JSON of a component, or null when entity/component is gone.
pub fn componentJson(id: u64, name: []const u8) ?[]const u8 {
    const e = world.find(id) orelse return null;
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), name)) return comp.jsonSlice();
    }
    return null;
}

pub fn entityAlive(id: u64) bool {
    return world.find(id) != null;
}

pub fn aliveCount() usize {
    var n: usize = 0;
    for (world.entities[0..world.entity_count]) |*e| {
        if (e.alive) n += 1;
    }
    return n;
}

/// Did any script→host emission contain `needle`? (Entries are
/// "<name> <json>".)
pub fn eventsContain(needle: []const u8) bool {
    for (world.events[0..world.event_count]) |*ev| {
        if (std.mem.indexOf(u8, ev.slice(), needle) != null) return true;
    }
    return false;
}

/// Did any labelle_log line contain `needle`? Error-path assertions
/// (tracebacks, chunk names) go through this.
pub fn logsContain(needle: []const u8) bool {
    for (world.logs[0..world.log_count]) |*l| {
        if (std.mem.indexOf(u8, l.buf[0..l.len], needle) != null) return true;
    }
    return false;
}

pub fn sceneName() []const u8 {
    return world.scene[0..world.scene_len];
}
