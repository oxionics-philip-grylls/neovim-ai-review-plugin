---@mod ai-review In-Neovim GitHub PR review: commands + glue.

local url = require("ai-review.url")
local batch = require("ai-review.batch")
local state = require("ai-review.state")
local gh = require("ai-review.gh")
local diff = require("ai-review.diff")
local overlay = require("ai-review.overlay")
local nudge = require("ai-review.nudge")
local panel = require("ai-review.panel")
local sheet = require("ai-review.sheet")

local M = {}
---@type prreview.PR?
local current_pr = nil
---@type uv.uv_fs_event_t?
M._watch = nil
-- Snacks explorer picker opened on the RIGHT during a review (diffview's diff panel
-- holds the left). Captured so we close exactly this one on :PrReviewClose.
M._review_tree = nil
-- The Claude /peer-review session, run as a plugin-owned snacks terminal (bottom split).
-- job is its channel — nudges are nvim_chan_send'd straight to Claude's stdin.
M._claude = nil ---@type { win: any, buf: integer, job: integer }|nil
-- The review sheet: the batch as one editable document in its own tab, code pane beside it.
---@type { buf: integer, tab: integer, code_win: integer, sheet_win: integer, pr: prreview.PR, last_anchor: { path: string, line: integer }?, prior_submitted_at: string? }|nil
M._sheet = nil
-- One-shot watcher armed while the sheet POST waits for Claude to write the batch back.
---@type uv.uv_fs_event_t?
M._sheet_wait = nil

--- Stop the batch fs-watcher (idempotent).
function M._stop_watch()
  if M._watch then
    pcall(function()
      M._watch:stop()
      M._watch:close()
    end)
    M._watch = nil
  end
end

--- Stop the sheet POST's one-shot re-anchor watcher (idempotent). Kept beside _stop_watch
--- because it carries the same hazard: a watcher outliving what it was waiting for is how
--- the confirm-then-post flow gets re-entered at a moment nobody asked for, so every
--- teardown path has to come through here.
function M._stop_sheet_wait()
  if M._sheet_wait then
    pcall(function()
      M._sheet_wait:stop()
      M._sheet_wait:close()
    end)
    M._sheet_wait = nil
  end
end

--- Close the review's right-side file tree, if we opened one (idempotent).
function M._close_review_tree()
  if M._review_tree then
    pcall(function()
      M._review_tree:close()
    end)
    M._review_tree = nil
  end
end

--- Kill the Claude terminal + its job, if we spawned one (idempotent, pcall-guarded).
function M._close_claude()
  if M._claude then
    pcall(vim.fn.jobstop, M._claude.job)
    if M._claude.win then
      pcall(function()
        M._claude.win:close()
      end)
    end
    M._claude = nil
  end
end

--- Close the review sheet's tab, if we opened one (idempotent, pcall-guarded). The sheet
--- buffer is bufhidden=wipe, so closing its tab already disposes of the buffer and fires
--- BufWipeout (which clears M._sheet) — this just forces that from outside the sheet's own
--- UI, e.g. on :PrReviewClose, so a stale sheet from a closed review can't linger.
---
--- Never silently discards unsaved edits: a teardown path (:PrReviewClose, VimLeavePre,
--- M.sheet() replacing a stale sheet) must not be interactive or block on a prompt, and
--- must not attempt an auto-save (a parse failure there would have nowhere to surface),
--- so an unsaved buffer just gets a clear notify naming the batch path before closing —
--- the human can reopen :PrReviewSheet and re-apply from memory, but at least isn't left
--- wondering where the edits went.
function M._close_sheet()
  M._stop_sheet_wait() -- a sheet being torn down can't still be waiting on a re-anchor
  if M._sheet and vim.api.nvim_tabpage_is_valid(M._sheet.tab) then
    if vim.api.nvim_buf_is_valid(M._sheet.buf) and vim.bo[M._sheet.buf].modified then
      vim.notify(
        "prreview: closed the review sheet with unsaved edits — they were discarded ("
          .. state.batch_path(M._sheet.pr)
          .. " was not changed)",
        vim.log.levels.WARN
      )
    end
    pcall(function()
      vim.api.nvim_set_current_tabpage(M._sheet.tab)
      vim.cmd("tabclose!")
    end)
  end
  M._sheet = nil
end

--- Open a normal file tree on the RIGHT for the review, alongside diffview's diff panel.
--- No-op when snacks isn't installed (e.g. headless tests), so it never breaks a review.
local function open_review_tree()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return
  end
  pcall(function()
    -- Snacks keeps ONE explorer per source: calling explorer() while one is already
    -- open toggles it SHUT. So if the user already has their normal <leader>e explorer
    -- open, leave it be — bail rather than hijack/close it (we just skip the right tree
    -- this review). We only ever open + close OUR own tree.
    if #(snacks.picker.get({ source = "explorer" }) or {}) > 0 then
      return
    end
    -- Open files in a vsplit, not the picker's heuristic "main" window — during a review
    -- that main window is usually a diff pane, so a plain <CR> would clobber the diff.
    M._review_tree = snacks.explorer({
      layout = { layout = { position = "right" } },
      win = {
        list = {
          keys = {
            ["<CR>"] = "edit_vsplit",
            ["l"] = "edit_vsplit",
            ["<2-LeftMouse>"] = "edit_vsplit",
          },
        },
      },
    })
  end)
end

--- Spawn the Claude /peer-review session as a terminal we own in its OWN TAB, capturing
--- its channel for chansend nudges. No-op without snacks (headless tests).
---
--- Own tab, not a split in the review tab: it keeps the review layout to the diff and the
--- tree, which is what we want anyway. It was ALSO an attempt to stop the terminal's output
--- disturbing command-line completion popups — that did NOT work; the flicker persists from
--- a background tab, so don't credit this layout with fixing it. (Not noice either — it
--- flickers with noice disabled.) Focus returns to the review tab; :PrClaude jumps to Claude.
---
--- auto_insert: Claude's TUI runs on the alternate screen and grabs the mouse, so it owns
--- its scrollback — nvim's terminal buffer has nothing to scroll, and the wheel only
--- reaches Claude while the window is in terminal-mode. Without this, entering the pane
--- lands in normal mode and both scrolling and Claude's own drag-select are dead.
---@param pr_url string
local function open_claude(pr_url)
  M._close_claude() -- a restart without :PrReviewClose would otherwise orphan the old job+window
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return
  end
  pcall(function()
    local review_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local term = snacks.terminal.open(('claude "/peer-review %s"'):format(pr_url), {
      cwd = vim.uv.cwd(),
      -- Blank $TMUX: nvim usually runs inside tmux, and an inherited $TMUX makes Claude
      -- wrap clipboard writes in a tmux DCS passthrough that nvim's terminal can't parse,
      -- so the base64 payload renders as literal text into Claude's own prompt. Blank
      -- rather than removed (jobstart's env extends, it can't unset); Claude reads blank
      -- as absent and falls back to plain OSC 52, which nvim honours.
      env = { TMUX = "", TMUX_PANE = "" },
      start_insert = false,
      auto_insert = true,
      win = { position = "current" }, -- fill the tab we just made, don't split it
    })
    local buf = term and term.buf
    if not buf then
      -- don't strand the user on the empty scratch tab we opened for a terminal that never came
      pcall(vim.cmd, "tabclose")
      pcall(vim.api.nvim_set_current_tabpage, review_tab)
      return
    end
    -- winfixbuf: Claude fills its whole tab, so anything that opens a buffer in the current
    -- window (clicking a file in the tabline, an LSP jump, a quickfix entry) would swap the
    -- terminal out. The job keeps running but is displayed nowhere, which strands the user
    -- with no window to return to. Refusing the swap (E1513) is far kinder than that.
    pcall(function()
      vim.wo[vim.api.nvim_get_current_win()].winfixbuf = true
    end)
    M._claude = {
      win = term,
      buf = buf,
      tab = vim.api.nvim_get_current_tabpage(),
      job = vim.b[buf].terminal_job_id,
    }
    -- back to the diff: the review is what you drive, Claude just runs
    if vim.api.nvim_tabpage_is_valid(review_tab) then
      pcall(vim.api.nvim_set_current_tabpage, review_tab)
    end
    if not M._claude.job then
      -- terminal_job_id can lag the open by a tick; grab it on the next loop
      vim.defer_fn(function()
        if M._claude and M._claude.buf == buf then
          M._claude.job = vim.b[buf].terminal_job_id
        end
      end, 50)
    end
  end)
