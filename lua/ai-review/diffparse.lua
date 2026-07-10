---@mod ai-review.diffparse Pure `git diff -U0` → suggestion anchors.

local M = {}

---@class prreview.Hunk
---@field old_start integer   first PR-head line the hunk covers
---@field old_count integer   number of PR-head lines replaced (0 = pure insertion)
---@field new_lines string[]  the replacement (`+`) lines

--- Parse `git diff -U0` text into hunks. Old-side range drives the RIGHT-side anchor;
--- `+` lines are the suggestion body. Assumes -U0 (no context lines in the hunk body).
---@param diff_text string
---@return prreview.Hunk[]
function M.parse(diff_text)
  local hunks = {}
  local cur = nil
  for line in (diff_text .. "\n"):gmatch("(.-)\n") do
    local os_, oc = line:match("^@@ %-(%d+),?(%d*) %+%d+,?%d* @@")
    if line:match("^diff %-%-git ") then
      cur = nil -- next hunk belongs to a new file; stop collecting into the old one
    elseif os_ then
      cur = { old_start = tonumber(os_), old_count = oc == "" and 1 or tonumber(oc), new_lines = {} }
      hunks[#hunks + 1] = cur
    elseif cur and line:sub(1, 1) == "+" then
      cur.new_lines[#cur.new_lines + 1] = line:sub(2)
    end
  end
  return hunks
end

--- Map a REPLACE hunk (old_count >= 1) to a RIGHT-side suggestion anchor. Returns nil for a
--- pure insertion (old_count == 0); the staging layer anchors those to the adjacent line.
---@param h prreview.Hunk
---@return { side: "RIGHT", start_line: integer, line: integer, suggestion: { lines: string[] } }?
function M.to_entry(h)
  if h.old_count < 1 then
    return nil
  end
  return {
    side = "RIGHT",
    start_line = h.old_start,
    line = h.old_start + h.old_count - 1,
    suggestion = { lines = h.new_lines },
  }
end

return M
