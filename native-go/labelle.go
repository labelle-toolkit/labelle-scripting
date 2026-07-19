// Package labelle is the Script Runtime Contract binding for game
// scripts written in Go (labelle-engine#746, native-compiled family —
// the third language on the rust/crystal skeleton).
//
// There is no bindings layer to generate: for native languages the
// contract header (labelle-engine/contract/labelle_script.h) IS the
// binding — the cgo preamble below mirrors it and the symbols resolve
// at link time against the host game binary that exports them (the
// labelle-engine#734 POC's finding #3, verbatim). The declared set is
// exactly the v1 core surface labelle-scripting binds today
// (src/contract.zig, SUPPORTED_CONTRACT_VERSION 1) plus the plugin's
// always-present bulk shims (batch.go).
//
// Strings are (pointer, length) pairs, NOT NUL-terminated — no
// C.CString, ever (it allocates AND appends a NUL the contract does
// not want). Structured payloads are UTF-8 JSON (encoding v1). Entity
// ids are uint64 end to end; 0 is the failure sentinel — no float ever
// touches an id in this package (a bit-63 id would round).
//
// # Allocation discipline (the RFC's Go idiom, rev 15)
//
// The cgo JSON boundary is the per-frame allocator, so the wrapper
// layer reuses grow-only scratch (`s = s[:0]` retains capacity) across
// contract calls instead of allocating per call. Two spellings:
//
//   - convenience wrappers (GetComponent, Query) fill PACKAGE-LEVEL
//     scratch — safe because the contract is main-thread-only — and
//     return a view VALID UNTIL THE NEXT CALL of the same wrapper;
//   - append-style wrappers (GetComponentInto, QueryInto) take and
//     return a caller-owned slice, reusing its capacity and growing at
//     most once per call via the contract's required-size convention —
//     a script that keeps its buffers in struct fields reaches steady
//     state after warm-up and never allocates again.
//
// # The signal / threading coexistence matrix (the #746 acceptance)
//
// Go is the one native language that brings its OWN RUNTIME as a guest
// — scheduler, GC and signal handlers ride into the game binary with
// the c-archive. The rules, each with its mechanism:
//
//   - RUNTIME BOOT: the archive initializes the Go runtime from a
//     global constructor at process start (buildmode=c-archive's
//     documented behavior) — before main(), before any labelle_go_*
//     entry. There is no boot leg to sequence (crystal's labelle_cr_boot
//     has no Go analog) and nothing to poison.
//   - THREADS: the runtime starts worker threads (sysmon, GC) at boot.
//     They never touch the contract — every contract call in this
//     package happens synchronously inside a labelle_go_* entry, which
//     the plugin Controller calls on the game's main thread, and a cgo
//     callback runs on the thread that called it. Goroutines are fine
//     for computation (channels, sync — the suite pins it), but MUST
//     NOT call the labelle API: the contract is main-thread-only. A
//     cheap guard enforces the detectable half — every wrapper panics
//     pointedly when called outside a hook dispatch (before setup,
//     after deinit, or from a goroutine running between frames); a
//     goroutine racing DURING a hook is beyond a flag's reach and is
//     documented UB, exactly like data races are.
//   - SIGNALS: the runtime installs handlers for synchronous signals
//     (SIGSEGV & co, SA_ONSTACK) at boot and FORWARDS signals raised in
//     non-Go code to whatever handler was installed before it (the
//     documented os/signal non-Go-program rule), so a host crash still
//     reaches the host's/OS's handling — with the caveat that the Go
//     handler runs first and prints its own report for truly fatal
//     faults. No labelle backend installs competing handlers (bdw-gc —
//     crystal's sharp edge — is not in a go game's binary), so there is
//     no ordering dance to perform; a game embedding OTHER
//     signal-installing runtimes must initialize them BEFORE process
//     start can't be ordered — see os/signal's cgo notes.
//   - GC: fully concurrent, runs on the runtime's own threads, moves
//     nothing across the FFI boundary mid-call (cgo pins pointer
//     arguments for the duration of each call — the cgo pointer-passing
//     rules; the host never retains a Go pointer past a call, which is
//     the contract's borrowed-pointer rule anyway). The suite forces
//     runtime.GC() every tick to pin exactly this coexistence.
//   - STACK SWITCH vs the host's Debug allocator: cgo runs the C call
//     (this package's contract calls) on a SWITCHED stack (the runtime's
//     asmcgocall system-stack transition). A host built in DEBUG whose
//     allocator captures a stack trace on every allocation (the engine's
//     default Debug allocator) walks the frame-pointer chain — and that
//     walk derails across the go cgo frame and SEGFAULTS the moment a
//     script makes its first host-ALLOCATING contract call (Subscribe,
//     which the host dupes the name for, is the usual first one). So a
//     go game must be built **ReleaseSafe+, not Debug** (ReleaseSafe
//     keeps safety + info logs while using a non-stack-capturing
//     allocator). rust/crystal call the host on the same stack and never
//     hit this. See src/go/vm.zig's "Build mode" section.
//
// # Scripts
//
// Game code lives in the game's scripts/ dir (package game, staged as
// the module's `labelle/game` package). Its game.go implements the one
// convention entry point:
//
//	func Register(s *labelle.Scripts) {
//	    s.Add("player", &Player{})
//	}
//
// and each script is a plain struct implementing [Script] (embed
// [NoopScript] to get empty defaults). The glue (glue.go, shipped
// beside this file) drives the interface from the plugin Controller's
// C entry points and recovers every panic at the FFI boundary — see
// its docs for the exact hook order and panic semantics.
package labelle

