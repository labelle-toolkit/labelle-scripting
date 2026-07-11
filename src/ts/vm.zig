//! QuickJS (quickjs-ng 0.15) state management for the `typescript`
//! sub-module. Scripts are plain JavaScript at runtime — the TS→JS
//! transpile arrives with the assembler build-hook seam (assembler#586);
//! what makes this the *typescript* backend today is the authoring
//! surface: contract/labelle.d.ts types the whole script API, and ES
//! modules are the script format.
//!
//! The C API is hand-declared (the lua/mruby pattern — no @cImport).
//! quickjs-ng v0.15 exports everything we call as real symbols (even
//! JS_FreeValue/JS_DupValue, inline in older trees), so unlike mruby no
//! functional shim is needed; src/ts/abi_check.c pins the hand-mirrored
//! facts (JSValue layout, tag numbering, flag values) with
//! _Static_asserts against the fetched headers instead.
//!
//! Error policy (the load-bearing part, mirroring src/lua/vm.zig):
//! QuickJS never longjmps through C frames — a throwing script leaves an
//! exception pending on the context and returns JS_EXCEPTION. After every
//! entry the VM checks, formats "<Error>: <message>" plus the error's
//! `.stack` through labelle_log, clears the slot, and moves on — a broken
//! behavior script must NEVER kill the game tick. Boot-point failures are
//! stricter, exactly like lua: a module body that throws (loadScript) or
//! an `init()` that throws (evictScript, driven by the shared Controller)
//! evicts the script — its registry entry and every event handler it
//! registered are purged, so a half-initialized script never receives
//! `update`/`deinit`.
//!
//! Script isolation: each registered script is evaluated as its own ES
//! MODULE (JS_EVAL_TYPE_MODULE). Module scope is real, engine-native
//! isolation — top-level `let`/`const`/`function` are private to the
//! file, two scripts defining `update` never collide (no lua _ENV trick,
//! no ruby harvest) — and hooks are the module's EXPORTS (`export
//! function init/update/deinit`), read off the module namespace object.
//! The prelude keeps the namespace registry in the global
//! `__labelle_scripts` (name → namespace), which is how `callScriptHook`
//! finds each script's hooks and how eviction removes them.
//!
//! One consequence worth naming: an UNexported `function update()` is
//! module-private and never called — the export IS the hook contract
//! (contract/labelle.d.ts and the README both say so). Modules are also
//! strict mode by spec, imports are refused (no module loader — scripts
//! arrive through registerScript, never disk), and top-level await is
//! rejected at load (a pending module promise would mean hooks running
//! against a half-evaluated script).
//!
//! Current-script tracking: around EVERY entry from the VM into script
//! code — the module body in `loadScript`, each hook in `callScriptHook`
//! — the global `__labelle_current_script` is set to the script's name
//! and cleared after. It is the VM-truth answer to "whose code is
//! running", which the prelude's `labelle.on` reads to record handler
//! ownership (and `dispatch_inbox` re-stamps around each handler call).
//! Ownership canNOT be derived from the registering call site: a
//! script-local helper closing over an alias of `labelle.on` gives the
//! registration no visible home, and its handlers would dodge the
//! eviction purge (the lua module's hard-won rule).
//!
//! GC discipline: QuickJS is reference-counted with a cycle collector on
//! top — acyclic garbage frees deterministically at the last reference,
//! so there is no per-frame collector step to budget. The discipline that
//! IS load-bearing sits on this file: every owned JSValue must be freed
//! (in Debug, JS_FreeRuntime asserts the heap is empty — a leaked handle
//! aborts the test suite loudly).

const std = @import("std");
const contract = @import("../contract.zig");

