local sheet = require("ai-review.sheet")

describe("ai-review.sheet render", function()
  local function batch(overrides)
    local b = {
      pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" },
      verdict = nil,
      body = "",
      comments = {},
      next_id = 1,
      reviewed = {},
    }
    return vim.tbl_extend("force", b, overrides or {})
  end

  it("renders the verdict header, defaulting to COMMENT", function()
    local lines = sheet.render(batch())
    assert.are.equal("# verdict: COMMENT", lines[1])
    assert.are.equal("# verdict: APPROVE", sheet.render(batch({ verdict = "APPROVE" }))[1])
  end)

  it("renders the summary body under an @@@ summary section", function()
    local lines = sheet.render(batch({ body = "line one\nline two" }))
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("@@@ summary\nline one\nline two", 1, true))
  end)

  it("renders a comment header with anchor, kind, id and status", function()
    local lines = sheet.render(batch({
      comments = {
        {
          id = "c1",
          path = "src/foo.rs",
          side = "RIGHT",
          line = 42,
          kind = "comment",
          origin = "human",
          status = "verified",
          body = "nope",
        },
      },
    }))
    assert.is_truthy(table.concat(lines, "\n"):find("@@@ src/foo.rs:42 [comment] #c1 verified", 1, true))
  end)

  it("renders a multi-line anchor as start-end", function()
    local lines = sheet.render(batch({
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          start_line = 10,
          line = 14,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = "x",
        },
      },
    }))
    assert.is_truthy(table.concat(lines, "\n"):find("@@@ a.rs:10-14 [comment] #c1 draft", 1, true))
  end)

  it("renders a suggestion's lines as a fenced block after the body", function()
    local lines = sheet.render(batch({
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 3,
          kind = "suggestion",
          origin = "claude",
          status = "verified",
          body = "prefer this",
          suggestion = { lines = { "let x = 1;", "let y = 2;" } },
        },
      },
    }))
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("prefer this\n```suggestion\nlet x = 1;\nlet y = 2;\n```", 1, true))
  end)

  it("escapes body lines that would be mistaken for headers", function()
    -- the whole `^ *@@@` family is escaped, so the transform is a bijection
    local lines = sheet.render(batch({ body = "@@@ not a header\n  @@@ also not" }))
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("\n @@@ not a header\n", 1, true))
    assert.is_truthy(joined:find("\n   @@@ also not", 1, true))
  end)
end)

