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
---@field next_id integer monotonic id counter; persisted so ids never reuse across saves
---@field reviewed string[] repo-relative paths marked reviewed (local-only; never serialized)
---@field submitted_at? string
---@field submitted_review? integer
---@field _loaded_mtime? { sec: integer, nsec: integer } generation stamp; not persisted

---@param pr prreview.PR
---@return prreview.Batch
function M.new(pr)
  return { pr = pr, verdict = nil, body = "", comments = {}, next_id = 1, reviewed = {} }
end

---@param b prreview.Batch
---@param entry prreview.Comment
---@return string id
function M.add(b, entry)
  if b.next_id == nil then
    -- legacy batch decoded from a file predating the persistent counter: seed it from
    -- the current max so we don't collide with existing entries
    local max = 0
    for _, c in ipairs(b.comments) do
      local n = tonumber(tostring(c.id or ""):match("^c(%d+)$") or "")
      if n and n > max then
        max = n
      end
    end
    b.next_id = max + 1
  end
  entry.id = "c" .. b.next_id
  b.next_id = b.next_id + 1
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
---@param path string
---@return boolean
function M.is_reviewed(b, path)
  for _, p in ipairs(b.reviewed or {}) do
    if p == path then
      return true
    end
  end
  return false
end

--- Toggle a path's reviewed membership. Returns the NEW state (true = now reviewed).
---@param b prreview.Batch
---@param path string
---@return boolean
function M.toggle_reviewed(b, path)
  b.reviewed = b.reviewed or {}
  for i, p in ipairs(b.reviewed) do
    if p == path then
      table.remove(b.reviewed, i)
      return false
    end
  end
  b.reviewed[#b.reviewed + 1] = path
  return true
end

---@param b prreview.Batch
---@return integer
function M.count_reviewed(b)
  return #(b.reviewed or {})
end

---@param b prreview.Batch
---@return string
function M.encode(b)
  local persisted = {}
  for k, v in pairs(b) do
    if not tostring(k):match("^_") then
      persisted[k] = v
    end
  end
  return vim.json.encode(persisted)
end

---@param s string
---@return prreview.Batch
function M.decode(s)
  return vim.json.decode(s)
end

local VALID_SIDES = { RIGHT = true, LEFT = true }
local VALID_STATUSES = { draft = true, verified = true }
local VALID_KINDS = { comment = true, suggestion = true, question = true, nit = true }

---@param n unknown
---@return boolean
local function is_integer(n)
  return type(n) == "number" and n == math.floor(n)
end

--- Lenient post-decode sanitizer for a batch that may have been hand-edited or written
--- by another process: drops entries that aren't well-shaped rather than rejecting the
--- whole file, so one bad entry can't take down the entire review session.
---@param decoded table
---@return prreview.Batch
function M.validate(decoded)
  -- coerce reviewed FIRST, before any early return: a doubly-corrupt file (bad comments
  -- AND bad reviewed) must still leave a list-shaped reviewed, else later ipairs() throws.
  if type(decoded.reviewed) ~= "table" then
    decoded.reviewed = {}
  end
  if type(decoded.comments) ~= "table" then
    decoded.comments = {}
    return decoded
  end
  local kept = {}
  for _, c in ipairs(decoded.comments) do
    local ok = type(c) == "table"
      and type(c.path) == "string"
      and is_integer(c.line)
      and VALID_SIDES[c.side]
      and VALID_STATUSES[c.status]
      and VALID_KINDS[c.kind]
    if ok then
      kept[#kept + 1] = c
    else
      local id = (type(c) == "table" and c.id) or "?"
      vim.notify("prreview: dropping malformed batch entry " .. tostring(id), vim.log.levels.WARN)
    end
  end
  decoded.comments = kept
  return decoded
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
