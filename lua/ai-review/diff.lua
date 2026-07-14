---@mod ai-review.diff diffview split + cursor-anchor extraction.

local lib = require("diffview.lib")

local M = {}

---@param base string
function M.open(base)
  vim.cmd(string.format("DiffviewOpen origin/%s...FETCH_HEAD", base))
end

--- Repo-relative path of the current buffer.
---
--- Diffview backs "local" (working-tree) sides with a buffer named for the
--- real file, but backs commit/stage revisions with a synthetic
--- "diffview://<ctx.dir>/<rev>/<path>" buffer (see diffview/vcs/file.lua
--- `create_buffer`). `ctx.dir` isn't always "<toplevel>/.git": a linked
--- worktree's is "<main>/.git/worktrees/<name>", so the number of segments
--- before "<rev>/<path>" varies and can't be found by counting from ".git".
--- Ask diffview's own view model for the path instead, which is authoritative
--- regardless of gitdir layout.
---@return string?
local function rel_path()
  local abs = vim.api.nvim_buf_get_name(0)

  if abs == "diffview://null" or abs:match("^diffview:///panels/") then
    -- "diffview://null" is the added/deleted side's placeholder buffer; the
    -- panels are the file/commit-log panel. Neither has a file to anchor to.
    return nil
  end

  if not abs:match("^diffview://") then
    local root = vim.fs.root(0, ".git") or vim.uv.cwd()
    return (abs:gsub("^" .. vim.pesc(root) .. "/", ""))
  end

  local view = lib.get_current_view()
  local entry = view and view.cur_entry
  return entry and entry.path or nil
end

--- Which diff side the cursor window shows. Reads diffview's own layout model
--- (view.cur_layout.a/b are the base/head Windows, mirroring overlay.side_bufs)
--- instead of a column-position heuristic: a third window in the tab (a
--- floating popup, quickfix, ...) can occupy the tabpage's rightmost column
--- without being either diff side, misclassifying the real cursor window.
---@return "RIGHT"|"LEFT"
local function cursor_side()
  local view = lib.get_current_view()
  local layout = view and view.cur_layout
  if layout and layout.a and layout.b then
    local cur = vim.api.nvim_get_current_win()
    if cur == layout.a.id then
      return "LEFT"
    elseif cur == layout.b.id then
      return "RIGHT"
    end
  end

  -- Fall back to the column heuristic when the layout/window ids aren't
  -- available (e.g. outside a diffview session, or a layout with no a/b).
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local cur = vim.api.nvim_get_current_win()
  local cur_col = vim.api.nvim_win_get_position(cur)[2]
  local max_col = cur_col
  for _, w in ipairs(wins) do
    max_col = math.max(max_col, vim.api.nvim_win_get_position(w)[2])
  end
  return cur_col >= max_col and "RIGHT" or "LEFT"
end

---@param range? { [1]: integer, [2]: integer } an explicit [lo, hi] line range
---  (from a `:'<,'>` command range), taking precedence over the mode()-based
---  v/V detection below. A command callback only sees normal mode by the
---  time it runs, even after a `:'<,'>` prefix, so the caller must thread its
---  own a.range/a.line1/a.line2 through here instead.
---@return { path: string, line: integer, start_line?: integer, side: "RIGHT"|"LEFT" }?
function M.cursor_anchor(range)
  local path = rel_path()
  if not path then
    return nil
  end

  local side = cursor_side()
  if range then
    local lo, hi = math.min(range[1], range[2]), math.max(range[1], range[2])
    return { path = path, start_line = lo, line = hi, side = side }
  end
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    local lo, hi = math.min(a, b), math.max(a, b)
    return { path = path, start_line = lo, line = hi, side = side }
  end
  return { path = path, line = vim.fn.line("."), side = side }
end

return M
