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
    close_diffview_and_wait()
    if orig_cwd then
      vim.cmd.cd(orig_cwd)
    end
    url.parse_remote, gh.pr_info, gh.run, diff.cursor_anchor, vim.ui.input, vim.ui.select, vim.fn.confirm, state.default_root =
      saved.parse_remote,
      saved.pr_info,
      saved.gh_run,
      saved.cursor_anchor,
      saved.ui_input,
      saved.ui_select,
      saved.confirm,
      saved.default_root
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
    vim.ui.select = function(_, _, cb)
      cb("COMMENT")
    end
    vim.fn.confirm = function()
      return 2
    end -- "no" to any re-submit confirm
    pr.submit()
    assert.are.equal(1, posts)
    assert.is_not_nil(state.load_or_init_batch(prkey).submitted_at)
    pr.submit() -- second time: submitted_at set → refuse
    assert.are.equal(1, posts)
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
    vim.ui.select = function(_, _, cb)
      cb("COMMENT")
    end
    vim.fn.confirm = function()
      return 1
    end -- "yes" — allow the re-submit through
    pr.submit()
    assert.are.equal(1, posts)
    pr.submit() -- confirmed re-submit: the already-confirmed submitted_at must NOT block it
    assert.are.equal(2, posts)
    close_diffview_and_wait()
  end)
end)
