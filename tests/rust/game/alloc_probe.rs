//! The steady-state allocation pin, crate-side (rust has no VM scratch —
//! `scripting.scratchGrowthCount()` is constitutionally 0 for this
//! backend, so the reuse discipline is proven where the buffers live):
//! a full per-tick boundary workload — query, get-into, mutate, set —
//! over 50 entities, buffers held in the script's fields. After a
//! warm-up the three capacities are recorded; 100 more ticks must not
//! move ANY of them (`Vec::clear` retains capacity; the wrappers grow
//! at most once — that's the whole idiom). The verdict lands as a
//! component the Zig side pins.

use super::util;
use crate::labelle::{self, EntityId, Script};

const ENTITIES: usize = 50;
const WARMUP: u32 = 10;
const MEASURED: u32 = 100;

#[derive(Default)]
pub struct AllocProbe {
    verdict: EntityId,
    ids: Vec<EntityId>,
    scratch: Vec<u8>,
    comp: Vec<u8>,
    ticks: u32,
    warm_caps: Option<(usize, usize, usize)>,
    grew: bool,
}

impl AllocProbe {
    fn caps(&self) -> (usize, usize, usize) {
        (
            self.ids.capacity(),
            self.scratch.capacity(),
            self.comp.capacity(),
        )
    }
}

impl Script for AllocProbe {
    fn init(&mut self) {
        self.verdict = labelle::create_entity();
        for _ in 0..ENTITIES {
            let id = labelle::create_entity();
            labelle::set_component(id, "Hot", r#"{"count":0}"#);
        }
        // The other half of the idiom: size the payload buffer ONCE at
        // init with sane headroom. Without it, capacity tracks required
        // EXACTLY and the payload gaining a digit ("count":9 → 10) would
        // read as growth — required-driven growth is big_query.rs's pin;
        // this script pins that a sized buffer never moves again.
        self.comp = Vec::with_capacity(64);
    }

    fn update(&mut self, _dt: f32) {
        self.ticks += 1;

        // The boundary workload, all through reused buffers.
        assert!(labelle::query_into(
            r#"["Hot"]"#,
            &mut self.ids,
            &mut self.scratch
        ));
        assert_eq!(self.ids.len(), ENTITIES);
        // Split the borrow: walk indices so `comp` stays usable.
        for i in 0..self.ids.len() {
            let id = self.ids[i];
            assert!(labelle::get_component_into(id, "Hot", &mut self.comp));
            let count = util::i64_field(&self.comp, "\"count\":").expect("count field");
            assert_eq!(count + 1, self.ticks as i64, "a tick was lost");
            labelle::set_component(id, "Hot", &format!("{{\"count\":{}}}", self.ticks));
        }

        if self.ticks == WARMUP {
            self.warm_caps = Some(self.caps());
        } else if let Some(warm) = self.warm_caps {
            if self.caps() != warm {
                self.grew = true;
            }
        }

        if self.ticks == WARMUP + MEASURED {
            labelle::set_component(
                self.verdict,
                "AllocProbe",
                &format!("{{\"settled\":{},\"ticks\":{}}}", !self.grew, self.ticks),
            );
        }
    }
}
