local nudge = require("ai-review.nudge")

describe("ai-review.nudge.make", function()
  local function immediate_schedule(_, fn)
    fn()
  end

  it("sends the message when there are drafts", function()
    local sent = {}
    local n = nudge.make({
      delay_ms = 0,
      msg = "verify please",
      count_drafts = function()
        return 2
      end,
      send = function(m)
        sent[#sent + 1] = m
      end,
      schedule = immediate_schedule,
    })
    n.request()
    assert.are.same({ "verify please" }, sent)
  end)

  it("does not send when there are no drafts", function()
    local sent = 0
    local n = nudge.make({
      delay_ms = 0,
      msg = "x",
      count_drafts = function()
        return 0
      end,
      send = function()
        sent = sent + 1
      end,
      schedule = immediate_schedule,
    })
    n.request()
    assert.are.equal(0, sent)
  end)

  it("coalesces concurrent requests into one send", function()
    local pending
    local sent = 0
    local n = nudge.make({
      delay_ms = 0,
      msg = "x",
      count_drafts = function()
        return 1
      end,
      send = function()
        sent = sent + 1
      end,
      schedule = function(_, fn)
        pending = fn
      end, -- capture, fire manually
    })
    n.request()
    n.request() -- armed → no-op
    n.request()
    pending() -- one deferred fire
    assert.are.equal(1, sent)
  end)
end)
