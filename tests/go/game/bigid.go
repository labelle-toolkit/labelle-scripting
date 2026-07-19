// The 64-bit id pin: go has a REAL uint64, so a bit-63 id must survive
// create → set → query → render with no signed detour and no float hop
// anywhere (the wrapper's parseIDs is pure uint64 arithmetic).
package game

import (
	"fmt"
	"strconv"

	"labelle"
)

type BigID struct{ labelle.NoopScript }

func (BigID) Init() {
	e := labelle.CreateEntity()
	if e != 0x8000000000000001 {
		panic("expected the forced bit-63 id")
	}
	labelle.SetComponent(e, "Marker", `{"tag":42}`)

	ids, ok := labelle.Query(`["Marker"]`)
	if !ok || len(ids) != 1 || ids[0] != e {
		panic("query did not round-trip the bit-63 id")
	}

	// The id renders unsigned end to end (9223372036854775809, not a
	// negative int64 or a rounded float).
	labelle.SetComponent(e, "BigId",
		fmt.Sprintf(`{"idstr":"%s"}`, strconv.FormatUint(ids[0], 10)))
}
