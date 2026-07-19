//! Bulk-component-access scenarios (contract v1.3, labelle-scripting#44)
//! — the rust mirror of the ruby suite's "bulk v1.3" / "bulk stage 2"
//! coverage, driven by tests/rust_suite.zig against the mock world's
//! packed schema table (Stats / BatchPos / BatchVel; "Plain" plays the
//! non-packable component).
//!
//! Scripts assert their own invariants (a failed assert panics → the
//! glue contains it and the expected log token never lands); the Zig
//! side asserts the world (stored JSON key order proves which codec
//! path wrote — packed writes SCHEMA order, the JSON fallback sorts).

use crate::labelle::{self, BatchError, EntityId, Script};
use std::panic::{catch_unwind, AssertUnwindSafe};

labelle::packed_view! {
    Stats {
        power: f32 = 0.0,
        score: i64 = 0,
        alive: bool = false,
        seed: u64 = 0,
    }
}

labelle::packed_view! {
    Plain {
        a: f32 = 0.0,
    }
}

labelle::batch_view! {
    BatchPos {
        x: f32 = 0.0,
        y: f32 = 0.0,
    }
}

labelle::batch_view! {
    BatchVel {
        vx: f32 = 0.0,
        vy: f32 = 0.0,
    }
}

/// A second view over the SAME component name — the duplicate-name
/// refusal's test double (`batch2::<BatchPos, dup::BatchPos>`).
mod dup {
    use crate::labelle;
    labelle::batch_view! {
        BatchPos {
            x: f32 = 0.0,
            y: f32 = 0.0,
        }
    }
}

/// A batch view whose declared stride DISAGREES with the host stream:
/// "Plain" has no packed schema, so it contributes ZERO stream floats
/// (the mock's stand-in for a non-scalar component) while this view
/// declares one — the cross-check must refuse, never mis-map.
mod mismatched {
    use crate::labelle;
    labelle::batch_view! {
        Plain {
            a: f32 = 0.0,
        }
    }
}

fn set_json(id: EntityId, name: &str, json: &str) {
    assert!(
        labelle::set_component(id, name, json),
        "set {} failed",
        name
    );
}

// ── scenario "bulk_packed": the per-component packed codec ──────────────

#[derive(Default)]
pub struct PackedRt {
    scratch: Vec<u8>,
}

impl Script for PackedRt {
    fn init(&mut self) {
        // Entity 1: every packed scalar kind survives the binary
        // round-trip (f32 / i64 / bool / u64).
        let e1 = labelle::create_entity();
        let s = Stats {
            power: 1.5,
            score: -42,
            alive: true,
            seed: 123,
        };
        assert!(labelle::set_from(e1, &s), "packed set refused");
        let mut s2 = Stats::default();
        assert!(
            labelle::get_into(e1, &mut s2, &mut self.scratch),
            "packed get_into failed"
        );
        assert_eq!(s, s2, "packed round-trip drifted");
        labelle::log(&format!(
            "rust: packed:{}:{}:{}:{}",
            s2.power, s2.score, s2.alive, s2.seed
        ));

        // The schema-less component still round-trips — through JSON
        // (set_packed -1 / get_packed 0xFF), invisibly to the script.
        let p = Plain { a: 2.5 };
        assert!(labelle::set_from(e1, &p), "plain set refused");
        let mut p2 = Plain::default();
        assert!(
            labelle::get_into(e1, &mut p2, &mut self.scratch),
            "plain get_into failed"
        );
        labelle::log(&format!("rust: plain:{}", p2.a));

        // JSON-fallback coercion (round 1): a whole-number float is
        // spelled `2` in JSON — an int-class token — and must still
        // land in the f32 view field on the fallback path.
        assert!(labelle::set_component(e1, "Plain", "{\"a\":2}"));
        let mut p3 = Plain::default();
        assert!(
            labelle::get_into(e1, &mut p3, &mut self.scratch),
            "plain int get_into failed"
        );
        labelle::log(&format!("rust: plain int:{}", p3.a));

        // And our OWN JSON fallback spells whole floats the same way —
        // the set_from -> get_into round trip must survive it.
        let whole = Plain { a: 3.0 };
        assert!(labelle::set_from(e1, &whole), "whole set refused");
        let mut p4 = Plain::default();
        assert!(
            labelle::get_into(e1, &mut p4, &mut self.scratch),
            "whole get_into failed"
        );
        labelle::log(&format!("rust: plain whole:{}", p4.a));

        // Entity 2: rust has a REAL u64, so a bit-63 seed rides tag 3
        // bit-exact — no signed detour (the bitcast pair stays the
        // wire-level guarantee for signed-only bindings; here the value
        // is simply carried).
        let e2 = labelle::create_entity();
        let big = Stats {
            seed: 0x8000000000000001,
            ..Stats::default()
        };
        assert!(labelle::set_from(e2, &big), "u64 set refused");
        let mut b2 = Stats::default();
        assert!(
            labelle::get_into(e2, &mut b2, &mut self.scratch),
            "u64 get_into failed"
        );
        labelle::log(&format!("rust: u64rt:{}", b2.seed == 0x8000000000000001));

        // Entity 3: the non-finite policy — NaN refuses up front
        // (parity with this family's hand-written-JSON route, where
        // NaN has no spelling and the host would refuse the parse);
        // nothing is stored.
        let e3 = labelle::create_entity();
        let nan = Stats {
            power: f32::NAN,
            ..Stats::default()
        };
        labelle::log(&format!(
            "rust: nan_refused:{}",
            !labelle::set_from(e3, &nan)
        ));

        // An absent component answers false through BOTH routes.
        let mut absent = Stats::default();
        labelle::log(&format!(
            "rust: absent:{}",
            !labelle::get_into(e3, &mut absent, &mut self.scratch)
        ));
    }
}

