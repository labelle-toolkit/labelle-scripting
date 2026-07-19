// The plugin glue: the C entry points labelle-scripting's `go` arm
// (src/go/vm.zig) drives, and the script registry + dispatch loops
// behind them. Games never touch this half of the package — their
// surface is the wrappers (labelle.go, batch.go), [Script], [Scripts]
// and the one `Register` convention in their scripts/game.go.
//
// The //export entries live INSIDE package labelle (cgo exports work
// from any linked package, and //export must sit in a file that
// imports "C"): the shipped glue/main.go stub only WIRES the game
// module — `labelle.SetRegisterFn(game.Register)` from its init() — so
// this repo's test module can recompose the same shipped glue around
// its own scenario package with an eight-line stub of its own (the go
// spelling of tests/rust/src/lib.rs's #[path] recomposition).
//
// # The labelle_go_* entry convention (go glue ABI v1)
//
// The Zig arm calls, in Controller order:
//
//	labelle_go_abi_version    Vm.init — handshake, must return 1
//	labelle_go_setup          end of Controller.setup — runs the game's
//	                          Register, then every script's Init
//	                          (panicking Inits are EVICTED)
//	labelle_go_dispatch_inbox top of Controller.tick — drains the event
//	                          inbox, fans out to OnEvent
//	labelle_go_tick           Controller.tick — every Update(dt)
//	labelle_go_deinit         Controller.deinit — every Deinit (reverse
//	                          registration order), registry dropped
//
// Bump GoABIVersion on any change to this table's names or signatures —
// the Zig arm refuses a mismatched glue at boot (the stale-archive
// case: a plugin upgrade with a stale {cache} artifact must fail the
// handshake, not corrupt a tick).
//
// # Panics MUST NOT unwind across the FFI boundary
//
// Every entry point recovers its whole body, and every script hook call
// is ADDITIONALLY recovered one script at a time, so one panicking
// script cannot starve its siblings — a Go panic unwinding out of a
// cgo-exported function would crash the process. Semantics mirror the
// rust glue (the family's pins): Init panic → logged + evicted;
// Update/OnEvent panic → logged every time, script stays; Deinit panic
// → logged, teardown continues; Register panic → logged, ALL
// registrations dropped (all-or-nothing — a half-registered set would
// run hooks the author never ordered). A RECOVERED Go panic writes
// nothing to stderr (unlike rust, whose default hook had to be
// replaced), so expected-panic tests leave a passing build clean; the
// report carries the panic VALUE with script attribution — the panic
// site's file:line lives in the goroutine stack Go only renders for
// UNrecovered panics, and parsing debug.Stack() for one frame is not
// worth the fragility (the deliberate delta from rust's two-line
// location+message report).
//
// The one panic this recovery can never catch: a panic in a GOROUTINE a
// script spawned — Go kills the process when a goroutine panics
// unrecovered, whatever the main thread was doing. Scripts that spawn
// goroutines own their recovery (and must not call the labelle API from
// them — labelle.go's threading matrix).
package labelle

import "C"

// GoABIVersion is the glue ABI revision labelle_go_abi_version reports
// and the Zig arm's SUPPORTED_GO_ABI_VERSION must equal.
const GoABIVersion uint32 = 1

// Script is one game script: a plain struct with per-frame state in its
// fields. Embed [NoopScript] to get empty defaults and implement only
// what you need.
//
// Hook order per frame (driven by the plugin Controller through the
// glue): OnEvent for every drained inbox entry (FIFO, last frame's
// events), then Update(dt). Init runs once at plugin setup, Deinit at
// teardown (reverse registration order).
type Script interface {
	// Init runs once, at plugin setup — create entities, subscribe.
	Init()
	// Update runs every frame, after the inbox drain. dt is the
	// gameplay delta-time in seconds — the same scaled dt Zig scripts
	// received.
	Update(dt float32)
	// OnEvent receives one drained inbox event: name is the
	// subscription key, payload the event's JSON. The inbox is
	// PLUGIN-wide — every subscription any script makes feeds the same
	// drain, so filter on name.
	OnEvent(name, payload string)
	// Deinit runs once, at plugin teardown (the game is still alive —
	// contract calls are valid here).
	Deinit()
}

// NoopScript is the embeddable all-defaults [Script] implementation.
type NoopScript struct{}

func (NoopScript) Init()                  {}
func (NoopScript) Update(float32)         {}
func (NoopScript) OnEvent(string, string) {}
func (NoopScript) Deinit()                {}

// Scripts is the registration collector handed to the game's Register
// entry point. Names are diagnostics identity: panic reports read
// "script '<name>' panicked in <hook>".
type Scripts struct {
	entries []scriptEntry
}

type scriptEntry struct {
	name   string
	script Script
	// alive is cleared when Init panics: an evicted script never
	// receives OnEvent/Update/Deinit (half-initialized state must not
	// run).
	alive bool
}

// Add registers one script. Registration order is hook order (Init,
// per-event fan-out and Update run in it; Deinit runs reversed).
func (s *Scripts) Add(name string, script Script) {
	s.entries = append(s.entries, scriptEntry{name: name, script: script, alive: true})
}

// registerFn is the game module's Register, wired by the glue stub's
// init() before any entry point can run (package init precedes the
// c-archive's exported calls by construction).
var registerFn func(*Scripts)

// SetRegisterFn wires the game's Register convention entry point into
// the glue. Glue-only: the generated module stub (glue/main.go — or a
// test module's own stub) calls it from init(); game scripts never do.
func SetRegisterFn(f func(*Scripts)) { registerFn = f }

