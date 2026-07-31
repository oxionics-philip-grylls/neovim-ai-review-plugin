-- End-to-end integration test for ai-review against a synthetic GitHub PR built
-- in a throwaway local repo (base branch + refs/pull/1/head). The two network calls
-- (gh pr view, the URL guard's remote parse) and vim.ui.input are stubbed; the git
-- fetches, diffview split, batch persistence, and serialization are exercised for real.
--
-- Guards the class of bug unit tests miss: e.g. a fetch-ordering regression that leaves
-- FETCH_HEAD on the base so the diff comes out empty.

-- diffview is a runtime dep, not on the test rtp by default; put it there before any
-- require of ai-review.diff (which requires diffview.lib at load time).
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

-- DiffviewClose kicks off async teardown coroutines; a subsequent DiffviewOpen that
-- races them intermittently dies ("Could not find the Git directory!") or fails to
-- select real buffers. Poll for teardown instead of a fixed sleep, both between two
-- opens within one test and across tests in after_each.
local function close_diffview_and_wait()
  pcall(vim.cmd, "DiffviewClose")
  vim.wait(2000, function()
    return require("diffview.lib").get_current_view() == nil
  end, 20)
  -- get_current_view() clears synchronously inside the close, so the poll above
  -- resolves ~instantly and doesn't by itself wait out the async teardown
  -- (watcher:close(), file:destroy(), ...) that runs after. Pump the loop a bit
  -- longer so those coroutines actually drain before the next DiffviewOpen.
  vim.wait(150)
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
    -- The review worktree shares this clone's config, and `git rebase` needs a committer
    -- identity; set one locally so the specs don't depend on the machine's global gitconfig.
    sh("git -C " .. clone .. " config user.email h@h.co")
    sh("git -C " .. clone .. " config user.name harness")

    orig_cwd = vim.fn.getcwd()
    vim.cmd.cd(clone)

    saved = {
      parse_remote = url.parse_remote,
      pr_info = gh.pr_info,
      cursor_anchor = diff.cursor_anchor,
      ui_input = vim.ui.input,
      ui_select = vim.ui.select,
      confirm = vim.fn.confirm,
      gh_run = gh.run,
      default_root = state.default_root,
      chan_send = vim.api.nvim_chan_send,
      notify = vim.notify,
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
    require("ai-review")._stop_watch() -- stop the batch fs-watcher before deleting troot
    require("ai-review")._stop_sheet_wait() -- ditto the sheet's one-shot re-anchor watcher
    close_diffview_and_wait()
    if orig_cwd then
      vim.cmd.cd(orig_cwd)
    end
    url.parse_remote, gh.pr_info, gh.run, diff.cursor_anchor, vim.ui.input, vim.ui.select, vim.fn.confirm, state.default_root, vim.api.nvim_chan_send =
      saved.parse_remote,
      saved.pr_info,
      saved.gh_run,
      saved.cursor_anchor,
      saved.ui_input,
      saved.ui_select,
      saved.confirm,
      saved.default_root,
      saved.chan_send
    -- Both of these are stubbed inline mid-test; restore them HERE too, or a failing assert
    -- leaks the stub into every test that follows and degrades their diagnostics.
    vim.notify = saved.notify
    vim.fn.getcmdtype = nil -- assigning nil restores the builtin; a no-op if none was set
    require("ai-review")._claude = nil -- clear any fake terminal a test set
    require("ai-review")._close_sheet() -- close (not just nil) — a failed assert can leave the real tab open
    package.loaded.snacks = nil -- drop any fake snacks a test injected (real snacks isn't on the test rtp)
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

  it("the scrollbind guard leaves floating windows and the cmdline alone", function()
    -- A completion popup is a floating WINDOW, so it fires the WinNew that schedules the
    -- guard. The guard used to set options on the popup and then call diffview's
    -- sync_scroll(), which dismissed it — once per character typed, for the whole review.
    pr.start("https://github.com/test/repo/pull/1")
    local fbuf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(fbuf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
    vim.wo[float].scrollbind = true -- a value the guard must NOT touch on a float

    -- ...and the guard's actual JOB, in the same call: a plain split off a diff window
    -- inherits scrollbind/cursorbind and silently joins the diff panes' scroll group. Without
    -- this, a mutant making _guard_scrollbind a no-op for every window passes the suite.
    vim.cmd("new")
    local split = vim.api.nvim_get_current_win()
    vim.wo[split].scrollbind = true
    vim.wo[split].cursorbind = true

    pr._guard_scrollbind()
    assert.is_true(vim.wo[float].scrollbind) -- float left alone
    assert.is_false(vim.wo[split].scrollbind) -- non-diff split cleared
    assert.is_false(vim.wo[split].cursorbind)
    pcall(vim.api.nvim_win_close, split, true)

    -- and it must not run at all while a cmdline is open, whatever windows exist
    local ran = false
    local real_view = require("diffview.lib").get_current_view
    require("diffview.lib").get_current_view = function()
      ran = true
      return real_view()
    end
    vim.fn.getcmdtype = function()
      return ":"
    end
    pr._guard_scrollbind()
    vim.fn.getcmdtype = nil -- restore the builtin
    require("diffview.lib").get_current_view = real_view
    assert.is_false(ran) -- bailed before touching diffview

    pcall(vim.api.nvim_win_close, float, true)
    close_diffview_and_wait()
  end)

  it("PrGoto opens the real worktree file at the cursor line AND column (RIGHT side)", function()
    pr.start("https://github.com/test/repo/pull/1")
    -- put the cursor at a known non-zero column so we prove the column is CAPTURED before
    -- the vsplit (a capture-after-split regression would land at col 0 and fail this).
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- col 5 (1-based) → captured as 4 (0-based)
    diff.cursor_anchor = function()
      return { path = "file.txt", line = 3, side = "RIGHT" }
    end
    vim.cmd("PrGoto")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 })
    assert.are.equal(wt .. "/file.txt", vim.api.nvim_buf_get_name(0))
    assert.are.same({ 3, 4 }, vim.api.nvim_win_get_cursor(0)) -- line 3, column preserved
    vim.cmd("bwipeout!")
    close_diffview_and_wait()
  end)

  it("PrGoto on a LEFT-side line warns and does not open the worktree file", function()
    pr.start("https://github.com/test/repo/pull/1")
    diff.cursor_anchor = function()
      return { path = "file.txt", line = 2, side = "LEFT" }
    end
    local before = vim.api.nvim_buf_get_name(0)
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg, lvl)
      if type(msg) == "string" and msg:find("LEFT lines don't map", 1, true) then
        warned = true
      end
      return orig(msg, lvl)
    end
    vim.cmd("PrGoto")
    vim.notify = orig
    assert.is_true(warned)
    assert.are.equal(before, vim.api.nvim_buf_get_name(0)) -- no new buffer opened
    close_diffview_and_wait()
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

  it("cursor_anchor reports RIGHT even with a floating window docked top-right", function()
    pr.start("https://github.com/test/repo/pull/1")

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

    vim.api.nvim_set_current_win(view.cur_layout.b.id)

    -- A floating window docked at the top-right corner occupies the tabpage's
    -- rightmost column; the old column heuristic mistook that for the diff's
    -- head/RIGHT window and misclassified the real (unfloated) cursor window
    -- as LEFT.
    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = "editor",
      row = 0,
      col = vim.o.columns - 10,
      width = 10,
      height = 3,
      style = "minimal",
    })

    -- Opening the float transiently reflows diffview's layout back through its
    -- null-buffer placeholder before re-settling on the real file buffer; wait
    -- that out (same pattern as the readiness poll above) before reading the anchor.
    local settled = vim.wait(2000, function()
      return vim.api.nvim_buf_get_name(0) ~= "diffview://null"
    end, 10)
    assert.is_true(settled, "diff buffer never resettled after the float was opened")

    local anchor = diff.cursor_anchor()

    vim.api.nvim_win_close(float_win, true)
    vim.api.nvim_buf_delete(float_buf, { force = true })

    assert.is_not_nil(anchor)
    assert.are.equal("RIGHT", anchor.side)
  end)

  it("PrComment honours an explicit command range (real cursor_anchor, not stubbed)", function()
    pr.start("https://github.com/test/repo/pull/1")

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

    -- Real cursor_anchor (NOT stubbed): the whole point of B4 is that the command
    -- callback sees normal mode, so only the threaded a.range keeps the multi-line
    -- span. Cursor in the RIGHT (head) window.
    vim.api.nvim_set_current_win(view.cur_layout.b.id)
    -- the head window can still be showing diffview's 1-line null placeholder for a
    -- tick after selection; a command range (":2,3") is validated against the window's
    -- current buffer, so wait for the real 4-line head file before issuing it.
    local shown = vim.wait(2000, function()
      return vim.api.nvim_buf_get_name(0) ~= "diffview://null" and vim.api.nvim_buf_line_count(0) >= 3
    end, 10)
    assert.is_true(shown, "head window never showed the real file")
    vim.ui.input = function(_, cb)
      cb("spans two lines")
    end
    vim.cmd("2,3PrComment")

    local b = state.load_or_init_batch({ owner = "test", repo = "repo", number = 1 })
    assert.are.equal(1, #b.comments)
    assert.are.equal(2, b.comments[1].start_line)
    assert.are.equal(3, b.comments[1].line)
    assert.are.equal("RIGHT", b.comments[1].side)
    close_diffview_and_wait()
  end)

  it("creates the review worktree on start and removes it on close", function()
    pr.start("https://github.com/test/repo/pull/1")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    assert.is_not_nil(vim.uv.fs_stat(wt))
    assert.is_not_nil(require("ai-review.state").read_active(troot).worktree)
    vim.cmd("PrReviewClose")
    assert.is_nil(vim.uv.fs_stat(wt))
  end)

  it("aborts close when the worktree is dirty and the user declines to discard", function()
    pr.start("https://github.com/test/repo/pull/1")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    -- dirty the checked-out file directly (not through the BufWritePost staging path)
    vim.fn.writefile({ "line1", "DIRTY", "line3", "line4-added" }, wt .. "/file.txt")
    vim.fn.confirm = function()
      return 2 -- "No" — decline the discard
    end
    vim.cmd("PrReviewClose")
    -- dirty worktree + active.json must both survive a declined close
    assert.is_not_nil(vim.uv.fs_stat(wt))
    assert.is_not_nil(state.read_active(troot))
  end)

  it("watcher-start failure notifies and leaves M._watch unset, without aborting start", function()
    local orig_new_fs_event = vim.uv.new_fs_event
    local fake_handle = {
      start = function()
        return -1 -- simulate libuv fs_event:start failure
      end,
      close = function() end,
    }
    vim.uv.new_fs_event = function()
      return fake_handle
    end
    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and msg:find("live re-render off", 1, true) then
        warned = true
      end
    end

    pr.start("https://github.com/test/repo/pull/1")

    vim.uv.new_fs_event = orig_new_fs_event
    vim.notify = orig_notify
    assert.is_true(warned, "expected the watcher-start-failure WARN")
    assert.is_nil(pr._watch)
    -- start() must otherwise have completed normally (worktree present, review active)
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    assert.is_not_nil(vim.uv.fs_stat(wt))
    vim.cmd("PrReviewClose")
  end)

  it("staging: editing a worktree file on save produces a draft suggestion", function()
    pr.start("https://github.com/test/repo/pull/1")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    local f = wt .. "/file.txt"
    -- open the file so BufWritePost fires under the autocmd; edit the live buffer (not the
    -- file on disk out-of-band) so the second :write below doesn't trip Vim's blocking
    -- "file changed since reading" y/n prompt, which hangs headless (no stdin to answer it)
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "SUGGESTED line 2" })
    vim.cmd("write")
    local b = state.load_or_init_batch({ owner = "test", repo = "repo", number = 1 })
    local drafts = {}
    for _, c in ipairs(b.comments) do
      if c.status == "draft" and c.kind == "suggestion" then
        drafts[#drafts + 1] = c
      end
    end
    assert.are.equal(1, #drafts)
    assert.are.equal("file.txt", drafts[1].path)
    assert.are.equal("RIGHT", drafts[1].side)
    assert.are.equal(2, drafts[1].line)
    assert.are.same({ "SUGGESTED line 2" }, drafts[1].suggestion.lines)
    -- re-save with a further edit: still one draft for the file (no accumulation)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "SUGGESTED again" })
    vim.cmd("write")
    local b2 = state.load_or_init_batch({ owner = "test", repo = "repo", number = 1 })
    local n = 0
    for _, c in ipairs(b2.comments) do
      if c.status == "draft" then
        n = n + 1
      end
    end
    assert.are.equal(1, n)
  end)
  it("staging: does not re-stage an already-verified hunk when a different hunk is saved", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local wt = state.worktree_path(prkey, troot)
    local f = wt .. "/file.txt"
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    -- hunk1: edit line 1 ("line1" -> ...), save, then verify it out-of-band
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "SUGGESTED line 1" })
    vim.cmd("write")
    local b = state.load_or_init_batch(prkey)
    assert.are.equal(1, #b.comments)
    b.comments[1].status = "verified"
    state.save_batch(b)

    -- hunk2: edit line 3 (a different, non-adjacent region of the same file), save
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "SUGGESTED line 3" })
    vim.cmd("write")

    local b2 = state.load_or_init_batch(prkey)
    assert.are.equal(2, #b2.comments) -- hunk1 verified + hunk2 draft, NOT a re-staged hunk1 duplicate
    local by_line = {}
    for _, c in ipairs(b2.comments) do
      by_line[c.line] = c
    end
    assert.are.equal("verified", by_line[1].status)
    assert.are.same({ "SUGGESTED line 1" }, by_line[1].suggestion.lines)
    assert.are.equal("draft", by_line[3].status)
    assert.are.same({ "SUGGESTED line 3" }, by_line[3].suggestion.lines)
  end)
  it("staging: a pure-insertion save anchors to head_sha's line, not the shifted worktree line", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local wt = state.worktree_path(prkey, troot)
    local f = wt .. "/file.txt"
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    -- two pure insertions in ONE save, after head lines 1 and 2 respectively, without
    -- touching any existing line. After the first insert the worktree's own line 2 is
    -- "NEW-A" (shifted), not head_sha's "line2" — the anchor content must still come
    -- from head_sha, so the second draft's suggestion.lines[1] must be "line2".
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "NEW-A" }) -- after "line1"
    vim.api.nvim_buf_set_lines(0, 3, 3, false, { "NEW-B" }) -- after "line2" (pre-shift)
    assert.are.same({ "line1", "NEW-A", "line2", "NEW-B", "line3" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("write")

    local b = state.load_or_init_batch(prkey)
    local drafts = {}
    for _, c in ipairs(b.comments) do
      if c.status == "draft" and c.kind == "suggestion" then
        drafts[#drafts + 1] = c
      end
    end
    assert.are.equal(2, #drafts) -- not "0 draft suggestions" (the old pure-insertion skip)
    table.sort(drafts, function(a, c)
      return a.line < c.line
    end)

    assert.are.equal(1, drafts[1].start_line)
    assert.are.equal(1, drafts[1].line)
    assert.are.same({ "line1", "NEW-A" }, drafts[1].suggestion.lines)

    assert.are.equal(2, drafts[2].start_line)
    assert.are.equal(2, drafts[2].line)
    -- CRUCIAL: head_sha's line 2 ("line2"), NOT the worktree's now-shifted line 2 ("NEW-A")
    assert.are.same({ "line2", "NEW-B" }, drafts[2].suggestion.lines)
  end)
  it("staging: a pure-insertion at the very top of the file anchors to line 1", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local wt = state.worktree_path(prkey, troot)
    local f = wt .. "/file.txt"
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "PREPENDED" })
    vim.cmd("write")

    local b = state.load_or_init_batch(prkey)
    local drafts = {}
    for _, c in ipairs(b.comments) do
      if c.status == "draft" and c.kind == "suggestion" then
        drafts[#drafts + 1] = c
      end
    end
    assert.are.equal(1, #drafts)
    assert.are.equal(1, drafts[1].start_line)
    assert.are.equal(1, drafts[1].line)
    -- new content precedes head_sha's original first line
    assert.are.same({ "PREPENDED", "line1" }, drafts[1].suggestion.lines)
  end)
  it("staging: an insertion whose head_sha lookup fails is skipped with a WARN, not a crash", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local wt = state.worktree_path(prkey, troot)
    local newf = wt .. "/newfile.txt"
    vim.fn.writefile({ "a", "b" }, newf)
    sh("git -C " .. wt .. " add newfile.txt") -- staged, so it diffs as an addition against head_sha
    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = true
      end
      orig_notify(msg, level)
    end
    vim.cmd("edit " .. vim.fn.fnameescape(newf))
    vim.cmd("write")
    vim.notify = orig_notify

    assert.is_true(warned, "expected a WARN when head_sha:newfile.txt can't be read")
    local b = state.load_or_init_batch(prkey)
    for _, c in ipairs(b.comments) do
      assert.are_not.equal("newfile.txt", c.path) -- no bogus draft staged against a nonexistent anchor
    end
  end)
  it("resets a stale worktree to the current head on re-start", function()
    pr.start("https://github.com/test/repo/pull/1")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    local head = vim.trim(sh("git rev-parse origin/master"))
    -- move the worktree off the current head (FETCH_HEAD is the PR head, a different commit)
    local other = vim.trim(sh("git rev-parse FETCH_HEAD"))
    assert.are_not.equal(head, other)
    sh("git -C " .. wt .. " reset --hard " .. other)
    close_diffview_and_wait()
    pr.start("https://github.com/test/repo/pull/1")
    assert.are.equal(head, vim.trim(sh("git -C " .. wt .. " rev-parse HEAD")))
    vim.cmd("PrReviewClose")
  end)

  it("rebuilds a broken worktree dir on re-start", function()
    pr.start("https://github.com/test/repo/pull/1")
    local wt = state.worktree_path({ owner = "test", repo = "repo", number = 1 }, troot)
    -- corrupt it: drop the gitdir link so `rev-parse HEAD` fails inside the worktree
    vim.fn.delete(wt .. "/.git", "rf")
    assert.are_not.equal(0, gh.run(gh.worktree_head_cmd(wt)).code)
    close_diffview_and_wait()
    pr.start("https://github.com/test/repo/pull/1")
    local after = gh.run(gh.worktree_head_cmd(wt))
    assert.are.equal(0, after.code)
    assert.are.equal(vim.trim(sh("git rev-parse origin/master")), vim.trim(after.stdout))
    vim.cmd("PrReviewClose")
  end)

  it("re-renders when the batch file is flipped draft->verified out-of-band", function()
    pr.start("https://github.com/test/repo/pull/1")
    -- stage a draft via the batch directly, render, confirm it shows as draft
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "suggestion",
      origin = "human",
      status = "draft",
      body = "x",
      suggestion = { lines = { "y" } },
    })
    state.save_batch(b)
    require("ai-review.overlay").refresh(prkey)
    -- flip it to verified out-of-band (as peer-review would), then wait for the fs-watcher
    local b2 = state.load_or_init_batch(prkey)
    b2.comments[#b2.comments].status = "verified"
    state.save_batch(b2)
    -- the watcher debounces ~200ms; wait until an extmark carries the verified decoration
    local ns = vim.api.nvim_create_namespace("pip_prreview")
    local got_verified = vim.wait(3000, function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
          local vl = m[4] and m[4].virt_lines
          if vl and vl[1] and vl[1][1] and vl[1][1][1]:find("✓", 1, true) then
            return true
          end
        end
      end
      return false
    end, 50)
    assert.is_true(got_verified, "verified flip did not re-render within 3s")
    close_diffview_and_wait()
  end)

  it("records submitted_at and refuses a second submit", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "ok",
    })
    state.save_batch(b)
    local posts = 0
    local real_run = gh.run
    gh.run = function(cmd)
      if cmd[1] == "gh" and cmd[2] == "api" then
        posts = posts + 1
        return { code = 0, stdout = "{}", stderr = "" }
      end
      return real_run(cmd)
    end
    -- yes to everything for the first post, then no, to decline the re-submit
    local say_yes = true
    vim.fn.confirm = function()
      return say_yes and 1 or 2
    end
    pr.submit() -- opens the sheet; no Claude session, so the post takes two confirms
    pr._sheet_post()
    pr._sheet_post() -- second press: the two-phase gate's post
    assert.are.equal(1, posts)
    assert.is_not_nil(state.load_or_init_batch(prkey).submitted_at)
    say_yes = false
    pr.submit() -- second time: submitted_at set → refuse before the sheet is even touched
    assert.are.equal(1, posts)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("posts again when the user confirms a re-submit", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "ok",
    })
    state.save_batch(b)
    local posts = 0
    local real_run = gh.run
    gh.run = function(cmd)
      if cmd[1] == "gh" and cmd[2] == "api" then
        posts = posts + 1
        return { code = 0, stdout = "{}", stderr = "" }
      end
      return real_run(cmd)
    end
    vim.fn.confirm = function()
      return 1
    end -- "yes" — allow the re-submit, and each post's own confirm, through
    pr.submit()
    pr._sheet_post()
    pr._sheet_post() -- second press: the two-phase gate's post
    assert.are.equal(1, posts)
    pr.submit() -- confirmed re-submit: the already-confirmed submitted_at must NOT block it
    pr._sheet_post()
    pr._sheet_post()
    assert.are.equal(2, posts)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("PrBody writes the batch body and prefills it on reopen", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }

    vim.cmd("PrBody")
    -- :PrBody focuses the body buffer in a new split
    assert.are.equal("prreview://body/test__repo__pr1", vim.api.nvim_buf_get_name(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Overall solid.", "", "One concern about pull_policy." })
    vim.cmd("write") -- BufWriteCmd, not a disk write
    assert.is_false(vim.bo.modified)

    local b = state.load_or_init_batch(prkey)
    assert.are.equal("Overall solid.\n\nOne concern about pull_policy.", b.body)

    -- wipe the buffer, reopen: prefilled from the saved body
    vim.cmd("bwipeout!")
    vim.cmd("PrBody")
    assert.are.same(
      { "Overall solid.", "", "One concern about pull_policy." },
      vim.api.nvim_buf_get_lines(0, 0, -1, false)
    )
    vim.cmd("bwipeout!")
    close_diffview_and_wait()
  end)

  it("PrBody reveals a live body buffer as-is, without re-prefilling", function()
    pr.start("https://github.com/test/repo/pull/1")
    vim.cmd("PrBody")
    local body_buf = vim.api.nvim_get_current_buf()
    -- unsaved working edits; the batch body on disk is still ""
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half-written thought" })
    vim.cmd("wincmd p") -- leave the body window; buffer stays loaded (hidden)

    vim.cmd("PrBody") -- reveal, not recreate
    assert.are.equal(body_buf, vim.api.nvim_get_current_buf())
    assert.are.same({ "half-written thought" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("bwipeout!")
    close_diffview_and_wait()
  end)

  -- Start a review with snacks stubbed out, capturing how we handed the terminal to
  -- Claude (the opts, and the tabpage we were on when we asked for it).
  local function claude_spawn()
    local got = {}
    package.loaded.snacks = { -- stub restored in after_each
      terminal = {
        open = function(_, o)
          got.opts = o
          got.tab = vim.api.nvim_get_current_tabpage()
          got.buf = vim.api.nvim_create_buf(false, true)
          -- faithful to win.position = "current": real snacks shows the terminal in the
          -- current window, which is the window open_claude then pins with winfixbuf
          vim.api.nvim_win_set_buf(0, got.buf)
          got.win = vim.api.nvim_get_current_win()
          return { buf = got.buf, close = function() end }
        end,
      },
      picker = {
        get = function() -- open_review_tree also requires snacks
          return {}
        end,
      },
    }
    pr.start("https://github.com/test/repo/pull/1")
    assert.is_not_nil(got.opts)
    return got
  end

  it("opens the Claude terminal so that entering the pane can scroll it", function()
    -- Claude's TUI runs on the alternate screen and grabs the mouse, so it owns its
    -- scrollback: the wheel only reaches it while the window is in terminal-mode, and
    -- nvim's own buffer has nothing to scroll. Hence auto_insert — without it every
    -- click into the pane lands in normal mode and scrolling is silently dead.
    -- start_insert/enter stay false so opening a review doesn't yank focus off the diff.
    local opts = claude_spawn().opts
    assert.is_true(opts.auto_insert)
    assert.is_false(opts.start_insert)
    close_diffview_and_wait()
  end)

  it("puts Claude in its own tab and leaves you on the diff", function()
    -- nvim redraws visible windows on terminal output, and those redraws tear down
    -- cmdline completion popups. A background tab isn't drawn, so Claude costs nothing
    -- while you review. Leaving focus on the diff is the point of doing it this way.
    local got = claude_spawn()
    assert.are.equal("current", got.opts.win.position) -- fills its tab rather than splitting one
    local landed = vim.api.nvim_get_current_tabpage()
    assert.are_not.equal(got.tab, landed) -- Claude is somewhere else
    assert.is_true(vim.api.nvim_tabpage_is_valid(got.tab)) -- and still open
    assert.is_not_nil(require("diffview.lib").get_current_view()) -- we're on the review tab
    close_diffview_and_wait()
  end)

  it(":PrClaude focuses the Claude tab, and warns when there's no session", function()
    local got = claude_spawn()
    pr.claude()
    assert.are.equal(got.tab, vim.api.nvim_get_current_tabpage())
    close_diffview_and_wait()

    pr._claude = nil
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      warned = { msg = msg, lvl = lvl }
    end
    pr.claude()
    vim.notify = real_notify
    assert.is_truthy(warned and warned.msg:find("no Claude session", 1, true))
    assert.are.equal(vim.log.levels.WARN, warned.lvl)
  end)

  it("pins Claude's window so a tabline click can't strand the terminal off-screen", function()
    -- Claude fills its whole tab, so anything opening a buffer in that window (clicking a
    -- file in the tabline, an LSP jump) would swap the terminal out. The job keeps running
    -- but is displayed nowhere and there's no window to return to.
    local got = claude_spawn()
    assert.is_true(vim.wo[got.win].winfixbuf)
    local intruder = vim.api.nvim_create_buf(true, false)
    assert.is_false(pcall(vim.api.nvim_win_set_buf, got.win, intruder)) -- refused: E1513
    assert.are.equal(got.buf, vim.api.nvim_win_get_buf(got.win)) -- Claude still shown
    close_diffview_and_wait()
  end)

  it(":PrClaude puts the terminal back when something evicted it anyway", function()
    -- winfixbuf refuses most evictions, but a closed window or a plugin setting the buffer
    -- another way can still leave the job running with nothing showing it.
    local got = claude_spawn()
    local intruder = vim.api.nvim_create_buf(true, false)
    vim.wo[got.win].winfixbuf = false -- simulate an eviction winfixbuf didn't catch
    vim.api.nvim_win_set_buf(got.win, intruder)
    assert.are.equal(0, #vim.fn.win_findbuf(got.buf)) -- stranded: alive but displayed nowhere

    pr.claude()
    assert.are.equal(got.tab, vim.api.nvim_get_current_tabpage())
    assert.is_true(#vim.fn.win_findbuf(got.buf) > 0) -- restored
    assert.is_true(vim.wo[vim.api.nvim_get_current_win()].winfixbuf) -- and re-pinned
    close_diffview_and_wait()
  end)

  it("hides $TMUX from Claude so its clipboard writes don't corrupt the pane", function()
    -- When Claude sees $TMUX it wraps clipboard writes in a tmux DCS passthrough
    -- (ESC P tmux; ...). nvim's terminal emulator can't parse that and renders the
    -- base64 payload as literal text at the cursor — i.e. into Claude's own prompt.
    -- Blanking it makes Claude emit plain OSC 52, which nvim handles correctly.
    -- Empty string (not nil) because jobstart's env extends rather than removes; Claude
    -- treats blank as absent. Only these two keys, so PATH/HOME/auth still inherit.
    local opts = claude_spawn().opts
    assert.are.equal("", opts.env.TMUX)
    assert.are.equal("", opts.env.TMUX_PANE)
    close_diffview_and_wait()
  end)

  it("PrComments edits the chosen comment's body by id, leaving others untouched", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    local id1 = batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "first",
    })
    local id2 = batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "second",
    })
    state.save_batch(b)

    -- pick the SECOND comment
    vim.ui.select = function(items, _, cb)
      assert.are.equal(2, #items)
      cb(items[2], 2)
    end
    vim.cmd("PrComments")
    assert.are.equal("prreview://comment/test__repo__pr1/" .. id2, vim.api.nvim_buf_get_name(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "second, edited" })
    vim.cmd("write")

    local after = state.load_or_init_batch(prkey)
    local by_id = {}
    for _, c in ipairs(after.comments) do
      by_id[c.id] = c.body
    end
    assert.are.equal("second, edited", by_id[id2])
    assert.are.equal("first", by_id[id1]) -- untouched
    vim.cmd("bwipeout!")
    close_diffview_and_wait()
  end)

  it("PrComments notifies and opens nothing when there are no comments", function()
    pr.start("https://github.com/test/repo/pull/1")
    local opened = false
    vim.ui.select = function()
      opened = true
    end
    vim.cmd("PrComments")
    assert.is_false(opened) -- select never called
    close_diffview_and_wait()
  end)

  it("PrReviewed toggles the current file and persists it", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    -- stub the diffview current-file lookup used by M.toggle_reviewed
    local diffview = require("diffview.lib")
    local orig = diffview.get_current_view
    diffview.get_current_view = function()
      return { cur_entry = { path = "file.txt" } }
    end

    vim.cmd("PrReviewed")
    assert.is_true(batch.is_reviewed(state.load_or_init_batch(prkey), "file.txt"))
    vim.cmd("PrReviewed") -- toggle off
    assert.is_false(batch.is_reviewed(state.load_or_init_batch(prkey), "file.txt"))

    diffview.get_current_view = orig
    close_diffview_and_wait()
  end)

  it("clears reviewed marks when the PR head moves on re-start", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.toggle_reviewed(b, "file.txt")
    state.save_batch(b)
    close_diffview_and_wait()

    -- move the PR head: push a new commit to refs/pull/1/head so head_sha changes
    local seed = root .. "/seed"
    vim.fn.writefile({ "line1", "CHANGED", "line3", "line4-added", "line5-new" }, seed .. "/file.txt")
    local function g(a)
      return sh("git -C " .. seed .. " " .. a)
    end
    g("commit -qam prmove")
    g("push -q origin HEAD:refs/pull/1/head")
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git -C " .. seed .. " rev-parse HEAD") }
    end

    pr.start("https://github.com/test/repo/pull/1") -- head moved → worktree reset → reviewed cleared
    assert.are.equal(0, batch.count_reviewed(state.load_or_init_batch(prkey)))
    close_diffview_and_wait()
  end)

  it("submit warns about unreviewed files (non-blocking)", function()
    -- The default harness stub sets head_sha = origin/master (== base), so
    -- `git diff base...head` would be empty and the warning (gated on total>0)
    -- wouldn't fire. Point head at the REAL PR head (the seed's prchange commit,
    -- fetched into the clone by pr.start) so the diff touches file.txt (total=1).
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git -C " .. root .. "/seed rev-parse HEAD") }
    end
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "note",
    })
    b.body = "overall"
    state.save_batch(b) -- 0 files marked reviewed; the PR touches 1 file (file.txt)

    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if type(msg) == "string" and msg:find("not marked reviewed", 1, true) then
        warned = true
      end
      return orig_notify(msg, level)
    end
    local posts = 0
    local real_run = gh.run
    gh.run = function(cmd)
      if cmd[1] == "gh" and cmd[2] == "api" then
        posts = posts + 1
        return { code = 0, stdout = "{}", stderr = "" }
      end
      return real_run(cmd)
    end
    vim.fn.confirm = function()
      return 1
    end
    pr.submit()
    pr._sheet_post()
    pr._sheet_post() -- second press: the two-phase gate's post
    vim.notify = orig_notify
    assert.is_true(warned) -- warned...
    assert.are.equal(1, posts) -- ...but did NOT block the post
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  -- Seed a batch with one verified comment on file.txt:2, save it, and open the sheet
  -- on it — shared setup for the PrReviewSheet tests below (mirrors claude_spawn()'s
  -- role for the Claude tests above). Returns the batch key, the resulting M._sheet
  -- state, and the tab we were on before :PrReviewSheet ran.
  local function open_sheet_with_one_comment()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "original",
    })
    b.verdict = "COMMENT"
    state.save_batch(b)
    local review_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("PrReviewSheet")
    return prkey, pr._sheet, review_tab
  end

  it("PrReviewSheet opens a tab with the code pane and the sheet", function()
    local _, sheet_state, review_tab = open_sheet_with_one_comment()
    assert.is_not_nil(sheet_state)
    assert.are_not.equal(review_tab, vim.api.nvim_get_current_tabpage()) -- own tab
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0)) -- code + sheet
    local rendered = table.concat(vim.api.nvim_buf_get_lines(sheet_state.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("original", 1, true))
    assert.is_truthy(rendered:find("@@@ file.txt:2 [comment] #c1 verified", 1, true))
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("PrReviewSheet :w saves edits to the on-disk batch", function()
    local prkey, sheet_state = open_sheet_with_one_comment()
    local lines = vim.api.nvim_buf_get_lines(sheet_state.buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == "original" then
        lines[i] = "edited in the sheet"
      end
    end
    vim.api.nvim_buf_set_lines(sheet_state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(sheet_state.buf, function()
      vim.cmd("write")
    end)
    assert.are.equal("edited in the sheet", state.load_or_init_batch(prkey).comments[1].body)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("PrReviewSheet stays writable across repeated :w", function()
    -- A truthy return from an autocmd callback DELETES the autocmd, and save_sheet returns
    -- `true, dropped`. Passed directly as the BufWriteCmd callback, the second :w died with
    -- E676 and left the buffer permanently `modified` — which permanently disarms the
    -- stale-sheet guard that protects comments Claude added behind the sheet.
    local prkey, sheet_state = open_sheet_with_one_comment()
    local function rewrite_body(text)
      local lines = vim.api.nvim_buf_get_lines(sheet_state.buf, 0, -1, false)
      for i, l in ipairs(lines) do
        if l:find("edit", 1, true) or l == "original" then
          lines[i] = text
        end
      end
      vim.api.nvim_buf_set_lines(sheet_state.buf, 0, -1, false, lines)
      vim.api.nvim_buf_call(sheet_state.buf, function()
        vim.cmd("write")
      end)
    end
    rewrite_body("edit one")
    assert.are.equal("edit one", state.load_or_init_batch(prkey).comments[1].body)
    rewrite_body("edit two") -- this is the write that used to fail
    assert.are.equal("edit two", state.load_or_init_batch(prkey).comments[1].body)
    rewrite_body("edit three")
    assert.are.equal("edit three", state.load_or_init_batch(prkey).comments[1].body)
    assert.is_false(vim.bo[sheet_state.buf].modified) -- else the stale-sheet guard is disarmed
    assert.is_true(#vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = sheet_state.buf }) > 0)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("PrReviewSheet rejects a :w it cannot parse, leaving the batch untouched", function()
    local prkey = open_sheet_with_one_comment()
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR then
        warned = msg
      end
    end
    vim.api.nvim_buf_set_lines(pr._sheet.buf, 0, -1, false, { "# verdict: NONSENSE", "", "@@@ summary" })
    vim.api.nvim_buf_call(pr._sheet.buf, function()
      vim.cmd("write")
    end)
    vim.notify = real_notify
    assert.is_truthy(warned and warned:find("verdict", 1, true))
    assert.are.equal("original", state.load_or_init_batch(prkey).comments[1].body) -- untouched
    -- rejecting the write correctly leaves the buffer 'modified' (nothing was synced) —
    -- bang-close it, same as this file's other tests do for a modified scratch buffer
    vim.cmd("tabclose!")
    close_diffview_and_wait()
  end)

  it("moving in the sheet syncs the code pane once per comment, not on every keystroke within one", function()
    -- the default before_each stub points head_sha at origin/master (base, 3 lines) so
    -- most tests don't care; this one anchors a comment at line 4, which only exists on
    -- the real PR head (line1/CHANGED/line3/line4-added) — point the worktree there, same
    -- override "submit warns about unreviewed files" uses above for the same reason.
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git -C " .. root .. "/seed rev-parse HEAD") }
    end
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "first\nsecond", -- two body lines: moving between them must stay one sync
    })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 4,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "other",
    })
    b.verdict = "COMMENT"
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    local s = pr._sheet

    local h1, h2
    for i, l in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
      if l:find("^@@@ file%.txt:2 ") then
        h1 = i
      elseif l:find("^@@@ file%.txt:4 ") then
        h2 = i
      end
    end
    assert.is_not_nil(h1)
    assert.is_not_nil(h2)

    -- move onto the first comment's header: this is a real anchor change → syncs
    vim.api.nvim_win_set_cursor(s.sheet_win, { h1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
    assert.are.equal(2, vim.api.nvim_win_get_cursor(s.code_win)[1])

    -- simulate the human manually scrolling the code pane to read surrounding context —
    -- a wrongful re-sync on the next move would stomp this
    vim.api.nvim_win_set_cursor(s.code_win, { 1, 0 })

    -- move onto the SAME comment's second body line — same anchor, must NOT re-sync
    vim.api.nvim_win_set_cursor(s.sheet_win, { h1 + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
    assert.are.equal(1, vim.api.nvim_win_get_cursor(s.code_win)[1]) -- untouched

    -- move into the OTHER comment's section — a real anchor change → must re-sync
    vim.api.nvim_win_set_cursor(s.sheet_win, { h2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
    assert.are.equal(4, vim.api.nvim_win_get_cursor(s.code_win)[1])

    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("closing the sheet with unsaved edits notifies instead of silently discarding them", function()
    local prkey, sheet_state = open_sheet_with_one_comment()
    vim.api.nvim_buf_set_lines(sheet_state.buf, -1, -1, false, { "an edit never written" })
    assert.is_true(vim.bo[sheet_state.buf].modified)

    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.WARN then
        warned = msg
      end
    end
    pr._close_sheet()
    vim.notify = real_notify

    assert.is_not_nil(warned) -- the human is told, not left to discover the loss later
    assert.is_truthy(warned:find("unsaved", 1, true))
    assert.is_truthy(warned:find(state.batch_path(prkey), 1, true)) -- names which batch, not a mystery
    assert.is_nil(pr._sheet) -- torn down
    assert.are.equal("original", state.load_or_init_batch(prkey).comments[1].body) -- no auto-save attempted
    close_diffview_and_wait()
  end)

  it("M.sheet() with nothing to review does not tear down a live sheet from a different review", function()
    local prkey, sheet_state = open_sheet_with_one_comment()
    vim.api.nvim_buf_set_lines(sheet_state.buf, -1, -1, false, { "an edit never written" })
    assert.is_true(vim.bo[sheet_state.buf].modified)

    -- Simulate M.sheet() being called for a DIFFERENT, since-emptied review without a
    -- second full pr.start()/fetch/diffview cycle: M._sheet.pr is compared to current_pr
    -- by reference, so swapping it for an equal-but-distinct table reproduces the "stale
    -- sheet from another review" branch; emptying the batch reproduces "nothing to
    -- review yet" for whatever review is now current. The bug this guards against: a
    -- naive M.sheet() would tear down the (unsaved!) sheet above before ever checking
    -- whether the new review even has anything to show.
    pr._sheet.pr = vim.deepcopy(prkey)
    local b = state.load_or_init_batch(prkey)
    b.comments = {}
    b.body = ""
    state.save_batch(b)

    local warned = false
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.WARN and type(msg) == "string" and msg:find("unsaved", 1, true) then
        warned = true
      end
    end
    pr.sheet() -- "nothing to review yet" for the (now-empty) current batch
    vim.notify = real_notify

    assert.is_false(warned) -- nothing was torn down, so nothing to warn about
    assert.is_not_nil(pr._sheet)
    assert.are.equal(sheet_state.buf, pr._sheet.buf) -- still the original, unsaved sheet
    assert.is_true(vim.api.nvim_buf_is_valid(sheet_state.buf))
    assert.is_true(vim.bo[sheet_state.buf].modified) -- the unsaved edit survived

    vim.cmd("tabclose!") -- discard the deliberately-unsaved test edit
    close_diffview_and_wait()
  end)

  -- Count `gh api` POSTs without touching the network; every other gh.run call (the real
  -- git plumbing the harness depends on) passes through. gh.run is restored in after_each.
  local function count_posts(stdout)
    local posts = { n = 0 }
    local real_run = gh.run
    gh.run = function(cmd)
      if cmd[1] == "gh" and cmd[2] == "api" then
        posts.n = posts.n + 1
        return { code = 0, stdout = stdout or "{}", stderr = "" }
      end
      return real_run(cmd)
    end
    return posts
  end

  it("sheet POST re-anchors via Claude and posts nothing until confirmed", function()
    local prkey = open_sheet_with_one_comment()
    -- no snacks on the test rtp, so start() never populates pr._claude; fake a live
    -- terminal job here to exercise the chansend branch (cleared in after_each).
    pr._claude = { win = nil, buf = 1, job = 99 }
    local posts = count_posts('{"id":7}')
    local sent
    vim.api.nvim_chan_send = function(chan, data)
      sent = { chan = chan, data = data }
    end

    pr._sheet_post()
    -- the re-anchor request went out, and nothing has been posted
    assert.is_not_nil(sent)
    assert.are.equal(99, sent.chan)
    assert.is_truthy(sent.data:lower():find("re%-anchor"))
    assert.are.equal(0, posts.n)
    assert.is_not_nil(pr._sheet_wait) -- armed, waiting on the batch

    -- Claude writes the batch back; the plugin re-renders and hands control back
    local reanchored = state.load_or_init_batch(prkey)
    reanchored.comments[1].line = 3
    state.save_batch(reanchored)
    vim.fn.confirm = function()
      return 1 -- yes
    end
    pr._sheet_reanchored()
    assert.are.equal(0, posts.n) -- the re-anchor alone must not post; the human hasn't read it
    pr._sheet_post() -- second press: post what is now on screen
    assert.are.equal(1, posts.n)
    local after = state.load_or_init_batch(prkey)
    assert.is_not_nil(after.submitted_at)
    assert.are.equal(7, after.submitted_review)
    assert.are.equal(3, after.comments[1].line) -- Claude's corrected anchor, not the stale one
    assert.is_nil(pr._sheet_wait) -- the one-shot watcher was disarmed

    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("sheet POST posts nothing when the confirm is declined", function()
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    vim.fn.confirm = function()
      return 2 -- no
    end
    pr._sheet_reanchored()
    pr._sheet_post() -- second press: reaches the confirm, which is declined
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("the first <leader>p after a re-anchor does not post; the second does", function()
    local prkey = open_sheet_with_one_comment()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local posts = count_posts('{"id":3}')
    local sent = 0
    vim.api.nvim_chan_send = function()
      sent = sent + 1
    end
    local confirms = 0
    vim.fn.confirm = function()
      confirms = confirms + 1
      return 1 -- say yes to everything: the GATE, not the human, has to hold the first press
    end

    pr._sheet_post() -- press 1: asks Claude, waits
    local d = state.load_or_init_batch(prkey)
    d.comments[1].line = 3
    state.save_batch(d)

    local msg
    local real_notify = vim.notify
    vim.notify = function(m)
      if type(m) == "string" and m:find("anchor(s) changed", 1, true) then
        msg = m
      end
    end
    pr._sheet_reanchored()
    vim.notify = real_notify

    -- the re-render alone posts nothing, and says how much moved and what to do next
    assert.are.equal(0, posts.n)
    assert.are.equal(0, confirms) -- no modal took over the screen the human must read
    assert.is_truthy(msg and msg:find("1 anchor(s) changed", 1, true))
    assert.is_truthy(msg:find("<leader>p to post", 1, true))

    pr._sheet_post() -- press 2
    assert.are.equal(1, confirms) -- now the post confirm, once
    assert.are.equal(1, posts.n)
    assert.are.equal(1, sent) -- and the re-anchor was NOT re-run on the second press
    assert.is_not_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("refuses to post when the re-anchor changed anything but the anchors", function()
    local prkey = open_sheet_with_one_comment()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local posts = count_posts()
    vim.api.nvim_chan_send = function() end
    vim.fn.confirm = function()
      return 1 -- yes to anything; the contract check has to get there first
    end
    pr._sheet_post()

    -- a Claude that quietly rewords a body and flips the verdict, then says it's ready
    local d = state.load_or_init_batch(prkey)
    d.comments[1].line = 3 -- a legitimate anchor fix...
    d.comments[1].body = "words the human never approved" -- ...and one that isn't
    d.verdict = "APPROVE"
    state.save_batch(d)

    local errored
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR then
        errored = msg
      end
    end
    pr._sheet_reanchored()
    vim.notify = real_notify

    assert.is_truthy(errored and errored:find("more than the anchors", 1, true))
    assert.is_truthy(errored:find("#c1 body", 1, true)) -- itemised: which id, which field
    assert.is_truthy(errored:find("verdict COMMENT->APPROVE", 1, true))
    assert.are.equal(0, posts.n)
    -- the sheet still shows what the human approved, not Claude's rewrite
    local rendered = table.concat(vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("original", 1, true))
    assert.is_nil(rendered:find("words the human never approved", 1, true))
    -- ...and the refusal is sticky: pressing again must not post it either
    pr._sheet_post()
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("PrReviewSubmit opens the sheet rather than prompting for a verdict", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "note",
    })
    state.save_batch(b)
    local selected = false
    vim.ui.select = function(_, _, cb)
      selected = true
      cb(nil)
    end
    local posts = count_posts()
    vim.cmd("PrReviewSubmit")
    assert.is_false(selected) -- no verdict picker any more
    assert.is_not_nil(pr._sheet)
    assert.are.equal(0, posts.n) -- opening the sheet posts nothing on its own
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("sheet POST aborts, and asks Claude nothing, when the sheet will not parse", function()
    open_sheet_with_one_comment()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local posts = count_posts()
    local sent
    vim.api.nvim_chan_send = function(chan, data)
      sent = { chan = chan, data = data }
    end
    vim.fn.confirm = function()
      return 1 -- would say yes to anything; the parse failure has to get there first
    end
    vim.api.nvim_buf_set_lines(pr._sheet.buf, 0, -1, false, { "# verdict: NONSENSE", "", "@@@ summary" })
    local errored
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR then
        errored = msg
      end
    end
    pr._sheet_post()
    vim.notify = real_notify
    assert.is_truthy(errored and errored:find("verdict", 1, true))
    assert.is_nil(sent) -- Claude was never asked
    assert.is_nil(pr._sheet_wait) -- and no watcher was left armed
    assert.are.equal(0, posts.n)
    vim.cmd("tabclose!") -- the rejected write leaves the buffer modified
    close_diffview_and_wait()
  end)

  it("sheet POST with no Claude session offers to post without re-anchoring", function()
    local prkey = open_sheet_with_one_comment()
    pr._claude = nil
    local posts = count_posts()
    local prompts = {}
    vim.fn.confirm = function(msg)
      prompts[#prompts + 1] = msg
      return 2 -- decline
    end
    pr._sheet_post()
    assert.are.equal(1, #prompts) -- asked, rather than dead-ending
    assert.is_truthy(prompts[1]:find("without re-anchoring", 1, true))
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    assert.is_nil(pr._sheet_wait) -- no Claude to wait for, so nothing armed
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("the post confirm names the verified count and the drafts that will not post", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "will post",
    })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "claude",
      status = "draft",
      body = "will NOT post",
    })
    b.verdict = "REQUEST_CHANGES"
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    local posts = count_posts()
    local prompt
    vim.fn.confirm = function(msg)
      prompt = msg
      return 2
    end
    pr._sheet_reanchored()
    pr._sheet_post() -- second press: the confirm the human reads before publishing
    assert.is_not_nil(prompt)
    assert.is_truthy(prompt:find("1 verified", 1, true))
    assert.is_truthy(prompt:find("1 draft", 1, true)) -- a silently-unverified comment can't vanish
    assert.is_truthy(prompt:find("REQUEST_CHANGES", 1, true))
    assert.is_truthy(prompt:find("Summary body is empty", 1, true))
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("sheet POST bails when another submit landed while we waited on Claude", function()
    local prkey = open_sheet_with_one_comment()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local posts = count_posts()
    vim.api.nvim_chan_send = function() end
    pr._sheet_post() -- captures prior_submitted_at (nil)
    local other = state.load_or_init_batch(prkey) -- a concurrent submit lands mid-wait
    other.submitted_at = "2026-01-01T00:00:00Z"
    state.save_batch(other)
    vim.fn.confirm = function()
      return 1 -- the human says yes; the guard, not the confirm, has to stop this
    end
    pr._sheet_reanchored()
    pr._sheet_post() -- second press: the concurrent-submit guard, not the confirm, must stop this
    assert.are.equal(0, posts.n)
    assert.are.equal("2026-01-01T00:00:00Z", state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("closing the sheet disarms the re-anchor watcher", function()
    open_sheet_with_one_comment()
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function() end
    pr._sheet_post()
    assert.is_not_nil(pr._sheet_wait)
    vim.cmd("tabclose") -- BufWipeout has to take the watcher with it
    assert.is_nil(pr._sheet_wait)
    close_diffview_and_wait()
  end)

  it("refuses to post a batch whose verdict isn't a real one, rather than filing a pending review", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "note",
    })
    -- batch.new defaults the verdict to COMMENT, so only a batch written by another tool (or
    -- an older version) can reach the POST without a usable one. Simulate that.
    b.verdict = "LGTM?"
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    local posts = count_posts()
    vim.fn.confirm = function()
      return 1
    end
    local errored
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR then
        errored = msg
      end
    end
    pr._sheet_reanchored()
    vim.notify = real_notify
    assert.are.equal(0, posts.n)
    assert.is_truthy(errored and errored:find("verdict", 1, true))
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  -- Seed a batch with two verified comments (both present BEFORE the sheet opens, so the
  -- sheet is never stale) and open the sheet on it, so a test can delete one section.
  local function open_sheet_with_two_comments(verdict, body)
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "keeps",
    })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "the human deletes this one",
    })
    b.verdict = verdict
    b.body = body
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    return prkey
  end

  it("refuses to post a sheet gone stale behind us, refreshing it instead of deleting the comment", function()
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local sent
    vim.api.nvim_chan_send = function(_, data)
      sent = data
    end
    vim.fn.confirm = function()
      return 1 -- yes to anything; the staleness check has to get there first
    end

    -- Claude's session adds a comment to the batch. Nothing re-renders an open sheet, so the
    -- buffer still shows only #c1 — and sheet.apply is a replace, not a merge.
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "claude",
      status = "verified",
      body = "claude added this while the sheet was open",
    })
    state.save_batch(b)
    assert.are.equal(2, #state.load_or_init_batch(prkey).comments)

    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.WARN then
        warned = msg
      end
    end
    pr._sheet_post() -- the human typed nothing
    vim.notify = real_notify

    assert.are.equal(2, #state.load_or_init_batch(prkey).comments) -- NOT deleted from disk
    assert.are.equal(0, posts.n)
    assert.is_nil(sent) -- Claude was never asked
    assert.is_nil(pr._sheet_wait)
    assert.is_truthy(warned and warned:find("while this sheet was open", 1, true))
    -- and the sheet now shows what the human would otherwise have silently destroyed
    local rendered = table.concat(vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("claude added this while the sheet was open", 1, true))
    assert.is_false(vim.bo[pr._sheet.buf].modified)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  -- Open the sheet on a single DRAFT comment, so a test can flip it to verified behind the
  -- sheet the way Claude's §5b verification pass does.
  local function open_sheet_with_one_draft()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "draft",
      body = "needs verifying",
    })
    b.verdict = "COMMENT"
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    return prkey
  end

  -- Replace the first buffer line equal to `from` with `to`, leaving the buffer `modified`.
  local function edit_sheet_line(from, to)
    local lines = vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == from then
        lines[i] = to
        break
      end
    end
    vim.api.nvim_buf_set_lines(pr._sheet.buf, 0, -1, false, lines)
    assert.is_true(vim.bo[pr._sheet.buf].modified)
  end

  -- Capture the "sheet saved (...)" notify around a `:w` of the sheet.
  local function write_sheet()
    local saved_msg
    local real_notify = vim.notify
    vim.notify = function(msg)
      if type(msg) == "string" and msg:find("sheet saved", 1, true) then
        saved_msg = msg
      end
    end
    vim.api.nvim_buf_call(pr._sheet.buf, function()
      vim.cmd("write")
    end)
    vim.notify = real_notify
    return saved_msg
  end

  it("a comment Claude added behind a modified sheet survives the save instead of being deleted", function()
    local prkey = open_sheet_with_one_comment()
    -- The human edits a body, so the buffer is `modified` and the stale-sheet guard steps
    -- aside — which is exactly the path on which sheet.apply used to be a straight replace.
    edit_sheet_line("original", "the human's edit")

    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "claude",
      status = "verified",
      body = "claude added this",
    })
    state.save_batch(b)

    local saved_msg = write_sheet()

    local after = state.load_or_init_batch(prkey)
    assert.are.equal(2, #after.comments) -- Claude's comment was NOT deleted from disk
    assert.are.equal("the human's edit", after.comments[1].body) -- the sheet still wins for body
    assert.are.equal("claude added this", after.comments[2].body)
    -- reported separately: the human dropped nothing, one change came in from the batch
    assert.is_truthy(saved_msg and saved_msg:find("0 dropped", 1, true))
    assert.is_truthy(saved_msg:find("1 merged from the batch", 1, true))
    -- ...and the buffer now shows it, so the POST confirm's counts aren't built on a fiction
    local rendered = table.concat(vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("claude added this", 1, true))
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("a draft->verified flip landing behind a modified sheet is not reverted by the save", function()
    local prkey = open_sheet_with_one_draft()
    edit_sheet_line("needs verifying", "reworded by the human")

    local d = state.load_or_init_batch(prkey) -- Claude verifies it while the human types
    d.comments[1].status = "verified"
    state.save_batch(d)

    local saved_msg = write_sheet()

    local after = state.load_or_init_batch(prkey)
    -- reverting this to `draft` is how a comment the human read in the sheet silently doesn't post
    assert.are.equal("verified", after.comments[1].status)
    assert.are.equal("reworded by the human", after.comments[1].body) -- sheet still wins for body
    assert.is_truthy(saved_msg and saved_msg:find("1 merged from the batch", 1, true))
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("refuses to post an unmodified sheet whose statuses the batch has moved on from", function()
    local prkey = open_sheet_with_one_draft()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local sent
    vim.api.nvim_chan_send = function(_, data)
      sent = data
    end
    vim.fn.confirm = function()
      return 1 -- yes to anything; the staleness check has to get there first
    end

    local d = state.load_or_init_batch(prkey)
    d.comments[1].status = "verified" -- a flip, no new comment: id presence alone can't see this
    state.save_batch(d)

    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.WARN then
        warned = msg
      end
    end
    pr._sheet_post() -- the human typed nothing
    vim.notify = real_notify

    assert.is_truthy(warned and warned:find("status change", 1, true))
    assert.are.equal(0, posts.n)
    assert.is_nil(sent) -- Claude was never asked
    assert.is_nil(pr._sheet_wait)
    -- the sheet now shows the flip, so the next press posts what the human has actually read
    local rendered = table.concat(vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("#c1 verified", 1, true))
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("the post confirm names comments the human deleted from the sheet", function()
    local prkey = open_sheet_with_two_comments("COMMENT", "overall")
    local posts = count_posts()
    pr._claude = nil -- no session: one confirm to skip re-anchoring, then the post confirm
    -- delete #c2's whole section by rewriting the document without it
    vim.api.nvim_buf_set_lines(pr._sheet.buf, 0, -1, false, {
      "# verdict: COMMENT",
      "",
      "@@@ summary",
      "overall",
      "",
      "@@@ file.txt:2 [comment] #c1 verified",
      "keeps",
    })
    local prompts = {}
    vim.fn.confirm = function(msg)
      prompts[#prompts + 1] = msg
      if msg:find("without re-anchoring", 1, true) then
        return 1 -- proceed to the post confirm
      end
      return 2 -- ...and decline that, so nothing posts
    end
    pr._sheet_post()
    pr._sheet_post() -- second press: the two-phase gate's post confirm

    local post_prompt = prompts[#prompts]
    assert.are.equal(2, #prompts)
    assert.is_truthy(post_prompt:find("1 verified", 1, true))
    -- the spec's designated safety net for "deleting a section deletes a comment"
    assert.is_truthy(post_prompt:find("1 comment(s) removed from the sheet will NOT post.", 1, true))
    assert.are.equal(0, posts.n)
    assert.are.equal(1, #state.load_or_init_batch(prkey).comments) -- the deletion did apply
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("re-pins commit_id to the moved head, and posts exactly the verified comments", function()
    pr.start("https://github.com/test/repo/pull/1")
    local prkey = { owner = "test", repo = "repo", number = 1 }
    local b = state.load_or_init_batch(prkey)
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 2,
      kind = "comment",
      origin = "human",
      status = "verified",
      body = "this one posts",
    })
    batch.add(b, {
      path = "file.txt",
      side = "RIGHT",
      line = 3,
      kind = "comment",
      origin = "claude",
      status = "draft",
      body = "this one must not post",
    })
    b.verdict = "REQUEST_CHANGES"
    b.body = "overall assessment"
    state.save_batch(b)
    vim.cmd("PrReviewSheet")
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function() end

    -- the PR head moves after :PrReviewStart pinned the batch to origin/master
    local moved_sha = sh("git -C " .. root .. "/seed rev-parse HEAD")
    gh.pr_info = function()
      return { base = "master", head_sha = moved_sha }
    end

    -- read the JSON gh api is actually handed, not just that it was called
    local payload
    local real_run = gh.run
    gh.run = function(cmd)
      if cmd[1] == "gh" and cmd[2] == "api" then
        for i, a in ipairs(cmd) do
          if a == "--input" then
            payload = vim.json.decode(table.concat(vim.fn.readfile(cmd[i + 1]), "\n"))
          end
        end
        return { code = 0, stdout = '{"id":11}', stderr = "" }
      end
      return real_run(cmd)
    end
    vim.fn.confirm = function()
      return 1
    end
    local wt = state.worktree_path(prkey)
    pr._sheet_post()
    -- re-pinned before Claude was asked, so the corrected anchors and commit_id agree
    assert.are.equal(moved_sha, state.load_or_init_batch(prkey).pr.head_sha)
    -- ...and the rest of the state Claude is told to read moved with it, or it would be
    -- re-anchoring "on the PR head" against a stale sha and a stale checkout
    assert.are.equal(moved_sha, sh("git -C " .. wt .. " rev-parse HEAD"))
    assert.are.equal(moved_sha, state.read_active().head_sha)
    pr._sheet_reanchored()
    pr._sheet_post() -- second press: the two-phase gate's post

    assert.is_not_nil(payload)
    assert.are.equal("REQUEST_CHANGES", payload.event)
    assert.are.equal(moved_sha, payload.commit_id)
    assert.are.equal("overall assessment", payload.body)
    assert.are.equal(1, #payload.comments) -- the draft is absent from what GitHub receives
    assert.are.equal("this one posts", payload.comments[1].body)
    assert.are.equal(2, payload.comments[1].line)
    assert.are.equal("RIGHT", payload.comments[1].side)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("declining the head-moved confirm posts nothing and leaves the pinned head alone", function()
    local prkey = open_sheet_with_one_comment()
    local pinned = state.load_or_init_batch(prkey).pr.head_sha
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local sent
    vim.api.nvim_chan_send = function(_, data)
      sent = data
    end
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git -C " .. root .. "/seed rev-parse HEAD") }
    end
    local prompt
    vim.fn.confirm = function(msg)
      prompt = msg
      return 2
    end
    pr._sheet_post()
    assert.is_truthy(prompt and prompt:find("PR head moved", 1, true))
    assert.are.equal(0, posts.n)
    assert.is_nil(sent)
    assert.is_nil(pr._sheet_wait)
    assert.are.equal(pinned, state.load_or_init_batch(prkey).pr.head_sha) -- not re-pinned
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("a head move that conflicts with the review branch moves nothing and posts nothing", function()
    local prkey = open_sheet_with_one_comment()
    local pinned = state.load_or_init_batch(prkey).pr.head_sha
    local wt = state.worktree_path(prkey)
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    local sent
    vim.api.nvim_chan_send = function(_, data)
      sent = data
    end
    vim.fn.confirm = function()
      return 1 -- yes to the drift confirm; the conflicting rebase has to stop this
    end

    -- A verification commit on review/pr-1-suggestions, on the same line the new PR head
    -- rewrites. `suggestion.verified_sha` names commits like this one, which is why the
    -- worktree is moved by rebase: `reset --hard` would silently destroy them.
    vim.fn.writefile({ "line1", "VERIFIED-FIX", "line3" }, wt .. "/file.txt")
    sh("git -C " .. wt .. " commit -qam claude-verified-fix")
    local verification_sha = sh("git -C " .. wt .. " rev-parse HEAD")
    local active_before = state.read_active().head_sha

    local moved_sha = sh("git -C " .. root .. "/seed rev-parse HEAD")
    gh.pr_info = function()
      return { base = "master", head_sha = moved_sha }
    end

    local errored
    local real_notify = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR then
        errored = msg
      end
    end
    pr._sheet_post()
    vim.notify = real_notify

    assert.is_truthy(errored and errored:find("conflicts with review/pr-1-suggestions", 1, true))
    assert.are.equal(0, posts.n)
    assert.is_nil(sent) -- Claude was never asked to re-anchor against a head we couldn't reach
    assert.is_nil(pr._sheet_wait)
    -- nothing moved: batch pin, active.json and the worktree are all where they were...
    assert.are.equal(pinned, state.load_or_init_batch(prkey).pr.head_sha)
    assert.are.equal(active_before, state.read_active().head_sha)
    assert.are.equal(verification_sha, sh("git -C " .. wt .. " rev-parse HEAD")) -- commit intact
    -- ...and the rebase was aborted, not left half-applied (mid-rebase HEAD is detached)
    assert.are.equal("review/pr-1-suggestions", sh("git -C " .. wt .. " rev-parse --abbrev-ref HEAD"))
    assert.are.equal("", sh("git -C " .. wt .. " status --porcelain"))
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  -- Write the batch the way ANOTHER process (Claude) does. state.save_batch records the mtime
  -- of every write THIS process makes and the re-anchor watcher ignores those, so an in-process
  -- save_batch can no longer stand in for Claude — that is the point of the suppression.
  local function foreign_save(prkey, b)
    local path = state.batch_path(prkey)
    local tmp = path .. ".foreign"
    local fd = assert(io.open(tmp, "w"))
    fd:write(batch.encode(b))
    fd:close()
    assert(os.rename(tmp, path)) -- atomic, like state.save_batch's own write
  end

  it("a :w in the sheet during the wait does not wake the re-anchor confirm; a foreign write does", function()
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function() end
    local confirms = 0
    vim.fn.confirm = function()
      confirms = confirms + 1
      return 2 -- decline, so a spurious wake can't post either
    end
    pr._sheet_post()
    assert.is_not_nil(pr._sheet_wait)
    assert.are.equal(0, confirms)

    -- the human saves the sheet while waiting: our own write, not Claude's re-anchor
    vim.api.nvim_buf_set_lines(pr._sheet.buf, -1, -1, false, { "a thought added while waiting" })
    vim.api.nvim_buf_call(pr._sheet.buf, function()
      vim.cmd("write")
    end)
    vim.wait(500)
    assert.are.equal(0, confirms) -- no consent asked for a re-anchor that never happened
    assert.are.equal(0, posts.n)
    assert.is_not_nil(pr._sheet_wait) -- still waiting on Claude

    -- ...but a write we did NOT make still wakes it, so the suppression didn't break the wait
    local d = state.load_or_init_batch(prkey)
    d.comments[1].line = 3
    foreign_save(prkey, d)
    vim.wait(3000, function()
      return pr._sheet_wait == nil
    end, 20)
    assert.is_nil(pr._sheet_wait) -- woken and disarmed by the write that wasn't ours
    -- the wake re-renders and hands back (the two-phase gate); it must not confirm or post
    local rendered = table.concat(vim.api.nvim_buf_get_lines(pr._sheet.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("@@@ file.txt:3 ", 1, true)) -- Claude's corrected anchor
    assert.are.equal(0, confirms)
    assert.are.equal(0, posts.n)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("a batch write from somewhere other than the sheet does not raise a post confirm", function()
    -- mark_self_write used to be called from save_sheet and the re-pin only, so :PrReviewed,
    -- :PrBody, :PrComments and the worktree draft-staging handler each woke the watcher and
    -- produced a confirm byte-identical to the genuine post-re-anchor one.
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function() end
    local confirms = 0
    vim.fn.confirm = function()
      confirms = confirms + 1
      return 2 -- decline, so even a spurious wake can't post
    end
    pr._sheet_post()
    assert.is_not_nil(pr._sheet_wait)

    local diffview = require("diffview.lib")
    local orig = diffview.get_current_view
    diffview.get_current_view = function()
      return { cur_entry = { path = "file.txt" } }
    end
    vim.cmd("PrReviewed") -- a real batch write, from a command that isn't the sheet
    diffview.get_current_view = orig
    vim.wait(500)

    assert.is_true(batch.is_reviewed(state.load_or_init_batch(prkey), "file.txt")) -- it did write
    assert.are.equal(0, confirms) -- ...and it did not ask to publish anything
    assert.are.equal(0, posts.n)
    assert.is_not_nil(pr._sheet_wait) -- still waiting on the real answer
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("a failed chansend offers the no-re-anchor post instead of a wait that can only time out", function()
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function()
      error("Invalid channel id") -- what a dead terminal job really does
    end
    local prompts = {}
    vim.fn.confirm = function(msg)
      prompts[#prompts + 1] = msg
      return 2 -- decline, so nothing posts
    end
    pr._sheet_post()
    assert.are.equal(1, #prompts)
    assert.is_truthy(prompts[1]:find("Couldn't send to the Claude session", 1, true))
    assert.is_truthy(prompts[1]:find("without re-anchoring", 1, true))
    assert.is_nil(pr._sheet_wait) -- no 120s dead-end
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)

  it("a second <leader>p that aborts supersedes the first wait instead of leaving it armed", function()
    local prkey = open_sheet_with_one_comment()
    local posts = count_posts()
    pr._claude = { win = nil, buf = 1, job = 99 }
    vim.api.nvim_chan_send = function() end
    local confirms = 0
    vim.fn.confirm = function()
      confirms = confirms + 1
      return 1
    end
    pr._sheet_post() -- no drift, so Claude is asked and a watcher arms without any confirm
    assert.is_not_nil(pr._sheet_wait)
    assert.are.equal(0, confirms)

    -- the PR author pushes, and on the second press the human declines the drift confirm
    gh.pr_info = function()
      return { base = "master", head_sha = sh("git -C " .. root .. "/seed rev-parse HEAD") }
    end
    vim.fn.confirm = function()
      confirms = confirms + 1
      return 2
    end
    pr._sheet_post()
    assert.are.equal(1, confirms) -- the drift confirm, declined
    assert.is_nil(pr._sheet_wait) -- the first wait was superseded, not left live

    -- Claude now answers the FIRST request. With that wait gone its re-anchor must not raise a
    -- post confirm built on premises the human has just rejected.
    local d = state.load_or_init_batch(prkey)
    d.comments[1].line = 3
    state.save_batch(d)
    vim.wait(500)
    assert.are.equal(1, confirms) -- no unbidden confirm after the decline
    assert.are.equal(0, posts.n)
    assert.is_nil(state.load_or_init_batch(prkey).submitted_at)
    vim.cmd("tabclose")
    close_diffview_and_wait()
  end)
end)
