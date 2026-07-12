//! The csharp sub-module's "VM" (labelle-engine#743, the language-plugins
//! epic's Phase 4 / final entry): a CoreCLR HOST. Unlike rust and crystal
//! — which compile game scripts INTO the game binary and resolve their
//! entry points at link time — C# scripts are compiled to a managed
//! assembly (`labelle_csharp_scripts.dll`) that this module LOADS AT
//! RUNTIME through the .NET hosting API (`hostfxr`), then drives through
//! function pointers the runtime hands back. The runtime is embedded in
//! the game process, so C# joins lua/ruby/typescript in the "embedded
//! runtime" family; the DISPATCH shape, however, is the compiled family's
//! — scripts are compiled structures registered by a `Game.Register`
//! convention (not `registerScript` source), so this file is a thin
//! dispatcher onto the managed glue's four Controller-tier entries, the
//! exact labelle_rs_*/labelle_cr_* twin plus one boot leg:
//!
//!   Controller.setup   → Vm.init (locate hostfxr via nethost → init
//!                        runtime config → load assembly + resolve the
//!                        [UnmanagedCallersOnly] entries → cs abi
//!                        handshake; ONCE per process — see the boot leg)
//!                        … registered-source loop: no-ops
//!                        → callLabelleFn("__setup_controllers")
//!                          = Glue.Setup (Game.Register + every Init)
//!   Controller.tick    → callLabelleFn("dispatch_inbox")
//!                          = Glue.DispatchInbox (event fan-out)
//!                        → callLabelleFn("__tick_controllers", dt)
//!                          = Glue.Tick (every Update(dt))
//!   Controller.deinit  → callLabelleFn("__teardown_controllers")
//!                          = Glue.Deinit (deinits, LIFO)
//!                        → Vm.close (no-op — the runtime stays up)
//!
//! ## The boot leg (the CoreCLR host handshake)
//!
//! Nothing managed can run until the runtime initializes, so `Vm.init`
//! performs the canonical hostfxr sequence ONCE per process (guarded
//! zig-side, like crystal's runtime boot):
//!
//!   1. Resolve the managed assembly directory — `LABELLE_CS_ASSEMBLY_DIR`
//!      (the assembler stages the assembly there) or the running host
//!      executable's own directory (a shipped game keeps the DLL beside
//!      its binary).
//!   2. Locate `hostfxr` via `nethost`'s `get_hostfxr_path` (biased by the
//!      assembly path) — the SDK's own resolver, so BOTH deployment modes
//!      resolve with one call: a SELF-CONTAINED deployment finds hostfxr
//!      beside the assembly, a FRAMEWORK-DEPENDENT one finds the globally
//!      installed runtime (see the plugin README's csharp section).
//!   3. `hostfxr_initialize_for_runtime_config(<assembly>.runtimeconfig.json)`
//!      — the runtimeconfig (emitted by `dotnet publish` beside the DLL)
//!      names the framework the assembly targets; hostfxr infers
//!      `dotnet_root` from its own resolved location, so null init
//!      parameters suffice for both modes.
//!   4. `hostfxr_get_runtime_delegate(hdt_load_assembly_and_get_function_pointer)`.
//!   5. For each Controller entry, `load_assembly_and_get_function_pointer`
//!      against `Glue` with `UNMANAGEDCALLERSONLY_METHOD` — the managed
//!      methods are `[UnmanagedCallersOnly]`, so the delegate the runtime
//!      returns is a bare C function pointer, no marshalling thunk. These
//!      pointers are what `callLabelleFn` invokes.
//!   6. `AbiVersion()` handshake — the one realistic skew is a STALE
//!      assembly in the plugin's build cache after a plugin upgrade; it
//!      must fail here, not corrupt dispatch mid-game (the rust/crystal
//!      ABI-refusal philosophy).
//!
//! A boot failure POISONS csharp scripting for the process (like
//! crystal's runtime boot): a half-initialized CoreCLR cannot be safely
//! re-initialized, so every later setup fails fast with a pointed message
//! instead of retrying into undefined runtime state. An ABI MISMATCH is
//! reported distinctly (the assembly loaded fine, it is simply the wrong
//! revision) and does NOT poison — regenerating the assembly and
//! re-setting up is the fix.
//!
//! The contract flows the OTHER way across the seam exactly as it does
//! for rust/crystal: the managed glue declares the `labelle_*` symbols via
//! `[LibraryImport]` resolved against the HOST PROCESS (Labelle.cs's
//! `DllImportResolver` → the game binary's own exports), so a C# script's
//! `Labelle.Log(...)` lands in the same game log sink a Zig script would.
//! That requires the host binary to EXPORT the contract symbols in its
//! dynamic symbol table — see the README's deployment notes.
//!
//! Exception safety lives managed-side: every Glue entry wraps its body
//! (and each script hook individually) in try/catch — a managed exception
//! unwinding out of an `[UnmanagedCallersOnly]` method into foreign frames
//! is undefined behavior, so the glue's containment is a hard requirement,
//! mirroring the rust/crystal panic/raise gates.
//!
//! ## Platform note (why not std.DynLib / std.fs / std.process)
//!
//! This module reaches for libc / OS primitives (`std.c.dlopen`,
//! `nethost`, `LoadLibraryW`, `GetModuleFileNameW`, `/proc/self/exe`,
//! `_NSGetExecutablePath`) rather than the higher-level std wrappers: the
//! plugin links libc, hosting is inherently a native-loader affair, and
//! `std.DynLib` has no Windows arm while the current `std.fs`/`std.process`
//! filesystem+env surface is mid-migration to `std.Io`. Keeping this to
//! flat C calls makes the one platform-specific corner explicit.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("../contract.zig");
const eval_mod = @import("../eval.zig");

