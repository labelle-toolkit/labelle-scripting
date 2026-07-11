//! The plugin glue: the C entry points labelle-scripting's `rust` arm
//! (src/rust/vm.zig) drives, and the script registry + dispatch loops
//! behind them. Games never touch this file — their surface is
//! [`crate::labelle`] (`Script`, `Scripts`, the wrappers) plus the one
//! `register` convention in their `rust/mod.rs`.
//!
//! ## The labelle_rs_* entry convention (rust glue ABI v1)
//!
//! The Zig arm calls, in Controller order:
//!
//! | entry                        | when                                    |
//! |------------------------------|-----------------------------------------|
//! | `labelle_rs_abi_version`     | `Vm.init` — handshake, must return 1     |
//! | `labelle_rs_setup`           | end of `Controller.setup` — runs the     |
//! |                              | game's `register`, then every script's   |
//! |                              | `init` (panicking inits are EVICTED)     |
//! | `labelle_rs_dispatch_inbox`  | top of `Controller.tick` — drains the    |
//! |                              | event inbox, fans out to `on_event`      |
//! | `labelle_rs_tick`            | `Controller.tick` — every `update(dt)`   |
//! | `labelle_rs_deinit`          | `Controller.deinit` — every `deinit`     |
//! |                              | (reverse registration order), registry   |
//! |                              | dropped                                  |
//!
//! Bump [`RS_ABI_VERSION`] on any change to this table's names or
//! signatures — the Zig arm refuses a mismatched glue at boot (the
//! stale-staticlib case: a plugin upgrade with a stale `{cache}`
//! artifact must fail the handshake, not corrupt a tick).
//!
//! ## Panics MUST NOT unwind across the FFI boundary
//!
//! Every entry point wraps its whole body in `catch_unwind`, and every
//! script hook call is ADDITIONALLY caught one script at a time, so one
//! panicking script cannot starve its siblings. Rust aborts the process
//! when a panic unwinds out of an `extern "C"` fn — the double catch is
//! the difference between "one script logged an error" and "the game
//! died". Semantics mirror the embedded-VM family (the lua suite's
//! pins): init panic → logged + evicted; update/on_event panic → logged
//! every time, script stays; deinit panic → logged, teardown continues;
//! `register` panic → logged, ALL registrations dropped (all-or-nothing
//! — a half-registered set would run hooks the author never ordered).
//!
//! The registry is a `thread_local` (the contract is main-thread-only;
//! every entry point runs on the game's main thread), so no `Send`
//! bound leaks into the [`Script`] trait.

use std::cell::RefCell;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::game;
use crate::labelle::{self, Script, Scripts};

/// The glue ABI revision `labelle_rs_abi_version` reports and the Zig
/// arm's `SUPPORTED_RS_ABI_VERSION` must equal.
pub const RS_ABI_VERSION: u32 = 1;

struct Entry {
    name: String,
    script: Box<dyn Script>,
    /// Cleared when `init` panics: an evicted script never receives
    /// `on_event`/`update`/`deinit` (half-initialized state must not run).
    alive: bool,
}

struct Registry {
    entries: Vec<Entry>,
    /// Reused drain buffer for `labelle_event_poll` — grow-only, so the
    /// steady state polls with zero allocation.
    inbox_buf: Vec<u8>,
}

thread_local! {
    static REGISTRY: RefCell<Option<Registry>> = const { RefCell::new(None) };
}

/// Route script panics through the game's log sink INSTEAD of stderr —
/// installed once per process by `labelle_rs_setup`.
///
/// Family parity first: in every embedded-VM backend a script error
/// travels through `labelle_log` (the game's sink) and NOWHERE else;
/// Rust's default panic hook would additionally splat
/// "thread panicked at …" onto raw stderr. And that stderr is not just
/// noise: zig's build runner relays a test/run child's RESIDUAL STDERR
/// through its failure printer EVEN WHEN THE STEP SUCCEEDS
/// (build_runner.zig `printErrorMessages` — "No matter the result…" —
/// appends the step's `failed command:` line), so a PASSING binary
/// whose expected-panic tests write stderr produces a phantom
/// `failed command:` in every green `zig build test`. CI pins this
/// stays fixed (the no-"failed command:"-on-success grep).
///
/// Division of labor: this hook logs the panic LOCATION (only the hook
/// can see it); the catch site (`log_panic`) logs the MESSAGE with
/// script attribution. One panic = two sink lines, no duplicated
/// message (log-count pins stay exact). Backtraces are dropped —
/// scripts are small; location + message is the story. A game that
/// embeds OTHER rust code and wants its own hook can set one after
/// plugin setup; the glue installs only once.
fn install_panic_hook() {
    static HOOK: std::sync::Once = std::sync::Once::new();
    HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let mut line = String::from("rust: script panic");
            if let Some(loc) = info.location() {
                use std::fmt::Write as _;
                let _ = write!(line, " at {}:{}:{}", loc.file(), loc.line(), loc.column());
            }
            labelle::log(&line);
        }));
    });
}

/// Render a panic payload for the log: `panic!("…")` and
/// `panic!(String)` payloads pass through, anything else gets a marker.
fn panic_text(payload: &(dyn std::any::Any + Send)) -> &str {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s
    } else {
        "<non-string panic payload>"
    }
}

fn log_panic(context: &str, payload: &(dyn std::any::Any + Send)) {
    // One format!-allocation per PANIC (not per frame) — diagnostics,
    // not a hot path.
    labelle::log(&format!(
        "rust: {} panicked: {}",
        context,
        panic_text(payload)
    ));
}

