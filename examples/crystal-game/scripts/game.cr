# scripts/game.cr — the game's module root (labelle-engine#741,
# native-compiled family; `scripts/` is the shared convention dir every
# script language uses since labelle-engine#237 / assembler v0.86.0):
# at `labelle generate` the assembler LINKS this whole `scripts/` dir
# over the scripting plugin's staged `native-crystal/src/game/`, the
# plugin's declared `.language_builds` steps compile it (`crystal build
# --cross-compile`) and localize its `main` away (ld -r on macOS,
# objcopy on linux — picked by the steps' `.os` allowlists), and the
# game binary links the resulting `labelle_crystal_scripts_lib.o` — the
# `labelle_*` contract symbols resolve against the host's exports in
# the same binary. No VM, nothing embeds; `Game.register` below is the
# one convention entry point (`scripts/game.cr` IS the module root —
# the native family's fixed name, where ruby uses ordering prefixes).
#
# The game mirrors examples/rust-game token-for-token (which mirrors
# examples/ruby-game) so the cross-language story is visible by eye:
# same Hunger/Worker component shapes (crystal-DECLARED here —
# components/*.cr, like the ruby game declares them in ruby), same
# command-event (events/hunger__feed.cr), same native Zig hook
# (hooks/feed_watcher.zig) — only the script layer swaps rust for
# crystal (and ruby's transcript carries one extra token, its pure-ruby
# feed-watcher's). Registration order stands in for ruby's two tiers: the
# spawner registers FIRST (its `init` seeds the world before the
# system's, its `update` runs before the system's each tick) and
# `deinit` runs in REVERSE registration order, so the system tears down
# first — the same interleaving rust spelled with Box registration.
#
# Tokens carry BEHAVIOR: every tick logs the freshly written level, so
# the pinned sequence encodes the whole decay-feed-decay sawtooth
# through the real ECS. All values are exact in binary floating point
# at every width en route (0.875 start, 0.25 steps, 0.5 feed), so the
# logged decimals are deterministic (crystal's Float32 interpolation
# prints the shortest round-trip decimal — "0.625", never a float
# artifact). Decay is 0.25 PER TICK, not `DECAY * dt` — the null
# backend's fixed dt is f32(1.0/60.0), which no decimal-exact multiple
# survives, and exact values in the tokens are the point.
#
# Frame-by-frame, as OBSERVED headless (LABELLE_NULL_FRAMES=5; per
# frame the plugin Controller runs: inbox dispatch (`on_event`s) →
# `update`s, both in registration order — crystal's glue drives
# `labelle_cr_dispatch_inbox` then `labelle_cr_tick`, the same
# interleaving rust's transcript pinned):
#
#   setup   CRYSTAL_INIT             (spawner init: worker seeded at 0.875)
#           CRYSTAL_CTRL_READY       hunger system init (after the spawner's)
#   tick 1  CRYSTAL_LEVEL_0.625      0.875 - 0.25 decay, written back
#   tick 2  CRYSTAL_FEED_SENT        (spawner update: emits hunger__feed)
#           CRYSTAL_LEVEL_0.375      0.625 - 0.25 — tick 1's write PERSISTED
#           ZIG_FEED_SEEN_0.5        (hooks/feed_watcher.zig — the native
#                                     subscriber, at THIS frame's
#                                     dispatchEvents: frame end, after the
#                                     Controller tick, one tick BEFORE the
#                                     crystal handler's inbox — the
#                                     cross-layer latency is part of the pin)
#   tick 3  CRYSTAL_ENGINE_TICK_SEEN (spawner's builtin sub, same inbox)
#           CRYSTAL_FED_LEVEL_0.875  inbox: feed handler ran — id + exact
#                                     f32 0.5 amount round-tripped the bus;
#                                     0.375 + 0.5 re-read AFTER the write
#           CRYSTAL_LEVEL_0.625      0.875 - 0.25 — decay resumes on the fed
#   tick 4  CRYSTAL_LEVEL_0.375
#   tick 5  CRYSTAL_LEVEL_0.125
#           CRYSTAL_STARVING         0.125 <= 0.25 crossed the threshold
#           CRYSTAL_BUFFERS_OK       warmed reused Labelle::Buffers never
#                                     grew — the grow-once discipline
#                                     (gc_churn.cr's pin, rehearsed over a
#                                     real game frame)
#           CRYSTAL_BATCH_OK_3_13.5   the batched swarm (scripts/swarm.cr):
#                                     3 boids × 5 ticks of x += 0.5 through
#                                     ONE batch_get + ONE batch_set per
#                                     tick (contract v1.3 — engine ≥ 2.6.0)
#   deinit  CRYSTAL_CTRL_DONE        hunger system (reverse registration)
#           CRYSTAL_DEINIT           spawner
#
# Why the one-frame latencies: script-contract subscriptions activate
# at drain boundaries (no same-tick replay) and drained entries reach
# `on_event` on the NEXT tick's inbox dispatch — see
# labelle-engine/src/script_contract.zig "Event tap semantics".