describe("ai-review.sheet parse", function()
  local function parse(text)
    return sheet.parse(vim.split(text, "\n", { plain = true }))
  end

  it("round-trips a batch through render and parse", function()
    local b = {
      pr = {},
      verdict = "REQUEST_CHANGES",
      body = "summary text",
      next_id = 3,
      reviewed = {},
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 42,
          kind = "comment",
          origin = "human",
          status = "verified",
          body = "plain body",
        },
        {
          id = "c2",
          path = "b.rs",
          side = "RIGHT",
          start_line = 10,
          line = 14,
          kind = "suggestion",
          origin = "claude",
          status = "draft",
          body = "fix it",
          suggestion = { lines = { "x = 1", "y = 2" } },
        },
      },
    }
    local parsed, err = sheet.parse(sheet.render(b))
    assert.is_nil(err)
    assert.are.equal("REQUEST_CHANGES", parsed.verdict)
    assert.are.equal("summary text", parsed.body)
    assert.are.equal(2, #parsed.entries)
    assert.are.same(
      { id = "c1", path = "a.rs", line = 42, kind = "comment", status = "verified", body = "plain body" },
      parsed.entries[1]
    )
    assert.are.equal("c2", parsed.entries[2].id)
    assert.are.equal(10, parsed.entries[2].start_line)
    assert.are.equal(14, parsed.entries[2].line)
    assert.are.equal("fix it", parsed.entries[2].body)
    assert.are.same({ "x = 1", "y = 2" }, parsed.entries[2].suggestion.lines)
  end)

  it("round-trips bodies containing markdown that could be mistaken for structure", function()
    local nasty = table.concat({
      "## a heading",
      "```lua",
      "local x = 1",
      "```",
      "<<<<<<< HEAD",
      "=======",
      ">>>>>>> other",
      "@@@ looks like a header",
      "  @@@ indented too",
      "@@ -1,2 +1,2 @@",
      "--- a/file",
    }, "\n")
    local b = {
      pr = {},
      verdict = "COMMENT",
      body = "",
      next_id = 2,
      reviewed = {},
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 1,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = nasty,
        },
      },
    }
    local parsed, err = sheet.parse(sheet.render(b))
    assert.is_nil(err)
    assert.are.equal(1, #parsed.entries)
    assert.are.equal(nasty, parsed.entries[1].body)
  end)

  it("round-trips a suggestion whose lines contain a code fence", function()
    local b = {
      pr = {},
      verdict = "COMMENT",
      body = "",
      next_id = 2,
      reviewed = {},
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 1,
          kind = "suggestion",
          origin = "human",
          status = "draft",
          body = "b",
          suggestion = { lines = { "text", "```", "more" } },
        },
      },
    }
    local parsed, err = sheet.parse(sheet.render(b))
    assert.is_nil(err)
    assert.are.equal("b", parsed.entries[1].body)
    assert.are.same({ "text", "```", "more" }, parsed.entries[1].suggestion.lines)
  end)

  it("treats an entry with no id as new, defaulting status to draft", function()
    local parsed, err = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ new.rs:7 [nit]\nbrand new")
    assert.is_nil(err)
    assert.is_nil(parsed.entries[1].id)
    assert.are.equal("draft", parsed.entries[1].status)
    assert.are.equal("new.rs", parsed.entries[1].path)
    assert.are.equal(7, parsed.entries[1].line)
  end)

  it("rejects a duplicate id", function()
    local parsed, err = parse(
      "# verdict: COMMENT\n\n@@@ summary\n\n@@@ a.rs:1 [comment] #c1 draft\nx\n\n@@@ b.rs:2 [comment] #c1 draft\ny"
    )
    assert.is_nil(parsed)
    assert.is_truthy(err:find("duplicate", 1, true))
  end)

  it("rejects an invalid or missing verdict", function()
    local _, err1 = parse("# verdict: LGTM\n\n@@@ summary\n")
    assert.is_truthy(err1:find("verdict", 1, true))
    local _, err2 = parse("@@@ summary\n")
    assert.is_truthy(err2:find("verdict", 1, true))
  end)

  it("rejects an unknown kind and a malformed header", function()
    local _, err1 = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ a.rs:1 [bogus] #c1 draft\nx")
    assert.is_truthy(err1:find("kind", 1, true))
    -- an id-less entry with no path:line cannot be anchored, and batch.validate would
    -- silently drop it on the next load, so the header grammar must reject it outright
    local _, err2 = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ no anchor here [comment]\nx")
    assert.is_truthy(err2:find("header", 1, true))
  end)

  it("reports the offending line number", function()
    local _, err = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ broken\nx")
    assert.is_truthy(err:find("line 5", 1, true))
  end)

  it("preserves trailing blank lines in entry bodies (middle and last entries)", function()
    local b = {
      pr = {},
      verdict = "COMMENT",
      body = "",
      next_id = 3,
      reviewed = {},
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 1,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = "line1\n\n",
        },
        {
          id = "c2",
          path = "b.rs",
          side = "RIGHT",
          line = 2,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = "line2\n",
        },
      },
    }
    local parsed, err = sheet.parse(sheet.render(b))
    assert.is_nil(err)
    assert.are.equal("line1\n\n", parsed.entries[1].body)
    assert.are.equal("line2\n", parsed.entries[2].body)
  end)

  it("requires a status word when an id is present, defaults to draft when id is absent", function()
    local _, err1 = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ a.rs:1 [comment] #c1\nx")
    assert.is_truthy(err1:find("status", 1, true))

    local _, err2 = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ a.rs:1 [comment] #c1 bogus\nx")
    assert.is_truthy(err2:find("status", 1, true))

    local parsed, err3 = parse("# verdict: COMMENT\n\n@@@ summary\n\n@@@ a.rs:1 [comment]\nx")
    assert.is_nil(err3)
    assert.are.equal("draft", parsed.entries[1].status)
  end)

  it("does not split suggestions for non-suggestion entries", function()
    local b = {
      pr = {},
      verdict = "COMMENT",
      body = "",
      next_id = 2,
      reviewed = {},
      comments = {
        {
          id = "c1",
          path = "a.rs",
          side = "RIGHT",
          line = 1,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = "body\n```suggestion\nsuggestion content\n```\nmore body",
        },
      },
    }
    local parsed, err = sheet.parse(sheet.render(b))
    assert.is_nil(err)
    assert.are.equal("body\n```suggestion\nsuggestion content\n```\nmore body", parsed.entries[1].body)
    assert.is_nil(parsed.entries[1].suggestion)
  end)
end)

