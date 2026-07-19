// The test module's c-archive main package — the same shape as the
// shipped native-go/glue/main.go stub (which it stands in for), plus
// ONE test-only seam: `labelle_go_test_select`, the export
// tests/go_suite.zig calls before each Controller.setup to pick the
// scenario the next Register builds (the go analog of the rust suite's
// labelle_rs_test_select). Everything else — registry, dispatch, panic
// containment, the labelle_go_* entries — is the SHIPPED package
// labelle, byte-identical via the go.mod replace directive.
package main

import "C"

import (
	"labelle"
	"labelle_go_test/game"
)

func init() { labelle.SetRegisterFn(game.Register) }

// labelle_go_test_select picks which scenario the next Register
// registers. Test-only; main-thread only, like every contract call.
//
//export labelle_go_test_select
func labelle_go_test_select(ptr *C.char, length C.size_t) {
	if ptr == nil || length == 0 {
		game.SelectScenario("")
		return
	}
	game.SelectScenario(C.GoStringN(ptr, C.int(length)))
}

func main() {}
