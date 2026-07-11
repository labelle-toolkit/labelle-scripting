//! Console-eval SHARED-code suite (labelle-scripting#4): the response-
//! JSON builder, the params decoding, the truncation helpers and the
//! VM-less `handleEvalCommand` legs — everything in src/eval.zig +
//! root.zig that is language-independent — plus a parse/AstGen compile
//! check over the pack hook shim (the one file in this repo that can
//! only fully compile inside a generated game).
//!
//! Runs in the LUA test binary only (tests/root.zig gates it like the
//! declare-tool goldens): the code under test is identical in every
//! binary, so one mirror is the whole coverage.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");
const crystal_lib_paths = @import("crystal_lib_paths");
const eval = scripting.eval;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The response shape the studio console reads back.
const Response = struct { ok: bool, value: []const u8 = "", @"error": []const u8 = "" };

fn parseResponse(json: []const u8) !std.json.Parsed(Response) {
    return std.json.parseFromSlice(Response, std.testing.allocator, json, .{});
}

// ── buildResponse ────────────────────────────────────────────────────

test "buildResponse: ok and error shapes" {
    var buf: [128]u8 = undefined;
    try expectEqualStrings(
        "{\"ok\":true,\"value\":\"3\"}",
        eval.buildResponse(true, "3", &buf),
    );
    try expectEqualStrings(
        "{\"ok\":false,\"error\":\"boom\"}",
        eval.buildResponse(false, "boom", &buf),
    );
}

test "buildResponse: escapes quotes, backslashes and control bytes" {
    var buf: [128]u8 = undefined;
    const got = eval.buildResponse(true, "say \"hi\"\\\n\ttab\x01", &buf);
    try expectEqualStrings(
        "{\"ok\":true,\"value\":\"say \\\"hi\\\"\\\\\\n\\ttab\\u0001\"}",
        got,
    );
    // And it round-trips through a real JSON parser.
    const parsed = try parseResponse(got);
    defer parsed.deinit();
    try expect(parsed.value.ok);
    try expectEqualStrings("say \"hi\"\\\n\ttab\x01", parsed.value.value);
}

test "buildResponse: truncates at the buffer with a marker and stays valid JSON" {
    var buf: [64]u8 = undefined;
    const long = "x" ** 200;
    const got = eval.buildResponse(true, long, &buf);
    try expect(got.len <= buf.len);
    const parsed = try parseResponse(got);
    defer parsed.deinit();
    try expect(parsed.value.ok);
    try expect(std.mem.endsWith(u8, parsed.value.value, eval.truncation_marker));
    try expect(std.mem.startsWith(u8, parsed.value.value, "xxxx"));
}

test "buildResponse: a truncated escape sequence is dropped whole" {
    // Budget the buffer so the cut lands exactly where a `\"` escape
    // would have to split: the escape must be omitted entirely, never
    // emitted as a lone backslash (which would corrupt the JSON).
    const text = "aaaaaaaa\"tail";
    var i: usize = 32;
    while (i <= 40) : (i += 1) {
        const buf = std.testing.allocator.alloc(u8, i) catch unreachable;
        defer std.testing.allocator.free(buf);
        const got = eval.buildResponse(true, text, buf);
        const parsed = try parseResponse(got);
        defer parsed.deinit();
        try expect(parsed.value.ok);
    }
}

test "buildResponse: never splits a multi-byte codepoint at the cut" {
    // 2-byte codepoints ("é") across every nearby buffer size: whatever
    // the cut position, the value must stay valid UTF-8 and valid JSON.
    const text = "é" ** 100;
    var i: usize = 32;
    while (i <= 48) : (i += 1) {
        const buf = std.testing.allocator.alloc(u8, i) catch unreachable;
        defer std.testing.allocator.free(buf);
        const got = eval.buildResponse(true, text, buf);
        const parsed = try parseResponse(got);
        defer parsed.deinit();
        try expect(std.unicode.utf8ValidateSlice(parsed.value.value));
        try expect(std.mem.endsWith(u8, parsed.value.value, eval.truncation_marker));
    }
}

test "buildResponse: invalid UTF-8 bytes become U+FFFD; valid sequences survive" {
    var buf: [128]u8 = undefined;
    // A lone 0xFF, a VALID 2-byte é that must pass through whole, a
    // stray continuation byte, and a truncated 2-byte sequence at the
    // very end — every invalid byte becomes one replacement char.
    const got = eval.buildResponse(true, "a\xffb" ++ "é" ++ "\x80z\xc3", &buf);
    // The WHOLE response is valid UTF-8 (JSON is UTF-8 by definition —
    // this is what the studio's JSON.parse chokes on otherwise)...
    try expect(std.unicode.utf8ValidateSlice(got));
    // ...and round-trips with byte-exact replacement placement.
    const parsed = try parseResponse(got);
    defer parsed.deinit();
    try expect(parsed.value.ok);
    try expectEqualStrings(
        "a" ++ eval.replacement_char ++ "bé" ++ eval.replacement_char ++ "z" ++ eval.replacement_char,
        parsed.value.value,
    );
}

