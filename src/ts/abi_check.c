/* abi_check.c — compile-time pins for everything src/ts/vm.zig and
 * src/ts/bindings.zig hand-mirror from the vendored quickjs-ng headers.
 *
 * Unlike mruby (src/ruby/shim.c), quickjs-ng v0.15+ exports every API the
 * bindings call as a real symbol, so no functional shim is needed — but
 * the Zig side still mirrors the JSValue layout, the tag numbering and a
 * handful of flag/enum values (quickjs-ng has renumbered tags before:
 * the BigFloat/BigDecimal removal shifted them relative to bellard's
 * tree). These _Static_asserts compile against the SAME fetched headers
 * and defines as the VM objects, so a future pin bump that moves any
 * mirrored fact fails the BUILD instead of corrupting values at runtime.
 *
 * JS_NAN_BOXING=0 (build.zig quickjs_flags) is part of the contract being
 * asserted: it pins the {union, i64 tag} struct encoding on every target,
 * 32-bit included, which is the only representation the Zig extern-struct
 * mirror can follow.
 */

#include <assert.h>
#include <stddef.h>

#include "quickjs.h"

/* The value struct the Zig `c.Value` extern struct mirrors. */
_Static_assert(sizeof(JSValue) == 16, "JSValue must be the 16-byte {union, i64 tag} struct");
_Static_assert(offsetof(JSValue, u) == 0, "JSValue union must lead");
_Static_assert(offsetof(JSValue, tag) == 8, "JSValue tag must sit at byte 8");
_Static_assert(sizeof(JSAtom) == 4, "JSAtom must be u32");

/* Tag numbering (vm.zig TAG_*). */
_Static_assert(JS_TAG_BIG_INT == -9, "tag drift: BIG_INT");
_Static_assert(JS_TAG_SYMBOL == -8, "tag drift: SYMBOL");
_Static_assert(JS_TAG_STRING == -7, "tag drift: STRING");
_Static_assert(JS_TAG_STRING_ROPE == -6, "tag drift: STRING_ROPE");
_Static_assert(JS_TAG_MODULE == -3, "tag drift: MODULE");
_Static_assert(JS_TAG_OBJECT == -1, "tag drift: OBJECT");
_Static_assert(JS_TAG_INT == 0, "tag drift: INT");
_Static_assert(JS_TAG_BOOL == 1, "tag drift: BOOL");
_Static_assert(JS_TAG_NULL == 2, "tag drift: NULL");
_Static_assert(JS_TAG_UNDEFINED == 3, "tag drift: UNDEFINED");
_Static_assert(JS_TAG_EXCEPTION == 6, "tag drift: EXCEPTION");
_Static_assert(JS_TAG_SHORT_BIG_INT == 7, "tag drift: SHORT_BIG_INT");
_Static_assert(JS_TAG_FLOAT64 == 8, "tag drift: FLOAT64");

/* Eval flags (vm.zig EVAL_*). */
_Static_assert(JS_EVAL_TYPE_GLOBAL == 0, "eval flag drift: TYPE_GLOBAL");
_Static_assert(JS_EVAL_TYPE_MODULE == 1, "eval flag drift: TYPE_MODULE");
_Static_assert(JS_EVAL_FLAG_COMPILE_ONLY == (1 << 5), "eval flag drift: COMPILE_ONLY");

/* C-function proto enum (bindings.zig passes the raw 0). */
_Static_assert(JS_CFUNC_generic == 0, "JSCFunctionEnum drift: generic");

/* Property enumeration (bindings.zig json encoder). */
_Static_assert(JS_GPN_STRING_MASK == (1 << 0), "GPN drift: STRING_MASK");
_Static_assert(JS_GPN_ENUM_ONLY == (1 << 4), "GPN drift: ENUM_ONLY");
_Static_assert(JS_PROP_C_W_E == 7, "prop flag drift: C_W_E");
_Static_assert(sizeof(JSPropertyEnum) == 8, "JSPropertyEnum layout drift");
_Static_assert(offsetof(JSPropertyEnum, atom) == 4, "JSPropertyEnum.atom offset drift");

/* Promise states (vm.zig module-eval result handling). */
_Static_assert(JS_PROMISE_NOT_A_PROMISE == -1, "promise enum drift: NOT_A_PROMISE");
_Static_assert(JS_PROMISE_PENDING == 0, "promise enum drift: PENDING");
_Static_assert(JS_PROMISE_FULFILLED == 1, "promise enum drift: FULFILLED");
_Static_assert(JS_PROMISE_REJECTED == 2, "promise enum drift: REJECTED");

/* Memory-usage struct (bindings.zig raw_gc_live test seam). */
_Static_assert(sizeof(JSMemoryUsage) == 26 * sizeof(int64_t), "JSMemoryUsage layout drift");
_Static_assert(offsetof(JSMemoryUsage, malloc_count) == 3 * sizeof(int64_t),
               "JSMemoryUsage.malloc_count offset drift");