/// Hand-declared quickjs-ng 0.15 C API — just the slice this plugin uses.
/// Real exported symbols only; the constants are pinned by abi_check.c.
pub const c = struct {
    pub const Runtime = opaque {};
    pub const Context = opaque {};
    /// JSModuleDef — only ever held between compile and namespace fetch.
    pub const ModuleDef = opaque {};
    pub const Atom = u32;

    // enum JS_TAG_* (quickjs.h; abi_check.c pins every one we mirror).
    // Negative tags are the reference-counted ones.
    pub const TAG_BIG_INT: i64 = -9;
    pub const TAG_SYMBOL: i64 = -8;
    pub const TAG_STRING: i64 = -7;
    pub const TAG_STRING_ROPE: i64 = -6;
    pub const TAG_MODULE: i64 = -3;
    pub const TAG_OBJECT: i64 = -1;
    pub const TAG_INT: i64 = 0;
    pub const TAG_BOOL: i64 = 1;
    pub const TAG_NULL: i64 = 2;
    pub const TAG_UNDEFINED: i64 = 3;
    pub const TAG_EXCEPTION: i64 = 6;
    pub const TAG_SHORT_BIG_INT: i64 = 7;
    pub const TAG_FLOAT64: i64 = 8;

    // JS_Eval flags.
    pub const EVAL_TYPE_GLOBAL: c_int = 0;
    pub const EVAL_TYPE_MODULE: c_int = 1 << 0;
    pub const EVAL_FLAG_COMPILE_ONLY: c_int = 1 << 5;

    // JS_PromiseState results.
    pub const PROMISE_NOT_A_PROMISE: c_int = -1;
    pub const PROMISE_PENDING: c_int = 0;
    pub const PROMISE_FULFILLED: c_int = 1;
    pub const PROMISE_REJECTED: c_int = 2;

    // JS_GetOwnPropertyNames flags and property flags.
    pub const GPN_STRING_MASK: c_int = 1 << 0;
    pub const GPN_ENUM_ONLY: c_int = 1 << 4;
    pub const PROP_C_W_E: c_int = 7;

    /// JSValue under JS_NAN_BOXING=0 (build.zig pins the define on every
    /// target): a {union, i64 tag} struct passed by value. Integers,
    /// floats, bools, null/undefined and short bigints are immediate —
    /// only the pointer arm references the heap. abi_check.c pins the
    /// layout.
    pub const Value = extern struct {
        u: extern union {
            int32: i32,
            float64: f64,
            ptr: ?*anyopaque,
        },
        tag: i64,

        pub const undefined_: Value = .{ .u = .{ .int32 = 0 }, .tag = TAG_UNDEFINED };
        pub const null_: Value = .{ .u = .{ .int32 = 0 }, .tag = TAG_NULL };
        pub const exception: Value = .{ .u = .{ .int32 = 0 }, .tag = TAG_EXCEPTION };

        pub fn int(i: i32) Value {
            return .{ .u = .{ .int32 = i }, .tag = TAG_INT };
        }
        pub fn float(f: f64) Value {
            return .{ .u = .{ .float64 = f }, .tag = TAG_FLOAT64 };
        }
        pub fn boolean(b: bool) Value {
            return .{ .u = .{ .int32 = @intFromBool(b) }, .tag = TAG_BOOL };
        }

        pub fn isException(v: Value) bool {
            return v.tag == TAG_EXCEPTION;
        }
        pub fn isUndefined(v: Value) bool {
            return v.tag == TAG_UNDEFINED;
        }
        pub fn isNull(v: Value) bool {
            return v.tag == TAG_NULL;
        }
        pub fn isString(v: Value) bool {
            return v.tag == TAG_STRING or v.tag == TAG_STRING_ROPE;
        }
        pub fn isObject(v: Value) bool {
            return v.tag == TAG_OBJECT;
        }
        pub fn isModule(v: Value) bool {
            return v.tag == TAG_MODULE;
        }
        pub fn isBigInt(v: Value) bool {
            return v.tag == TAG_BIG_INT or v.tag == TAG_SHORT_BIG_INT;
        }
        pub fn isNumberTag(v: Value) bool {
            return v.tag == TAG_INT or v.tag == TAG_FLOAT64;
        }
    };

    /// JSCFunction — the C function shape behind JS_NewCFunction2 (the
    /// generic proto: argv values are BORROWED, the return is owned).
    pub const CFunction = fn (ctx: ?*Context, this: Value, argc: c_int, argv: ?[*]const Value) callconv(.c) Value;

    /// JSPropertyEnum (abi_check.c pins the layout).
    pub const PropertyEnum = extern struct {
        is_enumerable: bool,
        atom: Atom,
    };

    /// JSMemoryUsage — 26 int64 counters; only malloc_count (live
    /// allocation count, the raw_gc_live test seam) is read by name.
    /// abi_check.c pins size and that field's offset.
    pub const MemoryUsage = extern struct {
        malloc_size: i64,
        malloc_limit: i64,
        memory_used_size: i64,
        malloc_count: i64,
        memory_used_count: i64,
        atom_count: i64,
        atom_size: i64,
        str_count: i64,
        str_size: i64,
        obj_count: i64,
        obj_size: i64,
        prop_count: i64,
        prop_size: i64,
        shape_count: i64,
        shape_size: i64,
        js_func_count: i64,
        js_func_size: i64,
        js_func_code_size: i64,
        js_func_pc2line_count: i64,
        js_func_pc2line_size: i64,
        c_func_count: i64,
        array_count: i64,
        fast_array_count: i64,
        fast_array_elements: i64,
        binary_object_count: i64,
        binary_object_size: i64,
    };

    // Runtime and context lifecycle.
    pub extern fn JS_NewRuntime() ?*Runtime;
    pub extern fn JS_FreeRuntime(rt: ?*Runtime) void;
    pub extern fn JS_NewContext(rt: ?*Runtime) ?*Context;
    pub extern fn JS_FreeContext(ctx: ?*Context) void;
    pub extern fn JS_GetRuntime(ctx: ?*Context) ?*Runtime;
    pub extern fn JS_RunGC(rt: ?*Runtime) void;
    pub extern fn JS_ComputeMemoryUsage(rt: ?*Runtime, s: *MemoryUsage) void;
    pub extern fn JS_ExecutePendingJob(rt: ?*Runtime, pctx: *?*Context) c_int;

    // Evaluation. NOTE: JS_Eval requires input[input_len] == 0 — sources
    // arrive as sentinel-terminated slices for exactly this reason.
    pub extern fn JS_Eval(ctx: ?*Context, input: [*]const u8, input_len: usize, filename: [*:0]const u8, eval_flags: c_int) Value;
    pub extern fn JS_EvalFunction(ctx: ?*Context, fun_obj: Value) Value;
    pub extern fn JS_GetModuleNamespace(ctx: ?*Context, m: ?*ModuleDef) Value;
    pub extern fn JS_PromiseState(ctx: ?*Context, promise: Value) c_int;
    pub extern fn JS_PromiseResult(ctx: ?*Context, promise: Value) Value;

    // Exceptions.
    pub extern fn JS_GetException(ctx: ?*Context) Value;
    pub extern fn JS_HasException(ctx: ?*Context) bool;
    pub extern fn JS_Throw(ctx: ?*Context, obj: Value) Value;
    /// Variadic printf-style — call with a constant, %-free message only.
    pub extern fn JS_ThrowTypeError(ctx: ?*Context, fmt: [*:0]const u8, ...) Value;
    pub extern fn JS_ThrowSyntaxError(ctx: ?*Context, fmt: [*:0]const u8, ...) Value;
    pub extern fn JS_ThrowRangeError(ctx: ?*Context, fmt: [*:0]const u8, ...) Value;

    // Reference counting (real exports in quickjs-ng 0.15).
    pub extern fn JS_FreeValue(ctx: ?*Context, v: Value) void;
    pub extern fn JS_DupValue(ctx: ?*Context, v: Value) Value;

    // Objects, arrays and properties.
    pub extern fn JS_GetGlobalObject(ctx: ?*Context) Value;
    pub extern fn JS_NewObject(ctx: ?*Context) Value;
    pub extern fn JS_NewArray(ctx: ?*Context) Value;
    pub extern fn JS_IsArray(v: Value) bool;
    pub extern fn JS_IsFunction(ctx: ?*Context, v: Value) bool;
    pub extern fn JS_GetPropertyStr(ctx: ?*Context, this_obj: Value, prop: [*:0]const u8) Value;
    pub extern fn JS_SetPropertyStr(ctx: ?*Context, this_obj: Value, prop: [*:0]const u8, val: Value) c_int;
    pub extern fn JS_GetProperty(ctx: ?*Context, this_obj: Value, prop: Atom) Value;
    pub extern fn JS_SetProperty(ctx: ?*Context, this_obj: Value, prop: Atom, val: Value) c_int;
    pub extern fn JS_GetPropertyUint32(ctx: ?*Context, this_obj: Value, idx: u32) Value;
    pub extern fn JS_SetPropertyUint32(ctx: ?*Context, this_obj: Value, idx: u32, val: Value) c_int;
    pub extern fn JS_DefinePropertyValue(ctx: ?*Context, this_obj: Value, prop: Atom, val: Value, flags: c_int) c_int;
    pub extern fn JS_DeleteProperty(ctx: ?*Context, obj: Value, prop: Atom, flags: c_int) c_int;
    pub extern fn JS_GetLength(ctx: ?*Context, obj: Value, pres: *i64) c_int;
    pub extern fn JS_GetOwnPropertyNames(ctx: ?*Context, ptab: *?[*]PropertyEnum, plen: *u32, obj: Value, flags: c_int) c_int;
    pub extern fn JS_FreePropertyEnum(ctx: ?*Context, tab: ?[*]PropertyEnum, len: u32) void;

    // Atoms.
    pub extern fn JS_NewAtomLen(ctx: ?*Context, str: [*]const u8, len: usize) Atom;
    pub extern fn JS_FreeAtom(ctx: ?*Context, v: Atom) void;
    pub extern fn JS_AtomToCStringLen(ctx: ?*Context, plen: ?*usize, atom: Atom) ?[*:0]const u8;

    // Strings.
    pub extern fn JS_NewStringLen(ctx: ?*Context, str: [*]const u8, len: usize) Value;
    pub extern fn JS_ToCStringLen2(ctx: ?*Context, plen: ?*usize, val: Value, cesu8: bool) ?[*:0]const u8;
    pub extern fn JS_FreeCString(ctx: ?*Context, ptr: ?[*:0]const u8) void;

    // Numbers and BigInt.
    pub extern fn JS_ToFloat64(ctx: ?*Context, pres: *f64, val: Value) c_int;
    /// JS_ToInt64 for numbers, JS_ToBigInt64 (mod-2^64 wrap) for BigInts.
    pub extern fn JS_ToInt64Ext(ctx: ?*Context, pres: *i64, val: Value) c_int;
    pub extern fn JS_NewBigInt64(ctx: ?*Context, v: i64) Value;
    pub extern fn JS_NewBigUint64(ctx: ?*Context, v: u64) Value;

    // Calls and C functions.
    pub extern fn JS_Call(ctx: ?*Context, func_obj: Value, this_obj: Value, argc: c_int, argv: ?[*]const Value) Value;
    pub extern fn JS_NewCFunction2(ctx: ?*Context, func: *const CFunction, name: [*:0]const u8, length: c_int, cproto: c_int, magic: c_int) Value;
};