end

--- Jump to the Claude tab. Claude lives off-screen (see open_claude), so this is how you
--- go look at it; it never spawns a session, only focuses one that's already running.
function M.claude()
  if not (M._claude and M._claude.tab and vim.api.nvim_tabpage_is_valid(M._claude.tab)) then
    vim.notify("prreview: no Claude session (:PrReviewStart starts one)", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_tabpage(M._claude.tab)
  if not vim.api.nvim_buf_is_valid(M._claude.buf) then
    vim.notify("prreview: the Claude terminal buffer is gone — :PrReviewStart to restart", vim.log.levels.WARN)
    return
  end
  -- Recovery: winfixbuf refuses most evictions, but a closed window or a plugin that sets the
  -- buffer another way can still leave the job running with nothing showing it. Put it back
  -- rather than leaving the tab stuck on whatever replaced it.
  if #vim.fn.win_findbuf(M._claude.buf) == 0 then
    local win = vim.api.nvim_get_current_win()
    pcall(function()
      vim.wo[win].winfixbuf = false -- else the restore is refused by our own guard
    end)
    pcall(vim.api.nvim_win_set_buf, win, M._claude.buf)
    pcall(function()
      vim.wo[win].winfixbuf = true
    end)
  end
end

--- Strip scrollbind/cursorbind from every non-diff SPLIT in the review tab, then re-sync
--- the diff pair. The snacks tree (and any file opened via a split) is created FROM a diff
--- window, so Vim copies those options onto it — it silently joins the diff panes' scroll
--- group and desyncs them. All pcall-guarded (diffview internals; no-op on any failure).
---
--- Bails while the cmdline is open. A completion popup is a floating WINDOW, so it fires the
--- WinNew that schedules this, and running here dismissed the popup on every keystroke — the
--- diff panes cannot desync from a menu that lives for one character anyway. Floats are also
--- skipped below: they never inherit scrollbind from the split they were opened over.
function M._guard_scrollbind()
  if vim.fn.getcmdtype() ~= "" then
    return
  end
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end
  pcall(function()
    local view = lib.get_current_view()
    if not (view and view.cur_layout and view.cur_layout.windows) then
      return
    end
    local is_diff, diffs_valid = {}, true
    for _, w in ipairs(view.cur_layout.windows) do
      if w.id then
        is_diff[w.id] = true
        if not vim.api.nvim_win_is_valid(w.id) then
          diffs_valid = false
        end
      end
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local floating = vim.api.nvim_win_get_config(win).relative ~= ""
      if not is_diff[win] and not floating and vim.api.nvim_win_is_valid(win) then
        pcall(function()
          vim.wo[win].scrollbind = false
          vim.wo[win].cursorbind = false
        end)
      end
    end
    -- skip the re-sync when the diff windows are gone (e.g. right after close_diffs):
    -- sync_scroll would throw on the stale ids — harmless under pcall, but pointless.
    if diffs_valid and type(view.cur_layout.sync_scroll) == "function" then
      pcall(function()
        view.cur_layout:sync_scroll()
      end)
    end
  end)
end

--- Close just the diff windows, leaving diffview's file panel open, so you can pick
--- another file from the tree — diffview recreates the diffs on select (ensure_layout).
--- This is the "close this diff, keep browsing" that plain :DiffviewClose isn't.
function M.close_diffs()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end
  pcall(function()
    local view = lib.get_current_view()
    if not (view and view.cur_layout and view.cur_layout.windows) then
      return
    end
    for _, w in ipairs(view.cur_layout.windows) do
      if w.id and vim.api.nvim_win_is_valid(w.id) then
        pcall(vim.api.nvim_win_close, w.id, false)
      end
    end
    -- land the cursor in the panel so the next file pick (which reopens the diffs) is one keystroke away
    if view.panel and view.panel.winid then
      pcall(vim.api.nvim_set_current_win, view.panel.winid)
    end
  end)
end

--- Watch the batch's PARENT DIRECTORY (not the file itself), filtered to its basename.
--- state.save_batch writes atomically (tmp + os.rename), replacing the file's inode on
--- every write; vim.uv.new_fs_event watching the file path holds the old inode and
--- typically stops firing after that first rename. Watching the directory survives it.
---@param pr prreview.PR
local function start_watch(pr)
  M._stop_watch()
  local bp = state.batch_path(pr)
  local dir = vim.fn.fnamemodify(bp, ":h")
  local base = vim.fn.fnamemodify(bp, ":t")
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local pending = false
  -- libuv fs_event:start returns 0 on success, nil+errmsg on failure — 0 is truthy
  -- in Lua, so test `~= 0`, not `not rc`.
  local rc = handle:start(dir, {}, function(_, filename)
    if filename and filename ~= base then
      return
    end
    if pending then
      return
    end
    pending = true
    -- Debounce: peer-review's own edits can fire multiple dir events in quick
    -- succession; coalesce them into one re-render ~200ms after the first of a burst.
    vim.defer_fn(function()
      pending = false
      if current_pr then
        overlay.refresh(current_pr)
      end
    end, 200)
  end)
  if rc ~= 0 then
    vim.notify("prreview: live re-render off — use :PrReviewRefresh", vim.log.levels.WARN)
    pcall(function()
      handle:close()
    end)
    return
  end
  M._watch = handle
end

---@param arg string  PR URL, or a bare number when inside the repo.
---@return prreview.PR?
local function resolve_pr(arg)
  local ref = url.parse_pr_url(arg)
  if ref then
    -- a pasted URL names its own owner/repo, but every fetch/diff below runs
    -- against the CWD's origin; if they disagree we'd review one repo and post to another
    local r = gh.run({ "git", "remote", "get-url", "origin" })
    local local_remote = r.code == 0 and url.parse_remote(r.stdout) or nil
    -- GitHub owner/repo are case-insensitive; compare lowercased so a differently-cased paste isn't falsely refused.
    if
      not local_remote
      or local_remote.owner:lower() ~= ref.owner:lower()
      or local_remote.repo:lower() ~= ref.repo:lower()
    then
      local local_desc = local_remote and (local_remote.owner .. "/" .. local_remote.repo) or "<unresolved>"
      vim.notify(
        ("prreview: URL targets %s/%s but this repo's origin is %s — refusing (would review the wrong repo)"):format(
          ref.owner,
          ref.repo,
          local_desc
        ),
        vim.log.levels.ERROR
      )
      return nil
    end
  else
    local n = tonumber(arg)
    if not n then
      vim.notify("prreview: pass a GitHub PR URL (or a number inside the repo)", vim.log.levels.ERROR)
      return nil
    end
    local r = gh.run({ "git", "remote", "get-url", "origin" })
    local remote = r.code == 0 and url.parse_remote(r.stdout) or nil
    if not remote then
      vim.notify("prreview: could not resolve owner/repo from origin", vim.log.levels.ERROR)
      return nil
    end
    ref = { owner = remote.owner, repo = remote.repo, number = n }
  end
  local info = gh.pr_info(ref.owner, ref.repo, ref.number)
  if not info then
    vim.notify("prreview: gh pr view failed (auth? PR exists?)", vim.log.levels.ERROR)
    return nil
  end
  return { owner = ref.owner, repo = ref.repo, number = ref.number, base = info.base, head_sha = info.head_sha }
end

--- Number of files the PR touches (origin/<base>...<head_sha>), or nil if git fails.
--- Used for the "N/M reviewed" count and the submit warning; independent of diffview.
---@param pr prreview.PR
---@return integer?
local function changed_file_count(pr)
  local r = gh.run({ "git", "diff", "--name-only", ("origin/%s...%s"):format(pr.base, pr.head_sha) })
  if r.code ~= 0 then
    return nil
  end
  local n = 0
  for _ in r.stdout:gmatch("[^\n]+") do
    n = n + 1
  end
  return n
end

--- Create the review worktree at `wt` on branch review/pr-<n>-suggestions checked
--- out at pr.head_sha, retrying once behind a prune (add refuses a stale admin
--- entry that prune clears). Notifies and returns false on hard failure.
---@param pr prreview.PR
---@param wt string
---@return boolean ok
local function create_worktree(pr, wt)
  local branch = ("review/pr-%d-suggestions"):format(pr.number)
  if gh.run(gh.worktree_add_cmd(wt, branch, pr.head_sha)).code ~= 0 then
    gh.run(gh.worktree_prune_cmd())
    if gh.run(gh.worktree_add_cmd(wt, branch, pr.head_sha)).code ~= 0 then
      vim.notify("prreview: could not create the review worktree at " .. wt, vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---@param arg string
function M.start(arg)
  local pr = resolve_pr(arg)
  if not pr then
    return
  end
  -- Fetch the base first (refreshes origin/<base>), the PR head LAST: every
  -- `git fetch` rewrites FETCH_HEAD, and diff.open diffs origin/<base>...FETCH_HEAD,
  -- so the head fetch must be the final one or the diff comes out empty.
  if gh.run({ "git", "fetch", "origin", pr.base }).code ~= 0 then
    vim.notify("prreview: git fetch of base ref failed (LEFT-side anchors may be stale)", vim.log.levels.WARN)
  end
  if gh.run(gh.fetch_head_cmd(pr.number)).code ~= 0 then
    vim.notify("prreview: git fetch of PR head failed", vim.log.levels.ERROR)
    return
  end
  local wt = state.worktree_path(pr)
  pr.worktree = wt
  if not vim.uv.fs_stat(wt) then
    if not create_worktree(pr, wt) then
      return
    end
  else
    -- a worktree left over from an unclosed prior session (crash, reboot, no :PrReviewClose)
    -- can sit on a stale head, or be a broken/partial dir; the save→draft diff below is
    -- computed against the freshly-fetched pr.head_sha, so anything but an exact match here
    -- would silently stage garbage suggestions.
    local cur = gh.run(gh.worktree_head_cmd(wt))
    if cur.code ~= 0 then
      -- not a usable worktree (partial/corrupt dir, or a dangling admin entry): rebuild it.
      -- `delete -rf` wipes untracked files too, so warn — a :w'd-but-undrafted new file here is lost.
      vim.notify(
        "prreview: review worktree was broken — rebuilding it; any un-drafted edits in it are discarded",
        vim.log.levels.WARN
      )
      gh.run(gh.worktree_remove_cmd(wt))
      if vim.uv.fs_stat(wt) then
        vim.fn.delete(wt, "rf") -- stray dir `worktree remove` won't own
      end
      gh.run(gh.worktree_prune_cmd())
      if not create_worktree(pr, wt) then
        return
      end
    elseif vim.trim(cur.stdout) ~= pr.head_sha then
      vim.notify(
        "prreview: existing worktree was stale (PR moved) — resetting to the current head",
        vim.log.levels.WARN
      )
      gh.run({ "git", "-C", wt, "reset", "--hard", pr.head_sha })
      local moved = state.load_or_init_batch(pr)
      moved.reviewed = {}
      state.save_batch(moved)
      vim.notify("prreview: PR moved — reviewed marks cleared", vim.log.levels.WARN)
    end
  end
  current_pr = pr
  state.write_active(pr, string.format("https://github.com/%s/%s/pull/%d", pr.owner, pr.repo, pr.number))
  if not vim.uv.fs_stat(state.batch_path(pr)) then
    state.save_batch(batch.new(pr))
  end
  diff.open(pr.base) -- the review tree opens on DiffviewViewOpened (post-layout), not here
  open_claude(string.format("https://github.com/%s/%s/pull/%d", pr.owner, pr.repo, pr.number))
  overlay.refresh(pr)
  -- Watch the batch file: when Claude (peer-review) flips draft→verified and writes it
  -- back, re-render so the flip shows without the human doing anything.
  start_watch(pr)

  -- Debounced nudge: after staging drafts, poke Claude's terminal (if present) to verify them.
  local nudger = nudge.make({
    delay_ms = 1500,
    msg = ("prreview: new draft suggestion(s) in %s — verify and flip to verified"):format(state.batch_path(pr)),
    count_drafts = function()
      -- If the review was closed or switched, a pending deferred nudge must no-op
      -- (current_pr is cleared by :PrReviewClose / replaced by another :PrReviewStart).
      if current_pr ~= pr then
        return 0
      end
      return batch.count_drafts(state.load_or_init_batch(pr))
    end,
    send = function(msg)
      -- write straight to Claude's stdin; no-op if the terminal's gone
      if M._claude and M._claude.job then
        pcall(vim.api.nvim_chan_send, M._claude.job, msg .. "\r")
      end
    end,
    schedule = function(ms, fn)
      vim.defer_fn(fn, ms)
    end,
  })

  local diffparse = require("ai-review.diffparse")
  -- A verified suggestion's anchor+lines uniquely identify the hunk it came from;
  -- re-deriving from the whole-worktree diff on every save would otherwise re-stage
  -- it as a fresh duplicate draft (A1).
  local function same_anchor(a, b)
    return a.start_line == b.start_line and a.line == b.line and vim.deep_equal(a.suggestion.lines, b.suggestion.lines)
  end
  -- Assumes one active review at a time, like PipPrReviewOverlay below: this augroup's
  -- BufWritePost pattern is pinned to whatever review was most recently started.
  local grp = vim.api.nvim_create_augroup("PrReviewEdit", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = grp,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      -- fires for whichever diff buffer is entered (both sides); the RIGHT-only guard lives in M.suggest
      vim.keymap.set("n", "i", "<cmd>PrSuggest<cr>", { buffer = 0, desc = "PR: edit on branch to suggest" })
      vim.keymap.set("n", "<leader>re", "<cmd>PrSuggest<cr>", { buffer = 0, desc = "PR: edit on branch to suggest" })
      vim.keymap.set("n", "R", "<cmd>PrReviewed<cr>", { buffer = 0, desc = "PR: toggle file reviewed" })
      vim.keymap.set("n", "gO", "<cmd>PrGoto<cr>", { buffer = 0, desc = "PR: open real file here (LSP nav)" })
      -- `q` in a diff closes just the diff windows, keeping diffview's panel so you can
      -- open another file from it (overrides diffview's own view `q`=DiffviewClose here).
      vim.keymap.set("n", "q", M.close_diffs, { buffer = 0, desc = "PR: close diffs, keep the panel" })
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    pattern = current_pr.worktree .. "/*",
    callback = function(a)
      if not current_pr then -- fired after :PrReviewClose tore down the worktree
        return
      end
      -- <amatch> (unlike <afile>) is always the full expanded path, so this holds
      -- even if the file was opened via a relative path (e.g. after :lcd into the worktree)
      local rel = a.match:sub(#current_pr.worktree + 2) -- strip "<wt>/"
      local r = gh.run({ "git", "-C", current_pr.worktree, "diff", "-U0", current_pr.head_sha, "--", rel })
      if r.code ~= 0 then
        vim.notify("prreview: could not diff " .. rel .. ": " .. r.stderr, vim.log.levels.WARN)
        return
      end
      local entries = {}
      -- Lazily fetch head_sha's file content, once per save, only if a pure-insertion hunk
      -- needs it: an insertion must anchor to head_sha's own line content, not the worktree's
      -- (an earlier insertion hunk in the same save already shifts the worktree's line numbers).
      local head_lines, head_fetched = nil, false
      local function get_head_lines()
        if not head_fetched then
          head_fetched = true
          local hr = gh.run({ "git", "-C", current_pr.worktree, "show", current_pr.head_sha .. ":" .. rel })
          if hr.code == 0 then
            -- Empty is the truly-empty (0-byte) file; test that BEFORE stripping the
            -- trailing newline, so a one-blank-line file ("\n") stays a 1-line {""}
            -- rather than collapsing to {} and dropping its anchor line.
            local content = hr.stdout:gsub("\n$", "") -- trailing newline -> no spurious empty last line
            head_lines = hr.stdout == "" and {} or vim.split(content, "\n", { plain = true })
          end
        end
        return head_lines
      end
      for _, h in ipairs(diffparse.parse(r.stdout)) do
        local e = diffparse.to_entry(h)
        if e then
          entries[#entries + 1] = vim.tbl_extend("force", e, {
            path = rel,
            kind = "suggestion",
            origin = "human",
            status = "draft",
            body = "",
          })
        elseif h.old_count == 0 then
          local hl = get_head_lines()
          if not hl then
            -- e.g. the file is newly added in the PR and absent from head_sha
            vim.notify(
              ("prreview: could not read %s@%s to anchor an insertion suggestion"):format(rel, current_pr.head_sha),
              vim.log.levels.WARN
            )
          else
            local anchor, lines
            if h.old_start == 0 then
              -- insertion before head_sha's first line
              anchor = 1
              lines = {}
              vim.list_extend(lines, h.new_lines)
              if #hl > 0 then
                lines[#lines + 1] = hl[1]
              end
            elseif hl[h.old_start] then
              anchor = h.old_start
              lines = { hl[anchor] }
              vim.list_extend(lines, h.new_lines)
            end
            if anchor then
              entries[#entries + 1] = {
                path = rel,
                side = "RIGHT",
                start_line = anchor,
                line = anchor,
                kind = "suggestion",
                origin = "human",
                status = "draft",
                body = "",
                suggestion = { lines = lines },
              }
            else
              vim.notify(
                ("prreview: insertion anchor beyond %s@%s's line count — skipped"):format(rel, current_pr.head_sha),
                vim.log.levels.WARN
              )
            end
          end
        end
      end
      local b = state.load_or_init_batch(current_pr)
      local fresh = {}
      for _, e in ipairs(entries) do
        local dup = false
        for _, c in ipairs(b.comments) do
          if c.path == rel and c.status == "verified" and c.kind == "suggestion" and same_anchor(e, c) then
            dup = true
            break
          end
        end
        if not dup then
          fresh[#fresh + 1] = e
        end
      end
      batch.replace_drafts_for_path(b, rel, fresh)
      state.save_batch(b)
      overlay.refresh(current_pr)
      vim.notify(("prreview: staged %d draft suggestion(s) for %s"):format(#fresh, rel))
      if #fresh > 0 then
        nudger.request()
      end
    end,
  })

  vim.notify(("prreview: reviewing %s/%s#%d"):format(pr.owner, pr.repo, pr.number))
end

---@param kind "comment"|"question"|"nit"
---@param range? { [1]: integer, [2]: integer } an explicit [line1, line2] from
---  a command's `a.range`/`a.line1`/`a.line2`, taking precedence over
---  diff.cursor_anchor's own mode()-based visual-selection detection.
local function add_comment(kind, range)
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local anchor = diff.cursor_anchor(range)
  if not anchor then
    return
  end
  vim.ui.input({ prompt = kind .. ": " }, function(body)
    if not body or body == "" then
      return
    end
    local b = state.load_or_init_batch(current_pr)
    batch.add(b, vim.tbl_extend("force", anchor, { kind = kind, origin = "human", status = "verified", body = body }))
    state.save_batch(b)
    overlay.refresh(current_pr)
  end)
end

--- Open the file under the cursor from the review worktree, at the cursor line, in a
--- vsplit — a real file on the branch, so LSP/formatting work. Editing + :w stages a draft.
function M.suggest()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local anchor = diff.cursor_anchor()
  if not anchor then
    return
  end
  local wt = current_pr.worktree or state.worktree_path(current_pr)
  vim.cmd("vsplit " .. vim.fn.fnameescape(wt .. "/" .. anchor.path))
  if anchor.side == "RIGHT" then
    pcall(vim.api.nvim_win_set_cursor, 0, { anchor.line, 0 })
  else
    -- anchor.line is a BASE-side line number; it doesn't correspond 1:1 to a line in the
    -- head-checked-out worktree file, so jumping there would silently land on the wrong line
    vim.notify("prreview: opened on the PR branch — LEFT-side line numbers don't map here", vim.log.levels.WARN)
  end
end

--- Open the worktree file under the cursor at the SAME line+column, in a vsplit. The diff
--- panes are diffview git-object buffers (no LSP attaches); the worktree is a real checkout,
--- so pyright is live there — native gd/grr work once you land on the symbol. RIGHT side
--- only: its lines map 1:1 to the head-checked-out worktree file.
function M.goto_file()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local col = vim.fn.col(".") - 1 -- capture before the split; 0-based for nvim_win_set_cursor
  local anchor = diff.cursor_anchor()
  if not anchor then
    return
  end
  if anchor.side ~= "RIGHT" then
    vim.notify(
      "prreview: LSP-goto works from the RIGHT (head) side — LEFT lines don't map to the worktree",
      vim.log.levels.WARN
    )
    return
  end
  local wt = current_pr.worktree or state.worktree_path(current_pr)
  vim.cmd("vsplit " .. vim.fn.fnameescape(wt .. "/" .. anchor.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { anchor.line, col })
end

--- Open (or reveal) a named acwrite scratch buffer. On :w it calls on_save(lines) and
--- marks the buffer unmodified — nothing hits disk. A live buffer of this name is
--- revealed as-is (no re-prefill, no duplicate BufWriteCmd); a fresh/unloaded one is
--- created and prefilled from initial_fn(). Any active-review / id-still-valid guard
--- belongs in on_save (this helper is content-agnostic).
---@param name string
---@param initial_fn fun():string  computed only on a fresh create
---@param on_save fun(lines: string[])
local function open_scratch_buffer(name, initial_fn, on_save)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
    vim.cmd("sbuffer " .. existing)
    return
  end
  local bufnr = existing ~= -1 and existing or vim.api.nvim_create_buf(true, false)
  if existing == -1 then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(initial_fn(), "\n", { plain = true }))
  vim.bo[bufnr].modified = false
  -- clear before attach: reusing an unloaded bufnr with this name would otherwise
  -- stack a second BufWriteCmd, firing on_save (and its notify) once per reuse cycle
  vim.api.nvim_clear_autocmds({ event = "BufWriteCmd", buffer = bufnr })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      on_save(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      vim.bo[bufnr].modified = false
    end,
  })
  vim.cmd("sbuffer " .. bufnr)
end

--- Open (or reveal) the review-body scratch buffer for the current PR. :w routes the
--- contents into batch.body via the shared scratch-buffer helper; nothing hits disk.
function M.body()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local pr = current_pr -- snapshot: a later :w must target THIS review's batch
  local name = ("prreview://body/%s__%s__pr%d"):format(pr.owner, pr.repo, pr.number)
  open_scratch_buffer(name, function()
    return state.load_or_init_batch(pr).body or ""
  end, function(lines)
    if current_pr ~= pr then
      vim.notify("prreview: body buffer is for a review that's no longer active", vim.log.levels.WARN)
      return
    end
    local b = state.load_or_init_batch(pr)
    b.body = table.concat(lines, "\n")
    state.save_batch(b)
    overlay.refresh(pr)
    vim.notify("prreview: body saved")
  end)
end

--- List the batch's comments (vim.ui.select) and open the chosen one's body in a
--- scratch buffer; :w writes the edited body back to that comment by id. Edits the
--- `body` prose only — a suggestion's ```suggestion``` block is left as-is.
function M.comments()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local pr = current_pr -- snapshot: a later :w must target THIS review's batch
  local b = state.load_or_init_batch(pr)
  if #b.comments == 0 then
    vim.notify("prreview: no comments yet", vim.log.levels.WARN)
    return
  end
  local items, ids = {}, {}
  for _, c in ipairs(b.comments) do
    local preview = (c.body or ""):gsub("\n.*", "") -- first line only
    items[#items + 1] = ("%s:%d [%s/%s/%s] %s"):format(c.path, c.line, c.kind, c.origin, c.status, preview)
    ids[#ids + 1] = c.id
  end
  vim.ui.select(items, { prompt = "Edit comment:" }, function(choice, idx)
    if not choice then
      return
    end
    local id = ids[idx]
    local name = ("prreview://comment/%s__%s__pr%d/%s"):format(pr.owner, pr.repo, pr.number, id)
    open_scratch_buffer(name, function()
      for _, c in ipairs(state.load_or_init_batch(pr).comments) do
        if c.id == id then
          return c.body or ""
        end
      end
      return ""
    end, function(lines)
      if current_pr ~= pr then
        vim.notify("prreview: comment buffer is for a review that's no longer active", vim.log.levels.WARN)
        return
      end
      local bb = state.load_or_init_batch(pr)
      local found = false
      for _, c in ipairs(bb.comments) do
        if c.id == id then
          c.body = table.concat(lines, "\n")
          found = true
          break
        end
      end
      if not found then
        vim.notify("prreview: that comment no longer exists — not saved", vim.log.levels.WARN)
        return
      end
      state.save_batch(bb)
      overlay.refresh(pr)
      vim.notify("prreview: comment saved")
    end)
  end)
end

--- Toggle the current diffview file's reviewed mark, persist it, and re-mark the panel.
function M.toggle_reviewed()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  local path = view and view.cur_entry and view.cur_entry.path
  if not path then
    vim.notify("prreview: no file under the cursor to mark", vim.log.levels.WARN)
    return
  end
  local b = state.load_or_init_batch(current_pr)
  batch.toggle_reviewed(b, path)
  state.save_batch(b)
  panel.refresh(current_pr)
  local m = changed_file_count(current_pr)
  if m then
    vim.notify(("prreview: reviewed %d/%d files"):format(batch.count_reviewed(b), m))
  else
    vim.notify(("prreview: reviewed %d files"):format(batch.count_reviewed(b)))
  end
end

--- Extract a numeric review id from a `gh api ... reviews` POST response, if parseable.
---@param stdout string
---@return integer?
local function parse_review_id(stdout)
  local ok, j = pcall(vim.json.decode, stdout)
  if ok and type(j) == "table" and type(j.id) == "number" then
    return j.id
  end
  return nil
end

local VALID_VERDICTS = { APPROVE = true, COMMENT = true, REQUEST_CHANGES = true }

--- Guard the one field GitHub silently reinterprets: a reviews POST with no `event` creates
--- a PENDING review, which looks submitted to its author and is invisible to everyone else.
--- Refuse instead, naming the sheet line that fixes it. batch.new now defaults the verdict to
--- COMMENT, so this only trips on a batch written by an older version or another tool.
---@param b prreview.Batch
---@return boolean ok
local function verdict_ok(b)
  if VALID_VERDICTS[b.verdict or ""] then
    return true
  end
  vim.notify(
    "prreview: not posted — the batch's verdict is missing or invalid; set the sheet's "
      .. "`# verdict:` line to APPROVE / COMMENT / REQUEST_CHANGES and :w it",
    vim.log.levels.ERROR
  )
  return false
end

--- Serialize the batch and POST it. Re-reads from disk so a verify-flip or a re-anchor that
--- landed while the sheet was open is included, and bails if another submit beat us to it.
--- The single route to `gh api`: every caller must already have taken an explicit confirm.
---@param pr_ prreview.PR
---@param prior_submitted_at string? the marker seen when this post flow began, if any
local function post_batch(pr_, prior_submitted_at)
  local b = state.load_or_init_batch(pr_)
  -- Only bail on a submitted_at that APPEARED since this flow began (a concurrent submit) —
  -- not on one the user already knowingly confirmed past.
  if b.submitted_at and b.submitted_at ~= prior_submitted_at then
    vim.notify("prreview: submit cancelled (already submitted at " .. b.submitted_at .. ")", vim.log.levels.WARN)
    return
  end
  if not verdict_ok(b) then
    return
  end
  local serialized = batch.serialize(b)
  if #serialized.comments == 0 and (not serialized.body or serialized.body == "") then
    vim.notify("prreview: nothing to submit", vim.log.levels.WARN)
    return
  end
  local tmp = vim.fn.tempname()
  local fd = assert(io.open(tmp, "w"))
  fd:write(vim.json.encode(serialized))
  fd:close()
  local r = gh.run(gh.post_review_cmd(pr_.owner, pr_.repo, pr_.number, tmp))
  if r.code == 0 then
    b.submitted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    b.submitted_review = parse_review_id(r.stdout)
    state.save_batch(b)
    vim.notify("prreview: review posted")
  else
    vim.notify("prreview: post failed: " .. r.stderr, vim.log.levels.ERROR)
  end
  vim.fn.delete(tmp) -- review JSON can carry code snippets; don't leave it in tmp
end

--- Point the sheet's code pane at the entry under the cursor. Best-effort: a comment can
--- name a path that no longer exists on the branch, and that must not break the sheet.
---
--- `anchor_at` returns the SAME anchor for every line inside one comment's body, so an
--- ordinary cursor move while editing a comment (not switching entries) would otherwise
--- re-trigger a full `:edit` + re-center on every keystroke, stomping any manual scrolling
--- in the code pane. `s.last_anchor` caches the anchor last synced to; re-sync only fires
--- when it actually changes. A fresh sheet has no `last_anchor` yet, so its first move
--- always syncs once, per spec ("moving in the sheet scrolls... to that comment's anchor").
local function sync_code_pane()
  local s = M._sheet
  if
    not (
      s
      and vim.api.nvim_win_is_valid(s.code_win)
      and vim.api.nvim_win_is_valid(s.sheet_win)
      and vim.api.nvim_buf_is_valid(s.buf)
    )
  then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(s.sheet_win)[1]
  local anchor = sheet.anchor_at(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), lnum)
  if not anchor then
    return
  end
  if s.last_anchor and s.last_anchor.path == anchor.path and s.last_anchor.line == anchor.line then
    return
  end
  s.last_anchor = anchor
  local wt = s.pr.worktree or state.worktree_path(s.pr)
  local path = wt .. "/" .. anchor.path
  if not vim.uv.fs_stat(path) then
    return
  end
  pcall(function()
    vim.api.nvim_win_call(s.code_win, function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      pcall(vim.api.nvim_win_set_cursor, s.code_win, { anchor.line, 0 })
      vim.cmd("normal! zz")
    end)
  end)
end

--- Record the mtime of a batch write WE just made. The re-anchor watcher is filtered to the
--- batch file, so without this a `:w` in the sheet during the wait fires it and produces a
--- post confirm byte-identical to the real one — consent for a re-anchor that never happened.
---@param s table the live M._sheet
local function mark_self_write(s)
  local st = vim.uv.fs_stat(state.batch_path(s.pr))
  s.self_write_mtime = st and st.mtime or nil
end

--- Parse the sheet buffer and fold it into the batch. Returns false (and notifies) on any
--- parse or apply failure, leaving the batch on disk untouched.
---
--- Drops accumulate on `M._sheet.dropped` rather than being reported only here: this notify
--- is transient, and on the path the spec worries about (a deleted section silently deleting
--- a comment) the very next thing on screen is a modal confirm that takes over the message
--- area. The POST confirm names the total, and clears it once the sheet has been re-rendered.
---@return boolean ok, integer? dropped
local function save_sheet()
  local s = M._sheet
  if not s then
    return false
  end
  local parsed, perr = sheet.parse(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false))
  if not parsed then
    vim.notify("prreview: sheet not saved — " .. perr, vim.log.levels.ERROR)
    return false
  end
  local b = state.load_or_init_batch(s.pr)
  local dropped, aerr = sheet.apply(b, parsed)
  if aerr then
    vim.notify("prreview: sheet not saved — " .. aerr, vim.log.levels.ERROR)
    return false
  end
  state.save_batch(b)
  mark_self_write(s)
  s.dropped = (s.dropped or 0) + dropped
  vim.bo[s.buf].modified = false
  vim.notify(("prreview: sheet saved (%d comments, %d dropped)"):format(#b.comments, dropped))
  return true, dropped
end

--- Second half of the sheet POST: Claude has re-anchored (or we're posting without it).
--- Re-render first, so the anchors the human confirms are the ones about to be published.
function M._sheet_reanchored()
  -- Unconditionally, before anything else: whatever the wait was for has now happened (or
  -- been overtaken by hand), so neither the watcher nor its timeout may outlive this call.
  M._stop_sheet_wait()
  local s = M._sheet
  if not (s and vim.api.nvim_buf_is_valid(s.buf)) then
    return -- no sheet to show the anchors in; showing them IS the confirm, so don't post
  end
  local b = state.load_or_init_batch(s.pr)
  if vim.bo[s.buf].modified then
    -- Edits made during the wait were never folded into the batch, so they were never going
    -- to post; the re-render drops them. Say so, same as _close_sheet does.
    vim.notify("prreview: unsaved sheet edits were discarded by the re-anchor re-render", vim.log.levels.WARN)
  end
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, sheet.render(b))
  vim.bo[s.buf].modified = false
  if not verdict_ok(b) then
    return
  end
  local verified, drafts = 0, 0
  for _, c in ipairs(b.comments or {}) do
    if c.status == "verified" then
      verified = verified + 1
    else
      drafts = drafts + 1
    end
  end
  -- Everything the human needs to judge the post goes in the one prompt: only verified
  -- entries post, so an unnoticed draft or a section deleted from the sheet would otherwise
  -- vanish silently. The re-render above resynced sheet and batch, so the running drop
  -- total is reported once here and then cleared.
  local dropped = s.dropped or 0
  s.dropped = 0
  local prompt = ("Post %d verified comment(s) as %s?"):format(verified, b.verdict)
  if drafts > 0 then
    prompt = prompt .. (" %d draft(s) will NOT post."):format(drafts)
  end
  if dropped > 0 then
    prompt = prompt .. (" %d comment(s) removed from the sheet will NOT post."):format(dropped)
  end
  if (b.body or ""):match("^%s*$") then
    prompt = prompt .. " Summary body is empty."
  end
  if b.submitted_at then
    -- <leader>p reaches gh api without passing M.submit's already-submitted confirm, so the
    -- re-post has to be named here too rather than landing a silent second review.
    prompt = prompt .. (" ALREADY submitted at %s — this posts a SECOND review."):format(b.submitted_at)
  end
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    vim.notify("prreview: not posted", vim.log.levels.WARN)
    return
  end
  post_batch(s.pr, s.prior_submitted_at)
end

--- Wait for Claude to write the batch back, then continue the post. One-shot and bounded:
--- silence is never consent, so the timeout notifies and posts nothing.
---@param pr_ prreview.PR
local function wait_for_reanchor(pr_)
  M._stop_sheet_wait()
  local bp = state.batch_path(pr_)
  local dir, base = vim.fn.fnamemodify(bp, ":h"), vim.fn.fnamemodify(bp, ":t")
  local handle = vim.uv.new_fs_event()
  if not handle then
    vim.notify("prreview: can't watch the batch — press <leader>p again once Claude is done", vim.log.levels.WARN)
    return
  end
  local fired = false
  -- Watch the DIRECTORY filtered to the basename, not the file: save_batch renames a tmp
  -- file over the batch, and a file watcher holds the replaced inode (cf. start_watch).
  -- fs_event:start returns 0 on success — 0 is truthy in Lua, so test `~= 0`.
  local rc = handle:start(dir, {}, function(_, filename)
    if fired or (filename and filename ~= base) then
      return
    end
    -- Our own writes land on this same file — a `:w` in the sheet goes through
    -- state.save_batch too. Waking on one would show the post confirm before Claude had
    -- re-anchored anything, in wording indistinguishable from the real thing. Keep waiting.
    local s, st = M._sheet, vim.uv.fs_stat(bp)
    if s and st and s.self_write_mtime and vim.deep_equal(st.mtime, s.self_write_mtime) then
      return
    end
    fired = true -- one-shot; libuv serializes these callbacks, so this can't race itself
    vim.schedule(function()
      M._sheet_reanchored()
    end)
  end)
  if rc ~= 0 then
    pcall(function()
      handle:close()
    end)
    vim.notify("prreview: can't watch the batch — press <leader>p again once Claude is done", vim.log.levels.WARN)
    return
  end
  M._sheet_wait = handle
  vim.defer_fn(function()
    -- Identity, not "is anything armed?": a superseded wait's timer is still pending, and
    -- must neither cancel the wait that replaced it nor claim that one timed out.
    if M._sheet_wait ~= handle then
      return
    end
    M._stop_sheet_wait()
    vim.notify(
      "prreview: Claude didn't write the batch back — nothing posted. Press <leader>p to retry.",
      vim.log.levels.WARN
    )
  end, 120000)
end

--- Pin the batch — and so the POST's `commit_id` — to `sha`. Only ever called when the anchors
--- are about to be re-checked against that same sha: a re-pin without a re-anchor would ask
--- GitHub to resolve the old line numbers against a different commit.
---@param pr_ prreview.PR
---@param sha string
local function repin_head(pr_, sha)
  local b = state.load_or_init_batch(pr_)
  -- fresh table, not a field write: a batch that came from batch.new shares current_pr, and
  -- re-pinning the POST must not reach through and repoint the live review's head
  b.pr = vim.tbl_extend("force", b.pr or {}, { head_sha = sha })
  state.save_batch(b)
end

--- Count batch comments the sheet buffer no longer shows.
---@param b prreview.Batch
---@param parsed table
---@return integer
local function count_absent_from_sheet(b, parsed)
  local in_sheet = {}
  for _, e in ipairs(parsed.entries or {}) do
    if e.id then
      in_sheet[e.id] = true
    end
  end
  local absent = 0
  for _, c in ipairs(b.comments or {}) do
    if c.id and not in_sheet[c.id] then
      absent = absent + 1
    end
  end
  return absent
end

--- Sheet POST (`<leader>p`): fold the sheet into the batch, ask Claude to re-anchor, wait.
--- Posts nothing itself — every route to `gh api` runs through _sheet_reanchored's confirm.
function M._sheet_post()
  -- A new press supersedes any earlier wait, unconditionally and before any early return can
  -- skip it. Otherwise an abort below (stale sheet, declined drift, failed send) leaves the
  -- previous watcher live, and Claude's answer to the SUPERSEDED request later raises a post
  -- confirm built from stale premises — including one whose drift the human just declined.
  M._stop_sheet_wait()
  local s = M._sheet
  if not (s and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  local parsed, perr = sheet.parse(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false))
  if not parsed then
    -- never post a batch the human didn't approve: abort before Claude is asked anything
    vim.notify("prreview: not posted — the sheet doesn't parse: " .. perr, vim.log.levels.ERROR)
    return
  end
  -- Nothing re-renders an open sheet when the batch changes on disk (start_watch only
  -- refreshes the overlay), so a sheet goes stale the moment Claude writes a new entry — the
  -- plugin's normal working mode. sheet.apply REPLACES b.comments with what the buffer shows,
  -- so saving a stale sheet would permanently delete those entries. An id the batch holds and
  -- an unedited buffer doesn't means stale, not deleted: refresh and abort instead of writing.
  local b = state.load_or_init_batch(s.pr)
  local modified = vim.bo[s.buf].modified
  local absent = count_absent_from_sheet(b, parsed)
  if absent > 0 and not modified then
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, sheet.render(b))
    vim.bo[s.buf].modified = false
    vim.notify(
      ("prreview: not posted — the batch gained %d comment(s) while this sheet was open; "):format(absent)
        .. "the sheet has been refreshed, re-read it and press <leader>p again",
      vim.log.levels.WARN
    )
    return
  end
  -- An edited buffer's drops are the human's own deletions; those are legitimate, and the
  -- POST confirm names them (save_sheet accumulates the count).
  if modified and not save_sheet() then
    return -- save_sheet already reported the offending line
  end
  local disk = state.load_or_init_batch(s.pr)
  s.prior_submitted_at = disk.submitted_at

  -- batch.serialize posts commit_id = the batch's PINNED head_sha, while the re-anchor asks
  -- Claude to fix coordinates against the CURRENT PR head. If those disagree, GitHub resolves
  -- the corrected line numbers against the old commit: a 422, or a comment published against
  -- the wrong code. <leader>p never passes M.submit's drift confirm, so check here.
  local pinned = (disk.pr and disk.pr.head_sha) or s.pr.head_sha
  local info = gh.pr_info(s.pr.owner, s.pr.repo, s.pr.number)
  if not info then
    vim.notify(
      "prreview: could not verify the PR head is unchanged (gh pr view failed) — proceeding anyway",
      vim.log.levels.WARN
    )
  end
  local new_head = (info and info.head_sha ~= pinned) and info.head_sha or nil

  -- A recorded job whose channel has since died is functionally no session, and a spec-
  -- mandated offer to post without re-anchoring beats a 120s wait that can only time out.
  local function without_reanchor(reason)
    local moved = new_head and " The PR head has moved since you started, so the anchors may be off." or ""
    if vim.fn.confirm(reason .. moved .. " Post without re-anchoring?", "&Yes\n&No", 2) ~= 1 then
      vim.notify("prreview: not posted", vim.log.levels.WARN)
      return
    end
    M._sheet_reanchored()
  end

  if not (M._claude and M._claude.job) then
    return without_reanchor("No Claude session to re-anchor.")
  end
  if new_head then
    if
      vim.fn.confirm("PR head moved since you started. Re-anchor against the new head and post?", "&Yes\n&No", 2) ~= 1
    then
      vim.notify("prreview: not posted (PR head moved)", vim.log.levels.WARN)
      return
    end
    repin_head(s.pr, new_head) -- so commit_id matches the head Claude is about to re-anchor to
    mark_self_write(s)
  end
  if not pcall(vim.api.nvim_chan_send, M._claude.job, nudge.reanchor_request_msg(state.batch_path(s.pr)) .. "\r") then
    if new_head then
      repin_head(s.pr, pinned) -- nothing will re-anchor now, so the anchors still describe `pinned`
      mark_self_write(s)
    end
    return without_reanchor("Couldn't send to the Claude session.")
  end
  vim.notify("prreview: asked Claude to re-anchor — waiting, nothing posted yet")
  wait_for_reanchor(s.pr)
end

--- Open the review sheet in its own tab: worktree branch file left, sheet right. Moving in
--- the sheet scrolls the code pane to that comment's anchor. A sheet already open for THIS
--- review is focused rather than duplicated — a second `nvim_create_buf` under the same name
--- would collide with the first. A sheet left over from a different (or since-closed) review
--- is torn down and rebuilt fresh, the same "restart heals a stale prior instance" convention
--- open_claude uses — otherwise saving here would silently write into the wrong PR's batch.
function M.sheet()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  if M._sheet and M._sheet.pr == current_pr and vim.api.nvim_tabpage_is_valid(M._sheet.tab) then
    vim.api.nvim_set_current_tabpage(M._sheet.tab)
    return
  end
  local pr_ = current_pr
  local b = state.load_or_init_batch(pr_)
  if #b.comments == 0 and (b.body or ""):match("^%s*$") then
    -- checked BEFORE tearing down any stale sheet below: a no-op call (nothing to
    -- review for pr_) must never destroy a live, unsaved sheet for a different PR
    vim.notify("prreview: nothing to review yet", vim.log.levels.WARN)
    return
  end
  M._close_sheet()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local code_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local sheet_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(sheet_win, buf)
  vim.api.nvim_buf_set_name(buf, ("prreview://sheet/%s__%s__pr%d"):format(pr_.owner, pr_.repo, pr_.number))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  -- wipe (not the scratch default "hide") so closing the tab frees the name too — otherwise
  -- a hidden-but-alive buffer blocks the NEXT :PrReviewSheet's nvim_buf_set_name with E95
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sheet.render(b))
  vim.bo[buf].modified = false
  M._sheet = { buf = buf, tab = tab, code_win = code_win, sheet_win = sheet_win, pr = pr_ }
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save_sheet })
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = sync_code_pane })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      M._stop_sheet_wait() -- a wiped sheet can't be waiting on a re-anchor
      M._sheet = nil
    end,
  })
  vim.keymap.set("n", "<leader>p", M._sheet_post, { buffer = buf, desc = "prreview: post this review" })
  sync_code_pane()
