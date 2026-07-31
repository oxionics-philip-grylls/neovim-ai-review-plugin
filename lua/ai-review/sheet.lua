---@mod ai-review.sheet Render/parse the review batch as one editable sheet document.
--- Pure: no windows, no I/O. The format's whole job is to survive a human editing it, so
--- the delimiter is a `@@@` sentinel at column 0 (bodies contain `##`, code fences and
--- quoted diffs, so none of those can delimit) and `#cN` ids carry identity.

local batch = require("ai-review.batch")

local M = {}

--- Escaping is a bijection: `render` prefixes one space to any body line matching `^ *@@@`
--- and `parse` strips one leading space from any line matching `^ +@@@`. Escaping only
--- `^@@@` would corrupt a body line that legitimately starts with a space before `@@@`,
--- because parse then can't tell an escaped line from an original one.
---@param l string
---@return string
local function escape_line(l)
  return l:match("^ *@@@") and (" " .. l) or l
end

---@param l string
---@return string
local function unescape_line(l)
  return l:match("^ +@@@") and l:sub(2) or l
end

---@param c prreview.Comment
---@return string
local function anchor_of(c)
  if c.start_line then
    return ("%s:%d-%d"):format(c.path, c.start_line, c.line)
  end
  return ("%s:%d"):format(c.path, c.line)
end

