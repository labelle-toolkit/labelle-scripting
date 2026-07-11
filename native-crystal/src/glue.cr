# The plugin glue: the C entry points labelle-scripting's `crystal` arm
# (src/crystal/vm.zig) drives, and the script registry + dispatch loops
# behind them. Games never touch this file — their surface is `Labelle`
# (`Script`, `Scripts`, the wrappers) plus the one `Game.register`
# convention in their `crystal/game.cr`.
#
# ## The labelle_cr_* entry convention (crystal glue ABI v1)
#
# The Zig arm calls, in Controller order:
#
# | entry                       | when                                     |
# |-----------------------------|-------------------------------------------|
# | `labelle_cr_abi_version`    | `Vm.init` — handshake, must return 1;      |
# |                             | runs BEFORE boot, so its body is pinned    |
# |                             | to a bare literal (see the fun)            |
# | `labelle_cr_boot`           | `Vm.init`, once per process — the crystal  |
# |                             | runtime boot (below); returns 0 ok / the   |
# |                             | 1-based FAILED STAGE, and on nonzero the   |
# |                             | Zig arm fails setup loudly and POISONS     |
# |                             | scripting for the process (a partial boot  |
# |                             | cannot be retried — the empirical          |
# |                             | rationale lives in src/crystal/vm.zig)     |
# | `labelle_cr_setup`          | end of `Controller.setup` — runs the       |
# |                             | game's `Game.register`, then every         |
# |                             | script's `init` (raising inits EVICT)      |
# | `labelle_cr_dispatch_inbox` | top of `Controller.tick` — drains the      |
# |                             | event inbox, fans out to `on_event`        |
# | `labelle_cr_tick`           | `Controller.tick` — every `update(dt)`     |
# | `labelle_cr_deinit`         | `Controller.deinit` — every `deinit`       |
# |                             | (reverse registration order), registry     |
# |                             | dropped                                    |
#
# Bump `CR_ABI_VERSION` on any change to this table's names or
# signatures — the Zig arm refuses a mismatched glue at boot (the
# stale-object case: a plugin upgrade with a stale `{cache}` artifact
# must fail the handshake, not corrupt a tick).
#
# ## The boot sequence (the labelle-engine#734 POC's sharp edges, solved)
#
# Crystal has no `--no-main`, so the build localizes the object's `main`
# away — which means NOTHING crystal-runtime-shaped has run when the
# host first calls in. `labelle_cr_boot` performs the full embed boot,
# in order:
#
#   1. `GC.init` — bdw-gc initialization ON THE HOST'S MAIN THREAD,
#      which is what registers that thread's stack bounds with the
#      collector (GC_init detects the calling thread's stack); skip it
#      (or boot on another thread than the one that ticks) and the
#      first collection scans garbage. Collections stay ENABLED — the
#      suite forces GC.collect every tick to pin exactly that.
#   2. `Crystal.init_runtime` — Thread/Fiber/Once class-var init; the
#      lazy-constant (`__crystal_once`) machinery needs it.
#   3. `Crystal.main_user_code(1, argv)` — runs the program's TOP LEVEL:
#      every eager constant and class-var initializer in the stdlib,
#      this glue and the game sources. THIS is the step the POC missed;
#      without it stdlib tables sit as null slices and e.g. the first
#      `to_i64` crashes at an address equal to the first parsed byte
#      (the POC's "raising APIs segfault at 0x2c" bisect — it was never
#      the raise, it was `CHAR_TO_DIGIT`). The argv must be a real
#      1-element array: `PROGRAM_NAME` derefs `argv[0]` (the null-argv
#      crash behind the POC's "main_user_code segfaults" note).
#
# The corollary game-code rule: no top-level statements with world
# side effects — the top level runs at BOOT (before any world exists),
# not at script setup. Put logic in `Script` subclasses.
#
# ## Exceptions MUST NOT unwind across the FFI boundary
#
# Every entry point wraps its whole body in begin/rescue, and every
# script hook call is ADDITIONALLY rescued one script at a time, so one
# raising script cannot starve its siblings. An exception that unwinds
# out of a crystal `fun` finds no handler in the host's foreign frames
# and crystal KILLS THE PROCESS ("Failed to raise an exception:
# END_OF_STACK") — the double rescue is the difference between "one
# script logged an error" and "the game died". Semantics mirror the
# rust glue exactly: init raise → logged + evicted; update/on_event
# raise → logged every time, script stays; deinit raise → logged,
# teardown continues; `Game.register` raise → logged, ALL registrations
# dropped (all-or-nothing — a half-registered set would run hooks the
# author never ordered).
#
# Reports carry class + message, no backtrace: backtrace DECODE reads
# the executable image via `Process.executable_path`, which under
# embedding resolves against the fake boot argv — an embedding hazard
# for zero diagnostic value (script raises are attributed by name and
# hook already; rust's glue makes the same call: "location + message is
# the story").
#
# The registry is module state on the main thread (the contract is
# main-thread-only; every entry point runs on the game's main thread).

