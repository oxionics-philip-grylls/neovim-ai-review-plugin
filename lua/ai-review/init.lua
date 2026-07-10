---@mod ai-review In-Neovim GitHub PR review: commands + glue.

local url = require("ai-review.url")
local batch = require("ai-review.batch")
local state = require("ai-review.state")
local gh = require("ai-review.gh")
local diff = require("ai-review.diff")
local overlay = require("ai-review.overlay")

local M = {}
---@type prreview.PR?
local current_pr = nil

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

  local diffparse = require("ai-review.diffparse")
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
        end
        -- pure insertions (to_entry == nil) are intentionally skipped in v1; not silently
        -- claimed as handled, just not yet anchored to a following-line suggestion
      end
      local b = state.load_or_init_batch(current_pr)
      batch.replace_drafts_for_path(b, rel, entries)
      state.save_batch(b)
      overlay.refresh(current_pr)
      vim.notify(("prreview: staged %d draft suggestion(s) for %s"):format(#entries, rel))
    end,
  })

  vim.notify(("prreview: reviewing %s/%s#%d"):format(pr.owner, pr.repo, pr.number))
end

---@param kind "comment"|"question"|"nit"
local function add_comment(kind)
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local anchor = diff.cursor_anchor()
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

function M.submit()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local b = state.load_or_init_batch(current_pr)
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
  vim.api.nvim_create_user_command("PrComment", function()
    add_comment("comment")
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
    local wt = current_pr.worktree or state.worktree_path(current_pr)
    if vim.uv.fs_stat(wt) then
      gh.run(gh.worktree_remove_cmd(wt))
      gh.run(gh.worktree_prune_cmd())
    end
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
end

return M