require "./hunger"
require "./spawner"
require "./swarm"

module Game
  # The game registration entry point (the game's `scripts/game.cr`,
  # staged as `native-crystal/src/game/game.cr` — see the plugin
  # README's crystal section). Registration order is hook order;
  # `deinit` runs reversed.
  def self.register(scripts : Labelle::Scripts) : Nil
    scripts.add "spawner", Spawner.new
    scripts.add "hunger", HungerSystem.new
    # The bulk-access swarm (contract v1.3, labelle-scripting#44) —
    # registers LAST so its per-tick token lands after the hunger
    # system's; see scripts/swarm.cr for the batch-block story.
    scripts.add "swarm", Swarm.new
  end

  # ── Shared payload parsing ──────────────────────────────────────────
  #
  # Scripts own their payload parsing (contract payloads are small, flat
  # JSON; a structured serde story is future work). Needles are
  # pre-quoted literals (`%("level":)`) and both helpers walk raw Bytes
  # (`Buffer#to_slice`, `String#to_slice`) so the hot path never
  # allocates a String — no float ever touches an entity id (UInt64 end
  # to end; a bit-63 id survives exactly).

  # The unsigned integer after `needle` (e.g. `%("entity":)`), or nil.
  # Tolerates a string-encoded id (`"entity":"123"`): dynamic-language
  # emitters that can't hold u64 precision natively spell ids as JSON
  # strings, and an exemplar parser should read both spellings.
  def self.u64_field(json : Bytes, needle : String) : UInt64?
    i = skip_to_value(json, needle)
    return nil unless i
    i += 1 if i < json.size && json[i] == 0x22 # '"' — string-encoded id
    val = 0_u64
    any = false
    while i < json.size && 48 <= json[i] <= 57
      val = val &* 10 &+ (json[i] - 48)
      any = true
      i += 1
    end
    any ? val : nil
  end

  # The float after `needle` (e.g. `%("level":)`), or nil. Slices the
  # numeric token (digits, sign, dot, exponent — whatever spelling the
  # host's encoder picked) and hands it to crystal's own Float32 parser,
  # which rounds to nearest — exact for every value this game touches.
  # The one String this module allocates: floats ride VALUES, never the
  # per-tick id lists, so the copy is a few bytes on event paths only.
  def self.f32_field(json : Bytes, needle : String) : Float32?
    start = skip_to_value(json, needle)
    return nil unless start
    finish = start
    while finish < json.size && numeric_byte?(json[finish])
      finish += 1
    end
    return nil if finish == start
    String.new(json[start, finish - start]).to_f32?
  end

  private def self.numeric_byte?(b : UInt8) : Bool
    case b
    when 48..57, 0x2d, 0x2b, 0x2e, 0x65, 0x45 then true # 0-9 - + . e E
    else                                           false
    end
  end

  # Index of the first value byte after `needle` (skipping any JSON
  # whitespace, not just the encoder-side space — a pretty-printed
  # payload is legal JSON too), or nil when absent.
  private def self.skip_to_value(json : Bytes, needle : String) : Int32?
    nb = needle.to_slice
    return nil if nb.empty? || json.size < nb.size
    at : Int32? = nil
    (0..json.size - nb.size).each do |i|
      if json[i, nb.size] == nb
        at = i
        break
      end
    end
    return nil unless at
    i = at + nb.size
    while i < json.size && json[i].unsafe_chr.ascii_whitespace?
      i += 1
    end
    i
  end
end
