---@mod ai-review.url Pure GitHub PR-URL / remote parsing.

local M = {}

---@param s string
---@return { owner: string, repo: string, number: integer }?
function M.parse_pr_url(s)
  local owner, repo, number = s:match("github%.com[/:]([^/]+)/([^/]+)/pull/(%d+)")
  if not owner then
    return nil
  end
  return { owner = owner, repo = (repo:gsub("%.git$", "")), number = tonumber(number) }
end

---@param s string
---@return { owner: string, repo: string }?
function M.parse_remote(s)
  local owner, repo = s:match("github%.com[/:]([^/]+)/([^/%s]+)")
  if not owner then
    return nil
  end
  return { owner = owner, repo = (repo:gsub("%.git$", "")) }
end

return M
