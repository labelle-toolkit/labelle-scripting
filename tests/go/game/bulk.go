// Bulk-component-access scenarios (contract v1.3, labelle-scripting#44)
// — the go mirror of the rust suite's raw-batch + typed-view coverage,
// driven by tests/go_suite.zig against the mock world's packed schema
// table (BatchPos / BatchVel; "Plain" plays the non-stream component).
//
// Scripts panic on a broken invariant (the glue contains it and the
// expected log token never lands); the Zig side asserts the world.
// Go has no macros, so the BatchView structs are written by hand — the
// mechanical Load/Store the rust batch_view! generates.
package game

import (
	"errors"

	"labelle"
)

// ── typed views (hand-written batch_view! twins) ────────────────────────

type BatchPos struct{ x, y float32 }

func (BatchPos) ComponentName() string { return "BatchPos" }
func (BatchPos) Stride() int           { return 2 }
func (p *BatchPos) Load(r []float32)   { p.x, p.y = r[0], r[1] }
func (p *BatchPos) Store(r []float32)  { r[0], r[1] = p.x, p.y }

type BatchVel struct{ vx, vy float32 }

func (BatchVel) ComponentName() string { return "BatchVel" }
func (BatchVel) Stride() int           { return 2 }
func (v *BatchVel) Load(r []float32)   { v.vx, v.vy = r[0], r[1] }
func (v *BatchVel) Store(r []float32)  { r[0], r[1] = v.vx, v.vy }

// dupPos is a second view over the SAME component name — the
// duplicate-name refusal's double.
type dupPos struct{ BatchPos }

// mismatchPlain declares one stream float, but "Plain" contributes zero
// (no packed schema — the mock's non-scalar stand-in): the stride
// cross-check must refuse, never mis-map.
type mismatchPlain struct{ a float32 }

func (mismatchPlain) ComponentName() string { return "Plain" }
func (mismatchPlain) Stride() int           { return 1 }
func (p *mismatchPlain) Load(r []float32)   { p.a = r[0] }
func (p *mismatchPlain) Store(r []float32)  { r[0] = p.a }

func setJSON(id labelle.EntityID, name, json string) {
	if !labelle.SetComponent(id, name, json) {
		panic("set " + name + " failed")
	}
}

const batchNames = `["BatchPos","BatchVel"]`

// ── scenario "bulk_batch": the raw flat-loop tier + loud refusals ───────

type BatchFlat struct {
	labelle.NoopScript
	buf  []float32
	tick int
}

func (b *BatchFlat) Init() {
	for i := 0; i < 3; i++ {
		e := labelle.CreateEntity()
		setJSON(e, "BatchPos", `{"x":`+itoa(i+1)+`,"y":0}`)
		setJSON(e, "BatchVel", `{"vx":10,"vy":-10}`)
	}
	lone := labelle.CreateEntity()
	setJSON(lone, "BatchPos", `{"x":7,"y":8}`)

	// Int-carrying components refuse LOUDLY — never a silent coercion
	// through f32's 24-bit mantissa.
	_, _, err := labelle.BatchGet(`["BatchPos","Stats"]`, b.buf)
	labelle.Logf("go: get int refused:%v", errors.Is(err, labelle.ErrBatchIntRefused))
	err = labelle.BatchSet(`["Stats"]`, []float32{1, 2, 3, 4})
	labelle.Logf("go: set int refused:%v", errors.Is(err, labelle.ErrBatchIntRefused))
}

func (b *BatchFlat) Update(dt float32) {
	b.tick++
	var count uint32
	var err error
	b.buf, count, err = labelle.BatchGet(batchNames, b.buf)
	if err != nil {
		panic("batch_get refused: " + err.Error())
	}
	if b.tick == 1 {
		labelle.Logf("go: batch count:%d floats:%d", count, len(b.buf))
	}
	for i := 0; i < int(count); i++ {
		o := i * 4
		b.buf[o] += b.buf[o+2]   // x += vx
		b.buf[o+1] += b.buf[o+3] // y += vy
	}
	if err := labelle.BatchSet(batchNames, b.buf); err != nil {
		panic("batch_set refused: " + err.Error())
	}
}

// ── scenario "bulk_stale": the positional-coupling guard ────────────────

type BatchStale struct {
	labelle.NoopScript
	es  []labelle.EntityID
	buf []float32
}