describe("ai-review.sheet apply", function()
  local batch = require("ai-review.batch")

  local function seeded()
    local b = batch.new({ owner = "o", repo = "r", number = 5, base = "m", head_sha = "abc" })
    batch.add(b, {
      path = "a.rs",
      side = "RIGHT",
      line = 1,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "first",
    })
    batch.add(
      b,
      { path = "b.rs", side = "LEFT", line = 2, kind = "comment", origin = "claude", status = "draft", body = "second" }
    )
    return b
  end

  it("updates bodies by id and preserves side and origin", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[1].body = "edited"
    local dropped, err = sheet.apply(b, parsed)
    assert.is_nil(err)
    assert.are.equal(0, dropped)
    assert.are.equal("edited", b.comments[1].body)
    assert.are.equal("RIGHT", b.comments[1].side) -- side isn't in the sheet; must survive
    assert.are.equal("claude", b.comments[2].origin)
    assert.are.equal("LEFT", b.comments[2].side)
  end)

  it("writes the sheet's verdict and summary body onto the batch", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.verdict, parsed.body = "APPROVE", "my summary"
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    assert.are.equal("APPROVE", b.verdict)
    assert.are.equal("my summary", b.body)
  end)

  it("records the sheet's anchor so Claude has the author's intent to correct", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[1].path, parsed.entries[1].line = "moved.rs", 99
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    assert.are.equal("moved.rs", b.comments[1].path)
    assert.are.equal(99, b.comments[1].line)
  end)

  it("drops entries whose section was deleted, reporting the count", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    table.remove(parsed.entries, 1)
    local dropped, err = sheet.apply(b, parsed)
    assert.is_nil(err)
    assert.are.equal(1, dropped)
    assert.are.equal(1, #b.comments)
    assert.are.equal("c2", b.comments[1].id)
  end)

  it("adds an id-less entry as a fresh human draft with a new id", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[#parsed.entries + 1] =
      { path = "new.rs", line = 8, kind = "nit", status = "draft", body = "new one" }
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    local added = b.comments[#b.comments]
    assert.are.equal("c3", added.id)
    assert.are.equal("human", added.origin)
    assert.are.equal("RIGHT", added.side)
    assert.are.equal("new.rs", added.path)
  end)

  it("keeps the sheet's ordering", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[1], parsed.entries[2] = parsed.entries[2], parsed.entries[1]
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    assert.are.equal("c2", b.comments[1].id)
    assert.are.equal("c1", b.comments[2].id)
  end)

  it("refuses an unknown id and leaves the batch untouched", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[1].id = "c99"
    local dropped, err = sheet.apply(b, parsed)
    assert.is_nil(dropped)
    assert.is_truthy(err:find("c99", 1, true))
    assert.are.equal(2, #b.comments) -- unchanged
    assert.are.equal("first", b.comments[1].body)
  end)

  it("preserves verified_sha on a suggestion whose lines are untouched", function()
    local b = batch.new({ owner = "o", repo = "r", number = 5, base = "m", head_sha = "abc" })
    batch.add(b, {
      path = "a.rs",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "fix",
      suggestion = { lines = { "let x = 1;" }, verified_sha = "abc123" },
    })
    local parsed = sheet.parse(sheet.render(b))
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    assert.are.equal("abc123", b.comments[1].suggestion.verified_sha)
    assert.are.same({ "let x = 1;" }, b.comments[1].suggestion.lines)
  end)

  it("drops verified_sha when the suggestion's lines were edited", function()
    local b = batch.new({ owner = "o", repo = "r", number = 5, base = "m", head_sha = "abc" })
    batch.add(b, {
      path = "a.rs",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "fix",
      suggestion = { lines = { "let x = 1;" }, verified_sha = "abc123" },
    })
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[1].suggestion.lines = { "let x = 2;" }
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    assert.is_nil(b.comments[1].suggestion.verified_sha)
    assert.are.same({ "let x = 2;" }, b.comments[1].suggestion.lines)
  end)

  it("gives a new id-less suggestion entry no verified_sha", function()
    local b = seeded()
    local parsed = sheet.parse(sheet.render(b))
    parsed.entries[#parsed.entries + 1] = {
      path = "new.rs",
      line = 8,
      kind = "suggestion",
      status = "draft",
      body = "new one",
      suggestion = { lines = { "let z = 3;" } },
    }
    assert.is_nil(select(2, sheet.apply(b, parsed)))
    local added = b.comments[#b.comments]
    assert.is_nil(added.suggestion.verified_sha)
  end)
end)

describe("ai-review.sheet anchor_at", function()
  local lines = vim.split(
    "# verdict: COMMENT\n\n@@@ summary\ntext\n\n@@@ a.rs:42 [comment] #c1 draft\nbody\nmore\n\n@@@ b.rs:10-14 [comment] #c2 draft\nx",
    "\n",
    { plain = true }
  )

  it("finds the anchor of the entry the cursor is inside", function()
    assert.are.same({ path = "a.rs", line = 42 }, sheet.anchor_at(lines, 6)) -- on the header
    assert.are.same({ path = "a.rs", line = 42 }, sheet.anchor_at(lines, 8)) -- in the body
    assert.are.same({ path = "b.rs", line = 14 }, sheet.anchor_at(lines, 11))
  end)

  it("returns nil above the first entry and in the summary", function()
    assert.is_nil(sheet.anchor_at(lines, 1))
    assert.is_nil(sheet.anchor_at(lines, 4)) -- inside @@@ summary
  end)
end)
