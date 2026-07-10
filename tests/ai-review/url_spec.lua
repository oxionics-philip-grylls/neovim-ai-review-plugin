local url = require("ai-review.url")

describe("ai-review.url", function()
  it("parses a PR URL", function()
    local r = url.parse_pr_url("https://github.com/oxionics/ionics/pull/5446")
    assert.are.same({ owner = "oxionics", repo = "ionics", number = 5446 }, r)
  end)

  it("returns nil on a non-PR URL", function()
    assert.is_nil(url.parse_pr_url("https://github.com/oxionics/ionics/issues/1"))
  end)

  it("parses https and ssh remotes, stripping .git", function()
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("https://github.com/o/r.git"))
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("git@github.com:o/r.git"))
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("https://github.com/o/r"))
  end)
end)
