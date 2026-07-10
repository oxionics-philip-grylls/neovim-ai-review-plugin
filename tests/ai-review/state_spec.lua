local state = require("ai-review.state")
local batch = require("ai-review.batch")

local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

describe("ai-review.state", function()
  it("derives deterministic batch/active paths", function()
    assert.are.equal("/root/o__r__pr5.json", state.batch_path(pr, "/root"))
    assert.are.equal("/root/active.json", state.active_path("/root"))
  end)

  it("persists active + batch under a temp root and reads them back", function()
    local root = vim.fn.tempname()
    state.write_active(pr, "https://github.com/o/r/pull/5", root)
    local a = state.read_active(root)
    assert.are.equal(5, a.number)
    assert.are.equal(state.batch_path(pr, root), a.batch_path)

    local b = state.load_or_init_batch(pr, root) -- new
    assert.are.equal(0, #b.comments)
    batch.add(
      b,
      { path = "a", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "verified", body = "x" }
    )
    state.save_batch(b, root)
    local b2 = state.load_or_init_batch(pr, root) -- existing
    assert.are.equal(1, #b2.comments)
    vim.fn.delete(root, "rf")
  end)

  it("falls back to a fresh batch on corrupt JSON instead of throwing", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local fd = assert(io.open(state.batch_path(pr, root), "w"))
    fd:write("{not valid json")
    fd:close()

    local b = state.load_or_init_batch(pr, root)
    assert.are.same(pr, b.pr)
    assert.are.equal(0, #b.comments)
    vim.fn.delete(root, "rf")
  end)

  it("derives the worktree path", function()
    local wtpr = { owner = "o", repo = "r", number = 5 }
    assert.are.equal("/root/wt/o__r__pr5", state.worktree_path(wtpr, "/root"))
  end)
end)