/*
#include <stddef.h>
#include <stdint.h>

extern uint32_t labelle_contract_version(void);

extern uint64_t labelle_entity_create(void);
extern void labelle_entity_destroy(uint64_t id);
extern uint64_t labelle_prefab_spawn(const char *name, size_t name_len,
                                     const char *params_json, size_t params_len);

extern int32_t labelle_component_set(uint64_t id, const char *name, size_t name_len,
                                     const char *json, size_t json_len);
extern size_t labelle_component_get(uint64_t id, const char *name, size_t name_len,
                                    char *out, size_t out_cap);
extern int32_t labelle_component_has(uint64_t id, const char *name, size_t name_len);
extern int32_t labelle_component_remove(uint64_t id, const char *name, size_t name_len);

extern size_t labelle_query(const char *names_json, size_t names_json_len,
                            char *out, size_t out_cap);

extern int32_t labelle_event_emit(const char *name, size_t name_len,
                                  const char *json, size_t json_len);
extern void labelle_event_subscribe(const char *name, size_t name_len);
extern size_t labelle_event_poll(char *out, size_t out_cap);

extern int32_t labelle_scene_change(const char *name, size_t name_len);
extern void labelle_log(const char *msg, size_t len);
extern float labelle_time_dt(void);
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// EntityID is an entity id exactly as the contract carries it. 0 is
// never a valid id and doubles as the failure sentinel.
type EntityID = uint64

// ── FFI plumbing ────────────────────────────────────────────────────────

// strPtr hands a Go string's bytes to C without copying. nil for the
// empty string — the contract's probe legs are specified as NULL/len-0.
func strPtr(s string) *C.char {
	if len(s) == 0 {
		return nil
	}
	return (*C.char)(unsafe.Pointer(unsafe.StringData(s)))
}

// outPtr hands a byte slice's storage to C as an out-buffer. nil when
// there is no capacity (probe leg) — never a dangling non-nil.
func outPtr(b []byte) *C.char {
	if cap(b) == 0 {
		return nil
	}
	return (*C.char)(unsafe.Pointer(unsafe.SliceData(b[:cap(b)])))
}

// growTo returns b cleared (capacity retained) with capacity >= n —
// the grow-at-most-once half of the reuse idiom.
func growTo(b []byte, n int) []byte {
	if cap(b) >= n {
		return b[:0]
	}
	return make([]byte, 0, n)
}

// ── The main-thread guard (the threading matrix's enforceable half) ─────

// hookDepth is nonzero while a labelle_go_* entry is dispatching on the
// game's main thread. Deliberately a plain int, not an atomic: the legal
// call pattern is single-threaded by contract, and the guard only needs
// to catch the DETECTABLE misuse (calls before setup / after deinit /
// from goroutines running between frames).
var hookDepth int

func enterHook() { hookDepth++ }
func leaveHook() { hookDepth-- }

func mustBeInHook() {
	if hookDepth == 0 {
		panic("labelle: contract call outside a script hook — the Script " +
			"Runtime Contract is main-thread-only; call the labelle API from " +
			"Register/Init/Update/OnEvent/Deinit, never from goroutines " +
			"(run computation on goroutines, join, then apply results in the hook)")
	}
}

// ── Core wrappers ───────────────────────────────────────────────────────

// CreateEntity creates an empty entity. Returns 0 when the host is not
// bound.
func CreateEntity() EntityID {
	mustBeInHook()
	return uint64(C.labelle_entity_create())
}

// DestroyEntity destroys an entity (children cascade). Unknown / dead
// ids are ignored.
func DestroyEntity(id EntityID) {
	mustBeInHook()
	C.labelle_entity_destroy(C.uint64_t(id))
}

// SpawnPrefab spawns a named prefab. paramsJSON is an optional
// `{"x":…,"y":…}` spawn position; "" spawns at the origin. ok=false =
// failure (unknown prefab, malformed params, not bound).
func SpawnPrefab(name, paramsJSON string) (id EntityID, ok bool) {
	mustBeInHook()
	got := uint64(C.labelle_prefab_spawn(strPtr(name), C.size_t(len(name)),
		strPtr(paramsJSON), C.size_t(len(paramsJSON))))
	return got, got != 0
}

// SetComponent sets component `name` on `id` from a whole-struct JSON
// object (REPLACE semantics; absent fields take declared defaults).
// false = unknown component / dead entity / parse error (entity
// untouched).
func SetComponent(id EntityID, name, json string) bool {
	mustBeInHook()
	return C.labelle_component_set(C.uint64_t(id), strPtr(name), C.size_t(len(name)),
		strPtr(json), C.size_t(len(json))) == 0
}

// GetComponentInto serializes component `name` of `id` into buf
// (cleared first — capacity is retained and reused; append-style: the
// returned slice replaces the caller's). Grows at most once via the
// contract's required-size return. ok=false = absent / unknown / dead.
func GetComponentInto(id EntityID, name string, buf []byte) (out []byte, ok bool) {
	mustBeInHook()
	buf = buf[:0]
	// First leg: whatever capacity the buffer already has. The write is
	// all-or-nothing, so a too-small capacity costs nothing.
	required := int(C.labelle_component_get(C.uint64_t(id), strPtr(name), C.size_t(len(name)),
		outPtr(buf), C.size_t(cap(buf))))
	if required == 0 {
		return buf, false
	}
	if required <= cap(buf) {
		return buf[:required], true
	}
	// Grow once, right-sized, and retry.
	buf = growTo(buf, required)
	got := int(C.labelle_component_get(C.uint64_t(id), strPtr(name), C.size_t(len(name)),
		outPtr(buf), C.size_t(cap(buf))))
	if got == 0 || got > cap(buf) {
		return buf, false // vanished or grew mid-frame; caller retries next tick
	}
	return buf[:got], true
}

// compScratch backs GetComponent — package-level, main-thread-only.
var compScratch []byte

// GetComponent is the convenience spelling of [GetComponentInto] over
// shared scratch. The returned slice is VALID UNTIL THE NEXT
// GetComponent CALL — copy (or use GetComponentInto with your own
// buffer) to hold two components at once.
func GetComponent(id EntityID, name string) (json []byte, ok bool) {
	compScratch, ok = GetComponentInto(id, name, compScratch)
	return compScratch, ok
}

// HasComponent reports whether the entity carries the component.
func HasComponent(id EntityID, name string) bool {
	mustBeInHook()
	return C.labelle_component_has(C.uint64_t(id), strPtr(name), C.size_t(len(name))) == 1
}

// RemoveComponent removes component `name` from `id`. Idempotent on the
// component. false = unknown component name / dead entity.
func RemoveComponent(id EntityID, name string) bool {
	mustBeInHook()
	return C.labelle_component_remove(C.uint64_t(id), strPtr(name), C.size_t(len(name))) == 0
}

// queryScratch carries the host's id JSON between Query's sizing legs.
var queryScratch []byte

// idsScratch backs Query — package-level, main-thread-only.
var idsScratch []EntityID

// QueryInto queries entity ids by component names. namesJSON is the
// contract's JSON array of component names (pass a literal —
// `["Marker"]` — for the zero-allocation path). Matching ids land in
// ids (append-style: cleared, capacity reused, grown at most once).
// ok=false = malformed input / not bound; unknown names yield an empty
// result (true, no ids).
func QueryInto(namesJSON string, ids []EntityID) (out []EntityID, ok bool) {
	mustBeInHook()
	ids = ids[:0]
	queryScratch = queryScratch[:0]
	required := int(C.labelle_query(strPtr(namesJSON), C.size_t(len(namesJSON)),
		outPtr(queryScratch), C.size_t(cap(queryScratch))))
	if required == 0 {
		return ids, false
	}
	if required > cap(queryScratch) {
		// The written prefix is valid JSON but truncated — grow once
		// right-sized and re-query for the full set.
		queryScratch = growTo(queryScratch, required)
		got := int(C.labelle_query(strPtr(namesJSON), C.size_t(len(namesJSON)),
			outPtr(queryScratch), C.size_t(cap(queryScratch))))
		if got == 0 {
			return ids, false
		}
		if got > cap(queryScratch) {
			got = cap(queryScratch)
		}
		queryScratch = queryScratch[:got]
	} else {
		queryScratch = queryScratch[:required]
	}
	return parseIDs(queryScratch, ids), true
}

// Query is the convenience spelling of [QueryInto] over shared scratch.
// The returned slice is VALID UNTIL THE NEXT Query CALL.
func Query(namesJSON string) (ids []EntityID, ok bool) {
	idsScratch, ok = QueryInto(namesJSON, idsScratch)
	return idsScratch, ok
}

// parseIDs parses a contract id-array (`[3,7,12]`) into ids (appending).
// Pure uint64 arithmetic — a bit-63 id survives exactly; no float, ever.
func parseIDs(json []byte, ids []EntityID) []EntityID {
	var cur uint64
	inNum := false
	for _, b := range json {
		if b >= '0' && b <= '9' {
			cur = cur*10 + uint64(b-'0')
			inNum = true
		} else if inNum {
			ids = append(ids, cur)
			cur = 0
			inNum = false
		}
	}
	if inNum {
		ids = append(ids, cur)
	}
	return ids
}

// Emit emits a game event by union-tag name. Empty json means `{}` (all
// defaults). false = unknown event name / parse failure / the game
// declares no events.
func Emit(name, json string) bool {
	mustBeInHook()
	return C.labelle_event_emit(strPtr(name), C.size_t(len(name)),
		strPtr(json), C.size_t(len(json))) == 0
}

// Subscribe declares interest in an event name (dedup'd host-side).
// Delivery starts with the next tick's events, through
// [Script.OnEvent] — the glue owns the drain loop.
func Subscribe(name string) {
	mustBeInHook()
	C.labelle_event_subscribe(strPtr(name), C.size_t(len(name)))
}

// pollInto drains one pending `"<name> <json>"` inbox entry into buf
// (cleared, capacity retained, grown at most once via the no-consume
// probe). ok=false = inbox empty. Glue-only: a script-side poll would
// STEAL entries from every other script's dispatch.
func pollInto(buf []byte) (out []byte, ok bool) {
	buf = buf[:0]
	// No-consume sizing probe (NULL/cap-0), then the real read.
	next := int(C.labelle_event_poll(nil, 0))
	if next == 0 {
		return buf, false
	}
	buf = growTo(buf, next)
	written := int(C.labelle_event_poll(outPtr(buf), C.size_t(cap(buf))))
	if written == 0 || written > cap(buf) {
		return buf, false
	}
	return buf[:written], true
}

// ChangeScene switches to a registered scene by name. false = unknown
// scene (the running scene is untouched) / not bound.
func ChangeScene(name string) bool {
	mustBeInHook()
	return C.labelle_scene_change(strPtr(name), C.size_t(len(name))) == 0
}

// Dt is the tick's gameplay delta-time in seconds — the same scaled dt
// Zig scripts received (0 while paused and before the first tick).
func Dt() float32 {
	mustBeInHook()
	return float32(C.labelle_time_dt())
}

// Log logs through the game's log sink at info level,
// "[script]"-prefixed. Deliberately guard-free: diagnostics must work
// everywhere (the glue's own panic reporting rides it).
func Log(msg string) {
	C.labelle_log(strPtr(msg), C.size_t(len(msg)))
}

// Logf is fmt.Sprintf into [Log]. It allocates — diagnostics, not a
// hot path.
func Logf(format string, args ...any) {
	Log(fmt.Sprintf(format, args...))
}
