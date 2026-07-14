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

---@param pr prreview.PR
---@param root? string
---@return string
function M.worktree_path(pr, root)
  return string.format("%s/wt/%s__%s__pr%d", root or M.default_root(), pr.owner, pr.repo, pr.number)
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
      worktree = pr.worktree,
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

--- Merge another writer's on-disk batch `d` with this process's in-memory batch `b`,
--- keyed by comment id: `b` wins for ids it holds (its status flips and new entries),
--- `d`'s ids that `b` never touched this cycle are kept. `d`'s order comes first, with
--- `b`-only ids appended in `b`'s order, so merges stay stable across repeated saves.
---@param d prreview.Batch on-disk batch, freshly re-read
---@param b prreview.Batch this process's in-memory batch
---@return prreview.Batch
local function merge_batches(d, b)
  -- id-less entries can't be keyed for a merge (a nil table index also throws); they only
  -- arise from a foreign/hand-edited file since add() always assigns an id, so drop them.
  local order, by_id = {}, {}
  for _, c in ipairs(d.comments or {}) do
    if c.id then
      if by_id[c.id] == nil then
        order[#order + 1] = c.id
      end
      by_id[c.id] = c
    end
  end
  for _, c in ipairs(b.comments or {}) do
    if c.id then
      if by_id[c.id] == nil then
        order[#order + 1] = c.id
      end
      by_id[c.id] = c
    end
  end
  local comments = {}
  for _, id in ipairs(order) do
    comments[#comments + 1] = by_id[id]
  end
  return {
    pr = b.pr,
    verdict = b.verdict,
    body = b.body,
    comments = comments,
    next_id = math.max(d.next_id or 0, b.next_id or 0),
    -- the double-post guard marker must never be dropped by a merge
    submitted_at = b.submitted_at or d.submitted_at,
    submitted_review = b.submitted_review or d.submitted_review,
  }
end

---@param b prreview.Batch
---@param root? string
function M.save_batch(b, root)
  local path = M.batch_path(b.pr, root)
  -- Refresh our generation stamp after writing exactly `b`: the file now equals our
  -- in-memory batch, so a later save of this same object must not read its own write
  -- back as a "concurrent writer" and needlessly take the merge path (which would
  -- resurrect entries this session deleted). Only for the branches where disk == b.
  local function write_as_b(text)
    write_file(path, text)
    local stat = vim.uv.fs_stat(path)
    b._loaded_mtime = stat and stat.mtime or nil
  end
  local disk_mtime = vim.uv.fs_stat(path)
  disk_mtime = disk_mtime and disk_mtime.mtime or nil
  if vim.deep_equal(disk_mtime, b._loaded_mtime) then
    -- no writer landed since we loaded (both-nil == file still absent): safe to overwrite
    write_as_b(batch.encode(b))
    return
  end
  -- A concurrent writer's change landed on disk since this batch was loaded. Re-read and
  -- merge by id rather than clobbering it. Residual limitation: two writes within the same
  -- mtime-nsec tick can still race past this check — acceptable given atomic rename +
  -- typical ext4 nsec resolution, not attempting to close that gap here.
  local text = read_file(path)
  local ok, decoded = false, nil
  if text then
    ok, decoded = pcall(batch.decode, text)
  end
  if not (ok and decoded) then
    -- unreadable/corrupt on-disk file: fall back to writing `b` as-is rather than losing it
    write_as_b(batch.encode(b))
    return
  end
  local d = batch.validate(decoded)
  -- Deliberately do NOT re-stamp here: the file now holds merge(d,b), which differs from
  -- our in-memory b. Leaving _loaded_mtime stale means a subsequent save re-reads and
  -- re-merges (idempotent) instead of clobbering the other writer's entries with b-only.
  write_file(path, batch.encode(merge_batches(d, b)))
end

---@param pr prreview.PR
---@param root? string
---@return prreview.Batch
function M.load_or_init_batch(pr, root)
  local path = M.batch_path(pr, root)
  local text = read_file(path)
  local b
  if not text then
    b = batch.new(pr)
  else
    local ok, decoded = pcall(batch.decode, text)
    b = ok and batch.validate(decoded) or batch.new(pr)
  end
  local stat = vim.uv.fs_stat(path)
  b._loaded_mtime = stat and stat.mtime or nil
  return b
end

return M
