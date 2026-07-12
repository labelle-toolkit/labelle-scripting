//! Game-root Zig hook — the NATIVE half of the two-layer story this
//! example demonstrates. The C# scripts run on the embedded CoreCLR runtime
//! but reach the world exclusively through the Script Runtime Contract;
//! when a system wants engine-side dispatch (Zig-only APIs, typed payload
//! structs), it consumes the SAME events from the same engine bus via the
//! game-root `hooks/` convention: the assembler scans `hooks/*.zig`
//! automatically, folds `FeedWatcher` into the generated `GameHooks =
//! engine.MergeHooks(...)` receiver tuple, and `g.dispatchEvents()` calls
//! every method named after a `GameEvents` variant.
//!
//! So one `Labelle.Emit("hunger__feed", …)` in scripts/Spawner.cs reaches
//! BOTH subscribers, one bus, no glue:
//!   - THIS hook, at the SAME frame's `dispatchEvents`, and
//!   - the C# OnEvent handler in scripts/HungerSystem.cs on the NEXT tick's
//!     inbox dispatch (drain-boundary latency).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5 is
//! exact in binary floating point), proving the JSON-emitted C# payload was
//! parsed into events/hunger__feed.zig's `HungerFeed` and crossed the layer
//! boundary intact — not just that the hook fired.

const std = @import("std");
const HungerFeed = @import("../events/hunger__feed.zig").HungerFeed;

pub const FeedWatcher = struct {
    pub fn hunger__feed(self: *const FeedWatcher, feed: HungerFeed) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