/// The managed glue ABI revision this arm drives (`Glue.cs
/// CS_ABI_VERSION`). `Vm.init` refuses a mismatch: the realistic skew is
/// a STALE `labelle_csharp_scripts.dll` in the plugin's build cache after
/// a plugin upgrade — that must fail the handshake, not corrupt dispatch.
pub const SUPPORTED_CS_ABI_VERSION: u32 = 1;

/// The managed glue type name and its default assembly name. `dotnet
/// publish` produces `labelle_csharp_scripts.dll` (native-csharp/
/// LabelleScripts.csproj `<AssemblyName>`); `Glue` lives in the global
/// namespace (see native-csharp/src/Glue.cs), so the assembly-qualified
/// type name is just "Glue, labelle_csharp_scripts".
const GLUE_TYPE = "Glue, labelle_csharp_scripts";
const ASSEMBLY_BASENAME = "labelle_csharp_scripts";

/// hostfxr's char_t: UTF-16 on Windows, UTF-8 everywhere else. Every path
/// and name handed to the hosting API is this width.
const is_windows = builtin.os.tag == .windows;
const char_t = if (is_windows) u16 else u8;

/// hostfxr_delegate_type::hdt_load_assembly_and_get_function_pointer.
const HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER: i32 = 5;

/// `UNMANAGEDCALLERSONLY_METHOD` — the sentinel `(const char_t*)-1` that
/// tells `load_assembly_and_get_function_pointer` the target method is
/// `[UnmanagedCallersOnly]` (return a raw fn pointer, no delegate type).
/// Typed opaque: it is a marker the runtime compares by value, never
/// dereferenced, and `-1` is not char_t-aligned (a `[*:0]const u16` of it
/// would fail Zig's alignment check on Windows).
const UNMANAGED_CALLERS_ONLY: *const anyopaque = @ptrFromInt(std.math.maxInt(usize));

// hostfxr entry-point signatures (hostfxr.h / coreclr_delegates.h).
const HostfxrHandle = ?*anyopaque;
const InitForConfigFn = *const fn (
    runtime_config_path: [*:0]const char_t,
    parameters: ?*const anyopaque,
    out_handle: *HostfxrHandle,
) callconv(.c) i32;
const GetDelegateFn = *const fn (
    handle: HostfxrHandle,
    delegate_type: i32,
    out_delegate: *?*anyopaque,
) callconv(.c) i32;
const CloseFn = *const fn (handle: HostfxrHandle) callconv(.c) i32;
const LoadAssemblyAndGetFnPtrFn = *const fn (
    assembly_path: [*:0]const char_t,
    type_name: [*:0]const char_t,
    method_name: [*:0]const char_t,
    // Always the UNMANAGEDCALLERSONLY sentinel here (opaque — see its doc);
    // a real delegate-type name is never passed, so the char_t spelling is
    // unnecessary and its odd sentinel address would fail alignment.
    delegate_type_name: ?*const anyopaque,
    reserved: ?*anyopaque,
    out_delegate: *?*anyopaque,
) callconv(.c) i32;

