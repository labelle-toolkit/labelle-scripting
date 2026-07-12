//! Game-root Zig hook — the NATIVE half of the two-layer story this
//! example demonstrates. The typescript scripts iterate at script speed
//! over the Script Runtime Contract; when a system needs to be native
//! (perf, Zig-only APIs), it consumes the SAME events from the same
//! engine bus via the game-root `hooks/` convention: the assembler scans
//! `hooks/*.zig` automatically (no project.labelle field), folds
//! `FeedWatcher` into the generated `GameHooks = engine.MergeHooks(...)`
//! receiver tuple, and `g.dispatchEvents()` calls every method named
//! after a `GameEvents` variant.
//!
//! So one `labelle.emit("hunger__feed", …)` in scripts/10_spawner.ts
//! reaches THREE subscribers, one bus, no glue:
//!   - THIS hook, natively, at the SAME frame's `dispatchEvents` (tick 2
//!     — after the scripts' Controller.tick, at frame end), and
//!   - the typescript `labelle.on("hunger__feed")` handler in
//!     scripts/20_hunger_controller.ts plus the pure-typescript top-level
//!     watcher in scripts/feed_watcher.ts on the NEXT tick's inbox
//!     dispatch (drain-boundary latency, tick 3).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5
//! is exact in binary floating point), proving the JSON-emitted
//! typescript payload was parsed into the typescript-DECLARED event's
//! generated struct and crossed the layer boundary intact — not just
//! that the hook fired. CI pins its position in the ordered transcript.
//!
//! The event is DECLARED in typescript now (events/hunger__feed.ts, rev
//! 20 option (b)), materialized as ONE generated scripting_events.zig the
//! game tree cannot import per-file — so this native hook spells its
//! payload param `anytype` (the documented consequence, RFC-LANGUAGE-
//! PLUGINS: the dispatcher never inspects param types; a Zig-AUTHORED
//! event would keep its typed `@import`). Field access is unchanged.

const std = @import("std");

pub const FeedWatcher = struct {
    // *const: this receiver is stateless (the dispatcher holds *FeedWatcher
    // and coerces). A hook that accumulates state takes `*FeedWatcher`.
    pub fn hunger__feed(self: *const FeedWatcher, feed: anytype) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