// registry is the live script set between setup and deinit. Module
// state, main-thread-only — the exact shape of the rust glue's
// thread_local, minus the thread_local (the contract is main-thread-
// only either way; the guard in labelle.go polices the callers).
var registry []scriptEntry

// inboxScratch is the reused drain buffer for the inbox — grow-only,
// so the steady state polls with zero allocation.
var inboxScratch []byte

// panicText renders a recovered panic value for the log.
func panicText(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case error:
		return t.Error()
	default:
		return "<non-string panic payload>"
	}
}

// guarded calls one script hook with per-script containment. Returns
// false when the hook panicked. context is only rendered ON panic —
// the happy path allocates nothing.
func guarded(name string, context string, f func()) (ok bool) {
	defer func() {
		if v := recover(); v != nil {
			Logf("go: script '%s' %s panicked: %s", name, context, panicText(v))
			ok = false
		}
	}()
	f()
	return true
}

// ── Entry points (the Zig arm's externs) ────────────────────────────────

// labelle_go_abi_version is the handshake: the glue ABI revision this
// module was built against.
//
//export labelle_go_abi_version
func labelle_go_abi_version() uint32 {
	return GoABIVersion
}

// labelle_go_setup builds the registry (the game's Register), then runs
// every script's Init — a panicking Init logs and EVICTS that script;
// the rest keep going. Idempotent-by-rebuild: a re-setup drops the old
// registry and registers from scratch (the Controller's re-setup =
// clean restart contract). Returns 0, or -1 when Register itself
// panicked (no scripts registered).
//
//export labelle_go_setup
func labelle_go_setup() (rc int32) {
	enterHook()
	defer leaveHook()
	defer func() {
		if v := recover(); v != nil {
			Logf("go: labelle_go_setup panicked: %s", panicText(v))
			rc = -1
		}
	}()

	var scripts Scripts
	registerOK := func() (ok bool) {
		defer func() {
			if v := recover(); v != nil {
				// All-or-nothing registration: drop whatever registered
				// before the panic — a partial set would run hooks the
				// author never finished ordering.
				Logf("go: Register() panicked: %s", panicText(v))
				Log("go: no scripts registered")
				ok = false
			}
		}()
		if registerFn == nil {
			// The module stub never wired a game — a build wiring bug,
			// named for what it is.
			Log("go: no Register wired — the glue stub's SetRegisterFn never ran")
			return false
		}
		registerFn(&scripts)
		return true
	}()
	if !registerOK {
		return -1
	}

	registry = scripts.entries
	for i := range registry {
		e := &registry[i]
		if !guarded(e.name, "in Init", e.script.Init) {
			e.alive = false
			Logf("go: script evicted: '%s'", e.name)
		}
	}
	return 0
}

// labelle_go_dispatch_inbox drains the event inbox (FIFO, one poll loop
// — the RFC's model) and fans each entry out to every live script's
// OnEvent. Handler panics are contained per script per event; the drain
// always completes.
//
//export labelle_go_dispatch_inbox
func labelle_go_dispatch_inbox() {
	enterHook()
	defer leaveHook()
	defer func() {
		if v := recover(); v != nil {
			Logf("go: labelle_go_dispatch_inbox panicked: %s", panicText(v))
		}
	}()
	for {
		var ok bool
		inboxScratch, ok = pollInto(inboxScratch)
		if !ok {
			return
		}
		// Entries are "<name> <json>"; an entry is never empty. The
		// string(...) conversions allocate per EVENT, not per frame —
		// events are edges, not the hot path.
		text := string(inboxScratch)
		name, payload := text, ""
		for i := 0; i < len(text); i++ {
			if text[i] == ' ' {
				name, payload = text[:i], text[i+1:]
				break
			}
		}
		for i := range registry {
			e := &registry[i]
			if !e.alive {
				continue
			}
			guarded(e.name, "in OnEvent('"+name+"')", func() { e.script.OnEvent(name, payload) })
		}
	}
}

// labelle_go_tick runs every live script's Update(dt), registration
// order. A panicking Update is logged EVERY tick and the script stays
// registered (its state is intact; the author gets the report until
// it's fixed) — siblings always run.
//
//export labelle_go_tick
func labelle_go_tick(dt float32) {
	enterHook()
	defer leaveHook()
	defer func() {
		if v := recover(); v != nil {
			Logf("go: labelle_go_tick panicked: %s", panicText(v))
		}
	}()
	for i := range registry {
		e := &registry[i]
		if !e.alive {
			continue
		}
		guarded(e.name, "in Update", func() { e.script.Update(dt) })
	}
}

// labelle_go_deinit runs every live script's Deinit, REVERSE
// registration order (teardown is LIFO against setup), then drops the
// registry. Panics are contained per script; teardown always
// completes. Idempotent.
//
//export labelle_go_deinit
func labelle_go_deinit() {
	enterHook()
	defer leaveHook()
	defer func() {
		if v := recover(); v != nil {
			Logf("go: labelle_go_deinit panicked: %s", panicText(v))
		}
	}()
	// Take the registry OUT before running hooks: a Deinit that somehow
	// re-enters an entry point sees "no registry" (a no-op) instead of
	// re-walking a half-torn set.
	reg := registry
	registry = nil
	for i := len(reg) - 1; i >= 0; i-- {
		e := &reg[i]
		if !e.alive {
			continue
		}
		guarded(e.name, "in Deinit", func() { e.script.Deinit() })
	}
}
