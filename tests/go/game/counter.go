// A healthy bystander: counts ticks into a Counter component. Entity
// creation happens in Init, so registration order = entity id order —
// the suites lean on that.
package game

import (
	"fmt"

	"labelle"
)

type Counter struct {
	labelle.NoopScript
	entity labelle.EntityID
	n      int
}

func (c *Counter) Init() {
	c.entity = labelle.CreateEntity()
}

func (c *Counter) Update(dt float32) {
	c.n++
	labelle.SetComponent(c.entity, "Counter",
		fmt.Sprintf(`{"dt":%v,"n":%d}`, dt, c.n))
}
