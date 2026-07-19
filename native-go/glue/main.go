// The c-archive main package: `go build -buildmode=c-archive ./glue`
// requires a main package, and this is all of it — the runtime ignores
// main() in archive mode. Its ONE job is wiring the game module's
// Register into the shipped glue (package labelle carries the registry,
// the dispatch loops and the labelle_go_* exports — see glue.go) from
// init(), which the c-archive's boot constructor runs before any
// exported entry can fire. The repo's test module recomposes the same
// shipped glue around its scenario package with a stub of exactly this
// shape (tests/go/main.go).
package main

import (
	"labelle"
	"labelle/game"
)

func init() { labelle.SetRegisterFn(game.Register) }

func main() {}