end

function M.submit()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local b = state.load_or_init_batch(current_pr)
  -- re-running :PrReviewSubmit (or restarting the PR, which reloads this same batch)
  -- would otherwise re-POST every verified comment as a second, duplicate review
  if b.submitted_at then
    if
      vim.fn.confirm("This review was already submitted at " .. b.submitted_at .. ". Submit again?", "&Yes\n&No", 2)
      ~= 1
    then
      vim.notify("prreview: submit cancelled (already submitted)", vim.log.levels.WARN)
      return
    end
  end
  -- the batch's comment anchors were computed against current_pr.head_sha; if the PR moved
  -- since :PrReviewStart, posting against stale line numbers can land comments on the wrong lines
  local info = gh.pr_info(current_pr.owner, current_pr.repo, current_pr.number)
  if not info then
    vim.notify(
      "prreview: could not verify the PR head is unchanged (gh pr view failed) — proceeding anyway",
      vim.log.levels.WARN
    )
  elseif info.head_sha ~= current_pr.head_sha then
    if vim.fn.confirm("PR head moved since review start; anchors may be off. Submit anyway?", "&Yes\n&No", 2) ~= 1 then
      vim.notify("prreview: submit cancelled (PR head moved)", vim.log.levels.WARN)
      return
    end
  end
  local drafts = batch.count_drafts(b)
  if drafts > 0 then
    vim.notify(
      ("prreview: %d unverified draft(s) will be skipped — ask Claude to verify first"):format(drafts),
      vim.log.levels.WARN
    )
  end
  local total = changed_file_count(current_pr)
  if total and total > 0 then
    local unreviewed = total - batch.count_reviewed(b)
    if unreviewed > 0 then
      vim.notify(("prreview: %d of %d files not marked reviewed"):format(unreviewed, total), vim.log.levels.WARN)
    end
  end
  -- Hand over: the verdict, the summary body and the final confirm are all the sheet's job
  -- now, so :PrReviewSubmit runs its own guards and then gets out of the human's way.
  M.sheet()
