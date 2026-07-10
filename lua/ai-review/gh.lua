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

---@param cmd string[]
---@return { code: integer, stdout: string, stderr: string }
function M.run(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
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
