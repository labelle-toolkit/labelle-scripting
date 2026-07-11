/* labelle mruby shim — flat C exports for the handful of mruby APIs that
 * are macros or struct-field pokes rather than linkable functions, so the
 * Zig side can stay pure hand-declared externs (no @cImport).
 *
 * Compiled by build.zig together with the vendored mruby sources (same
 * include path, same MRB_INT64/MRB_NO_BOXING defines), so every macro here
 * expands against the exact headers the VM was built from.
 *
 * Everything else the ruby sub-module calls is a real MRB_API function and
 * is declared directly in src/ruby/vm.zig.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/compile.h>
#include <mruby/string.h>

/* ── GC arena + heap counters ─────────────────────────────────────────────
 * mrb_gc_arena_save/restore are #defines over mrb->gc.arena_idx
 * (include/mruby.h) — the per-tick overflow guard every mruby embedding
 * needs. live/disabled are plain gc fields, exposed for the zero-alloc
 * test seams: with the GC disabled, `live` is a monotonic allocation
 * counter, which turns "this loop allocates nothing" into an exact
 * equality assert. */

int labelle_mrb_gc_arena_save(mrb_state *mrb) {
  return mrb_gc_arena_save(mrb);
}

void labelle_mrb_gc_arena_restore(mrb_state *mrb, int idx) {
  mrb_gc_arena_restore(mrb, idx);
}

size_t labelle_mrb_gc_live(mrb_state *mrb) {
  return (size_t)mrb->gc.live;
}

void labelle_mrb_gc_set_disabled(mrb_state *mrb, mrb_bool disabled) {
  mrb->gc.disabled = disabled;
}

/* ── pending exception (mrb->exc) ─────────────────────────────────────────
 * mruby's top-level entry APIs (mrb_load_*, mrb_funcall_* called with no
 * protecting VM frame) catch script exceptions and park them here instead
 * of unwinding through the caller — the error seam the whole vm.zig error
 * policy hangs off. */

mrb_value labelle_mrb_exc_get(mrb_state *mrb) {
  return mrb->exc ? mrb_obj_value(mrb->exc) : mrb_nil_value();
}

void labelle_mrb_exc_clear(mrb_state *mrb) {
  mrb->exc = NULL;
}

/* ── compile context ──────────────────────────────────────────────────────
 * mrbc_context is a public struct but carries bitfields — not cleanly
 * mirrorable from Zig. capture_errors makes the parser raise a proper
 * SyntaxError ("line N: ...") instead of printing to stderr, which is how
 * load errors reach the game's log sink. */

void labelle_mrbc_capture_errors(mrbc_context *cxt, mrb_bool on) {
  cxt->capture_errors = on;
}

/* ── string / array raw access (RSTRING_* / RARRAY_* macros) ────────────── */

const char *labelle_mrb_str_ptr(mrb_value s) {
  return RSTRING_PTR(s);
}

mrb_int labelle_mrb_str_len(mrb_value s) {
  return RSTRING_LEN(s);
}

mrb_int labelle_mrb_ary_len(mrb_value a) {
  return RARRAY_LEN(a);
}
