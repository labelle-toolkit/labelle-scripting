//! Game-side JSON field extraction, slice-1 style: scripts own their
//! payload parsing (a structured serde story is future work — the
//! contract's payloads are small and flat). Needles are pre-quoted
//! literals (`"\"x\":"`) so the hot path never allocates.

/// The integer after `needle` (e.g. `"\"x\":"`) in `json`, or None.
/// Pure i64 arithmetic — no float ever touches the value.
pub fn i64_field(json: &[u8], needle: &str) -> Option<i64> {
    let at = find(json, needle.as_bytes())?;
    let mut i = at + needle.len();
    // Tolerate the encoder-side space ("key": 1).
    while i < json.len() && json[i] == b' ' {
        i += 1;
    }
    let neg = i < json.len() && json[i] == b'-';
    if neg {
        i += 1;
    }
    let mut val: i64 = 0;
    let mut any = false;
    while i < json.len() && json[i].is_ascii_digit() {
        val = val.wrapping_mul(10).wrapping_add((json[i] - b'0') as i64);
        any = true;
        i += 1;
    }
    if !any {
        return None;
    }
    Some(if neg { -val } else { val })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}
