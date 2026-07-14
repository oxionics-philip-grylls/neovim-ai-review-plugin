local nudge = require("ai-review.nudge")

describe("ai-review.nudge.pick_pane", function()
  it("picks the claude pane", function()
    assert.are.equal("%2", nudge.pick_pane("%1 nvim\n%2 claude\n"))
  end)
  it("returns nil for a non-claude pane — no guessing at an unrelated process", function()
    assert.is_nil(nudge.pick_pane("%1 nvim\n%3 node\n"))
  end)
  it("returns nil when only nvim/shells are present", function()
    assert.is_nil(nudge.pick_pane("%1 nvim\n%2 fish\n"))
  end)
end)

describe("ai-review.nudge.nudge_cmd", function()
  it("builds the send-keys command", function()
    assert.are.same({ "tmux", "send-keys", "-t", "%2", "hi", "Enter" }, nudge.nudge_cmd("%2", "hi"))
  end)
end)

describe("ai-review.nudge.make", function()
  local function harness(drafts, pane)
    local fired, sends = {}, {}
    local n = nudge.make({
      delay_ms = 1500,
      msg = "verify drafts",
      count_drafts = function()
        return drafts
      end,
      find_pane = function()
        return pane
      end,
      send = function(cmd)
        sends[#sends + 1] = cmd
      end,
      schedule = function(_, fn)
        fired[#fired + 1] = fn
      end, -- capture, don't run
    })
    return n, fired, sends
  end

  it("coalesces N rapid requests into one scheduled fire → one send", function()
    local n, fired, sends = harness(2, "%2")
    n.request()
    n.request()
    n.request()
    assert.are.equal(1, #fired) -- armed once
    fired[1]() -- fire the timer
    assert.are.equal(1, #sends)
    assert.are.same({ "tmux", "send-keys", "-t", "%2", "verify drafts", "Enter" }, sends[1])
  end)

  it("does not send when there are no drafts", function()
    local n, fired, sends = harness(0, "%2")
    n.request()
    fired[1]()
    assert.are.equal(0, #sends)
  end)

  it("does not send when no pane is found", function()
    local n, fired, sends = harness(3, nil)
    n.request()
    fired[1]()
    assert.are.equal(0, #sends)
  end)

  it("re-arms after firing", function()
    local n, fired, sends = harness(1, "%2")
    n.request()
    fired[1]()
    n.request()
    fired[2]()
    assert.are.equal(2, #sends)
  end)
end)
