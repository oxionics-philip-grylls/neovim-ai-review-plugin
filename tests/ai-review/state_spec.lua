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

  it("re-reads and merges by id instead of clobbering a concurrent writer's landed change", function()
    local root = vim.fn.tempname()
    local b = state.load_or_init_batch(pr, root)
    local id_seed = batch.add(
      b,
      { path = "a", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "verified", body = "seed" }
    )
    state.save_batch(b, root) -- first write: nothing on disk yet, no merge needed

    -- a concurrent writer (e.g. peer-review flipping a status) lands directly on disk,
    -- without going through this process's in-memory batch or next_id counter
    local path = state.batch_path(pr, root)
    local fd = assert(io.open(path, "r"))
    local disk = batch.decode(fd:read("*a"))
    fd:close()
    disk.comments[#disk.comments + 1] = {
      id = "cX",
      path = "x",
      side = "RIGHT",
      line = 9,
      kind = "comment",
      origin = "claude",
      status = "verified",
      body = "concurrent",
    }
    local wfd = assert(io.open(path, "w"))
    wfd:write(batch.encode(disk))
    wfd:close()

    -- this writer never reloaded, so it's unaware of the concurrent write above; it stages
    -- its own new entry and saves against its now-stale generation
    local id_mine = batch.add(
      b,
      { path = "b", side = "RIGHT", line = 2, kind = "comment", origin = "human", status = "draft", body = "mine" }
    )
    -- force the mismatch deterministically, independent of real fs mtime resolution
    b._loaded_mtime = { sec = 0, nsec = 0 }
    state.save_batch(b, root)

    local final = state.load_or_init_batch(pr, root)
    local by_id = {}
    for _, c in ipairs(final.comments) do
      by_id[c.id] = c
    end
    assert.is_not_nil(by_id["cX"]) -- concurrent writer's entry must survive the merge
    assert.are.equal("concurrent", by_id["cX"].body)
    assert.is_not_nil(by_id[id_mine]) -- this writer's own new entry must not be lost
    assert.are.equal("mine", by_id[id_mine].body)
    assert.are.equal("seed", by_id[id_seed].body)
    assert.is_true(final.next_id > tonumber(id_mine:match("%d+")))
    vim.fn.delete(root, "rf")
  end)

  it("tolerates an id-less on-disk entry in the merge instead of throwing", function()
    local root = vim.fn.tempname()
    local b = state.load_or_init_batch(pr, root)
    local id_mine = batch.add(
      b,
      { path = "a", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "verified", body = "mine" }
    )
    state.save_batch(b, root)

    -- a foreign/hand-edited on-disk file carries an entry with no id (validate allows it)
    local path = state.batch_path(pr, root)
    local fd = assert(io.open(path, "r"))
    local disk = batch.decode(fd:read("*a"))
    fd:close()
    disk.comments[#disk.comments + 1] = {
      path = "x",
      side = "RIGHT",
      line = 9,
      kind = "comment",
      origin = "claude",
      status = "verified",
      body = "idless",
    }
    local wfd = assert(io.open(path, "w"))
    wfd:write(batch.encode(disk))
    wfd:close()

    b._loaded_mtime = { sec = 0, nsec = 0 } -- force the merge path
    assert.has_no.errors(function()
      state.save_batch(b, root)
    end)
    -- the id-keyed entry survives; the id-less one is dropped (can't be merged) but no crash
    local final = state.load_or_init_batch(pr, root)
    local by_id = {}
    for _, c in ipairs(final.comments) do
      by_id[c.id] = c
    end
    assert.is_not_nil(by_id[id_mine])
    vim.fn.delete(root, "rf")
  end)

  it("re-stamps the generation after a save so a session-deleted entry doesn't resurrect", function()
    local root = vim.fn.tempname()
    local b = state.load_or_init_batch(pr, root)
    batch.add(
      b,
      { path = "a", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "draft", body = "one" }
    )
    batch.add(
      b,
      { path = "b", side = "RIGHT", line = 2, kind = "comment", origin = "human", status = "draft", body = "two" }
    )
    state.save_batch(b, root) -- first write (file was absent)

    -- same in-memory batch, no reload: drop the first entry, then save again. Without the
    -- post-write re-stamp, the second save would see disk-mtime != a nil _loaded_mtime,
    -- take the merge path, and resurrect the just-deleted entry from disk.
    table.remove(b.comments, 1)
    state.save_batch(b, root)

    local final = state.load_or_init_batch(pr, root)
    assert.are.equal(1, #final.comments)
    assert.are.equal("two", final.comments[1].body)
    vim.fn.delete(root, "rf")
  end)

  it("falls back to writing the in-memory batch as-is when the re-read on-disk file is corrupt", function()
    local root = vim.fn.tempname()
    local b = state.load_or_init_batch(pr, root)
    batch.add(
      b,
      { path = "a", side = "RIGHT", line = 1, kind = "comment", origin = "human", status = "verified", body = "mine" }
    )
    vim.fn.mkdir(root, "p")
    local fd = assert(io.open(state.batch_path(pr, root), "w"))
    fd:write("{not valid json")
    fd:close()
    b._loaded_mtime = { sec = 0, nsec = 0 } -- force the merge attempt, which then hits the corrupt read
    state.save_batch(b, root)

    local final = state.load_or_init_batch(pr, root)
    assert.are.equal(1, #final.comments)
    assert.are.equal("mine", final.comments[1].body)
    vim.fn.delete(root, "rf")
  end)
end)
