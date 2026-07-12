//! Game-root Zig hook — the OPTIONAL native escape hatch, and the
//! strongest interop statement in this repo: a native system consuming
//! a RUBY-DECLARED event. Since labelle-engine#772 this game authors NO
//! mandatory Zig — components, scripts AND the hunger__feed event are
//! all .rb (this file is the example's only .zig, and CI proves it
//! optional by deleting hooks/ in a scratch copy and running the game
//! green without it). When a system needs to be native (perf, Zig-only
//! APIs), it consumes the SAME events from the same engine bus via the
//! game-root `hooks/` convention: the assembler scans `hooks/*.zig`
//! automatically (no project.labelle field), folds `FeedWatcher` into
//! the generated `GameHooks = engine.MergeHooks(...)` receiver tuple,
//! and `g.dispatchEvents()` calls every method named after a
//! `GameEvents` variant.
//!
//! The payload param is `anytype` — the documented spelling for a hook
//! consuming a DECLARED event (assembler v0.87.0): the event struct is
//! codegenned into `scripting_events.zig` at the generated-target root,
//! and the staged `hooks/` dir is a live link into this game, so there
//! is no `events/hunger__feed.zig` left to `@import`. Dispatch is
//! comptime-typed either way — the method receives the exact
//! `HungerFeed` payload struct (`amount: f32 = 0.5, entity: u64 = 0`,
//! declared in events/hunger__feed.rb) and field access is unchanged.
//!
//! So one `Labelle.emit("hunger__feed", …)` in scripts/10_spawner.rb
//! reaches THREE subscribers, one bus, no glue:
//!   - THIS hook, natively, at the SAME frame's `dispatchEvents` (tick 2
//!     — after the scripts' Controller.tick, at frame end), and
//!   - the ruby `on("hunger__feed")` handler in
//!     scripts/20_hunger_controller.rb plus the pure-ruby top-level
//!     watcher in scripts/feed_watcher.rb on the NEXT tick's inbox
//!     dispatch (drain-boundary latency, tick 3).
//!
//! The token carries the payload amount (`ZIG_FEED_SEEN_0.5` — f32 0.5
//! is exact in binary floating point), proving the JSON-emitted ruby
//! payload was parsed into the ruby-declared event's generated struct
//! and crossed BOTH layer boundaries intact — script → engine bus →
//! native — not just that the hook fired. CI pins its position in the
//! ordered transcript.

const std = @import("std");

pub const FeedWatcher = struct {
    // *const: this receiver is stateless (the dispatcher holds *FeedWatcher
    // and coerces). A hook that accumulates state takes `*FeedWatcher`.
    pub fn hunger__feed(self: *const FeedWatcher, feed: anytype) void {
        _ = self;
        std.log.info("ZIG_FEED_SEEN_{d} entity={d}", .{ feed.amount, feed.entity });
    }
};
