//! scripts/mod.rs — the game's crate-module root (labelle-engine#741,
//! native-compiled family; `scripts/` is the shared convention dir every
//! script language uses since labelle-engine#237 / assembler v0.86.0):
//! at `labelle generate` the assembler LINKS this whole `scripts/` dir
//! over the scripting plugin's staged `native/src/game/`, cargo compiles
//! it into `liblabelle_rust_scripts.a`, and the game binary links it —
//! the `labelle_*` contract symbols resolve against the host's exports
//! in the same binary. No VM, nothing embeds; `pub fn register` below is
//! the one convention entry point (`scripts/mod.rs` IS the module root —
//! the native family's fixed name, where ruby uses ordering prefixes).
//!
//! The game mirrors examples/ruby-game's hunger sawtooth so the
//! cross-language story is visible token-for-token: same Hunger/Worker
//! component shapes (rust-DECLARED here — components/*.rs, like the ruby
//! game declares them in ruby), same command-event
//! (events/hunger__feed.rs), same native Zig hook
//! (hooks/feed_watcher.zig) — only the script layer swaps ruby for rust
//! (ruby's transcript carries one extra token, its pure-ruby
//! feed-watcher's).
//! Registration order stands in for ruby's two tiers: the spawner
//! registers FIRST (its `init` seeds the world before the system's, its
//! `update` runs before the system's each tick) and `deinit` runs in
//! REVERSE registration order, so the system tears down first — the
//! same interleaving ruby got from plain-hooks-then-controllers.
//!
//! Tokens carry BEHAVIOR: every tick logs the freshly written level, so
//! the pinned sequence encodes the whole decay-feed-decay sawtooth
//! through the real ECS. All values are exact in binary floating point
//! at every width en route (0.875 start, 0.25 steps, 0.5 feed), so the
//! logged decimals are deterministic. Decay is 0.25 PER TICK, not
//! `DECAY * dt` — the null backend's fixed dt is f32(1.0/60.0), which
//! no decimal-exact multiple survives, and exact values in the tokens
//! are the point.
//!
//! Frame-by-frame (LABELLE_NULL_FRAMES=5; per frame the plugin
//! Controller runs: inbox dispatch (`on_event`s) → `update`s, both in
//! registration order):
//!
//!   setup   RUST_INIT             (spawner init: worker seeded at 0.875)
//!           RUST_CTRL_READY       hunger system init (after the spawner's)
//!   tick 1  RUST_LEVEL_0.625      0.875 - 0.25 decay, written back
//!   tick 2  RUST_FEED_SENT        (spawner update: emits hunger__feed)
//!           RUST_LEVEL_0.375      0.625 - 0.25 — tick 1's write PERSISTED
//!           ZIG_FEED_SEEN_0.5     (hooks/feed_watcher.zig — the native
//!                                  subscriber, at THIS frame's
//!                                  dispatchEvents: frame end, after the
//!                                  Controller tick, one tick BEFORE the
//!                                  rust handler's inbox — the cross-layer
//!                                  latency is part of the pin)
//!   tick 3  RUST_ENGINE_TICK_SEEN (spawner's builtin sub, same inbox)
//!           RUST_FED_LEVEL_0.875  inbox: feed handler ran — id + exact
//!                                  f32 0.5 amount round-tripped the bus;
//!                                  0.375 + 0.5 re-read AFTER the write
//!           RUST_LEVEL_0.625      0.875 - 0.25 — decay resumes on the fed
//!   tick 4  RUST_LEVEL_0.375
//!   tick 5  RUST_LEVEL_0.125
//!           RUST_STARVING         0.125 <= 0.25 crossed the threshold
//!           RUST_BUFFERS_OK       warmed reused buffers never grew —
//!                                  rust's FrameArray equivalent is
//!                                  `Vec::clear` retaining capacity
//!           RUST_BATCH_OK_3_13.5   the batched swarm (scripts/swarm.rs):
//!                                  3 boids × 5 ticks of x += 0.5 through
//!                                  ONE batch_get + ONE batch_set per tick
//!                                  (contract v1.3 — needs engine ≥ 2.6.0)
//!   deinit  RUST_CTRL_DONE        hunger system (reverse registration)
//!           RUST_DEINIT           spawner
//!
//! Why the one-frame latencies: script-contract subscriptions activate
//! at drain boundaries (no same-tick replay) and drained entries reach
//! `on_event` on the NEXT tick's inbox dispatch — see
//! labelle-engine/src/script_contract.zig "Event tap semantics".

