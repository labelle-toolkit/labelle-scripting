// The signal/threading coexistence pin (the labelle-engine#746
// acceptance's tested half): a script uses GOROUTINES for computation —
// fan out work, join through a channel — and then applies the result
// INSIDE the hook, on the main thread, through the labelle API. The
// contract is never touched off the main thread. Init forces a
// runtime.GC() so the guest GC churns while the game is live (the
// crystal suite's forced-collect analog), proving the go runtime and
// the host coexist across the FFI boundary.
package game

import (
	"runtime"
	"sync"

	"labelle"
)

type Goroutines struct {
	labelle.NoopScript
	entity labelle.EntityID
}

func (g *Goroutines) Init() {
	g.entity = labelle.CreateEntity()
	// Force the guest GC to run against live state — the coexistence
	// pin. If the runtime and the host clashed (competing signal
	// handlers, a moved pointer across the boundary), this is where it
	// would surface.
	runtime.GC()
	labelle.Log("go: goroutines ready")
}

func (g *Goroutines) Update(dt float32) {
	// Fan out a pure computation across goroutines — no contract call
	// inside any of them (the threading matrix: goroutines compute, the
	// hook applies). Sum 0..99 in ten parallel chunks.
	const chunks = 10
	partials := make([]int, chunks)
	var wg sync.WaitGroup
	for c := 0; c < chunks; c++ {
		wg.Add(1)
		go func(c int) {
			defer wg.Done()
			s := 0
			for i := c * 10; i < c*10+10; i++ {
				s += i
			}
			partials[c] = s
		}(c)
	}
	wg.Wait()
	total := 0
	for _, p := range partials {
		total += p
	}

	// GC again every tick — steady-state churn.
	runtime.GC()

	// Now, on the MAIN thread inside the hook, apply the joined result
	// through the contract. total is always 4950 (Σ0..99).
	labelle.SetComponent(g.entity, "Sum", `{"total":`+itoa(total)+`}`)
	if total == 4950 {
		labelle.Log("go: goroutine sum ok")
	}
}

// itoa avoids pulling strconv into the hot path's import for one call.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
