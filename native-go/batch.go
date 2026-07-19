// Bulk component access (contract v1.3, labelle-scripting#41/#44): the
// batched whole-query f32 stream — the raw tier plus the typed
// view/iterator tier — ported from the rust reference (native/src/
// labelle.rs; the ruby prelude is the family's original).
//
// CAPABILITY GATING — why these bind `labelle_scripting_bulk_*`, not
// the contract's own `labelle_component_batch_*`: those symbols exist
// only on engine hosts >= 2.6.0, and this module links against
// whatever host the game was built with — a direct extern would make
// every go game UNLINKABLE against an older engine. The scripting
// plugin's Zig side therefore exports ALWAYS-PRESENT shims
// (labelle-scripting src/bulk_shims.zig), comptime-gated on the engine
// module: on a v1.3+ host they forward 1:1; on an older host
// `labelle_scripting_bulk_capability` answers 0 — which the batch
// wrappers check FIRST and surface as the loud [ErrBatchUnsupported]
// ("needs labelle-engine >= 2.6.0"; there is no batch fallback —
// silently degrading a whole-query read would be data loss).
//
// The per-component PACKED codec (get_packed/set_packed) is
// deliberately NOT wrapped in v1 — go's typed access story starts with
// the batch tier the RFC headlines (this file); the packed
// per-component fast path is the documented follow-up, and the Zig-side
// shims already export it for the day it lands.
package labelle

