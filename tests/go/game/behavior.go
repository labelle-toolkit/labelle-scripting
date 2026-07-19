// The POC behavior, ported to the Script interface: the same five-tick
// world the lua/ruby/ts/rust/crystal suites drive (create player at the
// origin, +10/tick, bullet + emit on tick 3, tick_started subscriber
// reacting to n == 4) — one contract, every language, identical world.
package game

import (
	"fmt"

	"labelle"
)

type Behavior struct {
	labelle.NoopScript
	player labelle.EntityID
	// Reused across ticks — steady state reads Position with zero
	// allocation (the package's buffer-reuse idiom).
	posBuf []byte
}

func (b *Behavior) Init() {
	b.player = labelle.CreateEntity()
	if b.player == 0 {
		panic("entity_create failed")
	}
	if !labelle.SetComponent(b.player, "Position", `{"x":0,"y":0}`) {
		panic("set Position failed")
	}
	labelle.Subscribe("tick_started")
	labelle.Logf("go: player %d ready", b.player)
}

func (b *Behavior) OnEvent(name, payload string) {
	if name == "tick_started" && contains(payload, `"n":4`) {
		labelle.SetComponent(b.player, "TickLog", `{"last":4}`)
		labelle.Log("go: saw tick 4")
	}
}

func (b *Behavior) Update(dt float32) {
	var ok bool
	b.posBuf, ok = labelle.GetComponentInto(b.player, "Position", b.posBuf)
	if !ok {
		return
	}
	x, _ := i64Field(b.posBuf, `"x":`)
	x += 10
	labelle.SetComponent(b.player, "Position", fmt.Sprintf(`{"x":%d,"y":0}`, x))

	// The stamped dt reaches the script both ways: the hook argument
	// and the contract's own labelle_time_dt — they must agree.
	if labelle.Dt() != dt {
		panic("Dt() disagrees with the hook's dt")
	}

	if x == 30 {
		bullet := labelle.CreateEntity()
		labelle.SetComponent(bullet, "Bullet", `{"vx":0,"vy":-500}`)
		labelle.Emit("bullet_spawned", fmt.Sprintf(`{"owner":%d}`, b.player))
		labelle.Log("go: bullet away")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
