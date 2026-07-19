# RFC: Bulk Component Access for the Script Runtime Contract

**Status:** Draft — prototyped and measured (local worktrees), not yet productionized
**Affects:** `labelle-scripting` (binding + contract decls), `labelle-engine` (contract host), all scripting languages (Lua / Ruby / TypeScript / …)
**Motivating benchmark:** a 2000-entity "swarm" (each entity integrated + wall-bounced every tick), Ruby vs native Zig, ReleaseFast.

## Problem Statement

Reading and writing components from a script is **~100× slower than native Zig**, and today's "fast path" doesn't help. Measured per-entity cost of one integrate+bounce tick (2 component reads + 2 writes), ReleaseFast, N=2000:

| Approach | per-tick (2000 ent) | per-entity | vs Zig |
|---|---:|---:|---:|
| Zig native (`getComponent` → pointer, mutate in place) | 0.045 ms | 23 ns | 1× |
| Ruby naive (`e.get`/`e.set`, JSON+Hash) | 5.40 ms | 2700 ns | **117×** |
| Ruby `into:` (`e.get_into`/`e.set` as shipped) | 6.90 ms | 3447 ns | **150× (slower!)** |

Two findings fall out of this:

1. **`into:` is mislabeled as a fast path.** `raw_component_get_into` / `raw_component_set_from` still round-trip the component as **JSON text** across the FFI boundary (`getComponentJson` → `std.json.Stringify` on the host, parse in the binding). They only skip the mruby Hash allocation, swapping it for per-field `mrb_funcall` dispatch — which is *slower*. The documented promise ("scalar field values cross as immediates") is not what the code does.

2. **The dominant cost is the FFI boundary crossing, not JSON.** Even after removing JSON entirely (see the packed codec below), per-entity cost barely moves. The real expense is *crossing the host boundary 4× per entity* (~600 ns each), which no per-component codec can remove.

This makes scripting unusable for any workload that touches thousands of entities per frame — a hard ceiling of roughly **6k entities at 60 fps** for the naive path, where native Zig wouldn't strain until hundreds of thousands.

## Non-goals

- Making script-driven per-entity logic as fast as native. Running the game logic *in an interpreter* has an irreducible floor (see Results); this RFC removes the *contract* overhead, not the *interpreter* overhead.
- Changing the language-facing component model (declare-mode, view classes, `Labelle.component`). The proposals are additive contract calls.

## Design

Two additive contract capabilities, both language-agnostic (they live in the C ABI; each language binding opts in):

### 1. Packed component codec — fix the per-component fast path

Replace the JSON text round-trip in `get_into`/`set_from` with a compact binary record.

New contract calls (host-exported, mirror the existing `labelle_component_get`/`set`):

```
labelle_component_get_packed(id, name_ptr, name_len, out, out_cap) -> usize
labelle_component_set_packed(id, name_ptr, name_len, buf,  buf_len) -> i32
```

Wire format (little-endian, self-describing so the binding needs no type table):

```
[u8 field_count]                       ; 0xFF = SENTINEL "not packable"
repeat field_count times:
  [u8 name_len][name bytes][u8 tag][value bytes]
tag: 0=f32(4)  1=i64(8)  2=bool(1)  3=u64(8)  4=f64(8, SET-side only — #45)
```

