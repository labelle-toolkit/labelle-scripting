# vendored mruby 3.4.0

The `ruby` sub-module's runtime. mruby has **no amalgamation**, and its
upstream build needs host ruby + rake (mrbc bootstrapping, presym
scanning, mrblib/gem bytecode generation) — a toolchain labelle consumers
must never need. So the rake build ran ONCE, here, and this directory
snapshots its inputs and outputs:

- `include/` — upstream headers PLUS the generated presym tables
  (`include/mruby/presym/{id,table,…}.h`);
- `src/` — upstream core sources, plus the generated `src/mrblib.c`
  (core-library bytecode);
- `mrbgems/` — the compiler gem (with its pre-generated `y.tab.c`,
  shipped by mruby release trees), each selected gem's C sources, and the
  generated per-gem + master `gem_init.c` bytecode inits;
- `labelle_mruby_config.rb` — the exact build config the snapshot came
  from (gem selection + defines);
- `LICENSE` — mruby's (MIT).

build.zig compiles the whole set (see `mruby_sources`) only when
`-Dlanguage=ruby`, always with `-DMRB_INT64 -DMRB_NO_BOXING` — those two
defines are load-bearing: they are baked into this snapshot's config AND
into src/ruby/vm.zig's hand-mirrored `mrb_value` ABI (no-boxing is the
one representation a hand-declared extern struct can mirror; it also
keeps full-width i64 integers and floats immediate). Do not compile these
sources with different boxing/int defines.

## Gem selection (the sandbox posture)

Pure-language core gems only: the `stdlib` gembox (array/hash/string/…
-ext, set, fiber, enumerator, objectspace), math, random, sprintf, catch,
**struct** (Component.ref backing), **metaprog**, **error**
(mrb_protect), **compiler** (runtime script loading). Excluded on
purpose: io, socket, dir, errno, eval, time, sleep, exit, method,
binding, pack, bigint/rational/complex/cmath. `puts`/`p` are mruby-3.4
core (stdout only).

## Regenerating (mruby version bump)

On a host with ruby + rake:

```sh
git clone --depth 1 --branch <tag> https://github.com/mruby/mruby.git /tmp/mruby-src
cd /tmp/mruby-src
rake MRUBY_CONFIG=<this dir>/labelle_mruby_config.rb
```

Then re-copy into this directory:

- `build/host/include/` → `include/` (wholesale — it is the upstream
  include tree plus the generated presym headers);
- `src/*.{c,h}` → `src/`, `build/host/mrblib/mrblib.c` → `src/mrblib.c`;
- `build/host/mrbgems/gem_init.c` → `mrbgems/gem_init.c`;
- `mrbgems/mruby-compiler/core/{codegen.c,y.tab.c,node.h,lex.def}` →
  `mrbgems/mruby-compiler/core/`;
- per selected gem: `mrbgems/<gem>/src/*.c` and
  `build/host/mrbgems/<gem>/gem_init.c` → `mrbgems/<gem>/…`.

Update `mruby_sources` in build.zig if the file set changed, and re-run
`zig build test`.

## Local patches (RE-APPLY after regenerating)

A regeneration overwrites the files below with pristine upstream, dropping
these fixes — re-apply each one:

- **`src/vm.c`, `stack_init()`** (labelle-scripting#56): add
  `stack_clear(c->stbase, STACK_INIT_SIZE);` right after `c->stbase` is
  `mrb_malloc`'d. Upstream (through 3.4.0) never nil-initializes the
  INITIAL VM stack, unlike `stack_extend_alloc()` which clears the grown
  region. `mark_context_stack()` (gc.c) then reads those slots during GC;
  on a heap left dirty by a prior `mrb_open`/`mrb_close` cycle a leftover
  word is marked as a bogus object pointer and the VM crashes. Fresh
  zero-filled pages hid it on a first boot, so it only bit multiple VM
  lifecycles per process — the declare tool and any multi-VM test binary,
  on Linux (glibc/musl recycle dirty memory; macOS libmalloc masked it).
  Worth upstreaming.

## TODO — packaging refinement

Vendoring in-repo trades fetch-laziness for build-laziness (lua keeps
both via `b.lazyDependency`). Once a labelle-hosted prebuilt exists, move
this tree to a **lazy tarball dependency** (`.lazy = true`, like lua) so
`-Dlanguage=lua` projects never even download the ~2.6 MB snapshot.
