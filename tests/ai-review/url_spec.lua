local url = require("ai-review.url")

describe("ai-review.url", function()
  it("parses a PR URL", function()
    local r = url.parse_pr_url("https://github.com/oxionics/ionics/pull/5446")
    assert.are.same({ owner = "oxionics", repo = "ionics", number = 5446 }, r)
  end)

  it("returns nil on a non-PR URL", function()
    assert.is_nil(url.parse_pr_url("https://github.com/oxionics/ionics/issues/1"))
  end)

  it("rejects a spoof host with github.com in the path, not the host", function()
    assert.is_nil(url.parse_pr_url("https://evil.com/github.com/o/r/pull/1"))
    assert.is_nil(url.parse_remote("https://evil.com/github.com/o/r"))
  end)

  it("parses https and ssh remotes, stripping .git", function()
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("https://github.com/o/r.git"))
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("git@github.com:o/r.git"))
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("https://github.com/o/r"))
    assert.are.same({ owner = "o", repo = "r" }, url.parse_remote("ssh://git@github.com/o/r.git"))
  end)
end)