/// Global name of the prelude-owned namespace registry:
/// `__labelle_scripts[name]` is the module namespace of the script
/// registered under `name`.
const SCRIPTS_REGISTRY: [*:0]const u8 = "__labelle_scripts";

/// Global holding the name of the script whose code the VM is currently
/// executing (undefined between entries) — see the module doc. Written by
/// `setCurrentScript` around every VM→script entry; read by the prelude's
/// `labelle.on` for handler ownership.
const CURRENT_SCRIPT_GLOBAL: [*:0]const u8 = "__labelle_current_script";

/// Longest accepted script name for the module-filename buffer (stack
/// lines print "(<name>:<line>)"). Longer names truncate.
const FILENAME_CAP = 128;

/// Cap for one formatted error log line. Stacks can outgrow anything;
/// truncation beats a heap allocation inside the error path.
const ERROR_LOG_CAP = 2048;

/// Format + route one error line through the host's log sink.
fn logError(context: []const u8, text: []const u8) void {
    var buf: [ERROR_LOG_CAP]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    if (context.len > 0)
        w.print("[ts] {s}: {s}", .{ context, text }) catch {}
    else
        w.print("[ts] {s}", .{text}) catch {};
    const line = w.buffered();
    contract.labelle_log(line.ptr, line.len);
}