--- Render the batch as sheet lines.
---@param b prreview.Batch
---@return string[]
function M.render(b)
  local out = {
    "# verdict: " .. (b.verdict or "COMMENT"),
    "# ids (#cN) identify comments — leave them alone. Delete a section to drop it.",
    "",
    "@@@ summary",
  }
  for _, l in ipairs(vim.split(b.body or "", "\n", { plain = true })) do
    out[#out + 1] = escape_line(l)
  end
  for _, c in ipairs(b.comments or {}) do
    out[#out + 1] = ""
    out[#out + 1] = ("@@@ %s [%s] #%s %s"):format(anchor_of(c), c.kind, c.id, c.status)
    for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
      out[#out + 1] = escape_line(l)
    end
    if c.kind == "suggestion" and c.suggestion then
      out[#out + 1] = "```suggestion"
      for _, l in ipairs(c.suggestion.lines or {}) do
        out[#out + 1] = escape_line(l)
      end
      out[#out + 1] = "```"
    end
  end
  return out
end

local VALID_VERDICTS = { APPROVE = true, COMMENT = true, REQUEST_CHANGES = true }
local VALID_KINDS = { comment = true, suggestion = true, question = true, nit = true }
local VALID_STATUSES = { draft = true, verified = true }

--- Split an entry's raw lines into body and (for suggestions) the trailing fenced block.
--- The block runs from the `" ```suggestion "` line to the LAST bare fence, so suggestion
--- lines may themselves contain a fence.
---@param raw string[]
---@return string body, { lines: string[] }? suggestion
local function split_suggestion(raw)
  local open
  for i, l in ipairs(raw) do
    if l == "```suggestion" then
      open = i
      break
    end
  end
  if not open then
    return table.concat(raw, "\n"), nil
  end
  local close
  for i = #raw, open + 1, -1 do
    if raw[i] == "```" then
      close = i
      break
    end
  end
  if not close then
    return table.concat(raw, "\n"), nil
  end
  local body = {}
  for i = 1, open - 1 do
    body[#body + 1] = raw[i]
  end
  local sug = {}
  for i = open + 1, close - 1 do
    sug[#sug + 1] = raw[i]
  end
  return table.concat(body, "\n"), { lines = sug }
end

--- Parse sheet lines. Returns nil plus a message naming the offending line on any
--- ambiguity — a bad parse must never be applied to the batch.
---@param lines string[]
---@return table? parsed, string? err
function M.parse(lines)
  local verdict
  local entries = {}
  local seen_ids = {}
  local cur, cur_lines = nil, nil

  local function close_entry()
    if not cur then
      return
    end
    local body, sug
    if cur.kind == "suggestion" then
      body, sug = split_suggestion(cur_lines)
    else
      body = table.concat(cur_lines, "\n")
      sug = nil
    end
    cur.body, cur.suggestion = body, sug
    entries[#entries + 1] = cur
    cur, cur_lines = nil, nil
  end

  local summary_lines = nil
  for lnum, raw in ipairs(lines) do
    local v = raw:match("^#%s*verdict:%s*(%S+)%s*$")
    if v and not verdict and not cur and not summary_lines then
      if not VALID_VERDICTS[v] then
        return nil, ("invalid verdict %q — use APPROVE, COMMENT or REQUEST_CHANGES (line %d)"):format(v, lnum)
      end
      verdict = v
    elseif raw:match("^@@@ ") then
      -- Strip the separator blank that render added before this header
      if cur_lines and #cur_lines > 0 and cur_lines[#cur_lines] == "" then
        cur_lines[#cur_lines] = nil
      end
      close_entry()
      if raw == "@@@ summary" then
        summary_lines = {}
        cur_lines = summary_lines
      else
        local path, l1, l2, kind, rest = raw:match("^@@@ (.+):(%d+)%-?(%d*) %[(%a+)%]%s*(.*)$")
        if not path then
          return nil, ("malformed header — expected `@@@ path:line [kind] #id status` (line %d)"):format(lnum)
        end
        if not VALID_KINDS[kind] then
          return nil, ("unknown kind %q (line %d)"):format(kind, lnum)
        end
        local id = rest:match("#(c%d+)")
        local status
        if id then
          -- Status is required when id is present
          local remainder = rest:gsub("#c%d+%s*", "", 1)
          status = remainder:match("^(%S+)")
          if not status or not VALID_STATUSES[status] then
            return nil, ("missing or invalid status (line %d)"):format(lnum)
          end
        else
          -- No id: status defaults to draft
          status = "draft"
        end
        if id then
          if seen_ids[id] then
            return nil, ("duplicate id #%s (line %d)"):format(id, lnum)
          end
          seen_ids[id] = true
        end
        cur = { id = id, path = path, line = tonumber(l1), kind = kind, status = status }
        if l2 ~= "" then
          -- rendered as start-end; the end is the anchor line
          cur.start_line, cur.line = tonumber(l1), tonumber(l2)
        end
        cur_lines = {}
      end
    elseif cur_lines then
      cur_lines[#cur_lines + 1] = unescape_line(raw)
    end
  end
  close_entry()

  if not verdict then
    return nil, "missing `# verdict:` line — add one of APPROVE, COMMENT, REQUEST_CHANGES (line 1)"
  end
  return { verdict = verdict, body = table.concat(summary_lines or {}, "\n"), entries = entries }, nil
end

--- Fold a parsed sheet back into the batch. Entries are matched by id; an id-less entry
--- becomes a new human draft; an id that vanished from the sheet is a drop. Builds the
--- whole comment list before assigning, so a rejected apply leaves the batch untouched.
---@param b prreview.Batch
---@param parsed table
---@return integer? dropped, string? err
function M.apply(b, parsed)
  local by_id = {}
  for _, c in ipairs(b.comments) do
    by_id[c.id] = c
  end
  local kept, seen = {}, {}
  for _, e in ipairs(parsed.entries) do
    local c
    if e.id then
      c = by_id[e.id]
      if not c then
        return nil, ("unknown id #%s — it doesn't match any comment in the batch"):format(e.id)
      end
      seen[e.id] = true
    else
      c = { id = nil, side = "RIGHT", origin = "human" }
    end
    -- verified_sha attests to code actually built and tested; an untouched suggestion
    -- keeps that provenance, but an edited one no longer describes what was verified
    local suggestion = e.suggestion
    if e.id and c.suggestion and suggestion and vim.deep_equal(c.suggestion.lines, suggestion.lines) then
      suggestion = { lines = suggestion.lines, verified_sha = c.suggestion.verified_sha }
    end
    kept[#kept + 1] = {
      id = c.id,
      path = e.path,
      line = e.line,
      start_line = e.start_line,
      side = c.side,
      kind = e.kind,
      origin = c.origin,
      status = e.status,
      body = e.body,
      suggestion = suggestion,
    }
  end
  local dropped = 0
  for _, c in ipairs(b.comments) do
    if not seen[c.id] then
      dropped = dropped + 1
    end
  end
  -- every check passed: now mutate
  for _, c in ipairs(kept) do
    if not c.id then
      c.id = batch.alloc_id(b)
    end
  end
  b.comments = kept
  b.verdict = parsed.verdict
  b.body = parsed.body
  return dropped, nil
end

--- The anchor of the entry containing `lnum` (1-based), by scanning upward for its header.
--- Returns nil in the summary or above the first entry. Used to sync the code pane.
---@param lines string[]
---@param lnum integer
---@return { path: string, line: integer }?
function M.anchor_at(lines, lnum)
  for i = math.min(lnum, #lines), 1, -1 do
    local l = lines[i]
    if l == "@@@ summary" then
      return nil
    end
    if l and l:match("^@@@ ") then
      local path, l1, l2 = l:match("^@@@ (.+):(%d+)%-?(%d*) %[")
      if not path then
        return nil
      end
      return { path = path, line = tonumber(l2 ~= "" and l2 or l1) }
    end
  end
  return nil
end

return M
