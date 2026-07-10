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
  current_pr = pr
  state.write_active(pr, string.format("https://github.com/%s/%s/pull/%d", pr.owner, pr.repo, pr.number))
  if not vim.uv.fs_stat(state.batch_path(pr)) then
    state.save_batch(batch.new(pr))
  end
  diff.open(pr.base)
  overlay.refresh(pr)
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

function M.suggest()
  if not current_pr then
    vim.notify("prreview: no active review (:PrReviewStart)", vim.log.levels.ERROR)
    return
  end
  local anchor = diff.cursor_anchor()
  if not anchor or anchor.side ~= "RIGHT" then
    vim.notify("prreview: select lines on the PR (right) side to suggest", vim.log.levels.ERROR)
    return
  end
  local lo = anchor.start_line or anchor.line
  local lines = vim.api.nvim_buf_get_lines(0, lo - 1, anchor.line, false)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.bo[scratch].bufhidden = "wipe"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, scratch)
  vim.notify("prreview: edit the replacement, then :w to stage the suggestion")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = scratch,
    once = true,
    callback = function()
      local edited = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
      vim.ui.input({ prompt = "suggestion note: " }, function(body)
        if body == nil then -- Esc-cancelled: don't stage a draft
          return
        end
        local b = state.load_or_init_batch(current_pr)
        batch.add(
          b,
          vim.tbl_extend("force", anchor, {
            kind = "suggestion",
            origin = "human",
            status = "draft",
            body = body or "",
            suggestion = { lines = edited },
          })
        )
        state.save_batch(b)
        overlay.refresh(current_pr)
        vim.cmd("close")
        vim.notify("prreview: staged draft suggestion — Claude will verify it")
      end)
    end,
  })
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
