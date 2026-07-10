local dp = require("ai-review.diffparse")

describe("ai-review.diffparse", function()
  it("parses a replace hunk (U0)", function()
    local diff = table.concat({
      "diff --git a/f.txt b/f.txt",
      "index 111..222 100644",
      "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -2,1 +2,1 @@",
      "-old line 2",
      "+new line 2",
    }, "\n")
    local h = dp.parse(diff)
    assert.are.equal(1, #h)
    assert.are.equal(2, h[1].old_start)
    assert.are.equal(1, h[1].old_count)
    assert.are.same({ "new line 2" }, h[1].new_lines)
  end)

  it("maps a replace hunk to a RIGHT-anchored entry", function()
    local e = dp.to_entry({ old_start = 2, old_count = 1, new_lines = { "new line 2" } })
    assert.are.equal("RIGHT", e.side)
    assert.are.equal(2, e.start_line)
    assert.are.equal(2, e.line)
    assert.are.same({ "new line 2" }, e.suggestion.lines)
  end)

  it("maps a multi-line replace to the right range", function()
    local e = dp.to_entry({ old_start = 5, old_count = 3, new_lines = { "a", "b" } })
    assert.are.equal(5, e.start_line)
    assert.are.equal(7, e.line) -- 5 + 3 - 1
  end)

  it("parses multiple hunks", function()
    local diff = table.concat({
      "@@ -1,1 +1,1 @@",
      "-a",
      "+A",
      "@@ -4,0 +5,2 @@",
      "+x",
      "+y",
    }, "\n")
    local h = dp.parse(diff)
    assert.are.equal(2, #h)
    assert.are.equal(0, h[2].old_count) -- pure insertion
    assert.are.same({ "x", "y" }, h[2].new_lines)
  end)

  it("returns nil entry for a pure insertion (staging handles it)", function()
    assert.is_nil(dp.to_entry({ old_start = 4, old_count = 0, new_lines = { "x" } }))
  end)

  it("returns no hunks for an empty diff", function()
    assert.are.same({}, dp.parse(""))
  end)

  it("defaults old_count to 1 when the hunk header omits the count", function()
    local diff = table.concat({
      "@@ -5 +5,2 @@",
      "-old",
      "+new1",
      "+new2",
    }, "\n")
    local h = dp.parse(diff)
    assert.are.equal(1, h[1].old_count)
  end)

  it("preserves a ++-prefixed content line instead of dropping it", function()
    local diff = table.concat({
      "@@ -2,1 +2,1 @@",
      "-old line 2",
      "+++counter;", -- diff marker '+' followed by content '++counter;'
    }, "\n")
    local h = dp.parse(diff)
    assert.are.same({ "++counter;" }, h[1].new_lines)
  end)

  it("resets the current hunk at a file boundary so the next file's +++ header isn't collected", function()
    local diff = table.concat({
      "diff --git a/x b/x",
      "index 111..222 100644",
      "--- a/x",
      "+++ b/x",
      "@@ -1,1 +1,1 @@",
      "-old x",
      "+new x",
      "diff --git a/y b/y",
      "index 333..444 100644",
      "--- a/y",
      "+++ b/y",
      "@@ -1,1 +1,1 @@",
      "-old y",
      "+new y",
    }, "\n")
    local h = dp.parse(diff)
    assert.are.equal(2, #h)
    assert.are.same({ "new x" }, h[1].new_lines)
    assert.are.same({ "new y" }, h[2].new_lines)
  end)
end)
