//! The suite's game module — what a real game's `rust/mod.rs` is to the
//! shipped crate. One extra, TEST-ONLY seam: because `register` runs
//! afresh on every `Controller.setup` (the glue rebuilds the registry
//! from scratch), each Zig test picks its scenario through the
//! `labelle_rs_test_select` export below BEFORE setup — the rust analog
//! of the lua suite registering different sources per test. An empty /
//! unknown selection registers nothing (a scriptless game).
//!
//! It also demonstrates the point of the native family: game modules
//! are full Rust — they can export their own `extern "C"` symbols,
//! define traits, spawn helpers — while the `labelle` module keeps the
//! world access safe.

use std::cell::RefCell;

use crate::labelle::Scripts;

mod alloc_probe;
mod behavior;
mod big_id;
mod big_query;
mod counter;
mod events;
mod lifecycle;
mod panics;
mod util;

thread_local! {
    static SCENARIO: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Test-only: select which scenario the next `register` builds. Called
/// by tests/rust_suite.zig before `Controller.setup`; main-thread only,
/// like every contract call.
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_test_select(ptr: *const u8, len: usize) {
    let name = if ptr.is_null() || len == 0 {
        ""
    } else {
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).unwrap_or("")
    };
    SCENARIO.with(|s| {
        let mut slot = s.borrow_mut();
        slot.clear();
        slot.push_str(name);
    });
}

/// The game registration convention (see native/src/game/mod.rs for the
/// shape a real game implements). Registration order is hook order.
pub fn register(scripts: &mut Scripts) {
    let scenario = SCENARIO.with(|s| s.borrow().clone());
    match scenario.as_str() {
        "behavior" => {
            scripts.add("behavior", Box::new(behavior::Behavior::default()));
        }
        // Panicking update between two healthy siblings: containment must
        // be per-script (the sibling AFTER the exploder still runs).
        "errors" => {
            scripts.add("counter", Box::new(counter::Counter::default()));
            scripts.add("exploder", Box::new(panics::Exploder));
            scripts.add("counter_after", Box::new(counter::Counter::default()));
        }
        // Panicking init: evicted before any update/deinit; sibling
        // registered AFTER it still initializes and runs.
        "bad_init" => {
            scripts.add("bad_init", Box::new(panics::BadInit));
            scripts.add("counter", Box::new(counter::Counter::default()));
        }
        "register_panic" => panic!("register scenario panic"),
        "big_id" => {
            scripts.add("big_id", Box::new(big_id::BigId::default()));
        }
        "big_query" => {
            scripts.add("big_query", Box::new(big_query::BigQuery::default()));
        }
        // Two subscriber instances: inbox fan-out must reach every live
        // script, not just the first.
        "events" => {
            scripts.add("events_a", Box::new(events::EventCounter::new("Seen")));
            scripts.add("events_b", Box::new(events::EventCounter::new("SeenB")));
        }
        "lifecycle" => {
            scripts.add("lifecycle", Box::new(lifecycle::Lifecycle::default()));
        }
        "alloc" => {
            scripts.add("alloc_probe", Box::new(alloc_probe::AllocProbe::default()));
        }
        _ => {}
    }
}