use crate::labelle::Scripts;

mod hunger;
mod spawner;
mod swarm;

/// The game registration entry point (the game's `scripts/mod.rs`,
/// staged as `native/src/game/mod.rs` — see the plugin README's rust
/// section). Registration order is hook order; `deinit` runs reversed.
pub fn register(scripts: &mut Scripts) {
    scripts.add("spawner", Box::new(spawner::Spawner::default()));
    scripts.add("hunger", Box::new(hunger::HungerSystem::default()));
    // The bulk-access swarm (contract v1.3, labelle-scripting#44) —
    // registers LAST so its per-tick token lands after the hunger
    // system's; see scripts/swarm.rs for the batch-iterator story.
    scripts.add("swarm", Box::new(swarm::Swarm::default()));
}

// ── Shared payload parsing ──────────────────────────────────────────────
//
// Scripts own their payload parsing (contract payloads are small, flat
// JSON; a structured serde story is future work). Needles are pre-quoted
// literals (`"\"level\":"`) so the hot path never allocates. Both
// helpers are pure slice walks — no float ever touches an entity id
// (u64 end to end; a bit-63 id survives exactly).

/// The unsigned integer after `needle` (e.g. `"\"entity\":"`), or None.
/// Tolerates a string-encoded id (`"entity":"123"`): dynamic-language
/// emitters that can't hold u64 precision natively spell ids as JSON
/// strings, and an exemplar parser should read both spellings.
pub(crate) fn u64_field(json: &[u8], needle: &str) -> Option<u64> {
    let mut i = skip_to_value(json, needle)?;
    if i < json.len() && json[i] == b'"' {
        i += 1;
    }
    let mut val: u64 = 0;
    let mut any = false;
    while i < json.len() && json[i].is_ascii_digit() {
        val = val.wrapping_mul(10).wrapping_add((json[i] - b'0') as u64);
        any = true;
        i += 1;
    }
    if any {
        Some(val)
    } else {
        None
    }
}

/// The float after `needle` (e.g. `"\"level\":"`), or None. Slices the
/// numeric token (digits, sign, dot, exponent — whatever spelling the
/// host's encoder picked) and hands it to rust's own f32 parser, which
/// rounds to nearest — exact for every value this game touches.
pub(crate) fn f32_field(json: &[u8], needle: &str) -> Option<f32> {
    let start = skip_to_value(json, needle)?;
    let mut end = start;
    while end < json.len() && matches!(json[end], b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E') {
        end += 1;
    }
    if end == start {
        return None;
    }
    core::str::from_utf8(&json[start..end]).ok()?.parse().ok()
}

/// Index of the first value byte after `needle` (tolerating the
/// encoder-side space in `"key": 1`), or None when absent.
fn skip_to_value(json: &[u8], needle: &str) -> Option<usize> {
    let nb = needle.as_bytes();
    if nb.is_empty() || json.len() < nb.len() {
        return None;
    }
    let at = (0..=json.len() - nb.len()).find(|&i| &json[i..i + nb.len()] == nb)?;
    let mut i = at + nb.len();
    // Any JSON whitespace, not just the encoder-side space — a
    // pretty-printed payload is legal JSON too.
    while i < json.len() && json[i].is_ascii_whitespace() {
        i += 1;
    }
    Some(i)
}
