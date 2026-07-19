// scripts/spawner.go — the plain-script tier (go twin of the rust
// example's spawner.rs): seeds the world in Init and commands a feeding
// over the engine bus on tick 2. State lives in the struct's fields —
// the native family's isolation is the type system itself (two scripts
// are two structs).
//
// Each observable milestone logs ONE `GO_<TOKEN>` line so CI can
// `grep -oE '(GO|ZIG)_[A-Z0-9_.]+'` and diff the exact ordered
// sequence. This script's slice of the 5-frame timeline (game.go's
// header documents the full interleaving):
//
//	setup   GO_INIT              Init(): Worker entity created,
//	                             Hunger{level: 0.875} written
//	tick 2  GO_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
//	tick 3  GO_ENGINE_TICK_SEEN  first engine__tick reaches the inbox
//	deinit  GO_DEINIT            reverse registration order (after the
//	                             hunger system's GO_CTRL_DONE)
package game

import (
	"strconv"

	"labelle"
)

type Spawner struct {
	labelle.NoopScript
	worker         labelle.EntityID
	tick           int
	engineTickSeen bool
}

func (s *Spawner) Init() {
	// The worker the HungerSystem manages. 0.875 (7/8, exact in binary
	// fp at every width) seeds the decay chain; the component's declared
	// default is 1.0, so the read-back chain starting at 0.875 proves
	// THIS write traveled through the real ECS.
	s.worker = labelle.CreateEntity()
	labelle.SetComponent(s.worker, "Hunger", `{"level":0.875,"starving":false}`)
	labelle.SetComponent(s.worker, "Worker", "{}")

	// Builtin-event consumption: an ENGINE event that fires every frame
	// — proving the engine's own bus reaches go handlers through the
	// tap. Logged once in OnEvent; the frame number rides OUTSIDE the
	// token so the pinned sequence stays stable.
	labelle.Subscribe("engine__tick")

	// Ids are uint64 END TO END in go — no bitcast (lua/ruby) or BigInt
	// (typescript) caveat.
	labelle.Log("GO_INIT id=" + strconv.FormatUint(s.worker, 10))
}

func (s *Spawner) OnEvent(name, payload string) {
	if name == "engine__tick" && !s.engineTickSeen {
		s.engineTickSeen = true
		frame, _ := u64Field([]byte(payload), `"frame_number":`)
		labelle.Log("GO_ENGINE_TICK_SEEN frame=" + strconv.FormatUint(frame, 10))
	}
}

func (s *Spawner) Update(dt float32) {
	s.tick++
	// Command-as-event, CROSS-SCRIPT: this plain script commands the
	// HungerSystem (which subscribed in its Init) to feed the worker.
	// The id and the exact f32 0.5 amount round-trip the hunger__feed
	// event on the real engine bus; the handler sees them on tick 3's
	// inbox.
	if s.tick == 2 {
		payload := `{"entity":` + strconv.FormatUint(s.worker, 10) + `,"amount":0.5}`
		if labelle.Emit("hunger__feed", payload) {
			labelle.Log("GO_FEED_SENT")
		} else {
			labelle.Log("GO_FEED_EMIT_FAIL")
		}
	}
}

func (s *Spawner) Deinit() {
	labelle.Log("GO_DEINIT")
}
