# Bulk-component-access scenarios (contract v1.3, labelle-scripting#44)
# — the crystal mirror of the ruby suite's "bulk v1.3" / "bulk stage 2"
# coverage (and the rust suite's bulk.rs twin), driven by
# tests/crystal_suite.zig against the mock world's packed schema table
# (Stats / BatchPos / BatchVel; "Plain" plays the non-packable
# component).
#
# Scripts assert their own invariants by RAISING (the glue contains it
# and the expected log token never lands); the Zig side asserts the
# world (stored JSON key order proves which codec path wrote — packed
# writes SCHEMA order, the JSON fallback sorts).

Labelle.packed_view StatsView, "Stats", {power: f32, score: i64, alive: bool, seed: u64}
Labelle.packed_view PlainView, "Plain", {a: f32}
Labelle.batch_view PosView, "BatchPos", {x: f32, y: f32}
Labelle.batch_view VelView, "BatchVel", {vx: f32, vy: f32}
# A batch view whose declared stride DISAGREES with the host stream:
# "Plain" has no packed schema, so it contributes ZERO stream floats
# (the mock's stand-in for a non-scalar component) while this view
# declares one — the cross-check must refuse, never mis-map.
Labelle.batch_view PlainStreamView, "Plain", {a: f32}

module BulkUtil
  def self.set_json(id : Labelle::EntityId, name : String, json : String) : Nil
    raise "set #{name} failed" unless Labelle.set_component(id, name, json)
  end
end

# ── scenario "bulk_packed": the per-component packed codec ─────────────

class PackedRt < Labelle::Script
  @scratch = Labelle::Buffer.new

  def init : Nil
    # Entity 1: every packed scalar kind survives the binary round-trip
    # (f32 / i64 / bool / u64).
    e1 = Labelle.create_entity
    s = StatsView.new
    s.power = 1.5_f32
    s.score = -42_i64
    s.alive = true
    s.seed = 123_u64
    raise "packed set refused" unless Labelle.set_from(e1, s)
    s2 = StatsView.new
    raise "packed get_into failed" unless Labelle.get_into(e1, s2, @scratch)
    Labelle.log("crystal: packed:#{s2.power}:#{s2.score}:#{s2.alive}:#{s2.seed}")

    # The schema-less component still round-trips — through JSON
    # (set_packed -1 / get_packed 0xFF), invisibly to the script.
    p = PlainView.new
    p.a = 2.5_f32
    raise "plain set refused" unless Labelle.set_from(e1, p)
    p2 = PlainView.new
    raise "plain get_into failed" unless Labelle.get_into(e1, p2, @scratch)
    Labelle.log("crystal: plain:#{p2.a}")

    # JSON-fallback coercion (round 1): a whole-number float is spelled
    # `2` by the host's serializer — an int-class token — and must
    # still land in the f32 view field on the fallback path.
    raise "int set failed" unless Labelle.set_component(e1, "Plain", %({"a":2}))
    p3 = PlainView.new
    raise "plain int get_into failed" unless Labelle.get_into(e1, p3, @scratch)
    Labelle.log("crystal: plain int:#{p3.a}")

    # Whole-number set_from -> get_into round trip (crystal's own
    # encoder spells 3.0 with the ".0", but the host may re-serialize
    # integrally — either spelling must land).
    whole = PlainView.new
    whole.a = 3.0_f32
    raise "whole set refused" unless Labelle.set_from(e1, whole)
    p4 = PlainView.new
    raise "whole get_into failed" unless Labelle.get_into(e1, p4, @scratch)
    Labelle.log("crystal: plain whole:#{p4.a}")

    # Entity 2: crystal has a REAL UInt64, so a bit-63 seed rides tag 3
    # bit-exact — no signed detour.
    e2 = Labelle.create_entity
    big = StatsView.new
    big.seed = 0x8000000000000001_u64
    raise "u64 set refused" unless Labelle.set_from(e2, big)
    b2 = StatsView.new
    raise "u64 get_into failed" unless Labelle.get_into(e2, b2, @scratch)
    Labelle.log("crystal: u64rt:#{b2.seed == 0x8000000000000001_u64}")

    # Entity 3: the non-finite policy — NaN refuses up front (parity
    # with this family's hand-written-JSON route, where NaN has no
    # spelling and the host would refuse the parse); nothing is stored.
    e3 = Labelle.create_entity
    nan = StatsView.new
    nan.power = Float32::NAN
    Labelle.log("crystal: nan_refused:#{!Labelle.set_from(e3, nan)}")

    # An absent component answers false through BOTH routes.
    absent = StatsView.new
    Labelle.log("crystal: absent:#{!Labelle.get_into(e3, absent, @scratch)}")
  end
