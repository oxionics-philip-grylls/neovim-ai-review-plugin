---@mod ai-review.state Batch/active-file paths and persistence.

local batch = require("ai-review.batch")
local M = {}

---@return string
function M.default_root()
  return vim.fn.expand("~/.local/state/nvim/pr-review")
end

---@param pr prreview.PR
---@param root? string
---@return string
function M.batch_path(pr, root)
  root = root or M.default_root()
  return string.format("%s/%s__%s__pr%d.json", root, pr.owner, pr.repo, pr.number)
end

---@param root? string
---@return string
function M.active_path(root)
  return (root or M.default_root()) .. "/active.json"
end

---@param path string
---@param text string
local function write_file(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. ".tmp"
  local fd = assert(io.open(tmp, "w"))
  fd:write(text)
  fd:close()
  os.rename(tmp, path) -- same-fs rename is atomic: no reader ever sees a half-written batch
end

---@param path string
---@return string?
local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

---@param pr prreview.PR
---@param pr_url string
---@param root? string
function M.write_active(pr, pr_url, root)
  write_file(
    M.active_path(root),
    vim.json.encode({
      owner = pr.owner,
      repo = pr.repo,
      number = pr.number,
      base = pr.base,
      head_sha = pr.head_sha,
      pr_url = pr_url,
      batch_path = M.batch_path(pr, root),
    })
  )
end

---@param root? string
---@return table?
function M.read_active(root)
  local text = read_file(M.active_path(root))
  if not text then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  return ok and decoded or nil
end

---@param b prreview.Batch
---@param root? string
function M.save_batch(b, root)
  write_file(M.batch_path(b.pr, root), batch.encode(b))
end

---@param pr prreview.PR
---@param root? string
---@return prreview.Batch
function M.load_or_init_batch(pr, root)
  local text = read_file(M.batch_path(pr, root))
  if not text then
    return batch.new(pr)
  end
  local ok, decoded = pcall(batch.decode, text)
  return ok and decoded or batch.new(pr)
end

return M
