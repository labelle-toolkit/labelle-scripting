// Package game is THE GAME'S scripts/ DIR: this repo ships a
// placeholder (empty Register); at `labelle generate` the assembler
// links the game's scripts/ over native-go/game/ (plugin.labelle's
// `.stage_subdir`), so the game's scripts/game.go — its Register entry
// point, the `.module_root` — stands exactly here, and every other
// scripts/*.go file rides along as the rest of the package.
package game

import "labelle"

// Register is the one convention entry point (the rust `register` /
// crystal `Game.register` twin): add every script the game runs.
// Registration order is hook order; Deinit runs reversed.
func Register(s *labelle.Scripts) {
	_ = s
}