end

---@param opts? table
function M.setup(opts)
  local _ = opts
  vim.api.nvim_create_user_command("PrReviewStart", function(a)
    M.start(a.args)
  end, { nargs = 1 })
  vim.api.nvim_create_user_command("PrComment", function(a)
    -- a.range is 0 for a plain ":PrComment" (line1/line2 default to the
    -- current line even then) — only an explicit range (":'<,'>", a count)
    -- should override cursor_anchor's own mode() v/V detection.
    local range = a.range > 0 and { a.line1, a.line2 } or nil
    add_comment("comment", range)
  end, { range = true })
  vim.api.nvim_create_user_command("PrSuggest", M.suggest, { range = true })
  vim.api.nvim_create_user_command("PrGoto", M.goto_file, {})
  vim.api.nvim_create_user_command("PrBody", M.body, {})
  vim.api.nvim_create_user_command("PrComments", M.comments, {})
  vim.api.nvim_create_user_command("PrClaude", M.claude, {})
  vim.api.nvim_create_user_command("PrReviewSheet", M.sheet, {})
  vim.api.nvim_create_user_command("PrReviewed", M.toggle_reviewed, {})
  vim.api.nvim_create_user_command("PrReviewRefresh", function()
    if current_pr then
      overlay.refresh(current_pr)
    end
  end, {})
  vim.api.nvim_create_user_command("PrReviewSubmit", M.submit, {})
  vim.api.nvim_create_user_command("PrReviewClose", function()
    if not current_pr then
      vim.notify("prreview: no active review", vim.log.levels.WARN)
      return
    end
    local number = current_pr.number
    local wt = current_pr.worktree or state.worktree_path(current_pr)
    if vim.uv.fs_stat(wt) then
      local status = gh.run({ "git", "-C", wt, "status", "--porcelain" })
      if status.code == 0 and status.stdout ~= "" then
        if vim.fn.confirm("worktree has uncommitted changes — discard?", "&Yes\n&No", 2) ~= 1 then
          vim.notify("prreview: close aborted", vim.log.levels.WARN)
          return
        end
      end
      gh.run(gh.worktree_remove_cmd(wt))
      gh.run(gh.worktree_prune_cmd())
      -- ignore exit code: a branch checked out elsewhere (e.g. another worktree) refuses to delete
      gh.run({ "git", "branch", "-D", ("review/pr-%d-suggestions"):format(number) })
    end
    M._stop_watch()
    M._close_review_tree()
    M._close_claude()
    M._close_sheet()
    panel.detach()
    pcall(vim.fn.delete, state.active_path()) -- clear active.json
    overlay.clear()
    current_pr = nil
    vim.api.nvim_create_augroup("PrReviewEdit", { clear = true }) -- drop the now-stale worktree BufWritePost pattern
    vim.notify("prreview: review closed; worktree removed")
  end, {})
  -- diffview fires this on every file navigation (not just initial open), so
  -- re-render there to keep the overlay pinned to whatever file is now shown.
  -- `clear = true` (not just a named group) makes re-running setup() idempotent
  -- instead of stacking a duplicate autocmd on every :Lazy reload.
  -- Assumes one active review at a time: this fires for ANY diffview session
  -- in ANY tab, and always renders into whatever tab is current, not necessarily
  -- current_pr's — fine under that assumption, wrong if two reviews run at once.
  local augroup = vim.api.nvim_create_augroup("PipPrReviewOverlay", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      if current_pr then
        overlay.refresh(current_pr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "DiffviewViewOpened",
    callback = function()
      if current_pr then
        panel.attach(current_pr)
        open_review_tree() -- post-layout, so it doesn't race diffview's window setup
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "DiffviewViewClosed",
    callback = function()
      panel.detach()
    end,
  })
  -- Foreign windows (the snacks tree, split-opened files) inherit scrollbind from the
  -- diff window they're spawned off and desync the diff panes; re-clean on any window
  -- appearing/closing in the review tab. Gated on an active review + guarded internally.
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed" }, {
    group = augroup,
    callback = function()
      if current_pr then
        vim.schedule(M._guard_scrollbind)
      end
    end,
  })
  -- `clear = true` above already makes re-running setup() idempotent for the group;
  -- put the watcher teardown in it too so this doesn't stack duplicate autocmds.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M._stop_watch()
      M._close_review_tree()
      M._close_claude()
      M._close_sheet()
      panel.detach()
    end,
  })
end

return M
