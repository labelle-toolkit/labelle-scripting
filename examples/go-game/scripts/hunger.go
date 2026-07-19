// scripts/hunger.go — the labelle-engine#742 HungerController pattern,
// ported to the go native family (go twin of the rust example's
// hunger.rs):
//
//   - a plain struct implementing the Script interface, ALL state in
//     its fields — no VM, no registry magic,
//   - the buffer-reuse idiom at every contract boundary: caller-owned
//     slices held in fields, refilled per tick by QueryInto /
//     GetComponentInto (`s = s[:0]` retains capacity; growth is
//     required-size-driven, at most once) — go's steady-state-allocation
//     discipline, pinned flat by GO_BUFFERS_OK at tick 5,
//   - command-as-event feeding (hunger__feed) subscribed in Init —
//     emitted by scripts/spawner.go on tick 2, so the cross-script
//     round-trip over the engine bus is part of the pinned transcript,
//   - a NATIVE game-root Zig hook (hooks/feed_watcher.zig) consumes the
//     SAME hunger__feed from the same bus — the two-layer interop.
//
// `Hunger` is addressed by name over the contract; its schema is the
// Zig-authored components/hunger.zig (go ships no declare tool in v1 —
// see that file). Timeline: game.go's header.
package game

import "labelle"

const (
	decayPerTick = 0.25 // exact in binary fp — see game.go
	starveAt     = 0.25
	feedDefault  = 0.5
)

type HungerSystem struct {
	labelle.NoopScript
	// Reused across ticks — after tick 1's warm-up the steady state
	// allocates nothing (GO_BUFFERS_OK pins it). ids is refilled by
	// QueryInto (append form, capacity retained), comp by
	// GetComponentInto.
	ids         []labelle.EntityID
	comp        []byte
	tick        int
	wasStarving bool
	// Capacities recorded after tick 1 (the warm-up); any later
	// movement flips grew — go's growth-count analog.
	warmCaps [2]int
	warmed   bool
	grew     bool
}

// level reads `level` from the freshly filled component buffer.
func (h *HungerSystem) level() float32 {
	v, _ := f32Field(h.comp, `"level":`)
	return v
}

// writeHunger does a whole-struct REPLACE write.
func (h *HungerSystem) writeHunger(id labelle.EntityID, level float32, starving bool) {
	starvingStr := "false"
	if starving {
		starvingStr = "true"
	}
	labelle.SetComponent(id, "Hunger", `{"level":`+fmtF32(level)+`,"starving":`+starvingStr+`}`)
}

// feed is the go controller's command handler — the rust `feed` method,
// verbatim story.
func (h *HungerSystem) feed(id labelle.EntityID, amount float32) {
	var ok bool
	if h.comp, ok = labelle.GetComponentInto(id, "Hunger", h.comp); !ok {
		labelle.Log("GO_FEED_TARGET_MISSING")
		return
	}
	level := h.level() + amount
	h.writeHunger(id, level, level <= starveAt)
	// Re-read AFTER the write: the token carries what actually PERSISTED
	// in the ECS, not the in-memory value.
	if h.comp, ok = labelle.GetComponentInto(id, "Hunger", h.comp); ok {
		labelle.Log("GO_FED_LEVEL_" + fmtF32(h.level()))
	}
}

func (h *HungerSystem) Init() {
	labelle.Subscribe("hunger__feed")
	labelle.Log("GO_CTRL_READY")
}

func (h *HungerSystem) OnEvent(name, payload string) {
	if name != "hunger__feed" {
		return
	}
	// Guard the payload: a malformed hunger__feed without an entity has
	// no target — exemplar code shows the guard.
	entity, ok := u64Field([]byte(payload), `"entity":`)
	if !ok {
		return
	}
	amount, ok := f32Field([]byte(payload), `"amount":`)
	if !ok {
		amount = feedDefault
	}
	h.feed(entity, amount)
}

func (h *HungerSystem) Update(dt float32) {
	h.tick++

	// The hot-path reuse idiom: the ids slice is cleared (capacity
	// retained) and refilled by the wrapper — no per-tick list.
	var ok bool
	if h.ids, ok = labelle.QueryInto(`["Hunger","Worker"]`, h.ids); !ok {
		return
	}

	for _, id := range h.ids {
		// get returns false when the component vanished between the
		// query and this read — guard it rather than acting on the
		// PREVIOUS iteration's stale buffer.
		if h.comp, ok = labelle.GetComponentInto(id, "Hunger", h.comp); !ok {
			continue
		}
		level := h.level() - decayPerTick
		starving := level <= starveAt
		h.writeHunger(id, level, starving)

		// The token carries the written value — each tick's number is
		// only reachable through the PREVIOUS tick's persisted write, so
		// the sequence pins ECS persistence transitively.
		labelle.Log("GO_LEVEL_" + fmtF32(level))

		if starving && !h.wasStarving {
			h.wasStarving = true
			labelle.Log("GO_STARVING")
		}
	}

	// The growth pin: record every capacity after tick 1's warm-up;
	// ticks 2..5 must not move ANY of them (clear-retains-capacity,
	// grow-at-most-once — the whole idiom).
	if h.tick == 1 {
		h.warmCaps = [2]int{cap(h.ids), cap(h.comp)}
		h.warmed = true
	} else if h.warmed && (cap(h.ids) != h.warmCaps[0] || cap(h.comp) != h.warmCaps[1]) {
		h.grew = true
	}
	if h.tick == 5 {
		if !h.grew && len(h.ids) == 1 {
			labelle.Log("GO_BUFFERS_OK")
		} else {
			labelle.Log("GO_BUFFERS_MOVED")
		}
	}
}

func (h *HungerSystem) Deinit() {
	labelle.Log("GO_CTRL_DONE")
}
