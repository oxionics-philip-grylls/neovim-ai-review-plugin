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
end)
