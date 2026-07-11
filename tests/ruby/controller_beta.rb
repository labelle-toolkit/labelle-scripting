# controller_beta.rb — second-registered controllers: Beta pins setup /
# teardown ordering against Alpha (setup after, teardown BEFORE — LIFO),
# and Gamma pins controller-level eviction: a raising setup drops that
# controller (no tick, no teardown) without touching its siblings or its
# script's plain hooks.

def init
  Labelle.log("beta init")
end

def update(dt)
  # Plain hook sibling: must keep running even though Gamma's setup blew.
  @updates = (@updates || 0) + 1
end

def deinit
  Labelle.log("beta deinit ran #{@updates || 0}")
end

class BetaController < Labelle::Controller
  def setup
    log("beta setup")
    on("order__ping") { |_ev| log("beta handler ran") }
  end

  def teardown
    log("beta teardown")
  end
end

class GammaController < Labelle::Controller
  def setup
    raise "gamma setup boom"
  end

  def tick(_dt)
    log("gamma ticked")
  end

  def teardown
    log("gamma teardown")
  end
end