/// One embedded QuickJS VM. Plain two-pointer value — the Controller owns
/// exactly one per game process.
pub const Vm = struct {
    rt: *c.Runtime,
    ctx: *c.Context,

    pub fn init() error{JsStateInit}!Vm {
        const rt = c.JS_NewRuntime() orelse return error.JsStateInit;
        // JS_NewContext installs ALL intrinsics: game scripts are
        // first-party content, so the full language (JSON, Math, Map,
        // BigInt, RegExp, …) is available — the lua "full stdlib" call.
        const ctx = c.JS_NewContext(rt) orelse {
            c.JS_FreeRuntime(rt);
            return error.JsStateInit;
        };
        return .{ .rt = rt, .ctx = ctx };
    }

    /// Close the VM. The context free releases the globals (registry,
    /// namespaces, handlers, prelude) and every module; the runtime free
    /// asserts (in Debug) that nothing leaked — which is the whole
    /// teardown story AND the leak police for this file's own handles.
    pub fn close(self: Vm) void {
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    /// Run queued promise jobs (microtasks) to completion — after every
    /// VM entry, so a script using async/await for fire-and-forget work
    /// isn't silently frozen and rejections surface in the log instead of
    /// vanishing. Job errors never abort anything (update-hook policy).
    pub fn drainJobs(self: Vm) void {
        while (true) {
            var out_ctx: ?*c.Context = null;
            const rc = c.JS_ExecutePendingJob(self.rt, &out_ctx);
            if (rc == 0) return; // queue empty
            if (rc < 0) _ = self.logPendingException("async job");
        }
    }

    /// Compile + run an anonymous GLOBAL chunk — how the prelude installs
    /// itself (global eval, so its explicit `globalThis.*` exports land
    /// where module scripts can see them). Returns false (logged) on
    /// compile or runtime error.
    pub fn runChunk(self: Vm, chunkname: [*:0]const u8, source: [:0]const u8) bool {
        const ret = c.JS_Eval(self.ctx, source.ptr, source.len, chunkname, c.EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, ret);
        if (ret.isException()) {
            _ = self.logPendingException(std.mem.span(chunkname));
            return false;
        }
        return true;
    }

    /// Compile + evaluate one registered script as an ES MODULE and
    /// record its namespace in `__labelle_scripts`. The module filename
    /// is the script name, so every error and stack line reads
    /// "<name>:<line>". Returns false (logged) on any failure — and
    /// purges whatever handlers the failing body managed to register
    /// before it threw, so nothing keeps firing into half-initialized
    /// state (the registry itself is only written on success, so there is
    /// never an entry to pull back out).
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        const ctx = self.ctx;

        var namebuf: [FILENAME_CAP]u8 = undefined;
        const n = @min(name.len, namebuf.len - 1);
        @memcpy(namebuf[0..n], name[0..n]);
        namebuf[n] = 0;
        const filename: [*:0]const u8 = @ptrCast(&namebuf);

        // Compile only: parse errors (and refused `import`s — there is no
        // module loader on purpose) surface here, before anything ran, so
        // there is nothing to purge yet.
        const compiled = c.JS_Eval(
            ctx,
            source.ptr,
            source.len,
            filename,
            c.EVAL_TYPE_MODULE | c.EVAL_FLAG_COMPILE_ONLY,
        );
        if (compiled.isException()) {
            _ = self.logPendingException(name);
            return false;
        }
        if (!compiled.isModule()) {
            // Cannot happen for TYPE_MODULE compiles; drop whatever it is
            // rather than corrupt the registry.
            c.JS_FreeValue(ctx, compiled);
            logError(name, "module compile returned a non-module value");
            return false;
        }
        // The JSModuleDef survives JS_EvalFunction (the context's module
        // list holds its own reference) — grab it now for the namespace
        // fetch below, before the module value is consumed.
        const module_def: ?*c.ModuleDef = @ptrCast(compiled.u.ptr);

        // The module body is a VM→script entry: stamp the current script
        // so `labelle.on` at module scope attributes its handlers here.
        self.setCurrentScript(name);
        const ret = c.JS_EvalFunction(ctx, compiled); // consumes `compiled`
        self.setCurrentScript(null);
        self.drainJobs();

        // Module evaluation is spec'd async: a throwing body lands in the
        // returned promise's REJECTION (settled synchronously for bodies
        // without top-level await), while link-time errors come back as a
        // plain exception. Handle both shapes.
        var failed = false;
        if (ret.isException()) {
            _ = self.logPendingException(name);
            failed = true;
        } else switch (c.JS_PromiseState(ctx, ret)) {
            c.PROMISE_REJECTED => {
                const err = c.JS_PromiseResult(ctx, ret);
                self.logErrorValue(name, err);
                c.JS_FreeValue(ctx, err);
                failed = true;
            },
            c.PROMISE_PENDING => {
                // Top-level await: hooks would run against a module that
                // never finished evaluating. Refuse deterministically.
                logError(name, "top-level await is not supported — script evicted");
                failed = true;
            },
            else => {}, // fulfilled (or not a promise) — evaluated clean
        }
        c.JS_FreeValue(ctx, ret);
        if (failed) {
            // Whatever the body registered before throwing (a module-scope
            // labelle.on above the failing line) must not outlive it.
            self.purgeScriptHandlers(name);
            return false;
        }

        // __labelle_scripts[name] = namespace. The registry is a plain
        // prelude object; bail loudly when the prelude never ran.
        const ns = c.JS_GetModuleNamespace(ctx, module_def);
        if (ns.isException()) {
            _ = self.logPendingException(name);
            self.purgeScriptHandlers(name);
            return false;
        }
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const registry = c.JS_GetPropertyStr(ctx, global, SCRIPTS_REGISTRY);
        defer c.JS_FreeValue(ctx, registry);
        if (!registry.isObject()) {
            c.JS_FreeValue(ctx, ns);
            logError("", "script registry missing — prelude not installed?");
            return false;
        }
        const name_atom = c.JS_NewAtomLen(ctx, name.ptr, name.len);
        defer c.JS_FreeAtom(ctx, name_atom);
        if (c.JS_SetProperty(ctx, registry, name_atom, ns) < 0) { // consumes ns
            _ = self.logPendingException(name);
            self.purgeScriptHandlers(name);
            return false;
        }
        return true;
    }

    /// Stamp (or clear, with null) the `__labelle_current_script` global —
    /// the VM-truth "whose code is running" marker every VM→script entry
    /// sets and clears (see the module doc). Module scripts can't shadow
    /// it by accident: their top-level declarations are module-scoped.
    fn setCurrentScript(self: Vm, name: ?[]const u8) void {
        const ctx = self.ctx;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const v = if (name) |nm|
            c.JS_NewStringLen(ctx, nm.ptr, nm.len)
        else
            c.Value.undefined_;
        _ = c.JS_SetPropertyStr(ctx, global, CURRENT_SCRIPT_GLOBAL, v); // consumes v
    }

    /// Pull `name`'s namespace out of `__labelle_scripts`, making the
    /// script invisible to `callScriptHook` (hooks look the namespace up
    /// by name and silently skip missing entries). No-op when the
    /// registry — or the entry — is missing.
    fn removeScriptEntry(self: Vm, name: []const u8) void {
        const ctx = self.ctx;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const registry = c.JS_GetPropertyStr(ctx, global, SCRIPTS_REGISTRY);
        defer c.JS_FreeValue(ctx, registry);
        if (!registry.isObject()) return;
        const name_atom = c.JS_NewAtomLen(ctx, name.ptr, name.len);
        defer c.JS_FreeAtom(ctx, name_atom);
        _ = c.JS_DeleteProperty(ctx, registry, name_atom, 0);
    }

    /// Quarantine a script whose `init()` failed: remove its registry
    /// entry so the `update`/`deinit` loops skip it, purge its
    /// `labelle.on` handlers (module-scope subscriptions would otherwise
    /// keep firing into the broken state), and log the eviction once (the
    /// init stack alone would not explain why the script went silent).
    pub fn evictScript(self: Vm, name: []const u8) void {
        self.removeScriptEntry(name);
        self.purgeScriptHandlers(name);
        logError(name, "init() failed — script evicted; update/deinit will not run");
    }

    /// Drop every event handler `name` registered through `labelle.on` —
    /// the prelude-side half of eviction, via its `__labelle_purge_handlers`
    /// hook. Missing hook (prelude never installed) is a silent no-op; a
    /// throwing purge is logged like any script error.
    fn purgeScriptHandlers(self: Vm, name: []const u8) void {
        const ctx = self.ctx;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const purge_fn = c.JS_GetPropertyStr(ctx, global, "__labelle_purge_handlers");
        defer c.JS_FreeValue(ctx, purge_fn);
        if (!c.JS_IsFunction(ctx, purge_fn)) return;
        const arg = c.JS_NewStringLen(ctx, name.ptr, name.len);
        defer c.JS_FreeValue(ctx, arg); // argv is borrowed by JS_Call
        var argv = [_]c.Value{arg};
        const ret = c.JS_Call(ctx, purge_fn, c.Value.undefined_, 1, &argv);
        if (ret.isException()) _ = self.logPendingException(name);
        c.JS_FreeValue(ctx, ret);
    }

    /// Call `hook` ("init"/"update"/"deinit") of the script registered as
    /// `script_name`, passing `dt` when given. The hook is the module's
    /// EXPORT of that name, read off the namespace in `__labelle_scripts`
    /// — another script's same-named export can never leak in (module
    /// namespaces are sealed). Missing scripts and missing/non-function
    /// exports are simply skipped: all three hooks are optional. Returns
    /// false only when the hook RAN and threw (missing is not a failure)
    /// — how the Controller detects a failed `init()` to evict.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) bool {
        const ctx = self.ctx;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const registry = c.JS_GetPropertyStr(ctx, global, SCRIPTS_REGISTRY);
        defer c.JS_FreeValue(ctx, registry);
        if (!registry.isObject()) return true;

        const name_atom = c.JS_NewAtomLen(ctx, script_name.ptr, script_name.len);
        const ns = c.JS_GetProperty(ctx, registry, name_atom);
        c.JS_FreeAtom(ctx, name_atom);
        defer c.JS_FreeValue(ctx, ns);
        if (!ns.isObject()) return true; // evicted or never loaded

        var hookbuf: [32]u8 = undefined;
        const hn = @min(hook.len, hookbuf.len - 1);
        @memcpy(hookbuf[0..hn], hook[0..hn]);
        hookbuf[hn] = 0;
        const fn_val = c.JS_GetPropertyStr(ctx, ns, @ptrCast(&hookbuf));
        defer c.JS_FreeValue(ctx, fn_val);
        if (!c.JS_IsFunction(ctx, fn_val)) return true; // hooks are optional

        var argv: [1]c.Value = undefined;
        var argc: c_int = 0;
        if (dt) |v| {
            argv[0] = c.Value.float(v);
            argc = 1;
        }
        // Hooks are VM→script entries: stamp the current script so a
        // `labelle.on` inside init()/update() attributes its handlers to
        // this script (aliases and local helpers included).
        self.setCurrentScript(script_name);
        const ret = c.JS_Call(ctx, fn_val, c.Value.undefined_, argc, &argv);
        self.setCurrentScript(null);
        self.drainJobs();
        var ok = true;
        if (ret.isException()) {
            _ = self.logPendingException(script_name);
            ok = false;
        }
        c.JS_FreeValue(ctx, ret);
        return ok;
    }

    /// Call a prelude function `labelle.<name>`, passing `dt` when given —
    /// how the Controller triggers `labelle.dispatch_inbox()` at tick
    /// start (and the controller-tier sweeps on backends that have one).
    /// Silently a no-op when the prelude (or the function) is missing —
    /// which is exactly how this backend skips the controller hooks.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        const ctx = self.ctx;
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        const labelle_obj = c.JS_GetPropertyStr(ctx, global, "labelle");
        defer c.JS_FreeValue(ctx, labelle_obj);
        if (!labelle_obj.isObject()) return;
        const fn_val = c.JS_GetPropertyStr(ctx, labelle_obj, name);
        defer c.JS_FreeValue(ctx, fn_val);
        if (!c.JS_IsFunction(ctx, fn_val)) return;
        var argv: [1]c.Value = undefined;
        var argc: c_int = 0;
        if (dt) |v| {
            argv[0] = c.Value.float(v);
            argc = 1;
        }
        const ret = c.JS_Call(ctx, fn_val, labelle_obj, argc, &argv);
        if (ret.isException()) _ = self.logPendingException("dispatch");
        c.JS_FreeValue(ctx, ret);
        self.drainJobs();
    }

    /// If the context holds a pending exception: format it (message +
    /// stack) through labelle_log, clear the slot, and return true.
    pub fn logPendingException(self: Vm, context: []const u8) bool {
        if (!c.JS_HasException(self.ctx)) return false;
        const exc = c.JS_GetException(self.ctx); // owned; clears the slot
        self.logErrorValue(context, exc);
        c.JS_FreeValue(self.ctx, exc);
        return true;
    }

    /// Format one error VALUE as "[ts] <context>: <Error>: <message>"
    /// plus its `.stack` flattened to one log line (the qjs stack's
    /// newline-separated "    at fn (file:line)" frames joined by " | ",
    /// the mruby backtrace treatment). Defensive at every step — a
    /// pathological error object whose toString/stack getter throws
    /// degrades gracefully instead of recursing.
    fn logErrorValue(self: Vm, context: []const u8, err: c.Value) void {
        const ctx = self.ctx;
        var buf: [ERROR_LOG_CAP]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        if (context.len > 0)
            w.print("[ts] {s}: ", .{context}) catch {}
        else
            w.print("[ts] ", .{}) catch {};

        // ToString(err): for Error objects this is "<Name>: <message>".
        var mlen: usize = 0;
        if (c.JS_ToCStringLen2(ctx, &mlen, err, false)) |m| {
            w.print("{s}", .{m[0..mlen]}) catch {};
            c.JS_FreeCString(ctx, m);
        } else {
            self.swallowException();
            w.print("(unprintable error)", .{}) catch {};
        }

        if (err.isObject()) {
            const stack_val = c.JS_GetPropertyStr(ctx, err, "stack");
            defer c.JS_FreeValue(ctx, stack_val);
            if (c.JS_HasException(ctx)) {
                self.swallowException();
            } else if (stack_val.isString()) {
                var slen: usize = 0;
                if (c.JS_ToCStringLen2(ctx, &slen, stack_val, false)) |s| {
                    const trimmed = std.mem.trim(u8, s[0..slen], " \n");
                    if (trimmed.len > 0) {
                        w.print("\n  stack: ", .{}) catch {};
                        for (trimmed) |ch| {
                            if (ch == '\n')
                                w.print(" | ", .{}) catch {}
                            else
                                w.writeByte(ch) catch {};
                        }
                    }
                    c.JS_FreeCString(ctx, s);
                } else {
                    self.swallowException();
                }
            }
        }

        const line = w.buffered();
        contract.labelle_log(line.ptr, line.len);
    }

    /// Drop a pending exception raised WHILE formatting another one.
    fn swallowException(self: Vm) void {
        if (c.JS_HasException(self.ctx)) {
            c.JS_FreeValue(self.ctx, c.JS_GetException(self.ctx));
        }
    }
};
