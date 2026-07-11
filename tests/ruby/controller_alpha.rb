# controller_alpha.rb — first-registered controller for the lifecycle
# order test (this script registers before controller_beta.rb, the
# file-prefix ordering the generated registerScript calls encode).

def init
  Labelle.log("alpha init")
end

class AlphaController < Labelle::Controller
  def setup
    @e = Labelle::Entity.create
    @e.set("AlphaTicks", n: 0)
    log("alpha setup")
  end

  def tick(dt)
    t = @e.get("AlphaTicks")
    t[:n] += 1
    t[:dt] = dt
    @e.set("AlphaTicks", t)
  end

  def teardown
    log("alpha teardown")
  end
end
