---@mod ai-review.gh gh/git command builders + thin executor.

local M = {}

---@return string[]
function M.pr_info_cmd(owner, repo, number)
  return { "gh", "pr", "view", tostring(number), "--repo", owner .. "/" .. repo, "--json", "baseRefName,headRefOid" }
end

---@return string[]
function M.fetch_head_cmd(number)
  return { "git", "fetch", "origin", string.format("pull/%d/head", number) }
end

---@return string[]
function M.post_review_cmd(owner, repo, number, input_path)
  return {
    "gh",
    "api",
    string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, number),
    "--method",
    "POST",
    "--input",
    input_path,
  }
end

---@return string[]
function M.worktree_add_cmd(wt, branch, head_sha)
  return { "git", "worktree", "add", "-B", branch, wt, head_sha }
end

---@return string[]
function M.worktree_remove_cmd(wt)
  return { "git", "worktree", "remove", "--force", wt }
end

---@return string[]
function M.worktree_prune_cmd()
  return { "git", "worktree", "prune" }
end

---@return string[]
function M.worktree_head_cmd(wt)
  return { "git", "-C", wt, "rev-parse", "HEAD" }
end

--- Run a command, never throwing and never hanging. Missing binary (vim.system throws
--- ENOENT) or timeout both map to code=-1 with a descriptive stderr, so callers'
--- existing `code ~= 0` handling produces the right notify everywhere.
---@param cmd string[]
---@param opts? { timeout?: integer }
---@return { code: integer, stdout: string, stderr: string }
function M.run(cmd, opts)
  local timeout = (opts and opts.timeout) or 30000
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout)
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  -- vim.system:wait(timeout) SIGKILLs on expiry rather than returning code=nil; _system.lua
  -- then remaps the exit to 124. Pair it with signal==9 so a command that GENUINELY exits 124
  -- (signal 0) isn't mis-reported as a timeout. (The `code==nil` arm is defensive — not
  -- reachable on current nvim, kept for forward-compat.)
  if res.code == nil or (res.code == 124 and res.signal == 9) then
    return { code = -1, stdout = res.stdout or "", stderr = ("timed out after %dms: %s"):format(timeout, cmd[1]) }
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---@return { base: string, head_sha: string }?
function M.pr_info(owner, repo, number)
  local r = M.run(M.pr_info_cmd(owner, repo, number))
  if r.code ~= 0 then
    return nil
  end
  local ok, j = pcall(vim.json.decode, r.stdout)
  if not ok then
    return nil
  end
  return { base = j.baseRefName, head_sha = j.headRefOid }
end

return M
