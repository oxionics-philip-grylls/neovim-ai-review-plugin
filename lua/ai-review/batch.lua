---@mod ai-review.batch Pure review-batch model + serialization.

local M = {}

---@class prreview.PR
---@field owner string
---@field repo string
---@field number integer
---@field base string
---@field head_sha string

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
  entry.id = "c" .. (#b.comments + 1)
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

return M
