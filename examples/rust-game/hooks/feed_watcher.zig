//! Game-root Zig hook — the OPTIONAL native escape hatch, and the strongest
//! interop statement this example makes: a native system consuming a
//! RUST-DECLARED event. Since the native declare lane (labelle-engine#774 /
//! assembler v0.88.0) this game authors NO mandatory Zig — components, the
//! hunger__feed event AND the gameplay scripts are all .rs (this file is the
//! example's only .zig, and CI proves it optional by deleting hooks/ in a
//! scratch copy and running the game green without it). When a system needs
//! to be native (perf, Zig-only APIs, typed payload structs), it consumes the
//! SAME events from the same engine bus via the game-root `hooks/`
//! convention: the assembler scans `hooks/*.zig` automatically (no
//! project.labelle field), folds `FeedWatcher` into the generated `GameHooks =
//! engine.MergeHooks(...)` receiver tuple, and `g.dispatchEvents()` calls
//! every method named after a `GameEvents` variant.
//!
//! The payload param is `anytype` — the documented spelling for a hook
//! consuming a DECLARED event: the event struct is codegenned into
//! `scripting_events.zig` at the generated-target root (from the rust
//! `labelle::event!` in events/hunger__feed.rs), and the staged `hooks/` dir
//! is a live link into this game, so there is no `events/hunger__feed.zig`
//! left to `@import`. Dispatch is comptime-typed either way — the method
//! receives the exact `HungerFeed` payload struct (`amount: f32 = 0.5,
//! entity: u64 = 0`, declared in events/hunger__feed.rs) and field access is
//! unchanged.
//!
//! So one `labelle::emit("hunger__feed", …)` in scripts/spawner.rs reaches
//! BOTH subscribers, one bus, no glue:
//!   - THIS hook, natively, at the SAME frame's `dispatchEvents` (tick 2 —
//!     after the scripts' Controller.tick, at frame end), and
//!   - the rust `on_event` handler in scripts/hunger.rs on the NEXT tick's
//!     inbox dispatch (drain-boundary latency, tick 3).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5 is
//! exact in binary floating point), proving the JSON-emitted rust payload was
//! parsed into the rust-declared event's generated struct and crossed the
//! layer boundary intact — not just that the hook fired. CI pins its position
//! in the ordered transcript.

const std = @import("std");

pub const FeedWatcher = struct {
    // *const: this receiver is stateless (the dispatcher holds *FeedWatcher
    // and coerces). A hook that accumulates state takes `*FeedWatcher`.
    pub fn hunger__feed(self: *const FeedWatcher, feed: anytype) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
