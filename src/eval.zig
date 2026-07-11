//! Console-eval shared pieces (labelle-scripting#4, the studio Script
//! Console's `{plugin: "scripting", command: "eval", params: {code}}`
//! command): the language-agnostic result shape, the `params` JSON
//! decoding, and the bounded response-JSON builder. Everything here is
//! pure Zig with no engine coupling — it is fully exercised by this
//! repo's mock-world tests, while the engine-coupled half (the pack hook
//! shim under packs/scripting_console/) stays a thin caller.
//!
//! The response protocol (labelle-engine#758, engine ≥ 2.5.0): a handler
//! answers one plugin command through `engine.plugin_command.respond`,
//! whose channel is capped at `max_response_len` (4096) bytes. The
//! builder below therefore TRUNCATES — marker included, JSON still valid
//! — rather than ever handing the channel an over-cap payload it would
//! cut mid-escape.

const std = @import("std");

/// One console evaluation's outcome. `text` is the rendered result value
/// (ok) or the error + traceback (not ok) — always a bounded slice of a
/// caller-owned buffer, valid until the next eval.
pub const EvalResult = struct {
    ok: bool,
    text: []const u8,
};

/// Mirror of `engine.plugin_command.max_response_len` (labelle-engine
/// #758). Mirrored, not imported: this module must compile against the
/// mock world with no engine dependency, and the value is a protocol
/// constant the response channel's every consumer quotes (the studio
/// pre-sizes its read buffer from the same number). The pack hook shim
/// prefers the engine's own decl when it exists and only falls back to
/// this mirror on pre-#758 engines.
pub const max_response_len: usize = 4096;

/// Cap for one rendered result/error text. Same number as the response
/// cap on purpose: anything longer could never reach the studio anyway,
/// and the response builder re-bounds during escaping regardless.
pub const max_text_len: usize = 4096;

/// Cap for one eval's source code. Console input is human-typed (or
/// pasted) — 8 KiB is generous; the lua backend needs a few bytes of
/// headroom on top for its `return <code>;` expression wrapper.
pub const max_code_len: usize = 8192;

/// The truncation marker appended wherever a rendered value or response
/// was cut: U+2026 HORIZONTAL ELLIPSIS, three UTF-8 bytes.
pub const truncation_marker = "…";

/// Largest cut ≤ `limit` such that `bytes[0..cut]` does not end in the
/// middle of a UTF-8 sequence. Truncating rendered text at an arbitrary
/// byte can split a multi-byte codepoint; the JSON would stay
/// structurally valid but carry a mangled string, so every truncation
/// site backs off through this first. The test is boundary-based — a cut
/// is clean iff the FIRST byte it removes is not a continuation byte —
/// so a complete sequence ending exactly at `limit` is kept whole.
/// Invalid UTF-8 backs off at most 4 positions; it was garbage either way.
pub fn utf8SafeLen(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var n = limit;
    if (bytes[n] & 0xC0 != 0x80) return n; // clean boundary
    // bytes[n] continues a sequence that starts before the cut: back off
    // past the already-included continuations and the lead byte.
    var back: usize = 0;
    while (n > 0 and back < 4) : (back += 1) {
        n -= 1;
        if (bytes[n] & 0xC0 != 0x80) break; // consumed the lead
    }
    return n;
}

/// Copy `text` into `out`, bounded: when it doesn't fit, cut at a whole
/// UTF-8 codepoint and append the truncation marker. The shared tail of
/// every backend's result/error rendering. Returns the written slice.
pub fn copyBounded(text: []const u8, out: []u8) []const u8 {
    if (text.len <= out.len) {
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }
    // Doesn't fit. A buffer too small for even the marker gets a plain
    // codepoint-safe cut — a runtime guard, not an assert, because in
    // release builds an assert vanishes and `out.len - marker.len`
    // would underflow into an out-of-bounds @memcpy.
    if (out.len < truncation_marker.len) {
        const cut = utf8SafeLen(text, out.len);
        @memcpy(out[0..cut], text[0..cut]);
        return out[0..cut];
    }
    const cut = utf8SafeLen(text, out.len - truncation_marker.len);
    @memcpy(out[0..cut], text[0..cut]);
    @memcpy(out[cut..][0..truncation_marker.len], truncation_marker);
    return out[0 .. cut + truncation_marker.len];
}

