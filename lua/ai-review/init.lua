---@mod ai-review In-Neovim GitHub PR review: commands + glue.

local url = require("ai-review.url")
local batch = require("ai-review.batch")
local state = require("ai-review.state")
local gh = require("ai-review.gh")
local diff = require("ai-review.diff")
local overlay = require("ai-review.overlay")
local nudge = require("ai-review.nudge")

local M = {}
---@type prreview.PR?
local current_pr = nil
---@type uv.uv_fs_event_t?
M._watch = nil

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
    end
  end
  current_pr = pr
  state.write_active(pr, string.format("https://github.com/%s/%s/pull/%d", pr.owner, pr.repo, pr.number))
  if not vim.uv.fs_stat(state.batch_path(pr)) then
    state.save_batch(batch.new(pr))
  end
  diff.open(pr.base)
  overlay.refresh(pr)
  -- Watch the batch file: when Claude (peer-review) flips draft→verified and writes it
  -- back, re-render so the flip shows without the human doing anything.
  start_watch(pr)

  -- Debounced nudge: after staging drafts, poke the claude pane (if present) to verify them.
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
    find_pane = function()
      local sess = ("ai-rev-pr%d"):format(pr.number)
      -- pcall: gh.run/vim.system THROWS (ENOENT) when tmux isn't installed — not a nonzero code.
      local ok, r = pcall(gh.run, { "tmux", "list-panes", "-t", sess, "-F", "#{pane_id} #{pane_current_command}" })
      if not ok or r.code ~= 0 then
        return nil -- no tmux / no such session → silent no-op
      end
      return nudge.pick_pane(r.stdout)
    end,
    send = function(cmd)
      pcall(gh.run, cmd) -- best-effort; a send-keys failure must never surface
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

function M.submit()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local b = state.load_or_init_batch(current_pr)
  -- re-running :PrReviewSubmit (or restarting the PR, which reloads this same batch)
  -- would otherwise re-POST every verified comment as a second, duplicate review
  local prior_submitted_at = b.submitted_at
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
  vim.ui.select({ "COMMENT", "REQUEST_CHANGES", "APPROVE" }, { prompt = "Verdict:" }, function(verdict)
    if not verdict then
      return
    end
    -- re-read here (not the `b` captured above): a verify-flip landing while this
    -- picker was open must be included, not silently dropped from the post
    b = state.load_or_init_batch(current_pr)
    -- Only bail on a submitted_at that APPEARED while the picker was open (a concurrent
    -- submit) — not on the one the user already confirmed past at the top of M.submit,
    -- else the "Submit again?" Yes branch would be unreachable.
    if b.submitted_at and b.submitted_at ~= prior_submitted_at then
      vim.notify("prreview: submit cancelled (already submitted at " .. b.submitted_at .. ")", vim.log.levels.WARN)
      return
    end
    b.verdict = verdict
    local serialized = batch.serialize(b)
    if #serialized.comments == 0 and (not serialized.body or serialized.body == "") then
      vim.notify("prreview: nothing to submit", vim.log.levels.WARN)
      return
    end
    local tmp = vim.fn.tempname()
    local fd = assert(io.open(tmp, "w"))
    fd:write(vim.json.encode(serialized))
    fd:close()
    local r = gh.run(gh.post_review_cmd(current_pr.owner, current_pr.repo, current_pr.number, tmp))
    if r.code == 0 then
      b.submitted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      b.submitted_review = parse_review_id(r.stdout)
      state.save_batch(b)
      vim.notify("prreview: review posted")
    else
      vim.notify("prreview: post failed: " .. r.stderr, vim.log.levels.ERROR)
    end
    vim.fn.delete(tmp) -- review JSON can carry code snippets; don't leave it in tmp
  end)
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
  -- `clear = true` above already makes re-running setup() idempotent for the group;
  -- put the watcher teardown in it too so this doesn't stack duplicate autocmds.
  vim.api.nvim_create_autocmd("VimLeavePre", { group = augroup, callback = M._stop_watch })
end

return M