- **GET**: the host reflects the component's fields; if *every* field is a packable scalar it writes the record, else it writes a single `0xFF` byte. The binding checks `buf[0]`: on `0xFF` it **falls back to the existing JSON path** (correctness preserved for any component — enums, nested structs, slices — the codec can't pack). Otherwise it decodes each value straight into the view instance (`f32→Float`, `i64→Integer`, `bool`), no text parsing. GET never emits tag 4 (f64 *fields* stay on the 0xFF/JSON path).
- **SET**: the binding tags each field by the *script value's* runtime type (Ruby `Float`→f32 when the value survives the f32 narrow exactly, else the full-precision f64 tag 4 — so a `Float` destined for an int field lands exactly past f32's 24-bit mantissa (#45); `Integer`→i64, `true`/`false`→bool); the host matches the field by name and **coerces** the tagged value into the field's real Zig type. Non-scalar target field, or tag 4 handed to a pre-tag-4 host → the host refuses (`-1`) and the binding falls back to JSON (which carries the f64 faithfully).

This is a strict, safe improvement: same semantics, JSON kept as the fallback, only scalar components take the fast path.

### 2. Batched query — amortize the boundary crossing (the real win)

A single call moves **all matching entities'** component data across the boundary as one flat buffer, so the script's hot loop runs entirely in-VM with no per-entity host round-trip.

New contract calls:

```
labelle_component_batch_get(names_ptr, names_len, out, out_cap) -> usize
labelle_component_batch_set(names_ptr, names_len, buf,  buf_len) -> i32
```

- `batch_get` resolves the same entity set as `labelle_query` (a view on the first name, filter the rest), then for each entity **in query order**, for each named component **in the given order**, writes its scalar fields as raw `f32` (declaration order). Layout:

  ```
  [u32 entity_count][ f32 stream: count × stride ]
  ```

  The count header lets the binding learn cardinality without knowing stride (and keeps `count==0` distinct from the `0` = malformed/unbound return). `stride` = total scalar fields across the named components.

- `batch_set` re-resolves the same query in the same order and applies the `f32` stream positionally (coercing `f32` → each field's real type). No header — the re-query drives iteration.

Positional agreement holds because the host walks `@typeInfo(T).@"struct".fields` in **declaration order** for both directions (`packFloatsInto` ⇄ `readFloatsFrom` are exact mirrors). The binding is stride-agnostic — it just pipes floats; only the *script* hardcodes the layout it requested.

### Language-facing API (Ruby shown; each language mirrors it)

```ruby
# thin prelude wrappers over the raw shims
def self.batch_get(names, arr); raw_batch_get(json_encode(names), arr); end
def self.batch_set(names, arr, n); raw_batch_set(json_encode(names), arr, n); end
```

Game code — the whole per-tick update crosses the boundary exactly **twice**:

```ruby
NAMES = ["Position", "Velocity"].freeze   # layout per entity: [px, py, vx, vy]

def update(_dt)
  count = Labelle.batch_get(NAMES, @buf)   # 1 FFI call → @buf gets 4*count floats (reused Array)
  i = 0
  while i < count
    b = i * 4
    x = @buf[b]; y = @buf[b+1]; vx = @buf[b+2]; vy = @buf[b+3]
    x += vx; y += vy
    if x < 0.0 then x = 0.0; vx = -vx end
    if x > 800 then x = 800.0; vx = -vx end
    if y < 0.0 then y = 0.0; vy = -vy end
    if y > 600 then y = 600.0; vy = -vy end
    @buf[b] = x; @buf[b+1] = y; @buf[b+2] = vx; @buf[b+3] = vy
    i += 1
  end
  Labelle.batch_set(NAMES, @buf, count)    # 1 FFI call → whole swarm written back
end
```

`@buf` is a plain reused array (grown once, then flat — no per-tick allocation). Note there is no `mruby-pack` gem vendored, so `String#unpack` is unavailable; the binding decodes the byte stream into the array itself, and `FrameArray` is *not* used here (it is a growth-capped `Array` wrapper, not native storage).

### 3. Ergonomic layer — block / closure iteration (per language)

The raw `batch_get`/`batch_set` + manual offset loop is fast but low-level: the script hardcodes `@buf[b+2]` and owns the layout. Each language should layer its **idiomatic block/closure iterator** on top, hiding the buffer plumbing entirely — this is the API most authors should reach for.

Ruby (`each`-style block over a reused per-entity view):

```ruby
Labelle.batch(["Position", "Velocity"]) do |e|
  e.px += e.vx
  e.py += e.vy
  e.vx = -e.vx if e.px < 0 || e.px > 800
  e.vy = -e.vy if e.py < 0 || e.py > 600
end
# `batch` does one batch_get, yields a reused mutable view per entity
# (fields mapped to buffer offsets), then one batch_set after the block.
```

C# (CoreCLR) — a `ref struct` / `Span<float>` enumerator gives the same shape near-native:

```csharp
world.Batch<Position, Velocity>((ref Position p, ref Velocity v) => {
    p.X += v.Vx; p.Y += v.Vy;
    if (p.X < 0 || p.X > 800) v.Vx = -v.Vx;
    if (p.Y < 0 || p.Y > 600) v.Vy = -v.Vy;
});
```

TypeScript, Lua, etc. expose their own (`world.batch([...], (e) => {...})`, `for e in world.batch(...) do ... end`).

**Performance note — this is the crux of keeping the batch primitive language-agnostic.** The block adds a per-entity dispatch (the yield + field-accessor calls). In an **interpreted** VM (mruby, QuickJS) that reintroduces some VM overhead versus the raw hand-indexed loop — it is still batched (no per-entity FFI), so still vastly cheaper than per-entity `get`/`set`, but a measurable tax over `@buf[b+2]`. In a **JIT'd** runtime (**C# CoreCLR**, V8-class JS) the delegate/lambda inlines and the `ref struct`/`Span` iteration approaches the flat-loop speed — you get ergonomics *and* performance. So the layering is deliberate: expose the raw `batch_get`/`batch_set` primitive (max speed, ugly) once at the contract level, and let each language own the iterator — interpreted languages offer the block for ergonomics and the raw loop for the last drop of speed; JIT languages get both from the block.

**The Ruby yield tax, measured (stage 2).** Shipped as `Labelle.batch` in `src/ruby/prelude.rb` and measured on the same rig and method as the stage-1 numbers (2000-entity integrate+bounce, ReleaseFast, headless uncapped, two-point method T(2200)−T(200), min of reps; released engine 2.6.0; flat loop re-measured in the same session to validate the method — it reproduced stage 1's 0.649 within 1%):

| Ruby approach | per-tick | per-entity | vs flat loop | vs naive |
|---|---:|---:|---:|---:|
| naive per-entity `get`/`set` | 5.37 ms | 2685 ns | 8.4× | 1× |
| **`Labelle.batch { \|e\| }` block** | **1.25 ms** | **624 ns** | **1.9×** | **4.3× faster** |
| `batch_get`/`batch_set` flat loop | 0.64 ms | 321 ns | 1× | 8.4× faster |

The interpreted-block tax is **~1.9×** — the yield plus ~8–12 accessor dispatches per entity roughly doubles the flat loop, exactly the "measurable but far from catastrophic" band predicted above (correctness cross-checked: flat and block runs produce bit-identical position checksums at tick 600). Guidance this sets: **reach for the block by default** (readable, no hand-maintained offsets), drop to the flat loop for the hottest loops, never per-entity `get`/`set` over thousands.

**Ruby implementation shape (the copy-this pattern for stage-3 ports, #44).** Pure prelude Ruby — no new Zig or contract surface:

1. **Layout discovery**: on first use per names-set, JSON-`get` each named component once on the first matched entity — the host serializes struct fields in *declaration order*, the same order the batch stream walks — and keep the fields whose values are numeric/bool (the stream skips non-scalar fields the same way). Any way the probe could disagree with the stream is caught by a hard cross-check (`buf.size == count × stride`) before the first yield: a mismatch **raises** with "use the flat loop", never mis-maps. Duplicate field names across the named components also raise (the accessors could not disambiguate), as does a discovery re-query that comes back empty (an entity destroyed mid-tick — a clear "re-run next tick" raise, not a low-level nil error).
2. **One reused view**: mint a class per names-set whose accessors (`define_method`, field name → captured stream offset) read/write the shared buffer at a moving base offset; a single instance is yielded for every entity (document that stashing `e` itself is a bug, same as `Labelle.each`). Reserve exactly the names the view machinery itself needs — `initialize` (a field accessor by that name would replace the constructor before `new` runs) and the base-offset writer — with a clear raise naming the component and field; every *other* field name is fair game and intentionally shadows inherited object methods within the view's scope.
3. **Drive**: `batch_get` → yield per entity (bump the base) → `batch_set`. Empty query returns 0 without touching the block; a single non-array name is coerced to `[name]`, an empty names array refuses. **Exit semantics — break/return commit, raise aborts**: `break`/`return` inside the block is the normal iterator early-exit, so the writes made up to that point still flush through the one `batch_set` (not-yet-yielded entities round-trip unchanged, and `break value` becomes the call's return value); a raising block abandons the write entirely (all-or-nothing). In Ruby this is begin/rescue(mark abort + re-raise)/ensure(commit unless aborted) around the yield loop — nonlocal exits bypass `rescue` but run `ensure`; note mruby does not populate `$!`, so an `$!`-based ensure check would misfire. `batch_get`/`batch_set` refusals (int fields, set-drift, pre-v1.3 host) pass through unchanged — the block form's first act *is* `batch_get`, so an unsupported host raises the identical error.

JIT'd runtimes (C#, V8-class JS) should skip the derived-accessor machinery where the type system already knows the layout (`ref struct` enumerator over `Span<float>`), and can expect near-flat-loop speed from the closure form.

## Results

All four measured on the same machine, ReleaseFast, N=2000, two-point method (T(2200)−T(200), cancels one-time spawn/VM-init), min of reps, verified correct (all 2000 entities read + moved each tick):

| Approach | per-tick | per-entity | vs Zig | vs naive |
|---|---:|---:|---:|---:|
| Zig native | 0.045 ms | 23 ns | 1× | — |
| Ruby naive (JSON) | 5.40 ms | 2700 ns | 117× | 1.0× |
| Ruby packed `into:` | 4.97 ms | 2483 ns | 108× | 1.1× |
| **Ruby batched** | **0.61 ms** | **305 ns** | **13.3×** | **8.9×** |

What the numbers prove:

- **Packed codec: +10% only.** Removing JSON barely helps → JSON was a minority of the cost, and (importantly) it makes `into:` genuinely the fastest per-component path, fixing the mislabeled-fast-path bug.
- **Batching: 8.9×.** Collapsing 8000 crossings/tick → 2 closes **~89%** of the Ruby-vs-Zig gap. This is where the leverage is.
- **The residual 13.3×** is the inherent mruby cost of executing 2000 loop iterations (array access + arithmetic) — not removable without moving the loop out of the interpreter. That floor *is* Zig's 23 ns: native never crosses a boundary and never leaves compiled code.

### Guidance this establishes

- **Ruby/scripts for high-level logic** — a handful of entities, event handlers, orchestration, per-frame-but-not-per-entity work. Overhead is invisible (a 1-player game shows no perceptible difference).
- **Hot per-entity loops over thousands** — use `batch_get`/`batch_set` (13× penalty, tolerable), or keep the loop in Zig / a plugin (1×). **Never** per-entity `get`/`set` in a hot loop — that is the 100× trap.

## Alternatives considered

- **Allocation avoidance (the current `into:`)** — measured *slower* than naive; the allocation was never the bottleneck.
- **`FrameArray` for the batch buffer** — it is a Ruby `Array` wrapper (bounds-checked `[]`/`[]=`), not native float storage; a plain `Array` is faster.
- **`String#unpack('f*')`** — clean, but `mruby-pack` is not in the vendored gembox; the binding decodes the stream itself instead.
- **A better per-component codec only (no batching)** — capped at ~1.1× by the boundary-crossing floor; insufficient.

## Limitations / open questions

- **Prototype is f32-only for the batch path.** Fields are coerced to/from `f32` in the flat stream. Production should either (a) key the stream by a per-component field-type descriptor, or (b) restrict `batch_*` to declared-scalar components and document the coercion. The single-component packed codec already handles i64/u64/bool/f32 with tags.
- **Positional coupling.** `batch_get`/`batch_set` assume the query returns the same entities in the same order within a tick (true when no spawn/destroy happens between the two calls). A safer variant would embed entity ids and match on write; measure the cost of the id column before adopting.
- **Layout is script-owned.** ~~The script hardcodes the `[px,py,vx,vy]` stride from the `NAMES` order.~~ RESOLVED in stage 2 for the ergonomic tier: `Labelle.batch(NAMES) { |e| ... }` derives the layout host-side-truthfully (first-entity JSON probe, declaration order, stride cross-checked) and hides the offsets; the raw `batch_get`/`batch_set` tier deliberately stays script-owned for maximum speed. The block does reintroduce per-entity dispatch — measured at ~1.9× the flat loop (see Ergonomic layer).
- **Type generality of packed SET.** The host requires a component to be fully default-constructible (`var comp: T = .{}`) to apply a partial packed write with REPLACE semantics; components without full field defaults fall back to JSON. (The BATCH set has no such requirement — stage 1 made it read-modify-write.)
- **Test surface.** RESOLVED in stage 1: `tests/mock_world.zig` exports the four symbols behind a field-type schema table mirroring the engine host's semantics (refusals, preflight, bitcast pair included).
- **Versioning.** RESOLVED in stage 1 — see "Decisions" below for the one shipped mechanism: additive to the major version, detected by the comptime engine-module probe `contract.host_has_bulk_access` (NOT by `@hasDecl` on the externs, which cannot see host exports).

## Implementation status

Prototyped end-to-end and measured in local worktrees:

- `labelle-engine-packed/src/script_contract.zig` — packed + batch host impls, exports, VTable entries, reflection helpers (reusing the existing name-dispatch and `setPosition`/`setComponent` apply path so hooks/dirty-tracking fire).
- `labelle-scripting/src/contract.zig` — 4 new externs.
- `labelle-scripting/src/ruby/bindings.zig` + `vm.zig` — `get_into`/`set_from` packed path (JSON fallback), `raw_batch_get`/`raw_batch_set`, `mrb_ary_set`/`mrb_ensure_float_type` externs.
- `labelle-scripting/src/ruby/prelude.rb` — `batch_get`/`batch_set` wrappers.
- Benchmark games: `ruby-swarm` (naive), `ruby-swarm-fast` (packed `into:`), `ruby-swarm-batch` (batched), `zig-swarm` (native baseline).

### Proposed rollout

1. Land the **packed codec** first — strictly-safe improvement (JSON fallback), fixes `into:`, no new API surface for game authors.
2. Land **`batch_get`/`batch_set`** as the contract primitive, plus the thin per-language `batch_get`/`batch_set` wrappers; keep f32-only + document, or add the field-type descriptor.
3. ~~Add the **block/closure iterator** ergonomic layer per language~~ — DONE for Ruby in stage 2 (#43): `Labelle.batch(names) { |e| ... }` shipped in the prelude, interpreted-block tax measured at ~1.9× the flat loop (624 vs 321 ns/entity — see the Ergonomic layer section). Other languages land with their stage-3 ports (#44), following the documented copy-this pattern.
4. Port the binding changes to Lua / TypeScript (the contract is shared; only the per-language decode differs).
5. ~~Add mock-world exports + capability gating~~ — DONE in stage 1: mock exports landed, and capability detection shipped as the comptime engine-module probe (see Decisions; the contract major stays 1, the exports are "since v1.3").
6. Ship one batched example per language as a permanent perf regression net.

## Decisions (stage 1)

Recorded as landed in the stage-1 PRs (engine `feat/bulk-component-access` +
this repo's `feat/bulk-component-access`, contract **v1.3**):

- **f32-only batch stream + int-field refusal.** The batch stream stays raw
  f32 (option (b) of the type-generality question), but instead of
  documenting the coercion the host now **refuses** any named component
  carrying an int-typed field — `LABELLE_BATCH_INT_REFUSED` (`(size_t)-2`)
  from `batch_get`, `-2` from `batch_set` — because i64/u64 silently corrupt
  past f32's 24-bit mantissa. f32/f64 and bool (0/1) fields ride the stream;
  non-scalar fields are skipped identically in both directions. The Ruby
  binding surfaces the refusal as a **raised ArgumentError naming the
  component list** — loud, never a silent JSON fallback. Int-carrying
  components keep the per-entity paths (the packed codec carries ints
  losslessly).
- **Positional coupling gets a cheap count guard — now a PREFLIGHT.**
  `batch_set` sizes the re-resolved query BEFORE writing anything and
  refuses `-1` with NO writes unless `buf_len` matches exactly, catching
  any spawn/destroy between the paired calls that changes the entity count
  (a same-count membership/order change remains undetectable — the "no
  spawn/destroy between get and set" rule stands; the id-column variant
  stays a measured follow-up). The Ruby binding raises RuntimeError on
  `-1` ("re-run batch_get and recompute" — safe to retry, nothing was
  applied) and trims the reused Array to exactly count×stride after each
  `batch_get` so a shrinking set never ships stale trailing floats.
- **Batch set is READ-MODIFY-WRITE (get/set symmetry).** Everything
  `batch_get` emits is writable: the host fetches each queried component,
  overwrites only the stream-carried scalar fields, preserves non-scalar
  fields, and applies through the per-entity channels (scene built-ins
  included — a batched Camera zoom routes through the scene apply
  machinery). No default-constructibility is required on the batch path.
- **Packed codec hardening.** f64 fields are NOT packable (the wire only
  has an f32 tag; 0xFF/JSON keeps the precision); trailing bytes after
  the declared fields refuse; and 64-bit int fields accept the OTHER
  64-bit tag via two's-complement bitcast — the documented lossless pair
  that lets a signed-only binding (mruby) round-trip bit-63 u64 values
  exactly (GET tag 3 → signed bitcast → SET tag 1 → host bitcasts back).
- **Id column deferred pending measurement.** The safer embed-entity-ids
  variant stays out until the cost of the id column is measured against the
  305 ns/entity baseline.
- **Block iterator (`Labelle.batch { |e| }`)** — ~~deferred to stage 2~~
  SHIPPED for Ruby in stage 2 (#43), pure prelude (no new contract or
  C-ABI surface, so no capability-gating changes): layout derived from a
  first-entity JSON probe in declaration order with a hard stride
  cross-check, one reused view yielded per entity, all-or-nothing write.
  Interpreted-block tax measured at **~1.9× the flat loop** (624 vs
  321 ns/entity; still 4.3× faster than naive) — see the Ergonomic
  layer section for the table and the stage-3 porting pattern (#44).
- **Versioning + capability detection (supersedes the earlier "paired
  engine version, link fails on old host" statement):** additive minor
  revision per the contract's convention — major stays 1, the four exports
  are marked "since v1.3" in `labelle_script.h`. Detection is the
  **comptime engine-module probe** `contract.host_has_bulk_access`
  (`@hasDecl(engine.script_contract, "batch_int_refused")` — the marker
  decl the engine gained in the same 2.6.0 release as the exports; the
  assembler hands every generated game's scripting module `labelle-engine`
  as a dep, and this repo's own builds stand in `src/engine_stub.zig`).
  Every fast-path extern reference is gated on it, so **a game built
  against an older engine never references the symbols** (no link
  failure): `get_into`/`set` degrade to the JSON paths silently, while
  `batch_get`/`batch_set` **raise** a clear "host engine lacks batch
  support (needs labelle-engine ≥ 2.6.0)" script error — there is no batch
  fallback, and silently degrading a whole-query read would be data loss.
  Verified end to end: `examples/ruby-game` builds AND produces its full
  16-token transcript against the pinned released engine (2.5.0).
  A **weak-extern runtime probe** (`@extern(..., .linkage = .weak)` →
  null on old hosts) was prototyped and rejected on measurement: on Zig
  0.16 an ABSENT weak symbol links only on COFF and on ELF under the LLVM
  backend — the Mach-O linker refuses undefined weak externals (both
  backends), as does the self-hosted ELF linker (the x86_64-linux Debug
  default) — so it cannot cover the primary platforms. The comptime probe
  matches link-time truth exactly on every platform. The JSON paths
  additionally remain the semantic fallback for v1.3 host refusals
  (0xFF / -1), independent of the capability gate.