test "buildResponse: replacement chars compose with truncation at any buffer size" {
    // Alternating ASCII + invalid byte: whatever the cut position, the
    // response must stay valid UTF-8 and valid JSON, marker included.
    const text = "x\xff" ** 40;
    var i: usize = 32;
    while (i <= 56) : (i += 1) {
        const buf = std.testing.allocator.alloc(u8, i) catch unreachable;
        defer std.testing.allocator.free(buf);
        const got = eval.buildResponse(true, text, buf);
        try expect(std.unicode.utf8ValidateSlice(got));
        const parsed = try parseResponse(got);
        defer parsed.deinit();
        try expect(parsed.value.ok);
        try expect(std.mem.endsWith(u8, parsed.value.value, eval.truncation_marker));
    }
}

// ── truncation helpers ───────────────────────────────────────────────

test "utf8SafeLen: keeps a sequence that ends exactly at the limit" {
    const s = "ab" ++ "é"; // é = 2 bytes, s.len = 4
    try expectEqual(@as(usize, 4), eval.utf8SafeLen(s, 4));
    // A cut through the middle of é backs off to before its lead.
    const s2 = s ++ "z";
    try expectEqual(@as(usize, 2), eval.utf8SafeLen(s2, 3));
    // A clean ASCII boundary is untouched.
    try expectEqual(@as(usize, 2), eval.utf8SafeLen(s2, 2));
}

test "copyBounded: exact fit has no marker; overflow is marked" {
    var buf: [8]u8 = undefined;
    try expectEqualStrings("12345678", eval.copyBounded("12345678", &buf));
    try expectEqualStrings("12345…", eval.copyBounded("123456789", &buf));
}

test "buildResponse: buffers below the empty-response floor yield an empty slice" {
    // The same release-mode underflow class as copyBounded's guard, at
    // the builder's own reservation subtraction: every size from zero
    // up to just past the ok-prefix floor must come back empty (never
    // a partial write, never an out-of-bounds one) — and the first
    // size that CAN carry an empty response must be valid JSON.
    var i: usize = 0;
    while (i <= 26) : (i += 1) {
        const buf = std.testing.allocator.alloc(u8, i) catch unreachable;
        defer std.testing.allocator.free(buf);
        const got = eval.buildResponse(true, "whatever", buf);
        if (got.len == 0) continue; // guarded: below this buffer's floor
        const parsed = try parseResponse(got);
        defer parsed.deinit();
        try expect(parsed.value.ok);
    }
}

test "copyBounded: buffers smaller than the marker cut clean (release-mode underflow guard)" {
    // The marker is 3 bytes ("…"); out.len below that used to ride an
    // assert whose release-mode absence let `out.len - marker.len`
    // underflow into an out-of-bounds copy. Now: plain codepoint-safe
    // cut, no marker, never past out.len.
    var b2: [2]u8 = undefined;
    try expectEqualStrings("ab", eval.copyBounded("abcdef", &b2));
    var b1: [1]u8 = undefined;
    try expectEqualStrings("a", eval.copyBounded("abcdef", &b1));
    // A multi-byte codepoint that would straddle the tiny cap is dropped
    // whole rather than split.
    try expectEqualStrings("", eval.copyBounded("é", &b1));
    var b0: [0]u8 = undefined;
    try expectEqualStrings("", eval.copyBounded("abcdef", &b0));
    // Fits-exactly still copies verbatim below the marker size.
    try expectEqualStrings("ab", eval.copyBounded("ab", &b2));
}

// ── extractCode ──────────────────────────────────────────────────────

test "extractCode: plain, escaped, missing, malformed and non-string params" {
    var scratch: [4096]u8 = undefined;
    try expectEqualStrings("1+2", eval.extractCode("{\"code\":\"1+2\"}", &scratch).?);
    // Escapes are decoded (the studio JSON-encodes the code string).
    try expectEqualStrings(
        "print(\"hi\")\n",
        eval.extractCode("{\"code\":\"print(\\\"hi\\\")\\n\"}", &scratch).?,
    );
    // Unknown sibling keys are tolerated.
    try expectEqualStrings("x", eval.extractCode("{\"other\":1,\"code\":\"x\"}", &scratch).?);
    try expect(eval.extractCode("{}", &scratch) == null); // missing
    try expect(eval.extractCode("{\"code\":", &scratch) == null); // malformed
    try expect(eval.extractCode("{\"code\":42}", &scratch) == null); // non-string
    try expect(eval.extractCode("", &scratch) == null); // empty
}