require "./labelle"

module Labelle
  # :nodoc: — plugin-internal, not game surface.
  module Glue
    # The glue ABI revision `labelle_cr_abi_version` reports and the Zig
    # arm's `SUPPORTED_CR_ABI_VERSION` must equal. Keep the fun's body a
    # LITERAL copy of this value (the fun runs pre-boot; see its doc).
    CR_ABI_VERSION = 1_u32

    class Entry
      getter name : String
      getter script : Labelle::Script
      # Cleared when `init` raises: an evicted script never receives
      # `on_event`/`update`/`deinit` (half-initialized state must not
      # run).
      property alive : Bool = true

      def initialize(@name, @script)
      end
    end

    @@entries = [] of Entry
    # False until a setup succeeds and after deinit — the tick legs
    # no-op without a registry, mirroring rust's Option<Registry>.
    @@has_registry = false
    # Reused drain buffer for `labelle_event_poll` — grow-only, so the
    # steady state polls with zero buffer allocation (each drained
    # entry still copies into the immutable Strings handed to
    # `on_event`; that is crystal's String contract, and the GC suite
    # churns far more than that on purpose).
    @@inbox = Labelle::Buffer.new

    # One line per raise, class + message, never raising itself (it runs
    # inside rescue handlers — a raise here would escape the FFI gate).
    def self.log_raise(context : String, ex : Exception) : Nil
      Labelle.log("crystal: #{context} raised: #{ex.class.name}: #{ex.message}")
    rescue
      Labelle.log("crystal: exception while logging an exception")
    end

    # Build the registry (the game's `Game.register`), then run every
    # script's `init` — a raising `init` logs and EVICTS that script;
    # the rest keep going. Idempotent-by-rebuild: a re-setup drops the
    # old registry and registers from scratch (the Controller's
    # re-setup = clean restart contract). Returns 0, or -1 when
    # `Game.register` itself raised (no scripts registered).
    def self.setup : Int32
      @@entries = [] of Entry
      @@has_registry = false

      scripts = Labelle::Scripts.new
      begin
        Game.register(scripts)
      rescue ex
        # All-or-nothing registration: drop whatever registered before
        # the raise — a partial set would run hooks the author never
        # finished ordering.
        log_raise("register()", ex)
        Labelle.log("crystal: no scripts registered")
        return -1
      end

      @@entries = scripts.entries.map { |(name, script)| Entry.new(name, script) }
      @@has_registry = true

      @@entries.each do |entry|
        begin
          entry.script.init
        rescue ex
          log_raise("script '#{entry.name}' in init", ex)
          entry.alive = false
          Labelle.log("crystal: script evicted: '#{entry.name}'")
        end
      end
      0
    end

    # Drain the event inbox (FIFO, one poll loop — the RFC's model) and
    # fan each entry out to every live script's `on_event`. Handler
    # raises are contained per script per event; the drain always
    # completes.
    def self.dispatch_inbox : Nil
      return unless @@has_registry
      while Labelle.poll_into(@@inbox)
        # Entries are "<name> <json>"; an entry is never empty.
        text = String.new(@@inbox.to_slice)
        name, _, payload = text.partition(' ')
        @@entries.each do |entry|
          next unless entry.alive
          begin
            entry.script.on_event(name, payload)
          rescue ex
            log_raise("script '#{entry.name}' in on_event('#{name}')", ex)
          end
        end
      end
    end

    # Every live script's `update(dt)`, registration order. A raising
    # update is logged EVERY tick and the script stays registered (its
    # state is intact; the author gets the report until it's fixed) —
    # siblings always run.
    def self.tick(dt : Float32) : Nil
      return unless @@has_registry
      @@entries.each do |entry|
        next unless entry.alive
        begin
          entry.script.update(dt)
        rescue ex
          log_raise("script '#{entry.name}' in update", ex)
        end
      end
    end

    # Every live script's `deinit`, REVERSE registration order (teardown
    # is LIFO against setup), then the registry is dropped. Raises are
    # contained per script; teardown always completes. Idempotent. The
    # registry is taken OUT before hooks run: a deinit that somehow
    # re-enters an entry point sees "no registry" (a no-op).
    def self.deinit : Nil
      return unless @@has_registry
      @@has_registry = false
      entries = @@entries
      @@entries = [] of Entry
      entries.reverse_each do |entry|
        next unless entry.alive
        begin
          entry.script.deinit
        rescue ex
          log_raise("script '#{entry.name}' in deinit", ex)
        end
      end
    end
  end
