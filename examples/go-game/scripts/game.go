// scripts/game.go — the game's go package root (labelle-engine#746,
// native-compiled family; `scripts/` is the shared convention dir every
// script language uses since labelle-engine#237): at `labelle generate`
// the assembler LINKS this whole `scripts/` dir over the scripting
// plugin's staged `native-go/game/`, `go build -buildmode=c-archive`
// compiles it into `liblabelle_go_scripts.a`, and the game binary links
// it — the `labelle_*` contract symbols resolve against the host's
// exports in the same binary. No VM, nothing embeds; `Register` below
// is the one convention entry point (`scripts/game.go` IS the module
// root — go's fixed `.module_root`, where rust uses `mod.rs`).
//
// The game mirrors examples/rust-game's hunger sawtooth (trimmed of the
// batch swarm — go's example is the demand-driven WIRING proof, not
// exhaustive parity) so the cross-language story is visible
// token-for-token: same Hunger/Worker component shapes, same
// command-event (hunger__feed), same native Zig hook (feed_watcher.zig)
// — only the script layer swaps rust for go.
//
// Registration order stands in for two tiers: the spawner registers
// FIRST (its Init seeds the world before the system's, its Update runs
// before the system's each tick) and Deinit runs in REVERSE
// registration order, so the system tears down first.
//
// Tokens carry BEHAVIOR: every tick logs the freshly written level, so
// the pinned sequence encodes the whole decay-feed-decay sawtooth
// through the real ECS. All values are exact in binary floating point
// (0.875 start, 0.25 steps, 0.5 feed), so the logged decimals are
// deterministic. Decay is 0.25 PER TICK (not DECAY*dt — the null
// backend's fixed dt is f32(1.0/60.0), which no decimal-exact multiple
// survives, and exact tokens are the point).
//
// Frame-by-frame (LABELLE_NULL_FRAMES=5; per frame the plugin
// Controller runs: inbox dispatch (OnEvents) → Updates, both in
// registration order):
//
//	setup   GO_INIT            (spawner init: worker seeded at 0.875)
//	        GO_CTRL_READY      hunger system init (after the spawner's)
//	tick 1  GO_LEVEL_0.625     0.875 - 0.25 decay, written back
//	tick 2  GO_FEED_SENT       (spawner update: emits hunger__feed)
//	        GO_LEVEL_0.375     0.625 - 0.25 — tick 1's write PERSISTED
//	        ZIG_FEED_SEEN_0.5  (hooks/feed_watcher.zig — the native
//	                            subscriber, at THIS frame's
//	                            dispatchEvents, one tick BEFORE the go
//	                            handler's inbox)
//	tick 3  GO_ENGINE_TICK_SEEN (spawner's builtin sub, same inbox)
//	        GO_FED_LEVEL_0.875 inbox: feed handler ran — id + exact f32
//	                            0.5 amount round-tripped the bus; 0.375 +
//	                            0.5 re-read AFTER the write
//	        GO_LEVEL_0.625     0.875 - 0.25 — decay resumes on the fed
//	tick 4  GO_LEVEL_0.375
//	tick 5  GO_LEVEL_0.125
//	        GO_STARVING        0.125 <= 0.25 crossed the threshold
//	        GO_BUFFERS_OK      warmed reused slices never grew — go's
//	                            `s = s[:0]` retains capacity
//	deinit  GO_CTRL_DONE       hunger system (reverse registration)
//	        GO_DEINIT          spawner
package game

import (
	"strconv"

	"labelle"
)

// Register is the game registration entry point (staged as
// native-go/game/game.go — the module_root the plugin.labelle `.languages`
// go row names). Registration order is hook order; Deinit runs reversed.
func Register(s *labelle.Scripts) {
	s.Add("spawner", &Spawner{})
	s.Add("hunger", &HungerSystem{})
}

// ── Shared payload parsing ──────────────────────────────────────────────
//
// Scripts own their payload parsing (contract payloads are small, flat
// JSON; a structured story is future work). Pure slice walks — no float
// ever touches an entity id (uint64 end to end; a bit-63 id survives
// exactly).

// u64Field returns the unsigned integer after needle (e.g. `"entity":`),
// tolerating a string-encoded id (`"entity":"123"`).
func u64Field(json []byte, needle string) (uint64, bool) {
	i, ok := skipToValue(json, needle)
	if !ok {
		return 0, false
	}
	if i < len(json) && json[i] == '"' {
		i++
	}
	var v uint64
	any := false
	for i < len(json) && json[i] >= '0' && json[i] <= '9' {
		v = v*10 + uint64(json[i]-'0')
		any = true
		i++
	}
	return v, any
}

// f32Field returns the float after needle (e.g. `"level":`), or 0/false.
func f32Field(json []byte, needle string) (float32, bool) {
	start, ok := skipToValue(json, needle)
	if !ok {
		return 0, false
	}
	end := start
	for end < len(json) {
		c := json[end]
		if (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {
			end++
			continue
		}
		break
	}
	if end == start {
		return 0, false
	}
	v, err := strconv.ParseFloat(string(json[start:end]), 32)
	if err != nil {
		return 0, false
	}
	return float32(v), true
}

func skipToValue(json []byte, needle string) (int, bool) {
	if len(needle) == 0 || len(json) < len(needle) {
		return 0, false
	}
	at := -1
	for i := 0; i+len(needle) <= len(json); i++ {
		if string(json[i:i+len(needle)]) == needle {
			at = i
			break
		}
	}
	if at < 0 {
		return 0, false
	}
	i := at + len(needle)
	for i < len(json) && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') {
		i++
	}
	return i, true
}

// fmtF32 is the go spelling of the tokens' exact-decimal render: the
// shortest round-tripping decimal for a float32 (all this game's values
// are exact in binary fp, so this is deterministic).
func fmtF32(v float32) string {
	return strconv.FormatFloat(float64(v), 'g', -1, 32)
}