// The managed Controller-tier entries (native-csharp/src/Glue.cs), each an
// [UnmanagedCallersOnly] method resolved to a bare C fn pointer at boot.
const AbiVersionFn = *const fn () callconv(.c) u32;
const SetupFn = *const fn () callconv(.c) i32;
const DispatchFn = *const fn () callconv(.c) void;
const TickFn = *const fn (dt: f32) callconv(.c) void;
const DeinitFn = *const fn () callconv(.c) void;

// ── Platform loader / exe-path shims ─────────────────────────────────────

const win = struct {
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
    const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

    const FILETIME = extern struct { low: u32 = 0, high: u32 = 0 };
    const WIN32_FIND_DATAW = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        dwReserved0: u32,
        dwReserved1: u32,
        cFileName: [260]u16,
        cAlternateFileName: [14]u16,
    };

    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FindNextFileW(hFindFile: *anyopaque, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) c_int;
    extern "kernel32" fn FindClose(hFindFile: *anyopaque) callconv(.winapi) c_int;
};

// macOS: libSystem's executable-path query.
extern fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// hostfxr's platform library filename.
const HOSTFXR_LIB = switch (builtin.os.tag) {
    .windows => "hostfxr.dll",
    .macos => "libhostfxr.dylib",
    else => "libhostfxr.so",
};

const LibHandle = *anyopaque;

fn openLib(path: [*:0]const char_t) ?LibHandle {
    if (is_windows) return win.LoadLibraryW(path);
    return std.c.dlopen(path, .{ .NOW = true });
}

fn lookupSym(handle: LibHandle, comptime T: type, name: [:0]const u8) ?T {
    const p = if (is_windows) win.GetProcAddress(handle, name.ptr) else std.c.dlsym(handle, name.ptr);
    return if (p) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

/// The runtime boots at most once per process — CoreCLR cannot be safely
/// stood up twice in one process, and the managed registry is rebuilt on
/// every `Glue.Setup` anyway (the Controller's re-setup = clean restart).
var runtime_booted = false;

/// Latched when a boot FAILS, never cleared: a partial hostfxr init leaves
/// the runtime in an undefined state that a retry cannot recover — so a
/// failed boot poisons csharp scripting for the process lifetime. (The
/// crystal arm carries the same latch for the same reason.)
var runtime_boot_poisoned = false;

/// The resolved managed entries, valid once `runtime_booted`.
var entries: struct {
    setup: SetupFn = undefined,
    dispatch: DispatchFn = undefined,
    tick: TickFn = undefined,
    deinit: DeinitFn = undefined,
} = .{};

/// The ABI version the glue reported during boot (checked by `Vm.init`).
var boot_abi_version: u32 = 0;

fn logHost(msg: []const u8) void {
    contract.labelle_log(msg.ptr, msg.len);
}

/// Copy a UTF-8 path/name into `buf` as a null-terminated char_t string
/// (UTF-16 on Windows). Boot-time only; `buf` is a caller stack buffer.
fn toCharZ(utf8: []const u8, buf: []char_t) error{PathTooLong}![:0]const char_t {
    if (is_windows) {
        if (buf.len == 0) return error.PathTooLong;
        const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], utf8) catch return error.PathTooLong;
        buf[n] = 0;
        return buf[0..n :0];
    } else {
        if (utf8.len + 1 > buf.len) return error.PathTooLong;
        @memcpy(buf[0..utf8.len], utf8);
        buf[utf8.len] = 0;
        return buf[0..utf8.len :0];
    }
}

