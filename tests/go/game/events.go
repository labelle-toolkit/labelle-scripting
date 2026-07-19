// The inbox fan-out double: two instances of this script subscribe to
// the same event; every drained entry must reach BOTH (the inbox is
// plugin-wide), with the nested payload intact.
package game

import (
	"fmt"

	"labelle"
)

type EventCounter struct {
	labelle.NoopScript
	comp   string
	entity labelle.EntityID
	count  int
	amount int64
	nested bool
}

func NewEventCounter(comp string) *EventCounter {
	return &EventCounter{comp: comp}
}

func (e *EventCounter) write() {
	labelle.SetComponent(e.entity, e.comp,
		fmt.Sprintf(`{"amount":%d,"count":%d,"nested_ok":%v}`, e.amount, e.count, e.nested))
}

func (e *EventCounter) Init() {
	e.entity = labelle.CreateEntity()
	labelle.Subscribe("cargo__delivered")
	e.write()
}

func (e *EventCounter) OnEvent(name, payload string) {
	if name != "cargo__delivered" {
		return
	}
	e.count++
	if v, ok := i64Field([]byte(payload), `"amount":`); ok {
		e.amount = v
	}
	e.nested = contains(payload, `"tags":["fragile"]`)
	e.write()
}