end

# ── Entry points (the Zig arm's externs) ─────────────────────────────────

# Handshake: the glue ABI revision this object was built against.
#
# INVARIANT: the body stays a bare integer literal (mirroring
# `Labelle::Glue::CR_ABI_VERSION`). The Zig arm calls this BEFORE
# `labelle_cr_boot` so a stale object fails fast — nothing needing the
# crystal runtime (allocation, lazy constants, class vars) may ever
# appear here.
fun labelle_cr_abi_version : UInt32
  1_u32
end

# Runtime boot — the module doc's three-step embed sequence. Returns 0
# on success, else the 1-BASED STAGE that raised; the Zig arm fails
# setup loudly on nonzero and only latches "booted" on 0 (a swallowed
# boot failure would leave every later setup running scripts over a
# runtime whose GC/constants never initialized — the corrupt-quietly
# mode this contract exists to prevent). The Zig arm guards the
# once-ness AND refuses any re-boot after a failure: a repeat call
# after success would re-run the top level over live state, and a
# repeat after a PARTIAL run corrupts the runtime outright (crystal
# scripting is poisoned for the process — src/crystal/vm.zig carries
# the empirical evidence).
#
# Raise containment here predates the runtime proper: rescue itself is
# safe pre-top-level (raise allocates via bdw-gc's lazy init and never
# needs the eager-constant tables — the #734-POC-era spike pinned
# exactly that), but string INTERPOLATION isn't, so the failure reports
# are static literals picked per stage.
fun labelle_cr_boot : Int32
  stage = 1_i32
  begin
    GC.init
    stage = 2
    Crystal.init_runtime
    stage = 3
    program_name = "labelle".to_unsafe
    Crystal.main_user_code(1, pointerof(program_name))
    0_i32
  rescue ex
    msg = case stage
          when 1 then "crystal: runtime boot failed during GC.init"
          when 2 then "crystal: runtime boot failed during Crystal.init_runtime"
          else        "crystal: runtime boot failed during top-level initialization (main_user_code)"
          end
    LibLabelle.labelle_log(msg.to_unsafe, msg.bytesize)
    stage
  end
end

fun labelle_cr_setup : Int32
  Labelle::Glue.setup
    rescue ex
      Labelle::Glue.log_raise("labelle_cr_setup", ex)
      -1_i32
end

fun labelle_cr_dispatch_inbox : Void
  Labelle::Glue.dispatch_inbox
    rescue ex
      Labelle::Glue.log_raise("labelle_cr_dispatch_inbox", ex)
end

fun labelle_cr_tick(dt : Float32) : Void
  Labelle::Glue.tick(dt)
    rescue ex
      Labelle::Glue.log_raise("labelle_cr_tick", ex)
end

fun labelle_cr_deinit : Void
  Labelle::Glue.deinit
    rescue ex
      Labelle::Glue.log_raise("labelle_cr_deinit", ex)
end
