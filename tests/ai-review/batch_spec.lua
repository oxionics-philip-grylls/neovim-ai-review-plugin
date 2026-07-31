local batch = require("ai-review.batch")

describe("ai-review.batch", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("creates an empty batch for a PR", function()
    local b = batch.new(pr)
    assert.are.same(pr, b.pr)
    assert.are.equal(0, #b.comments)
    -- the non-committal verdict, not nil: nil serializes to no `event`, which GitHub files
    -- as a PENDING review instead of a posted one
    assert.are.equal("COMMENT", b.verdict)
  end)

  it("alloc_id hands out sequential c<N> ids and seeds from legacy batches", function()
    local b = batch.new(pr)
    assert.are.equal("c1", batch.alloc_id(b))
    assert.are.equal("c2", batch.alloc_id(b))
    local legacy = batch.new(pr)
    legacy.next_id = nil
    legacy.comments = { { id = "c7" } }
    assert.are.equal("c8", batch.alloc_id(legacy))
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

describe("ai-review.batch next_id", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("persists next_id across an encode/decode round-trip", function()
    local b = batch.new(pr)
    batch.add(
      b,
      { path = "a.rs", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "draft", body = "x" }
    )
    local b2 = batch.decode(batch.encode(b))
    assert.are.equal(b.next_id, b2.next_id)
  end)

  it("never reuses an id even after replace_drafts_for_path removes the max", function()
    local b = batch.new(pr)
    batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 1,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "one" } },
    })
    local id2 = batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 2,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "two" } },
    })
    assert.are.equal("c2", id2)
    -- removes both human drafts on "a" (id1 and the current max, id2), adding nothing back
    batch.replace_drafts_for_path(b, "a", {})
    assert.are.equal(0, #b.comments)
    local id3 = batch.add(b, {
      path = "a",
      side = "RIGHT",
      line = 3,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "",
      suggestion = { lines = { "three" } },
    })
    assert.are.equal("c3", id3) -- not "c1": the persistent counter, not a max-over-survivors recompute
  end)

  it("seeds next_id from max-suffix+1 on a legacy batch that has no counter", function()
    -- a batch decoded from a pre-counter file: has entries but no next_id
    local b = {
      pr = pr,
      body = "",
      comments = {
        {
          id = "c5",
          path = "a",
          side = "RIGHT",
          line = 1,
          kind = "comment",
          origin = "human",
          status = "draft",
          body = "",
        },
      },
    }
    local id = batch.add(
      b,
      { path = "a", side = "RIGHT", line = 2, kind = "comment", origin = "human", status = "draft", body = "" }
    )
    assert.are.equal("c6", id) -- max existing suffix (5) + 1, not c1 or c2
    assert.are.equal(7, b.next_id)
  end)

  it("encode output carries next_id but strips the non-persisted _loaded_mtime", function()
    local b = batch.new(pr)
    b._loaded_mtime = { sec = 1, nsec = 2 }
    local encoded = batch.encode(b)
    assert.is_truthy(encoded:find('"next_id"', 1, true))
    assert.is_nil(encoded:find("_loaded_mtime", 1, true))
  end)
end)