// ── handleEvalCommand (VM-less legs) ─────────────────────────────────

test "handleEvalCommand: responds ok:false when the VM is not running" {
    scripting.Controller.deinit(); // ensure no VM (idempotent)
    mock.reset();
    var buf: [eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand("{\"code\":\"1+2\"}", &buf);
    const parsed = try parseResponse(response);
    defer parsed.deinit();
    try expect(!parsed.value.ok);
    try expect(std.mem.indexOf(u8, parsed.value.@"error", "not running") != null);
}

test "handleEvalCommand: responds ok:false on malformed params" {
    scripting.Controller.deinit();
    mock.reset();
    var buf: [eval.max_response_len]u8 = undefined;
    const response = scripting.handleEvalCommand("not json at all", &buf);
    const parsed = try parseResponse(response);
    defer parsed.deinit();
    try expect(!parsed.value.ok);
    try expect(std.mem.indexOf(u8, parsed.value.@"error", "invalid eval params") != null);
}

// ── packaging consistency ────────────────────────────────────────────

test "packaging: build.zig.zon ships every directory plugin.labelle references" {
    // A bundled pack (or a ship_from_plugin convention dir) is resolved
    // by the assembler from the CONSUMER's fetched copy of this package —
    // if build.zig.zon's `.paths` whitelist doesn't ship the directory,
    // the manifest points at content the tarball doesn't have and the
    // console hook silently never wires. Parse both files (embedded via
    // build.zig anonymous imports) and cross-check.
    const gpa = std.testing.allocator;

    const PluginManifest = struct {
        packs: []const []const u8 = &.{},
        convention_dirs: []const struct {
            name: []const u8,
            extension: ?[]const u8 = null,
            mode: enum { copy_and_scan, copy_only, ship_from_plugin } = .copy_and_scan,
        } = &.{},
    };
    const plugin_src: [:0]const u8 = @embedFile("plugin_labelle_src");
    const pm = try std.zon.parse.fromSliceAlloc(
        PluginManifest,
        gpa,
        plugin_src,
        null,
        .{ .ignore_unknown_fields = true },
    );
    defer std.zon.parse.free(gpa, pm);

    const BuildZon = struct { paths: []const []const u8 = &.{} };
    const zon_src: [:0]const u8 = @embedFile("build_zig_zon_src");
    const bz = try std.zon.parse.fromSliceAlloc(
        BuildZon,
        gpa,
        zon_src,
        null,
        .{ .ignore_unknown_fields = true },
    );
    defer std.zon.parse.free(gpa, bz);

    const ships = struct {
        fn dir(paths: []const []const u8, name: []const u8) bool {
            for (paths) |p| {
                if (std.mem.eql(u8, p, name)) return true;
            }
            return false;
        }
    }.dir;

    // Every bundled pack lives under packs/ — referencing ANY requires
    // shipping the directory.
    if (pm.packs.len > 0) try expect(ships(bz.paths, "packs"));
    // ship_from_plugin convention dirs are read from THIS package too;
    // game-sourced modes (copy_and_scan/copy_only) read the game tree
    // and need no shipping.
    for (pm.convention_dirs) |cd| {
        if (cd.mode == .ship_from_plugin) try expect(ships(bz.paths, cd.name));
    }
    // Every `{package}/<dir>/…` reference in the manifest (the
    // `.language_builds` steps' commands and symbol lists — rust's
    // native/, crystal's native-crystal/) runs against the CONSUMER's
    // fetched copy too. A raw-source scan beats modeling the whole step
    // schema here: any first path segment after a {package}/ marker
    // must be shipped — this catches the "declared a build step,
    // forgot the tarball" gap for every current and future language.
    {
        var found_package_refs: usize = 0;
        var search: []const u8 = plugin_src;
        while (std.mem.indexOf(u8, search, "{package}/")) |at| {
            const rest = search[at + "{package}/".len ..];
            const seg_end = std.mem.indexOfAny(u8, rest, "/\"") orelse rest.len;
            try expect(ships(bz.paths, rest[0..seg_end]));
            found_package_refs += 1;
            search = rest;
        }
        // The manifest DOES declare package-relative build inputs today
        // (rust + crystal) — keeps the scan meaningful.
        try expect(found_package_refs >= 2);
    }

    // And the manifest DOES reference the console pack today — keeps the
    // cross-check meaningful (deleting `.packs` should revisit this test).
    try expectEqual(@as(usize, 1), pm.packs.len);
    try expectEqualStrings("scripting_console", pm.packs[0]);
}

// ── pack hook shim: source-level verification ────────────────────────

test "pack hook shim parses, AstGen-compiles and keeps its wired names" {
    // The shim imports labelle-engine, so it can only FULLY compile
    // inside a generated game. Parse + AstGen is the strongest check
    // available here — it catches syntax errors and every AstGen-level
    // semantic error without resolving imports (the flow-codegen suites'
    // expectAstGenOk precedent).
    const src = @embedFile("console_eval_shim_src");
    const gpa = std.testing.allocator;
    var ast = try std.zig.Ast.parse(gpa, src, .zig);
    defer ast.deinit(gpa);
    try expectEqual(@as(usize, 0), ast.errors.len);
    var zir = try std.zig.AstGen.generate(gpa, ast);
    defer zir.deinit(gpa);
    try expect(!zir.hasCompileErrors());

    // Pin the assembler-convention-facing names: the receiver struct must
    // be the Pascal form of the file stem (`console_eval.zig` →
    // `ConsoleEval`, what the generated GameHooks tuple references) and
    // the handler must subscribe the exact engine event tag.
    try expect(std.mem.indexOf(u8, src, "pub const ConsoleEval = struct") != null);
    try expect(std.mem.indexOf(u8, src, "pub fn engine__editor_plugin_command(") != null);
}

test "packaging: the language schema vocabulary IS build.zig's Language enum" {
    // plugin.labelle's .params_schema declares the assembler-facing
    // language vocabulary (labelle-assembler#591 validates projects
    // against it at generate); build.zig's Language enum — reflected
    // here through @TypeOf(scripting.language) — is what the package
    // actually builds. They must be the SAME set: adding a sub-module
    // without widening the schema (or vice versa) fails this suite
    // instead of surfacing as a consumer's generate-time vocabulary
    // error.
    const gpa = std.testing.allocator;

    const Manifest = struct {
        params_schema: []const struct {
            name: []const u8,
            type: enum { str, i64, f64, bool, @"enum" },
            values: []const []const u8 = &.{},
            required: bool = false,
        } = &.{},
    };
    const plugin_src: [:0]const u8 = @embedFile("plugin_labelle_src");
    const pm = try std.zon.parse.fromSliceAlloc(
        Manifest,
        gpa,
        plugin_src,
        null,
        .{ .ignore_unknown_fields = true },
    );
    defer std.zon.parse.free(gpa, pm);

    const lang_fields = @typeInfo(@TypeOf(scripting.language)).@"enum".fields;
    var found = false;
    for (pm.params_schema) |entry| {
        if (!std.mem.eql(u8, entry.name, "language")) continue;
        found = true;
        try expect(entry.type == .@"enum");
        try expect(entry.required);
        // Set equality: same count + every enum tag present in the vocab.
        try expectEqual(lang_fields.len, entry.values.len);
        inline for (lang_fields) |lf| {
            var present = false;
            for (entry.values) |v| {
                if (std.mem.eql(u8, v, lf.name)) present = true;
            }
            try expect(present);
        }
    }
    try expect(found);
}

// ── build support: CRYSTAL_LIBRARY_PATH splitting ────────────────────

test "crystal_lib_paths: colon-separated env values yield one path per entry" {
    // `crystal env CRYSTAL_LIBRARY_PATH` is a colon-separated LIST (the
    // brew/tarball single-dir case is just its one-entry degenerate);
    // build.zig walks this iterator to addLibraryPath each entry, and
    // the assembler's {crystal_env:CRYSTAL_LIBRARY_PATH} splice row owes
    // the same split. A whole-value path would survive every single-dir
    // machine and silently lose gc/pcre2 on the first multi-entry
    // environment — exactly the drift this pin exists to catch.
    const Case = struct { value: []const u8, want: []const []const u8 };
    const cases = [_]Case{
        // The multi-entry environment (a user override prepending a dir).
        .{ .value = "/custom/libs:/opt/crystal/lib\n", .want = &.{ "/custom/libs", "/opt/crystal/lib" } },
        // The common single-dir output, trailing newline included.
        .{ .value = "/opt/homebrew/lib\n", .want = &.{"/opt/homebrew/lib"} },
        // Empty segments (leading/doubled/trailing colons) are skipped,
        // not handed to the linker as "" paths.
        .{ .value = "::/a/b::\n", .want = &.{"/a/b"} },
        // A blank value yields no paths at all.
        .{ .value = "  \n", .want = &.{} },
    };
    for (cases) |case| {
        var it = crystal_lib_paths.iterate(case.value);
        for (case.want) |want| {
            const got = it.next() orelse return error.TestExpectedEntry;
            try expectEqualStrings(want, got);
        }
        try expectEqual(@as(?[]const u8, null), it.next());
    }
}