/// A comptime ASCII literal as a char_t string — for the fixed type/method
/// names handed to the hosting API (no runtime conversion needed).
inline fn L(comptime s: [:0]const u8) [:0]const char_t {
    if (!is_windows) return s;
    return comptime blk: {
        var arr: [s.len:0]u16 = undefined;
        for (s, 0..) |ch, i| arr[i] = ch; // ASCII-only names
        arr[s.len] = 0;
        const frozen = arr;
        break :blk &frozen;
    };
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// True when a file exists at the UTF-8 path.
fn fileExists(utf8: []const u8) bool {
    if (is_windows) {
        var wbuf: [2048]u16 = undefined;
        const w = toCharZ(utf8, &wbuf) catch return false;
        return win.GetFileAttributesW(w.ptr) != win.INVALID_FILE_ATTRIBUTES;
    } else {
        var zbuf: [2048]u8 = undefined;
        if (utf8.len + 1 > zbuf.len) return false;
        @memcpy(zbuf[0..utf8.len], utf8);
        zbuf[utf8.len] = 0;
        const f = std.c.fopen(zbuf[0..utf8.len :0], "rb") orelse return false;
        _ = std.c.fclose(f);
        return true;
    }
}

/// The directory of the running host executable, into `out` (UTF-8).
fn exeDir(out: []u8) ?[]const u8 {
    var full: []const u8 = undefined;
    if (is_windows) {
        var wbuf: [2048]u16 = undefined;
        const n = win.GetModuleFileNameW(null, &wbuf, wbuf.len);
        if (n == 0 or n >= wbuf.len) return null;
        const len = std.unicode.utf16LeToUtf8(out, wbuf[0..n]) catch return null;
        full = out[0..len];
    } else if (builtin.os.tag == .macos) {
        var size: u32 = @intCast(out.len);
        if (_NSGetExecutablePath(out.ptr, &size) != 0) return null;
        full = out[0..std.mem.indexOfScalar(u8, out, 0).?];
    } else {
        const n = std.c.readlink("/proc/self/exe", out.ptr, out.len);
        if (n <= 0) return null;
        full = out[0..@intCast(n)];
    }
    const slash = std.mem.lastIndexOfAny(u8, full, "/\\") orelse return null;
    return full[0..slash];
}

/// Resolve the managed assembly directory. `LABELLE_CS_ASSEMBLY_DIR`
/// overrides (the assembler stages the assembly there); otherwise the
/// directory of the running host executable — where a shipped game keeps
/// `labelle_csharp_scripts.dll` beside its binary.
fn assemblyDir(out: []u8) ?[]const u8 {
    if (env("LABELLE_CS_ASSEMBLY_DIR")) |dir| {
        if (dir.len == 0 or dir.len > out.len) return null;
        @memcpy(out[0..dir.len], dir);
        return out[0..dir.len];
    }
    return exeDir(out);
}

/// The .NET install roots to probe for a framework-dependent runtime,
/// after the app dir (self-contained) and `$DOTNET_ROOT`.
fn defaultDotnetRoots() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:\\Program Files\\dotnet", "C:\\Program Files (x86)\\dotnet" },
        .macos => &.{ "/usr/local/share/dotnet", "/opt/homebrew/share/dotnet" },
        else => &.{ "/usr/share/dotnet", "/usr/lib/dotnet", "/usr/lib64/dotnet", "/opt/dotnet" },
    };
}

/// Numeric dotted-version compare: is `a` an older version than `b`?
/// (Falls back to byte comparison for non-numeric components.)
fn versionLess(a: []const u8, b: []const u8) bool {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const at = ai.next();
        const bt = bi.next();
        if (at == null and bt == null) return false;
        if (at == null) return true;
        if (bt == null) return false;
        const an = std.fmt.parseInt(u64, at.?, 10) catch return std.mem.lessThan(u8, a, b);
        const bn = std.fmt.parseInt(u64, bt.?, 10) catch return std.mem.lessThan(u8, a, b);
        if (an != bn) return an < bn;
    }
}