end

# ── scenario "bulk_batch": the raw flat-loop tier + loud refusals ──────

class BatchFlat < Labelle::Script
  NAMES = %(["BatchPos","BatchVel"])

  @buf = [] of Float32
  @scratch = Labelle::Buffer.new
  @tick = 0

  def init : Nil
    3.times do |i|
      e = Labelle.create_entity
      BulkUtil.set_json(e, "BatchPos", %({"x":#{i + 1},"y":0}))
      BulkUtil.set_json(e, "BatchVel", %({"vx":10,"vy":-10}))
    end
    lone = Labelle.create_entity
    BulkUtil.set_json(lone, "BatchPos", %({"x":7,"y":8}))

    # Int-carrying components refuse LOUDLY — never a silent coercion
    # through f32's 24-bit mantissa.
    begin
      Labelle.batch_get(%(["BatchPos","Stats"]), @buf, @scratch)
      Labelle.log("crystal: get refusal missed")
    rescue ArgumentError
      Labelle.log("crystal: get int refused:true")
    end
    begin
      Labelle.batch_set(%(["Stats"]), [1.0_f32, 2.0_f32, 3.0_f32, 4.0_f32], 1, @scratch)
      Labelle.log("crystal: set refusal missed")
    rescue ArgumentError
      Labelle.log("crystal: set int refused:true")
    end

    # Non-finite refusal at the BINDING (#45): a NaN/Inf stream element
    # refuses BEFORE any host write. A finite Float32 overflow (MAX
    # doubled → INFINITY) is the "1e100 narrows to inf" smuggle in an
    # f32-native binding, and lands on the same refusal.
    begin
      Labelle.batch_set(NAMES, [1.0_f32, Float32::NAN, 2.0_f32, 3.0_f32], 1, @scratch)
      Labelle.log("crystal: set nan missed")
    rescue ArgumentError
      Labelle.log("crystal: set nan refused:true")
    end
    begin
      Labelle.batch_set(NAMES, [1.0_f32, 2.0_f32, Float32::MAX * 2.0_f32, 3.0_f32], 1, @scratch)
      Labelle.log("crystal: set overflow missed")
    rescue ArgumentError
      Labelle.log("crystal: set overflow refused:true")
    end
  end

  def update(dt : Float32) : Nil
    @tick += 1
    count = Labelle.batch_get(NAMES, @buf, @scratch)
    Labelle.log("crystal: batch count:#{count} floats:#{@buf.size}") if @tick == 1
    i = 0
    while i < count
      b = i * 4
      @buf[b] += @buf[b + 2]     # x += vx
      @buf[b + 1] += @buf[b + 3] # y += vy
      i += 1
    end
    Labelle.batch_set(NAMES, @buf, count, @scratch)
  end
end

# ── scenario "bulk_stale": the id-tagged destroy+spawn skip (v1.4) ──────

class BatchStale < Labelle::Script
  @es = [] of Labelle::EntityId
  @buf = [] of Float32
  @scratch = Labelle::Buffer.new

  def init : Nil
    2.times do |i|
      e = Labelle.create_entity
      BulkUtil.set_json(e, "BatchPos", %({"x":#{i},"y":0}))
      BulkUtil.set_json(e, "BatchVel", %({"vx":1,"vy":1}))
      @es << e
    end
  end

  def update(dt : Float32) : Nil
    Labelle.batch_get(BatchFlat::NAMES, @buf, @scratch)
    # Rewrite every field to a distinctive marker.
    @buf.each_index { |k| @buf[k] = (100 + k).to_f32 }
    # The same-count destroy+spawn between the paired calls: the id path
    # skips the dead row rather than shifting it onto the new entity that
    # takes the query slot (which the positional variant would have done).
    Labelle.destroy_entity(@es[1])
    fresh = Labelle.create_entity
    BulkUtil.set_json(fresh, "BatchPos", %({"x":7,"y":8}))
    BulkUtil.set_json(fresh, "BatchVel", %({"vx":9,"vy":9}))
    begin
      Labelle.batch_set(BatchFlat::NAMES, @buf, 2, @scratch)
      Labelle.log("crystal: id-batch accepted")
    rescue ex : Labelle::BatchError
      Labelle.log("crystal: id-batch refused: #{ex.message}")
    end
  end
end

# ── scenario "bulk_iter": the typed block tier (steady state) ──────────

class BatchIter < Labelle::Script
  def init : Nil
    3.times do |i|
      e = Labelle.create_entity
      BulkUtil.set_json(e, "BatchPos", %({"x":#{i + 1},"y":0}))
      BulkUtil.set_json(e, "BatchVel", %({"vx":10,"vy":-10}))
    end
  end

  def update(dt : Float32) : Nil
    n = Labelle.batch(PosView, VelView) do |p, v|
      p.x += v.vx
      p.y += v.vy
      v.vx = -v.vx if p.x > 12.0_f32 # bounce entity 3 (x reaches 13)
    end
    Labelle.log("crystal: iter n:#{n}")
  end
end

# ── scenario "bulk_iter_edge": exit semantics + refusals ───────────────

class BatchIterEdge < Labelle::Script
  def init : Nil
    # Empty query FIRST (no entities yet): 0, block untouched.
    n = Labelle.batch(PosView, VelView) do |_p, _v|
      Labelle.log("crystal: empty ran")
    end
    Labelle.log("crystal: empty n:#{n}")

    3.times do |i|
      e = Labelle.create_entity
      BulkUtil.set_json(e, "BatchPos", %({"x":#{i + 1},"y":0}))
      BulkUtil.set_json(e, "BatchVel", %({"vx":0,"vy":0}))
    end

    # BREAK COMMITS: stop after the first entity — its write (x += 10,
    # already in the write-through buffer) flushes through the one
    # batch_set; not-yet-yielded entities round-trip unchanged.
    # `break value` becomes the call's value.
    r = Labelle.batch(PosView, VelView) do |p, _v|
      p.x += 10.0_f32
      break :halted
    end
    Labelle.log("crystal: break r:#{r.inspect}")

    # A RAISING block abandons the whole write: batch_set never runs,
    # so the mutation before the raise is not applied (all-or-nothing).
    begin
      Labelle.batch(PosView, VelView) do |p, _v|
        p.x = 999.0_f32
        raise "boom"
      end
      Labelle.log("crystal: raise swallowed")
    rescue ex
      Labelle.log("crystal: block raised: #{ex.message}")
    end

    # DUPLICATE COMPONENT NAMES: two copies of the same fields per row
    # would let the unchanged copy overwrite the other's writes —
    # refused before any host call, nothing written.
    begin
      Labelle.batch(PosView, PosView) do |p, _q|
        p.x = 555.0_f32
      end
      Labelle.log("crystal: dup accepted")
    rescue ex : ArgumentError
      Labelle.log("crystal: dup refused: #{ex.message}")
    end

    # NESTED batch calls alias the shared stream buffer — refused.
    begin
      Labelle.batch(PosView) do |_p|
        Labelle.batch(PosView) { |_q| }
      end
      Labelle.log("crystal: nested accepted")
    rescue ex : Labelle::BatchError
      Labelle.log("crystal: nested refused: #{ex.message}")
    end

    # LAYOUT MISMATCH: "Plain" contributes zero stream floats while the
    # typed view declares one — refused before any yield.
    e = Labelle.create_entity
    BulkUtil.set_json(e, "BatchPos", %({"x":50,"y":0}))
    BulkUtil.set_json(e, "Plain", %({"a":2.5}))
    begin
      Labelle.batch(PosView, PlainStreamView) do |_p, _q|
        Labelle.log("crystal: mismatch ran")
      end
      Labelle.log("crystal: mismatch accepted")
    rescue ex : Labelle::BatchError
      Labelle.log("crystal: mismatch refused: #{ex.message}")
    end
  end
end
