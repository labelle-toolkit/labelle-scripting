//! Game-root Zig hook — the OPTIONAL native escape hatch, and the
//! strongest interop statement this example makes: a native system
//! consuming an event a GO script emits. When a system needs to be
//! native (perf, Zig-only APIs, typed payload structs), it consumes the
//! same events from the same engine bus via the game-root `hooks/`
//! convention: the assembler scans `hooks/*.zig` automatically (no
//! project.labelle field), folds `FeedWatcher` into the generated
//! `GameHooks = engine.MergeHooks(...)` receiver tuple, and
//! `g.dispatchEvents()` calls every method named after a `GameEvents`
//! variant.
//!
//! The payload param is `anytype` — the method receives the exact
//! `HungerFeed` payload struct (events/hunger__feed.zig) and field
//! access is comptime-typed.
//!
//! So one `labelle.Emit("hunger__feed", …)` in scripts/spawner.go
//! reaches BOTH subscribers, one bus, no glue:
//!   - THIS hook, natively, at the SAME frame's `dispatchEvents` (tick 2
//!     — after the scripts' Controller.tick, at frame end), and
//!   - the go `OnEvent` handler in scripts/hunger.go on the NEXT tick's
//!     inbox dispatch (drain-boundary latency, tick 3).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5
//! is exact in binary floating point), proving the JSON-emitted go
//! payload was parsed into the event's struct and crossed the layer
//! boundary intact. CI pins its position in the ordered transcript.

const std = @import("std");

pub const FeedWatcher = struct {
    pub fn hunger__feed(self: *const FeedWatcher, feed: anytype) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