/// The newest version-named subdirectory of `dir_utf8`, into `out` (UTF-8).
/// Null when the directory has none / cannot be opened.
fn newestVersionDir(dir_utf8: []const u8, out: []u8) ?[]const u8 {
    var best_len: usize = 0;
    if (is_windows) {
        var pat_buf: [1200]u8 = undefined;
        const pat_utf8 = std.fmt.bufPrint(&pat_buf, "{s}/*", .{dir_utf8}) catch return null;
        var pat_w: [2048]u16 = undefined;
        const pat = toCharZ(pat_utf8, &pat_w) catch return null;
        var data: win.WIN32_FIND_DATAW = undefined;
        const h = win.FindFirstFileW(pat.ptr, &data);
        if (h == null or h == win.INVALID_HANDLE_VALUE) return null;
        defer _ = win.FindClose(h.?);
        while (true) {
            if (data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0) {
                const name_w = std.mem.sliceTo(&data.cFileName, 0);
                var name_buf: [128]u8 = undefined;
                if (std.unicode.utf16LeToUtf8(&name_buf, name_w)) |n| {
                    const name = name_buf[0..n];
                    if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
                        (best_len == 0 or versionLess(out[0..best_len], name)) and name.len <= out.len)
                    {
                        @memcpy(out[0..name.len], name);
                        best_len = name.len;
                    }
                } else |_| {}
            }
            if (win.FindNextFileW(h.?, &data) == 0) break;
        }
    } else {
        // POSIX: enumerate via std.fs rather than raw opendir/readdir — the
        // translated `dirent.d_name` field does not resolve on Linux under
        // Zig 0.16's translate-c. `dir_utf8` is an absolute path
        // (<root>/host/fxr).
        var d = std.fs.cwd().openDir(dir_utf8, .{ .iterate = true }) catch return null;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |ent| {
            const name = ent.name;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if ((best_len == 0 or versionLess(out[0..best_len], name)) and name.len <= out.len) {
                @memcpy(out[0..name.len], name);
                best_len = name.len;
            }
        }
    }
    return if (best_len == 0) null else out[0..best_len];
}

/// Locate a loadable hostfxr, writing its path into `out` (UTF-8). Search
/// order encodes both deployment modes: the assembly dir first (a
/// SELF-CONTAINED deployment ships hostfxr beside the DLL), then
/// `$DOTNET_ROOT`, then the platform default install (FRAMEWORK-DEPENDENT
/// against the globally installed runtime), each at
/// `<root>/host/fxr/<newest>/`.
fn findHostfxr(asm_dir: []const u8, out: []u8) ?[]const u8 {
    // 1. Self-contained: hostfxr sits directly beside the assembly.
    {
        var b: [1200]u8 = undefined;
        if (std.fmt.bufPrint(&b, "{s}/{s}", .{ asm_dir, HOSTFXR_LIB })) |cand| {
            if (fileExists(cand) and cand.len <= out.len) {
                @memcpy(out[0..cand.len], cand);
                return out[0..cand.len];
            }
        } else |_| {}
    }
    // 2/3. Framework-dependent: <root>/host/fxr/<newest>/hostfxr.
    var roots_buf: [8][]const u8 = undefined;
    var n: usize = 0;
    if (env("DOTNET_ROOT")) |r| {
        roots_buf[n] = r;
        n += 1;
    }
    for (defaultDotnetRoots()) |r| {
        if (n >= roots_buf.len) break;
        roots_buf[n] = r;
        n += 1;
    }
    for (roots_buf[0..n]) |root| {
        var fxr_buf: [1100]u8 = undefined;
        const fxr_dir = std.fmt.bufPrint(&fxr_buf, "{s}/host/fxr", .{root}) catch continue;
        var ver_buf: [128]u8 = undefined;
        const ver = newestVersionDir(fxr_dir, &ver_buf) orelse continue;
        var path_buf: [1300]u8 = undefined;
        const cand = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ fxr_dir, ver, HOSTFXR_LIB }) catch continue;
        if (fileExists(cand) and cand.len <= out.len) {
            @memcpy(out[0..cand.len], cand);
            return out[0..cand.len];
        }
    }
    return null;
}