/*
#include <stddef.h>
#include <stdint.h>

extern uint32_t labelle_scripting_bulk_capability(void);
extern size_t labelle_scripting_bulk_batch_get(const char *names_json, size_t names_json_len,
                                               char *out, size_t out_cap);
extern int32_t labelle_scripting_bulk_batch_set(const char *names_json, size_t names_json_len,
                                                const char *buf, size_t buf_len);
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"math"
	"unsafe"
)

// batchIntRefused is labelle_component_batch_get's int-field refusal
// sentinel — the header's LABELLE_BATCH_INT_REFUSED, C's (size_t)-2.
// Checked BEFORE treating the return as a required size.
const batchIntRefused = ^uintptr(0) - 1

// The batch refusals. Every one is LOUD on purpose — there is no batch
// fallback (see the package doc above).
var (
	// ErrBatchUnsupported: the host engine lacks batch support (script
	// contract v1.3 needs labelle-engine >= 2.6.0) — use per-entity
	// get/set on this engine.
	ErrBatchUnsupported = errors.New(
		"labelle: batch — the host engine lacks batch support (script contract " +
			"v1.3 needs labelle-engine >= 2.6.0); use per-entity get/set on this engine")
	// ErrBatchIntRefused: a named component has an int-typed field
	// (i64/u64 cannot ride the f32 batch stream) — keep that component
	// on per-entity get/set.
	ErrBatchIntRefused = errors.New(
		"labelle: batch refused: a named component has an int-typed field (i64/u64 " +
			"cannot ride the f32 batch stream) — keep that component on per-entity get/set")
	// ErrBatchEntitySetChanged: batch_set's exact-size positional-
	// coupling guard fired — the entity set changed between the paired
	// calls (spawn/destroy is forbidden between them), or the names
	// were malformed / the host not bound. NOTHING was applied —
	// re-run BatchGet and recompute.
	ErrBatchEntitySetChanged = errors.New(
		"labelle: batch_set refused: the entity set changed between batch_get and " +
			"batch_set (spawn/destroy between the paired calls — the buffer was computed " +
			"against a stale set; re-run batch_get and recompute), or the names were " +
			"malformed / the host not bound")
	// ErrBatchLayoutMismatch (view tier only): the typed views'
	// declared stride does not match the host stream — a field the
	// stream skips (non-scalar) disagrees with the view layout. Use the
	// raw BatchGet/BatchSet flat loop for these components.
	ErrBatchLayoutMismatch = errors.New(
		"labelle: batch: the typed views' stride does not match the host stream (a " +
			"non-scalar field the stream skips confused the layout) — use the raw " +
			"BatchGet/BatchSet flat loop for these components")
	// ErrBatchDuplicateComponent (view tier only): the same component
	// named more than once — the stream would carry two copies of its
	// fields per entity and the positional write-back would let the
	// unchanged copy overwrite the other's writes; batch each
	// component once.
	ErrBatchDuplicateComponent = errors.New(
		"labelle: batch: the same component is named more than once — the stream " +
			"would carry two copies per entity and the positional write-back would let " +
			"the unchanged copy overwrite the other's writes; batch each component once")
)

// batchScratch carries the raw byte stream between the sizing legs and
// the write-back encode — package-level, main-thread-only, grow-only.
var batchScratch []byte

// BatchGet: ONE contract crossing fills the returned slice with every
// matching entity's scalar component data as a flat f32 stream
// ([c0_f0, c0_f1, …] per entity, components in namesJSON order, fields
// in declaration order) and returns the entity COUNT; the result is
// trimmed to exactly count×stride (a shrinking set never leaves stale
// trailing floats for BatchSet's exact-size guard to trip on). Append-
// style over the caller's buffer (capacity reused, grown at most
// once). count==0 with nil error = empty query (also malformed names /
// not bound — the family convention). The raw tier: the script owns
// the positional layout.
func BatchGet(namesJSON string, buf []float32) (out []float32, count uint32, err error) {
	mustBeInHook()
	buf = buf[:0]
	if uint32(C.labelle_scripting_bulk_capability()) == 0 {
		return buf, 0, ErrBatchUnsupported
	}
	batchScratch = batchScratch[:0]
	n := uintptr(C.labelle_scripting_bulk_batch_get(strPtr(namesJSON), C.size_t(len(namesJSON)),
		outPtr(batchScratch), C.size_t(cap(batchScratch))))
	// The refusal sentinel is (size_t)-2 — check BEFORE reading the
	// return as a required size.
	if n == batchIntRefused {
		return buf, 0, ErrBatchIntRefused
	}
	if n == 0 {
		return buf, 0, nil
	}
	if int(n) > cap(batchScratch) {
		batchScratch = growTo(batchScratch, int(n))
		n = uintptr(C.labelle_scripting_bulk_batch_get(strPtr(namesJSON), C.size_t(len(namesJSON)),
			outPtr(batchScratch), C.size_t(cap(batchScratch))))
		if n == 0 || int(n) > cap(batchScratch) {
			return buf, 0, nil // belt — mirrors the rust binding
		}
	}
	if n < 4 {
		return buf, 0, nil
	}
	batchScratch = batchScratch[:n]
	count = binary.LittleEndian.Uint32(batchScratch[0:4])
	nfloats := (len(batchScratch) - 4) / 4
	if cap(buf) < nfloats {
		buf = make([]float32, 0, nfloats)
	}
	for i := 0; i < nfloats; i++ {
		bits := binary.LittleEndian.Uint32(batchScratch[4+i*4:])
		buf = append(buf, math.Float32frombits(bits))
	}
	return buf, count, nil
}

// BatchSet: ONE contract crossing writes the whole stream back — the
// host re-queries the same entities in the same order and applies buf
// positionally, read-modify-write per component (only stream-carried
// scalar fields move). buf is exactly what BatchGet filled and
// trimmed, mutated in place. Refusals are errors — both mean the write
// would corrupt data and both are loud.
func BatchSet(namesJSON string, buf []float32) error {
	mustBeInHook()
	if uint32(C.labelle_scripting_bulk_capability()) == 0 {
		return ErrBatchUnsupported
	}
	batchScratch = growTo(batchScratch, len(buf)*4)
	for _, v := range buf {
		batchScratch = binary.LittleEndian.AppendUint32(batchScratch, math.Float32bits(v))
	}
	rc := int32(C.labelle_scripting_bulk_batch_set(strPtr(namesJSON), C.size_t(len(namesJSON)),
		outPtr(batchScratch), C.size_t(len(batchScratch))))
	switch rc {
	case 0:
		return nil
	case -2:
		return ErrBatchIntRefused
	default:
		return ErrBatchEntitySetChanged
	}
}

// BatchView is a typed per-entity view over the batch stream — the go
// spelling of rust's batch_view! structs, written by hand (go has no
// macros; the four methods are mechanical). The view's declared fields
// ARE the layout authority (declaration order, one stream float each),
// cross-checked against the host stream's real stride before the first
// callback — a mismatch is [ErrBatchLayoutMismatch], never a mis-map.
// f32 fields ride raw; bool fields ride 0/1 (the two the host stream
// carries — int fields are refused host-side).
type BatchView interface {
	// ComponentName is the component this view maps.
	ComponentName() string
	// Stride is the number of stream floats per entity (= declared
	// scalar field count).
	Stride() int
	// Load fills the view's fields from one entity's row
	// (len == Stride()).
	Load(row []float32)
	// Store writes the view's fields back into the row.
	Store(row []float32)
}

// The reused iterator-tier buffers, shared by every Batch/Batch2 call
// (grow once, steady state allocates nothing). Main-thread-only like
// everything here. batchActive turns a NESTED batch call — which would
// alias the shared stream mid-iteration — into a pointed panic instead
// of silent corruption (the family's "no nested batch" rule, enforced).
var (
	batchFloats []float32
	batchNames  []byte
	batchActive bool
)

// Batch is the iterator tier over one component: ONE BatchGet, then f
// runs once per matching entity against the view loaded from the
// stream (writes stored back after each call), then ONE BatchSet
// commits everything. Returns the entity count; an empty query returns
// (0, nil) without calling f.
//
// EXIT SEMANTICS (the family contract, go spelling):
//   - returning true from every call COMMITS via the one BatchSet;
//   - EARLY EXIT (return false) stops iterating and STILL COMMITS the
//     writes made so far — the current row's included — while
//     not-yet-visited rows round-trip unchanged;
//   - a PANIC in f aborts the whole write: it unwinds out of this call
//     before BatchSet ever runs (all-or-nothing; the glue contains it
//     at the hook boundary like any script panic).
func Batch(view BatchView, f func() bool) (uint32, error) {
	return batchCore([]BatchView{view}, f)
}

// Batch2 is the iterator tier over two components (the RFC's headline
// shape): both views load from each row before f, both store back
// after. Semantics of [Batch].
func Batch2(a, b BatchView, f func() bool) (uint32, error) {
	return batchCore([]BatchView{a, b}, f)
}

func batchCore(views []BatchView, f func() bool) (uint32, error) {
	// Duplicate component names would put two copies of the same fields
	// in every row — refuse before any host call.
	for i := range views {
		for j := i + 1; j < len(views); j++ {
			if views[i].ComponentName() == views[j].ComponentName() {
				return 0, ErrBatchDuplicateComponent
			}
		}
	}
	if batchActive {
		panic("labelle: nested Batch calls are not supported (the shared stream " +
			"buffer would alias mid-iteration) — restructure into sequential batches")
	}
	batchActive = true
	defer func() { batchActive = false }()

	batchNames = batchNames[:0]
	batchNames = append(batchNames, '[')
	stride := 0
	for i, v := range views {
		if i > 0 {
			batchNames = append(batchNames, ',')
		}
		batchNames = append(batchNames, '"')
		batchNames = append(batchNames, v.ComponentName()...)
		batchNames = append(batchNames, '"')
		stride += v.Stride()
	}
	batchNames = append(batchNames, ']')
	// A zero-copy string view over the reused names buffer — valid for
	// the two contract calls below, which never touch batchNames (the
	// steady state allocates nothing, matching the rust tier's reused
	// String).
	names := unsafe.String(unsafe.SliceData(batchNames), len(batchNames))

	var count uint32
	var err error
	batchFloats, count, err = BatchGet(names, batchFloats)
	if err != nil {
		return 0, err
	}
	if count == 0 {
		return 0, nil
	}
	if len(batchFloats) != int(count)*stride {
		return 0, ErrBatchLayoutMismatch
	}
	for row := 0; row < len(batchFloats); row += stride {
		at := row
		for _, v := range views {
			v.Load(batchFloats[at : at+v.Stride()])
			at += v.Stride()
		}
		keepGoing := f()
		at = row
		for _, v := range views {
			v.Store(batchFloats[at : at+v.Stride()])
			at += v.Stride()
		}
		if !keepGoing {
			break // early exit COMMITS — fall through to BatchSet
		}
	}
	if err := BatchSet(names, batchFloats); err != nil {
		return 0, err
	}
	return count, nil
}
