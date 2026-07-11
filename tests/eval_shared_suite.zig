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