pub const Vm = struct {
    /// Boot the embedded runtime (once per process), resolve the managed
    /// entries, and handshake the glue ABI. A boot failure poisons csharp
    /// scripting for the process; an ABI mismatch fails loudly without
    /// poisoning (regenerate the assembly and re-setup).
    pub fn init() error{ CsharpRuntimeInitFailed, CsharpGlueVersionMismatch }!Vm {
        if (runtime_boot_poisoned) {
            logHost("[scripting] csharp runtime boot previously failed and cannot be " ++
                "retried (a partially initialized CoreCLR is unrecoverable) — scripting " ++
                "is disabled for this process; fix the reported cause and restart the game");
            return error.CsharpRuntimeInitFailed;
        }
        if (!runtime_booted) {
            boot() catch |err| {
                runtime_boot_poisoned = true;
                return err;
            };
            if (boot_abi_version != SUPPORTED_CS_ABI_VERSION) {
                logHost("[scripting] csharp glue ABI mismatch — the loaded " ++
                    "labelle_csharp_scripts.dll was built by a different plugin version " ++
                    "(stale plugin-build cache?); regenerate/rebuild");
                // The runtime is up but this rev is unusable; do NOT poison
                // (a corrected assembly is a valid fix). Leave booted=false
                // so a fixed rebuild in the same process (tests) can retry.
                return error.CsharpGlueVersionMismatch;
            }
            runtime_booted = true;
        }
        return .{};
    }

    /// Nothing to free per-setup: the managed registry is the glue's,
    /// dropped by Glue.Deinit (the "__teardown_controllers" leg the shared
    /// Controller always calls first). The CoreCLR runtime stays up for the
    /// process lifetime (see runtime_booted) — like crystal's runtime.
    pub fn close(self: Vm) void {
        _ = self;
    }

    /// Registered SOURCES cannot run in C#: scripts are compiled into the
    /// managed assembly and arrive through the `Game.Register` convention,
    /// not through this seam. Refuse loudly (false), mirroring rust/crystal.
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        _ = self;
        _ = source;
        var buf: [192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[scripting] csharp is compiled: registered source '{s}' ignored — " ++
            "implement it in the game's csharp/ dir instead", .{name}) catch {};
        logHost(w.buffered());
        return false;
    }

    /// No per-source hook registry exists (loadScript admits nothing).
    pub fn evictScript(self: Vm, name: []const u8) void {
        _ = self;
        _ = name;
    }

    /// Per-registered-source hooks never run here (nothing loads); true
    /// keeps the always-empty loop inert.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) bool {
        _ = self;
        _ = script_name;
        _ = hook;
        _ = dt;
        return true;
    }

    /// The Controller-tier dispatch table — the whole csharp integration
    /// funnels through these four names onto the resolved managed entries.
    /// Unknown names are a no-op, mirroring the other backends.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        _ = self;
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "__setup_controllers")) {
            if (entries.setup() != 0) {
                logHost("[scripting] csharp setup failed — Register() threw; " ++
                    "no scripts are running (see the log lines above)");
            }
        } else if (std.mem.eql(u8, n, "dispatch_inbox")) {
            entries.dispatch();
        } else if (std.mem.eql(u8, n, "__tick_controllers")) {
            entries.tick(dt orelse 0);
        } else if (std.mem.eql(u8, n, "__teardown_controllers")) {
            entries.deinit();
        }
    }

    /// The studio console cannot evaluate C# — scripts are compiled into a
    /// managed assembly, there is no source-eval VM here. A documented
    /// refusal keeps the console usable for diagnostics.
    pub fn evalConsole(self: Vm, code: []const u8, out: []u8) eval_mod.EvalResult {
        _ = self;
        _ = code;
        _ = out;
        return .{
            .ok = false,
            .text = "eval not supported for compiled languages (csharp) — scripts are " ++
                "compiled into a managed assembly; use an embedded-VM language for " ++
                "console evaluation",
        };
    }
};

