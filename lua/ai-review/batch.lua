---@mod ai-review.batch Pure review-batch model + serialization.

local M = {}

---@class prreview.PR
---@field owner string
---@field repo string
---@field number integer
---@field base string
---@field head_sha string
---@field worktree? string

---@class prreview.Suggestion
---@field lines string[]
---@field verified_sha? string

---@class prreview.Comment
---@field id string
---@field path string
---@field side "RIGHT"|"LEFT"
---@field line integer
---@field start_line? integer
---@field kind "comment"|"suggestion"|"question"|"nit"
---@field origin "human"|"claude"
---@field status "draft"|"verified"
---@field body string
---@field suggestion? prreview.Suggestion

---@class prreview.Batch
---@field pr prreview.PR
---@field verdict? "APPROVE"|"COMMENT"|"REQUEST_CHANGES"
---@field body string
---@field comments prreview.Comment[]

---@param pr prreview.PR
---@return prreview.Batch
function M.new(pr)
  return { pr = pr, verdict = nil, body = "", comments = {} }
end

---@param b prreview.Batch
---@param entry prreview.Comment
---@return string id
function M.add(b, entry)
  -- Allocate max-existing-suffix + 1, not #comments + 1: after replace_drafts_for_path
  -- removes then re-adds entries, a positional id could collide with a surviving entry's.
  -- peer-review flips drafts by id, so ids must stay unique among current entries.
  local max = 0
  for _, c in ipairs(b.comments) do
    local n = tonumber(tostring(c.id or ""):match("^c(%d+)$") or "")
    if n and n > max then
      max = n
    end
  end
  entry.id = "c" .. (max + 1)
  b.comments[#b.comments + 1] = entry
  return entry.id
end

---@param b prreview.Batch
---@return integer
function M.count_drafts(b)
  local n = 0
  for _, c in ipairs(b.comments) do
    if c.status == "draft" then
      n = n + 1
    end
  end
  return n
end

---@param b prreview.Batch
---@return string
function M.encode(b)
  return vim.json.encode(b)
end

---@param s string
---@return prreview.Batch
function M.decode(s)
  return vim.json.decode(s)
end

---@param c prreview.Comment
---@return string
local function render_body(c)
  if c.kind == "suggestion" and c.suggestion then
    return c.body .. "\n\n```suggestion\n" .. table.concat(c.suggestion.lines, "\n") .. "\n```"
  end
  return c.body
end

---@param b prreview.Batch
---@return { event?: string, commit_id: string, body: string, comments: table[] }
function M.serialize(b)
  local comments = {}
  for _, c in ipairs(b.comments) do
    if c.status == "verified" then
      local gc = { path = c.path, line = c.line, side = c.side, body = render_body(c) }
      if c.start_line then
        gc.start_line = c.start_line
      end
      comments[#comments + 1] = gc
    end
  end
  -- anchor the review to the commit reviewed, not whatever HEAD has moved to since
  return { event = b.verdict, commit_id = b.pr.head_sha, body = b.body, comments = comments }
end

--- Replace `path`'s HUMAN draft suggestions with `entries`; leaves verified entries,
--- comments, other files' entries, and any claude-origin drafts untouched. Used by the
--- save→draft pipeline (which only ever stages origin="human" drafts) so re-saving a
--- file doesn't accumulate duplicate human drafts, without clobbering Claude's drafts
--- on the same path.
---@param b prreview.Batch
---@param path string
---@param entries prreview.Comment[]
function M.replace_drafts_for_path(b, path, entries)
  local kept = {}
  for _, c in ipairs(b.comments) do
    if not (c.path == path and c.status == "draft" and c.kind == "suggestion" and c.origin == "human") then
      kept[#kept + 1] = c
    end
  end
  b.comments = kept
  for _, e in ipairs(entries) do
    M.add(b, e)
  end
end

return M