func (b *BatchStale) Init() {
	for i := 0; i < 2; i++ {
		e := labelle.CreateEntity()
		setJSON(e, "BatchPos", `{"x":`+itoa(i)+`,"y":0}`)
		setJSON(e, "BatchVel", `{"vx":1,"vy":1}`)
		b.es = append(b.es, e)
	}
}

func (b *BatchStale) Update(dt float32) {
	var err error
	b.buf, _, err = labelle.BatchGet(batchNames, b.buf)
	if err != nil {
		panic("batch_get refused")
	}
	// Mutate everything so a wrongly-accepted write would be visible…
	for i := range b.buf {
		b.buf[i] += 100
	}
	// …then the forbidden move: destroy between the paired calls.
	labelle.DestroyEntity(b.es[1])
	err = labelle.BatchSet(batchNames, b.buf)
	labelle.Logf("go: stale refused:%v", errors.Is(err, labelle.ErrBatchEntitySetChanged))
}

// ── scenario "bulk_iter": the typed view tier (steady state) ────────────

type BatchIter struct{ labelle.NoopScript }

func (BatchIter) Init() {
	for i := 0; i < 3; i++ {
		e := labelle.CreateEntity()
		setJSON(e, "BatchPos", `{"x":`+itoa(i+1)+`,"y":0}`)
		setJSON(e, "BatchVel", `{"vx":10,"vy":-10}`)
	}
}

func (BatchIter) Update(dt float32) {
	var p BatchPos
	var v BatchVel
	n, err := labelle.Batch2(&p, &v, func() bool {
		p.x += v.vx
		p.y += v.vy
		if p.x > 12 {
			v.vx = -v.vx // bounce entity 3 (x reaches 13)
		}
		return true
	})
	if err != nil {
		panic("batch2 refused: " + err.Error())
	}
	labelle.Logf("go: iter n:%d", n)
}

// ── scenario "bulk_iter_edge": exit semantics + refusals ────────────────

type BatchIterEdge struct{ labelle.NoopScript }

func (BatchIterEdge) Init() {
	// Empty query FIRST (no entities yet): 0, closure untouched.
	var p BatchPos
	var v BatchVel
	n, err := labelle.Batch2(&p, &v, func() bool {
		labelle.Log("go: empty ran")
		return true
	})
	if err != nil {
		panic("empty batch refused")
	}
	labelle.Logf("go: empty n:%d", n)

	for i := 0; i < 3; i++ {
		e := labelle.CreateEntity()
		setJSON(e, "BatchPos", `{"x":`+itoa(i+1)+`,"y":0}`)
		setJSON(e, "BatchVel", `{"vx":0,"vy":0}`)
	}

	// EARLY EXIT COMMITS: stop after the first row — its write (x += 10)
	// flushes through the one batch_set; not-yet-visited rows round-trip
	// unchanged.
	n, err = labelle.Batch2(&p, &v, func() bool {
		p.x += 10
		return false
	})
	if err != nil {
		panic("batch2 early-exit refused")
	}
	labelle.Logf("go: while n:%d", n)

	// A PANICKING closure aborts the whole write: batch_set never runs,
	// the mutation before the panic is not applied (all-or-nothing).
	// Contained here in-script (the go recover() spelling of rust's
	// catch_unwind double).
	func() {
		defer func() {
			labelle.Logf("go: panic aborted:%v", recover() != nil)
		}()
		var pp BatchPos
		var vv BatchVel
		_, _ = labelle.Batch2(&pp, &vv, func() bool {
			pp.x = 999
			panic("boom")
		})
	}()

	// DUPLICATE COMPONENT NAMES: two copies of the same fields per row
	// would let the unchanged copy overwrite the other's writes —
	// refused before any host call, nothing written.
	var a BatchPos
	var d dupPos
	_, err = labelle.Batch2(&a, &d, func() bool {
		a.x = 555
		return true
	})
	labelle.Logf("go: dup refused:%v", errors.Is(err, labelle.ErrBatchDuplicateComponent))

	// LAYOUT MISMATCH: "Plain" contributes zero stream floats while the
	// typed view declares one — refused before any closure call.
	e := labelle.CreateEntity()
	setJSON(e, "BatchPos", `{"x":50,"y":0}`)
	setJSON(e, "Plain", `{"a":2.5}`)
	var bp BatchPos
	var mp mismatchPlain
	_, err = labelle.Batch2(&bp, &mp, func() bool {
		labelle.Log("go: mismatch ran")
		return true
	})
	labelle.Logf("go: mismatch refused:%v", errors.Is(err, labelle.ErrBatchLayoutMismatch))
}
