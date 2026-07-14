---@mod ai-review.url Pure GitHub PR-URL / remote parsing.

local M = {}

-- github.com must be the HOST, not a substring anywhere: else a spoof path like
-- "evil.com/github.com/o/r/pull/1" would parse as a github URL and target the wrong repo.
---@param s string
---@return { owner: string, repo: string, number: integer }?
function M.parse_pr_url(s)
  local owner, repo, number = s:match("^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)")
  if not owner then
    return nil
  end
  return { owner = owner, repo = (repo:gsub("%.git$", "")), number = tonumber(number) }
end

---@param s string
---@return { owner: string, repo: string }?
function M.parse_remote(s)
  -- host-anchored: https://github.com/o/r(.git), git@github.com:o/r(.git) (SCP form),
  -- or ssh://git@github.com/o/r(.git).
  local owner, repo = s:match("^https?://github%.com/([^/]+)/([^/%s]+)")
  if not owner then
    owner, repo = s:match("^git@github%.com:([^/]+)/([^/%s]+)")
  end
  if not owner then
    owner, repo = s:match("^ssh://git@github%.com/([^/]+)/([^/%s]+)")
  end
  if not owner then
    return nil
  end
  return { owner = owner, repo = (repo:gsub("%.git$", "")) }
end

return M
