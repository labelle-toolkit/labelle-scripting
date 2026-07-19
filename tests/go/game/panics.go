// The panic-containment doubles: every hook panic must be recovered at
// the FFI boundary by the shipped glue (a Go panic unwinding out of a
// cgo export would kill the test process — surviving these scenarios
// IS the pin).
package game

import "labelle"

// Exploder panics in every Update — logged every tick, never evicted,
// siblings unaffected.
type Exploder struct{ labelle.NoopScript }

func (Exploder) Update(float32) {
	panic("boom on tick")
}

// BadInit panics in Init — logged and EVICTED: Update/Deinit must
// never run on half-initialized state.
type BadInit struct{ labelle.NoopScript }

func (BadInit) Init() {
	panic("bad_init boom")
}

func (BadInit) Update(float32) {
	labelle.Log("bad_init update ran")
}

func (BadInit) Deinit() {
	labelle.Log("bad_init deinit ran")
}