describe("ai-review.batch.validate", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("drops malformed entries but keeps valid ones, notifying once per drop", function()
    local decoded = {
      pr = pr,
      body = "",
      next_id = 4,
      comments = {
        { id = "c1", path = "a.rs", side = "RIGHT", line = 1, kind = "comment", status = "draft", body = "ok" },
        { id = "c2", path = "a.rs", side = "RIGHT", kind = "comment", status = "draft", body = "no line" },
        { id = "c3", path = "a.rs", side = "UP", line = 1, kind = "comment", status = "draft", body = "bad side" },
      },
    }
    local notified = 0
    local orig_notify = vim.notify
    vim.notify = function()
      notified = notified + 1
    end
    local v = batch.validate(decoded)
    vim.notify = orig_notify
    assert.are.equal(1, #v.comments)
    assert.are.equal("c1", v.comments[1].id)
    assert.are.equal(2, notified)
  end)

  it("never nils comments, even when decoded.comments isn't a list", function()
    local v = batch.validate({ pr = pr, body = "", comments = "garbage" })
    assert.are.same({}, v.comments)
  end)

  it("gives an id-less entry an id, so the sheet can render it at all", function()
    -- sheet.render formats `#%s` with c.id, which THROWS under LuaJIT on nil — inside
    -- M.sheet(), before M._sheet is assigned, leaving a stranded tab and no sheet state.
    local sheet = require("ai-review.sheet")
    local v = batch.validate({
      pr = pr,
      body = "",
      next_id = 4,
      comments = {
        { path = "a.rs", side = "RIGHT", line = 1, kind = "comment", status = "draft", body = "no id" },
        { id = 7, path = "b.rs", side = "RIGHT", line = 2, kind = "comment", status = "draft", body = "numeric id" },
      },
    })
    assert.are.equal("c4", v.comments[1].id)
    assert.are.equal("c5", v.comments[2].id) -- a numeric id round-trips as an unmatchable one
    local rendered = table.concat(sheet.render(v), "\n")
    assert.is_truthy(rendered:find("#c4 draft", 1, true))
    -- ...and the ids survive the round-trip, so neither entry looks like a new comment
    local parsed = sheet.parse(sheet.render(v))
    assert.are.equal("c4", parsed.entries[1].id)
    assert.are.equal("c5", parsed.entries[2].id)
  end)

  it("never mints an id that collides with one already in the batch, even when next_id lags", function()
    -- A foreign batch whose next_id lags its own ids: next_id=2 but a "c2" already exists.
    -- alloc_id only rescans to seed next_id when next_id is nil, so a naive assignment here
    -- hands the id-less entry "c2" too — a duplicate that sheet.parse then rejects outright.
    local sheet = require("ai-review.sheet")
    local v = batch.validate({
      pr = pr,
      body = "",
      next_id = 2,
      comments = {
        { id = "c2", path = "a.rs", side = "RIGHT", line = 1, kind = "comment", status = "draft", body = "existing" },
        { path = "b.rs", side = "RIGHT", line = 2, kind = "comment", status = "draft", body = "no id" },
      },
    })
    assert.are_not.equal("c2", v.comments[2].id)
    local seen = {}
    for _, c in ipairs(v.comments) do
      assert.is_nil(seen[c.id], "duplicate id: " .. tostring(c.id))
      seen[c.id] = true
    end
    -- the whole point: this must round-trip through render/parse without a duplicate-id error
    local parsed, err = sheet.parse(sheet.render(v))
    assert.is_nil(err)
    assert.is_not_nil(parsed)
  end)
end)

describe("ai-review.batch.add id uniqueness", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }
  local function draft(line, origin)
    return {
      path = "a",
      side = "RIGHT",
      line = line,
      kind = "suggestion",
      origin = origin,
      status = origin == "claude" and "verified" or "draft",
      body = "",
      suggestion = { lines = { tostring(line) } },
    }
  end
  it("keeps ids unique among current entries after replace removes+re-adds", function()
    local b = batch.new(pr)
    batch.add(b, draft(1, "human"))
    batch.add(b, draft(2, "claude"))
    batch.add(b, draft(3, "human"))
    batch.replace_drafts_for_path(b, "a", { draft(4, "human") })
    local seen = {}
    for _, c in ipairs(b.comments) do
      assert.is_nil(seen[c.id], "duplicate id: " .. tostring(c.id))
      seen[c.id] = true
    end
  end)
end)

describe("ai-review.batch reviewed", function()
  local pr = { owner = "o", repo = "r", number = 5, base = "master", head_sha = "abc" }

  it("new batch starts with an empty reviewed list", function()
    assert.are.same({}, batch.new(pr).reviewed)
  end)

  it("toggles a path on and off, reporting the new state", function()
    local b = batch.new(pr)
    assert.is_true(batch.toggle_reviewed(b, "a.rs")) -- now reviewed
    assert.is_true(batch.is_reviewed(b, "a.rs"))
    assert.are.equal(1, batch.count_reviewed(b))
    assert.is_false(batch.toggle_reviewed(b, "a.rs")) -- toggled back off
    assert.is_false(batch.is_reviewed(b, "a.rs"))
    assert.are.equal(0, batch.count_reviewed(b))
  end)

  it("persists reviewed across encode/decode and EXCLUDES it from serialize", function()
    local b = batch.new(pr)
    batch.toggle_reviewed(b, "a.rs")
    b.verdict = "COMMENT"
    local rt = batch.decode(batch.encode(b))
    assert.are.same({ "a.rs" }, rt.reviewed)
    -- serialize is the GitHub payload: reviewed must not leak into it
    assert.is_nil(batch.serialize(b).reviewed)
  end)

  it("validate coerces a non-list reviewed to an empty list", function()
    local v = batch.validate({ pr = pr, body = "", comments = {}, reviewed = "garbage" })
    assert.are.same({}, v.reviewed)
  end)

  it("validate coerces reviewed even when comments is also garbage", function()
    local v = batch.validate({ pr = pr, body = "", comments = "bad", reviewed = "bad" })
    assert.are.same({}, v.reviewed)
    assert.are.same({}, v.comments)
  end)
end)
