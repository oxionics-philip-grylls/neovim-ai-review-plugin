local gh = require("ai-review.gh")

describe("ai-review.gh command builders", function()
  it("builds the pr-info command", function()
    assert.are.same(
      { "gh", "pr", "view", "5", "--repo", "o/r", "--json", "baseRefName,headRefOid" },
      gh.pr_info_cmd("o", "r", 5)
    )
  end)

  it("builds the fetch-head command", function()
    assert.are.same({ "git", "fetch", "origin", "pull/5/head" }, gh.fetch_head_cmd(5))
  end)

  it("builds the post-review command", function()
    assert.are.same(
      { "gh", "api", "repos/o/r/pulls/5/reviews", "--method", "POST", "--input", "/tmp/x.json" },
      gh.post_review_cmd("o", "r", 5, "/tmp/x.json")
    )
  end)

  it("builds worktree add/remove/prune commands", function()
    assert.are.same(
      { "git", "worktree", "add", "-B", "review/pr-5-suggestions", "/wt/x", "deadbeef" },
      gh.worktree_add_cmd("/wt/x", "review/pr-5-suggestions", "deadbeef")
    )
    assert.are.same({ "git", "worktree", "remove", "--force", "/wt/x" }, gh.worktree_remove_cmd("/wt/x"))
    assert.are.same({ "git", "worktree", "prune" }, gh.worktree_prune_cmd())
    assert.are.same({ "git", "-C", "/wt/x", "rev-parse", "HEAD" }, gh.worktree_head_cmd("/wt/x"))
  end)
end)
