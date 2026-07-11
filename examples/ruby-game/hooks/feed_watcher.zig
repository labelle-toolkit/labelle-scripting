//! Game-root Zig hook — the NATIVE half of the two-layer story this
//! example demonstrates. The ruby scripts iterate at script speed over
//! the Script Runtime Contract; when a system needs to be native (perf,
//! Zig-only APIs), it consumes the SAME events from the same engine bus
//! via the game-root `hooks/` convention: the assembler scans
//! `hooks/*.zig` automatically (no project.labelle field), folds
//! `FeedWatcher` into the generated `GameHooks = engine.MergeHooks(...)`
//! receiver tuple, and `g.dispatchEvents()` calls every method named
//! after a `GameEvents` variant.
//!
//! So one `Labelle.emit("hunger__feed", …)` in ruby/spawner.rb reaches
//! BOTH subscribers, one bus, no glue:
//!   - THIS hook, natively, at the SAME frame's `dispatchEvents` (tick 2
//!     — after the scripts' Controller.tick, at frame end), and
//!   - the ruby `on("hunger__feed")` handler in hunger_controller.rb on
//!     the NEXT tick's inbox dispatch (drain-boundary latency, tick 3).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5
//! is exact in binary floating point), proving the JSON-emitted ruby
//! payload was parsed into events/hunger__feed.zig's `HungerFeed` and
//! crossed the layer boundary intact — not just that the hook fired.
//! CI pins its position in the ordered transcript.

const std = @import("std");
const HungerFeed = @import("../events/hunger__feed.zig").HungerFeed;

pub const FeedWatcher = struct {
    pub fn hunger__feed(self: *FeedWatcher, feed: HungerFeed) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
