local batch = require("ai-review.batch")

describe("ai-review.batch", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("creates an empty batch for a PR", function()
    local b = batch.new(pr)
    assert.are.same(pr, b.pr)
    assert.are.equal(0, #b.comments)
    assert.is_nil(b.verdict)
  end)

  it("adds entries with sequential ids and counts drafts", function()
    local b = batch.new(pr)
    local id1 = batch.add(
      b,
      { path = "a.rs", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "verified", body = "x" }
    )
    local id2 = batch.add(b, {
      path = "a.rs",
      side = "RIGHT",
      line = 2,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "y",
      suggestion = { lines = { "z" } },
    })
    assert.are.equal("c1", id1)
    assert.are.equal("c2", id2)
    assert.are.equal(1, batch.count_drafts(b))
  end)

  it("round-trips through encode/decode", function()
    local b = batch.new(pr)
    batch.add(
      b,
      { path = "a.rs", side = "RIGHT", line = 1, kind = "comment", origin = "claude", status = "verified", body = "x" }
    )
    local b2 = batch.decode(batch.encode(b))
    assert.are.same(b.pr, b2.pr)
    assert.are.equal("c1", b2.comments[1].id)
  end)
end)

describe("ai-review.batch.serialize", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("emits only verified entries, with suggestion blocks and start_line", function()
    local b = batch.new(pr)
    b.verdict = "COMMENT"
    b.body = "overall"
    batch.add(b, {
      path = "a.rs",
      side = "RIGHT",
      line = 42,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "note",
    })
    batch.add(b, {
      path = "b.rs",
      side = "RIGHT",
      start_line = 10,
      line = 12,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "fix",
      suggestion = { lines = { "let x = 1;", "let y = 2;" } },
    })
    batch.add(b, {
      path = "c.rs",
      side = "RIGHT",
      line = 3,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "wip",
      suggestion = { lines = { "todo" } },
    })

    local r = batch.serialize(b)
    assert.are.equal("COMMENT", r.event)
    assert.are.equal(pr.head_sha, r.commit_id)
    assert.are.equal("overall", r.body)
    assert.are.equal(2, #r.comments) -- draft excluded
    assert.are.same({ path = "a.rs", line = 42, side = "RIGHT", body = "note" }, r.comments[1])
    assert.are.equal(10, r.comments[2].start_line)
    assert.is_truthy(r.comments[2].body:find("```suggestion\nlet x = 1;\nlet y = 2;\n```", 1, true))
  end)
end)

describe("ai-review.batch.replace_drafts_for_path", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("replaces a path's draft suggestions but keeps verified + comments + other files", function()
    local b = batch.new(pr)
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "old" } },
    })
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 9,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "",
      suggestion = { lines = { "keep" } },
    })
    batch.add(
      b,
      { path = "a", side = "RIGHT", line = 3, kind = "comment", origin = "human", status = "verified", body = "note" }
    )
    batch.add(b, {
      path = "b",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "other" } },
    })

    batch.replace_drafts_for_path(b, "a", {
      {
        path = "a",
        side = "RIGHT",
        line = 2,
        kind = "suggestion",
        origin = "human",
        status = "draft",
        body = "",
        suggestion = { lines = { "fresh" } },
      },
    })

    local kinds = {}
    for _, c in ipairs(b.comments) do
      kinds[#kinds + 1] = c.path .. ":" .. c.status .. ":" .. (c.suggestion and c.suggestion.lines[1] or c.body)
    end
    -- old draft "a" gone; verified "a", comment "a", draft "b" kept; fresh "a" added
    assert.are.same({ "a:verified:keep", "a:verified:note", "b:draft:other", "a:draft:fresh" }, kinds)
  end)

  it("drops only the human draft for a path, keeping a claude draft on the same path", function()
    local b = batch.new(pr)
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "human-old" } },
    })
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 5,
      kind = "suggestion",
      origin = "claude",
      status = "draft",
      body = "",
      suggestion = { lines = { "claude-draft" } },
    })
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 9,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "",
      suggestion = { lines = { "keep" } },
    })
    batch.add(
      b,
      { path = "a", side = "RIGHT", line = 3, kind = "comment", origin = "human", status = "verified", body = "note" }
    )
    batch.add(b, {
      path = "b",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "other" } },
    })

    -- simulates a human :w on "a" while a claude-authored draft is already staged there
    batch.replace_drafts_for_path(b, "a", {
      {
        path = "a",
        side = "RIGHT",
        line = 2,
        kind = "suggestion",
        origin = "human",
        status = "draft",
        body = "",
        suggestion = { lines = { "human-fresh" } },
      },
    })

    local kinds = {}
    for _, c in ipairs(b.comments) do
      kinds[#kinds + 1] = c.path
        .. ":"
        .. c.origin
        .. ":"
        .. c.status
        .. ":"
        .. (c.suggestion and c.suggestion.lines[1] or c.body)
    end
    -- human draft "a" replaced; claude draft "a" survives untouched; verified + comment +
    -- other-file draft all kept
    assert.are.same({
      "a:claude:draft:claude-draft",
      "a:claude:verified:keep",
      "a:human:verified:note",
      "b:human:draft:other",
      "a:human:draft:human-fresh",
    }, kinds)
  end)
end)
