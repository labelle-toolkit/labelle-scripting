// Package game is the suite's game module — what a real game's
// scripts/ dir is to the shipped native-go module. One extra,
// TEST-ONLY seam: because Register runs afresh on every
// Controller.setup (the glue rebuilds the registry from scratch), each
// Zig test picks its scenario through [SelectScenario] (reached via
// main.go's labelle_go_test_select export) BEFORE setup — the go
// analog of the rust suite's thread_local selector. An empty / unknown
// selection registers nothing (a scriptless game).
//
// It also demonstrates the point of the native family: game modules
// are full Go — they can spawn goroutines (see goroutines.go's rules),
// define interfaces, export their own cgo symbols — while the labelle
// package keeps the world access safe.
package game

import "labelle"

var scenario string

// SelectScenario picks which scenario the next Register builds.
func SelectScenario(name string) { scenario = name }

// Register is the game registration convention (see
// native-go/game/game.go for the shape a real game implements).
// Registration order is hook order.
func Register(s *labelle.Scripts) {
	switch scenario {
	case "behavior":
		s.Add("behavior", &Behavior{})
	// Panicking update between two healthy siblings: containment must
	// be per-script (the sibling AFTER the exploder still runs).
	case "errors":
		s.Add("counter", &Counter{})
		s.Add("exploder", &Exploder{})
		s.Add("counter_after", &Counter{})
	// Panicking init: evicted before any update/deinit; sibling
	// registered AFTER it still initializes and runs.
	case "bad_init":
		s.Add("bad_init", &BadInit{})
		s.Add("counter", &Counter{})
	case "register_panic":
		panic("register scenario panic")
	case "big_id":
		s.Add("big_id", &BigID{})
	// Two subscriber instances: inbox fan-out must reach every live
	// script, not just the first.
	case "events":
		s.Add("events_a", NewEventCounter("Seen"))
		s.Add("events_b", NewEventCounter("SeenB"))
	// The signal/threading coexistence pin: goroutines compute, the
	// hook applies, forced GC churns — the #746 acceptance's tested
	// half.
	case "goroutines":
		s.Add("goroutines", &Goroutines{})
	// Bulk component access (contract v1.3, #44): raw batch tier,
	// coupling guard, typed view tier, exit semantics.
	case "bulk_batch":
		s.Add("bulk_batch", &BatchFlat{})
	case "bulk_stale":
		s.Add("bulk_stale", &BatchStale{})
	case "bulk_iter":
		s.Add("bulk_iter", &BatchIter{})
	case "bulk_iter_edge":
		s.Add("bulk_iter_edge", &BatchIterEdge{})
	}
}
