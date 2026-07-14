---@mod ai-review.overlay Virtual-text overlay of batch entries on the diff.

local state = require("ai-review.state")
local M = {}

local ns = vim.api.nvim_create_namespace("pip_prreview")

--- base (LEFT) and head (RIGHT) buffers of the given view's current Diff2
--- layout. Read straight from diffview's own model (view.cur_layout.a/b are
--- the base/head Windows — see diffview/vcs/adapters/git/init.lua where
--- revs.a is the left_hash and revs.b the right_hash) instead of inferring
--- side from window column position: column-based heuristics misclassify as
--- soon as a third window (quickfix, floating popup) is in the tabpage, or
--- break outright under a vertical (top/bottom) Diff2Ver layout.
---@param view any diffview View
---@return integer? head_buf, integer? base_buf
local function side_bufs(view)
  local layout = view.cur_layout
  if not layout or not layout.a or not layout.b then
    return nil, nil
  end
  local base = layout.a.file and layout.a.file.bufnr
  local head = layout.b.file and layout.b.file.bufnr
  return head, base
end

function M.clear()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_clear_namespace, b, ns, 0, -1)
  end
end

--- Highlight group + tag suffix for a batch entry, by status/kind.
---@param c prreview.Comment
---@return string hl, string tag_suffix
function M.decorate(c)
  if c.status == "draft" then
    return "DiagnosticWarn", " draft"
  elseif c.status == "verified" and c.kind == "suggestion" then
    return "DiagnosticOk", " ✓"
  end
  return "Comment", ""
end

---@param b prreview.Batch
function M.render(b)
  local view = require("diffview.lib").get_current_view()
  if not view or not view.cur_entry then
    -- No live redraw here (e.g. a watcher-triggered refresh while another tab is
    -- current): clearing would wipe extmarks nothing is about to replace.
    return
  end
  local path = view.cur_entry.path

  local head_buf, base_buf = side_bufs(view)

  M.clear()
  for _, c in ipairs(b.comments) do
    if c.path == path then
      local bufnr = c.side == "RIGHT" and head_buf or base_buf
      if bufnr then
        local hl, suffix = M.decorate(c)
        local tag = ("[%s%s] %s"):format(c.origin, suffix, c.body)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, c.line - 1, 0, {
          virt_lines = { { { "  ▸ " .. tag, hl } } },
          virt_lines_above = false,
        })
      end
    end
  end
end

---@param pr prreview.PR
---@param root? string
function M.refresh(pr, root)
  M.render(state.load_or_init_batch(pr, root))
end

return M
