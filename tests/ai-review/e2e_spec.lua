-- End-to-end integration test for pip.prreview against a synthetic GitHub PR built
-- in a throwaway local repo (base branch + refs/pull/1/head). The two network calls
-- (gh pr view, the URL guard's remote parse) and vim.ui.input are stubbed; the git
-- fetches, diffview split, batch persistence, and serialization are exercised for real.
--
-- Guards the class of bug unit tests miss: e.g. a fetch-ordering regression that leaves
-- FETCH_HEAD on the base so the diff comes out empty.

-- diffview is a runtime dep, not on the test rtp by default; put it there before any
-- require of pip.prreview.diff (which requires diffview.lib at load time).
local diffview_dir = vim.fn.stdpath("data") .. "/lazy/diffview.nvim"
local have_diffview = vim.fn.isdirectory(diffview_dir) == 1
if have_diffview then
  vim.opt.rtp:prepend(diffview_dir)
  have_diffview = pcall(function()
    require("diffview").setup({})
    vim.cmd("runtime! plugin/diffview.lua") -- --noplugin skips this; needed for :DiffviewOpen
  end)
end

local function sh(cmd)
  return vim.trim(vim.fn.system(cmd))
end

describe("ai-review end-to-end", function()
  if not have_diffview then
    it("skipped (diffview not installed — run :Lazy sync)", function()
      pending("diffview.nvim not available on the test runtimepath")
    end)
    return
  end

  local pr = require("ai-review")
  local state = require("ai-review.state")
  local url = require("ai-review.url")
  local gh = require("ai-review.gh")
  local diff = require("ai-review.diff")
  local batch = require("ai-review.batch")
  pr.setup({})

  local root, clone, orig_cwd, troot, saved

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local remote, seed = root .. "/remote.git", root .. "/seed"
    clone = root .. "/clone"
    sh("git init -q --bare " .. remote)
    sh("git clone -q " .. remote .. " " .. seed)
    local function g(a)
      return sh("git -C " .. seed .. " " .. a)
    end
    g("config user.email h@h.co")
    g("config user.name harness")
    vim.fn.writefile({ "line1", "line2", "line3" }, seed .. "/file.txt")
    g("add file.txt")
    g("commit -qm base")
    g("push -q origin HEAD:master")
    vim.fn.writefile({ "line1", "CHANGED", "line3", "line4-added" }, seed .. "/file.txt")
    g("commit -qam prchange")
    g("push -q origin HEAD:refs/pull/1/head")
    sh("git clone -q " .. remote .. " " .. clone)

    orig_cwd = vim.fn.getcwd()
    vim.cmd.cd(clone)

    saved = {
      parse_remote = url.parse_remote,
      pr_info = gh.pr_info,
      cursor_anchor = diff.cursor_anchor,
      ui_input = vim.ui.input,
      default_root = state.default_root,
    }
    troot = vim.fn.tempname()
    state.default_root = function()
      return troot
    end
    url.parse_remote = function()
      return { owner = "test", repo = "repo" }
    end
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git rev-parse origin/master") }
    end
  end)

  after_each(function()
    pcall(vim.cmd, "DiffviewClose")
    if orig_cwd then
      vim.cmd.cd(orig_cwd)
    end
    url.parse_remote, gh.pr_info, diff.cursor_anchor, vim.ui.input, state.default_root =
      saved.parse_remote, saved.pr_info, saved.cursor_anchor, saved.ui_input, saved.default_root
    vim.fn.delete(root, "rf")
    vim.fn.delete(troot, "rf")
  end)

  it("start() fetches base+head in the right order → non-empty diff", function()
    pr.start("https://github.com/test/repo/pull/1")
    -- FETCH_HEAD must be the PR head, not the base (the fetch-order regression)
    assert.is_true(sh("git rev-parse FETCH_HEAD") ~= sh("git rev-parse origin/master"))
    assert.is_true(sh("git diff --name-only origin/master...FETCH_HEAD") ~= "")
    assert.is_not_nil(require("diffview.lib").get_current_view())
    assert.is_not_nil(vim.uv.fs_stat(state.batch_path({ owner = "test", repo = "repo", number = 1 })))
  end)

  it("PrComment appends an anchored comment; serialize is valid GitHub JSON", function()
    pr.start("https://github.com/test/repo/pull/1")
    diff.cursor_anchor = function()
      return { path = "file.txt", line = 2, side = "RIGHT" }
    end
    vim.ui.input = function(_, cb)
      cb("second line looks off")
    end
    vim.cmd("PrComment")

    local b = state.load_or_init_batch({ owner = "test", repo = "repo", number = 1 })
    assert.are.equal(1, #b.comments)
    assert.are.equal("file.txt", b.comments[1].path)
    assert.are.equal(2, b.comments[1].line)
    assert.are.equal("RIGHT", b.comments[1].side)

    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 4,
      kind = "suggestion",
      origin = "claude",
      status = "verified",
      body = "prefer this",
      suggestion = { lines = { "line4-fixed" } },
    })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "wip",
      suggestion = { lines = { "x" } },
    })
    b.verdict = "COMMENT"
    local r = batch.serialize(b)
    assert.are.equal("COMMENT", r.event)
    assert.are.equal(b.pr.head_sha, r.commit_id)
    assert.are.equal(2, #r.comments) -- draft excluded
    assert.is_truthy(r.comments[2].body:find("```suggestion\nline4-fixed\n```", 1, true))
    assert.is_true(pcall(vim.json.encode, r))
  end)

  it("routes a RIGHT-side comment to the head buffer, not the base buffer", function()
    pr.start("https://github.com/test/repo/pull/1")

    -- DiffviewOpen creates its Diff2 layout with placeholder "diffview://null"
    -- files immediately, then swaps in the real per-side buffers once the
    -- (async) git-diff file list resolves and the first entry auto-selects.
    -- Poll for that real selection rather than a single autocmd fire, since
    -- Diff2Hor's two windows can each settle at a slightly different tick.
    local view
    local ok = vim.wait(2000, function()
      view = require("diffview.lib").get_current_view()
      local layout = view and view.cur_layout
      if
        not (
          layout ~= nil
          and layout.a ~= nil
          and layout.b ~= nil
          and layout.a.file ~= nil
          and layout.b.file ~= nil
          and layout.a.file.bufnr ~= nil
          and layout.b.file.bufnr ~= nil
          and vim.api.nvim_buf_is_valid(layout.a.file.bufnr)
          and vim.api.nvim_buf_is_valid(layout.b.file.bufnr)
        )
      then
        return false
      end
      return vim.api.nvim_buf_get_name(layout.a.file.bufnr) ~= "diffview://null"
        and vim.api.nvim_buf_get_name(layout.b.file.bufnr) ~= "diffview://null"
    end, 20)
    assert.is_true(ok, "diffview's base/head windows never became ready within 2s")

    -- Read head/base buffers from diffview's own model — the same source
    -- overlay.lua's side_bufs() uses — so this is an independent check of
    -- render()'s output against the ground truth, not a re-derivation of it.
    local base_buf = view.cur_layout.a.file.bufnr
    local head_buf = view.cur_layout.b.file.bufnr
    assert.is_not_nil(base_buf)
    assert.is_not_nil(head_buf)
    assert.is_true(base_buf ~= head_buf)

    local b = state.load_or_init_batch({ owner = "test", repo = "repo", number = 1 })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "right side only",
    })
    state.save_batch(b)
    require("ai-review.overlay").refresh({ owner = "test", repo = "repo", number = 1 })

    local ns = vim.api.nvim_create_namespace("pip_prreview")
    local head_marks = vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {})
    local base_marks = vim.api.nvim_buf_get_extmarks(base_buf, ns, 0, -1, {})
    assert.is_true(#head_marks > 0)
    assert.are.equal(0, #base_marks)
  end)
end)
