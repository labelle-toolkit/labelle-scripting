# The raise pins: crystal's error-handling story at the FFI boundary.
# An exception MUST NOT unwind across the C seam (crystal finds no
# handler in the host's foreign frames and kills the process — "Failed
# to raise an exception: END_OF_STACK") — the glue's begin/rescue at
# every entry point and around every hook is what these scripts exist
# to trip, tick after tick.

# `update` raises every tick: logged EVERY time, never evicted (state
# is intact — the author gets the report until it's fixed), siblings
# unaffected. The embedded-family analog of a lua error() in update.
class Exploder < Labelle::Script
  def update(dt : Float32) : Nil
    raise "boom on tick"
  end
end

# `init` raises: the script is EVICTED — its update/deinit must never
# run against half-initialized state. Mirrors the lua suite's "a script
# whose init() errors is evicted from update and deinit".
class BadInit < Labelle::Script
  def init : Nil
    raise "bad_init boom"
  end

  def update(dt : Float32) : Nil
    Labelle.log("bad_init update ran")
  end

  def deinit : Nil
    Labelle.log("bad_init deinit ran")
  end
end