/// Call one script hook with per-script containment. Returns false when
/// the hook panicked. `context` is only rendered ON panic — the happy
/// path allocates nothing.
fn guarded<F, C>(entry: &mut Entry, context: C, f: F) -> bool
where
    F: FnOnce(&mut dyn Script),
    C: FnOnce() -> String,
{
    let script = entry.script.as_mut();
    match catch_unwind(AssertUnwindSafe(|| f(script))) {
        Ok(()) => true,
        Err(payload) => {
            log_panic(
                &format!("script '{}' {}", entry.name, context()),
                payload.as_ref(),
            );
            false
        }
    }
}

// ── Entry points (the Zig arm's externs) ─────────────────────────────────

/// Handshake: the glue ABI revision this crate was built against.
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_abi_version() -> u32 {
    RS_ABI_VERSION
}

/// Build the registry (the game's `register`), then run every script's
/// `init` — a panicking `init` logs and EVICTS that script; the rest
/// keep going. Idempotent-by-rebuild: a re-setup drops the old registry
/// and registers from scratch (the Controller's re-setup = clean
/// restart contract). Returns 0, or -1 when `register` itself panicked
/// (no scripts registered).
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_setup() -> i32 {
    // Before ANY script code can panic (register() included): script
    // panics must reach the game's log sink, never raw stderr.
    install_panic_hook();
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let mut scripts = Scripts::new();
        if let Err(payload) = catch_unwind(AssertUnwindSafe(|| game::register(&mut scripts))) {
            // All-or-nothing registration: drop whatever registered
            // before the panic — a partial set would run hooks the
            // author never finished ordering.
            drop(scripts);
            log_panic("register()", payload.as_ref());
            labelle::log("rust: no scripts registered");
            return -1;
        }

        let mut reg = Registry {
            entries: scripts
                .entries
                .into_iter()
                .map(|(name, script)| Entry {
                    name,
                    script,
                    alive: true,
                })
                .collect(),
            inbox_buf: Vec::new(),
        };

        for entry in reg.entries.iter_mut() {
            if !guarded(entry, || "in init".to_owned(), |s| s.init()) {
                entry.alive = false;
                labelle::log(&format!("rust: script evicted: '{}'", entry.name));
            }
        }

        REGISTRY.with(|r| *r.borrow_mut() = Some(reg));
        0
    }));
    outcome.unwrap_or_else(|payload| {
        log_panic("labelle_rs_setup", payload.as_ref());
        -1
    })
}

/// Drain the event inbox (FIFO, one poll loop — the RFC's model) and
/// fan each entry out to every live script's `on_event`. Handler panics
/// are contained per script per event; the drain always completes.
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_dispatch_inbox() {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        REGISTRY.with(|r| {
            let mut slot = r.borrow_mut();
            let Some(reg) = slot.as_mut() else { return };
            // Take the buffer out of the registry so the fan-out can
            // borrow entries while the event text stays alive.
            let mut buf = std::mem::take(&mut reg.inbox_buf);
            while labelle::poll_into(&mut buf) {
                // Entries are "<name> <json>"; an entry is never empty.
                let text = match std::str::from_utf8(&buf) {
                    Ok(t) => t,
                    Err(_) => {
                        // Never drop silently: name the problem, skip the
                        // entry, keep draining.
                        labelle::log("rust: non-UTF8 event entry skipped");
                        continue;
                    }
                };
                let (name, payload) = match text.split_once(' ') {
                    Some(pair) => pair,
                    None => (text, ""),
                };
                for entry in reg.entries.iter_mut() {
                    if !entry.alive {
                        continue;
                    }
                    guarded(
                        entry,
                        || format!("in on_event('{}')", name),
                        |s| s.on_event(name, payload),
                    );
                }
            }
            reg.inbox_buf = buf; // capacity kept for the next tick
        });
    }));
    if let Err(payload) = outcome {
        log_panic("labelle_rs_dispatch_inbox", payload.as_ref());
    }
}

/// Every live script's `update(dt)`, registration order. A panicking
/// update is logged EVERY tick and the script stays registered (its
/// state is intact; the author gets the report until it's fixed) —
/// siblings always run.
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_tick(dt: f32) {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        REGISTRY.with(|r| {
            let mut slot = r.borrow_mut();
            let Some(reg) = slot.as_mut() else { return };
            for entry in reg.entries.iter_mut() {
                if !entry.alive {
                    continue;
                }
                guarded(entry, || "in update".to_owned(), |s| s.update(dt));
            }
        });
    }));
    if let Err(payload) = outcome {
        log_panic("labelle_rs_tick", payload.as_ref());
    }
}

/// Every live script's `deinit`, REVERSE registration order (teardown
/// is LIFO against setup), then the registry is dropped. Panics are
/// contained per script; teardown always completes. Idempotent.
#[unsafe(no_mangle)]
pub extern "C" fn labelle_rs_deinit() {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // Move the registry OUT before running hooks: a deinit that
        // somehow re-enters an entry point sees "no registry" (a no-op)
        // instead of a RefCell double-borrow panic.
        let reg = REGISTRY.with(|r| r.borrow_mut().take());
        let Some(mut reg) = reg else { return };
        for entry in reg.entries.iter_mut().rev() {
            if !entry.alive {
                continue;
            }
            guarded(entry, || "in deinit".to_owned(), |s| s.deinit());
        }
    }));
    if let Err(payload) = outcome {
        log_panic("labelle_rs_deinit", payload.as_ref());
    }
}