/// The full hostfxr boot: resolve paths, locate + load hostfxr, init the
/// runtime config, get the load delegate, resolve the four Controller
/// entries and read the ABI version. Any failure logs a pointed message
/// and returns error.CsharpRuntimeInitFailed (the caller poisons on it).
fn boot() error{CsharpRuntimeInitFailed}!void {
    var asm_dir_buf: [1024]u8 = undefined;
    const asm_dir = assemblyDir(&asm_dir_buf) orelse
        return bootFail("csharp: could not resolve the assembly directory (set " ++
            "LABELLE_CS_ASSEMBLY_DIR or ship labelle_csharp_scripts.dll beside the game binary)");

    // <assembly-dir>/<basename>.dll and .runtimeconfig.json (UTF-8, then char_t).
    var dll_utf8_buf: [1280]u8 = undefined;
    const dll_utf8 = std.fmt.bufPrint(&dll_utf8_buf, "{s}/{s}.dll", .{ asm_dir, ASSEMBLY_BASENAME }) catch
        return bootFail("csharp: assembly path too long");
    if (!fileExists(dll_utf8))
        return bootFail("csharp: labelle_csharp_scripts.dll not found beside the assembly dir " ++
            "(build the C# project with `dotnet publish`)");

    var cfg_utf8_buf: [1280]u8 = undefined;
    const cfg_utf8 = std.fmt.bufPrint(&cfg_utf8_buf, "{s}/{s}.runtimeconfig.json", .{ asm_dir, ASSEMBLY_BASENAME }) catch
        return bootFail("csharp: runtimeconfig path too long");
    if (!fileExists(cfg_utf8))
        return bootFail("csharp: runtimeconfig.json not found beside the assembly " ++
            "(EnableDynamicLoading emits it on `dotnet publish`)");

    var dll_w: [2048]char_t = undefined;
    const dll_path = toCharZ(dll_utf8, &dll_w) catch return bootFail("csharp: assembly path too long");
    var cfg_w: [2048]char_t = undefined;
    const cfg_path = toCharZ(cfg_utf8, &cfg_w) catch return bootFail("csharp: runtimeconfig path too long");

    // Locate hostfxr for the installed (or app-local) runtime.
    var hostfxr_utf8_buf: [1300]u8 = undefined;
    const hostfxr_utf8 = findHostfxr(asm_dir, &hostfxr_utf8_buf) orelse
        return bootFail("csharp: could not locate hostfxr — install the .NET runtime, set " ++
            "DOTNET_ROOT, or ship a self-contained deployment beside the binary");
    var hostfxr_w: [2048]char_t = undefined;
    const hostfxr_path = toCharZ(hostfxr_utf8, &hostfxr_w) catch return bootFail("csharp: hostfxr path too long");

    const lib = openLib(hostfxr_path.ptr) orelse
        return bootFail("csharp: found hostfxr but failed to load it (architecture mismatch?)");

    const init_fn = lookupSym(lib, InitForConfigFn, "hostfxr_initialize_for_runtime_config") orelse
        return bootFail("csharp: hostfxr missing hostfxr_initialize_for_runtime_config");
    const get_delegate = lookupSym(lib, GetDelegateFn, "hostfxr_get_runtime_delegate") orelse
        return bootFail("csharp: hostfxr missing hostfxr_get_runtime_delegate");
    const close_fn = lookupSym(lib, CloseFn, "hostfxr_close") orelse
        return bootFail("csharp: hostfxr missing hostfxr_close");

    var handle: HostfxrHandle = null;
    if (init_fn(cfg_path.ptr, null, &handle) != 0 or handle == null)
        return bootFail("csharp: hostfxr_initialize_for_runtime_config failed — the " ++
            "runtimeconfig's target framework is not installed (framework-dependent) or " ++
            "the self-contained runtime is incomplete");
    defer _ = close_fn(handle);

    var raw_delegate: ?*anyopaque = null;
    if (get_delegate(handle, HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER, &raw_delegate) != 0 or raw_delegate == null)
        return bootFail("csharp: hostfxr_get_runtime_delegate(load_assembly...) failed");
    const load: LoadAssemblyAndGetFnPtrFn = @ptrCast(@alignCast(raw_delegate.?));

    entries.setup = @ptrCast(try resolve(load, dll_path, L("Setup")));
    entries.dispatch = @ptrCast(try resolve(load, dll_path, L("DispatchInbox")));
    entries.tick = @ptrCast(try resolve(load, dll_path, L("Tick")));
    entries.deinit = @ptrCast(try resolve(load, dll_path, L("Deinit")));
    const abi_ptr: AbiVersionFn = @ptrCast(try resolve(load, dll_path, L("AbiVersion")));
    boot_abi_version = abi_ptr();
}

/// One `load_assembly_and_get_function_pointer` call against the glue type
/// with the UNMANAGEDCALLERSONLY sentinel.
fn resolve(
    load: LoadAssemblyAndGetFnPtrFn,
    dll_path: [:0]const char_t,
    method: [:0]const char_t,
) error{CsharpRuntimeInitFailed}!*anyopaque {
    var out: ?*anyopaque = null;
    const rc = load(dll_path.ptr, L(GLUE_TYPE).ptr, method.ptr, UNMANAGED_CALLERS_ONLY, null, &out);
    if (rc != 0 or out == null)
        return bootFail("csharp: could not resolve a Glue entry point (assembly present " ++
            "but the [UnmanagedCallersOnly] method is missing or misnamed)");
    return out.?;
}

fn bootFail(comptime msg: []const u8) error{CsharpRuntimeInitFailed} {
    logHost("[scripting] " ++ msg);
    return error.CsharpRuntimeInitFailed;
}