// ── scenario "bulk_batch": the raw flat-loop tier + loud refusals ───────

#[derive(Default)]
pub struct BatchFlat {
    buf: Vec<f32>,
    scratch: Vec<u8>,
    tick: u32,
}

const NAMES: &str = r#"["BatchPos","BatchVel"]"#;

impl Script for BatchFlat {
    fn init(&mut self) {
        for i in 0..3 {
            let e = labelle::create_entity();
            set_json(e, "BatchPos", &format!("{{\"x\":{},\"y\":0}}", i + 1));
            set_json(e, "BatchVel", "{\"vx\":10,\"vy\":-10}");
        }
        let lone = labelle::create_entity();
        set_json(lone, "BatchPos", "{\"x\":7,\"y\":8}");

        // Int-carrying components refuse LOUDLY — never a silent
        // coercion through f32's 24-bit mantissa.
        let r = labelle::batch_get(r#"["BatchPos","Stats"]"#, &mut self.buf, &mut self.scratch);
        labelle::log(&format!(
            "rust: get int refused:{}",
            r == Err(BatchError::IntRefused)
        ));
        let r = labelle::batch_set(r#"["Stats"]"#, &[1.0, 2.0, 3.0, 4.0], &mut self.scratch);
        labelle::log(&format!(
            "rust: set int refused:{}",
            r == Err(BatchError::IntRefused)
        ));

        // Non-finite refusal at the BINDING (#45): a NaN/Inf stream
        // element refuses BEFORE any host write — the json-route
        // non-finite policy applied to the batch stream. (A finite
        // 1e100 into an f32 view field is BORN as inf and lands on the
        // same refusal, so the one check covers both smuggles.)
        let r = labelle::batch_set(NAMES, &[1.0, f32::NAN, 2.0, 3.0], &mut self.scratch);
        labelle::log(&format!(
            "rust: set nan refused:{}",
            r == Err(BatchError::NonFinite(1))
        ));
        // A finite-origin f32 overflow (f32::MAX doubled) is inf — the
        // "1e100 narrows to inf" smuggle, in an f32-native binding.
        let overflow = f32::MAX * 2.0;
        let r = labelle::batch_set(NAMES, &[1.0, 2.0, overflow, 3.0], &mut self.scratch);
        labelle::log(&format!(
            "rust: set overflow refused:{}",
            r == Err(BatchError::NonFinite(2))
        ));
    }

    fn update(&mut self, _dt: f32) {
        self.tick += 1;
        let count =
            labelle::batch_get(NAMES, &mut self.buf, &mut self.scratch).expect("batch_get refused");
        if self.tick == 1 {
            labelle::log(&format!(
                "rust: batch count:{} floats:{}",
                count,
                self.buf.len()
            ));
        }
        let mut i = 0usize;
        while i < count as usize {
            let b = i * 4;
            self.buf[b] += self.buf[b + 2]; // x += vx
            self.buf[b + 1] += self.buf[b + 3]; // y += vy
            i += 1;
        }
        labelle::batch_set(NAMES, &self.buf, &mut self.scratch).expect("batch_set refused");
    }
}

// ── scenario "bulk_stale": the positional-coupling guard ────────────────

#[derive(Default)]
pub struct BatchStale {
    es: Vec<EntityId>,
    buf: Vec<f32>,
    scratch: Vec<u8>,
}

impl Script for BatchStale {
    fn init(&mut self) {
        for i in 0..2 {
            let e = labelle::create_entity();
            set_json(e, "BatchPos", &format!("{{\"x\":{},\"y\":0}}", i));
            set_json(e, "BatchVel", "{\"vx\":1,\"vy\":1}");
            self.es.push(e);
        }
    }

    fn update(&mut self, _dt: f32) {
        let _count =
            labelle::batch_get(NAMES, &mut self.buf, &mut self.scratch).expect("batch_get refused");
        // Mutate everything so a wrongly-accepted write would be visible…
        for v in self.buf.iter_mut() {
            *v += 100.0;
        }
        // …then the forbidden move: destroy between the paired calls.
        labelle::destroy_entity(self.es[1]);
        let r = labelle::batch_set(NAMES, &self.buf, &mut self.scratch);
        labelle::log(&format!(
            "rust: stale refused:{}",
            r == Err(BatchError::EntitySetChanged)
        ));
    }
}

// ── scenario "bulk_iter": the typed closure tier (steady state) ─────────

#[derive(Default)]
pub struct BatchIter;

impl Script for BatchIter {
    fn init(&mut self) {
        for i in 0..3 {
            let e = labelle::create_entity();
            set_json(e, "BatchPos", &format!("{{\"x\":{},\"y\":0}}", i + 1));
            set_json(e, "BatchVel", "{\"vx\":10,\"vy\":-10}");
        }
    }

    fn update(&mut self, _dt: f32) {
        let n = labelle::batch2::<BatchPos, BatchVel>(|p, v| {
            p.x += v.vx;
            p.y += v.vy;
            if p.x > 12.0 {
                v.vx = -v.vx; // bounce entity 3 (x reaches 13)
            }
        })
        .expect("batch2 refused");
        labelle::log(&format!("rust: iter n:{}", n));
    }
}

// ── scenario "bulk_iter_edge": exit semantics + refusals ────────────────

#[derive(Default)]
pub struct BatchIterEdge;

impl Script for BatchIterEdge {
    fn init(&mut self) {
        // Empty query FIRST (no entities yet): Ok(0), closure untouched.
        let n = labelle::batch2::<BatchPos, BatchVel>(|_p, _v| {
            labelle::log("rust: empty ran");
        })
        .expect("empty batch refused");
        labelle::log(&format!("rust: empty n:{}", n));

        for i in 0..3 {
            let e = labelle::create_entity();
            set_json(e, "BatchPos", &format!("{{\"x\":{},\"y\":0}}", i + 1));
            set_json(e, "BatchVel", "{\"vx\":0,\"vy\":0}");
        }

        // EARLY EXIT COMMITS: stop after the first row — its write
        // (x += 10) flushes through the one batch_set; not-yet-visited
        // rows round-trip unchanged.
        let n = labelle::batch2_while::<BatchPos, BatchVel>(|p, _v| {
            p.x += 10.0;
            false
        })
        .expect("batch2_while refused");
        labelle::log(&format!("rust: while n:{}", n));

        // A PANICKING closure aborts the whole write: batch_set never
        // runs, the mutation before the panic is not applied
        // (all-or-nothing; contained here in-script, exactly as ruby's
        // suite rescues its raising block).
        let r = catch_unwind(AssertUnwindSafe(|| {
            let _ = labelle::batch2::<BatchPos, BatchVel>(|p, _v| {
                p.x = 999.0;
                panic!("boom");
            });
        }));
        labelle::log(&format!("rust: panic aborted:{}", r.is_err()));

        // DUPLICATE COMPONENT NAMES: two copies of the same fields per
        // row would let the unchanged copy overwrite the other's writes
        // — refused before any host call, nothing written.
        let r = labelle::batch2::<BatchPos, dup::BatchPos>(|p, _q| {
            p.x = 555.0;
        });
        labelle::log(&format!(
            "rust: dup refused:{}",
            r == Err(BatchError::DuplicateComponent)
        ));

        // LAYOUT MISMATCH: "Plain" contributes zero stream floats while
        // the typed view declares one — refused before any closure call.
        let e = labelle::create_entity();
        set_json(e, "BatchPos", "{\"x\":50,\"y\":0}");
        set_json(e, "Plain", "{\"a\":2.5}");
        let r = labelle::batch2::<BatchPos, mismatched::Plain>(|_p, _q| {
            labelle::log("rust: mismatch ran");
        });
        labelle::log(&format!(
            "rust: mismatch refused:{}",
            r == Err(BatchError::LayoutMismatch)
        ));
    }
}