/// Extract the `code` string from an eval command's `params` JSON
/// (`{"code": "..."}`). Returns null for anything that isn't a JSON
/// object carrying a string `code` — malformed JSON, a missing key, a
/// non-string value, or code longer than `max_code_len`.
///
/// `scratch` backs the parse (std.json's nesting stack plus the unescaped
/// string when the code carries escapes); the returned slice points into
/// `scratch` or into `params_json` itself and is valid until either is
/// reused. 2× `max_code_len` scratch always suffices.
pub fn extractCode(params_json: []const u8, scratch: []u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSliceLeaky(
        struct { code: ?[]const u8 = null },
        fba.allocator(),
        params_json,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    const code = parsed.code orelse return null;
    if (code.len > max_code_len) return null;
    return code;
}

/// U+FFFD REPLACEMENT CHARACTER — what `buildResponse` substitutes for
/// every byte that is not part of a valid UTF-8 sequence. Language VMs
/// hand back arbitrary byte strings (lua `string.char(255)`), and JSON
/// is UTF-8 by definition: passing such bytes through raw would make the
/// whole response unparseable on the studio side even though the eval
/// SUCCEEDED.
pub const replacement_char = "\u{FFFD}";

/// Build the console response JSON into `buf`:
///   `{"ok":true,"value":"<escaped text>"}` /
///   `{"ok":false,"error":"<escaped text>"}`.
///
/// The emitted string body is ALWAYS valid UTF-8 JSON, whatever bytes
/// `text` carries: control bytes and JSON metacharacters are escaped,
/// valid multi-byte sequences pass through whole, and every invalid
/// byte (stray continuation, bad lead, overlong/surrogate encoding,
/// truncated tail) becomes one `replacement_char`.
///
/// Bounded at `buf.len` with unit-safe truncation: the escaper emits
/// ATOMIC units (an escape sequence, one ASCII byte, one whole UTF-8
/// sequence, or one replacement char), so when the budget runs out the
/// cut lands between units, the truncation marker is appended, and the
/// JSON is closed — structurally valid at any buffer that fits an empty
/// response. A buffer too small for even that yields an empty slice —
/// the one shape that cannot masquerade as a response (a runtime guard,
/// not an assert: pub fn, and in release builds an assert vanishes,
/// letting the reservation subtraction below underflow into an
/// out-of-bounds write). Callers pass a response-cap-sized buffer so
/// the engine channel never truncates after us (its mid-escape cut is
/// exactly what this pre-bounding exists to avoid).
pub fn buildResponse(ok: bool, text: []const u8, buf: []u8) []const u8 {
    const prefix = if (ok) "{\"ok\":true,\"value\":\"" else "{\"ok\":false,\"error\":\"";
    const tail = "\"}";
    if (buf.len < prefix.len + truncation_marker.len + tail.len) return buf[0..0];
    // Reserve room for the worst-case tail: marker + closing quote/brace.
    const budget = buf.len - truncation_marker.len - tail.len;

    @memcpy(buf[0..prefix.len], prefix);
    var w: usize = prefix.len;
    var truncated = false;

    // Outlives the switch below (the `\u00XX` arm formats into it and
    // the emit reads it after the arm ends).
    var ubuf: [6]u8 = undefined;

    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        // How many input bytes this unit consumes (all arms take 1
        // except a whole valid multi-byte sequence).
        var step: usize = 1;
        const unit: []const u8 = switch (b) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0C => "\\f",
            else => blk: {
                if (b < 0x20) {
                    break :blk std.fmt.bufPrint(&ubuf, "\\u{x:0>4}", .{b}) catch unreachable;
                }
                if (b < 0x80) break :blk text[i .. i + 1];
                // Multi-byte lead (or a stray byte pretending to be one):
                // pass the sequence through WHOLE iff it decodes as valid
                // UTF-8; anything else — bad lead, truncated tail,
                // overlong/surrogate encoding, stray continuation — is
                // replaced one byte at a time (each invalid byte = one
                // replacement char, the conventional policy).
                const seq_len = std.unicode.utf8ByteSequenceLength(b) catch
                    break :blk replacement_char;
                if (i + seq_len > text.len) break :blk replacement_char;
                _ = std.unicode.utf8Decode(text[i..][0..seq_len]) catch
                    break :blk replacement_char;
                step = seq_len;
                break :blk text[i..][0..seq_len];
            },
        };
        if (w + unit.len > budget) {
            truncated = true;
            break;
        }
        @memcpy(buf[w..][0..unit.len], unit);
        w += unit.len;
        i += step;
    }

    if (truncated) {
        // Units are atomic (see above), so the cut cannot have split an
        // escape or a UTF-8 sequence — the marker composes directly.
        @memcpy(buf[w..][0..truncation_marker.len], truncation_marker);
        w += truncation_marker.len;
    }
    @memcpy(buf[w..][0..tail.len], tail);
    w += tail.len;
    return buf[0..w];
}
