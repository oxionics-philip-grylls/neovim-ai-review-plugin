---@mod ai-review.panel ✓ marks for reviewed files in diffview's file panel.
--- diffview exposes no decoration API, so this leans on internals (view.panel.bufid,
--- view.panel.components, FileEntry.path) and the fact that diffview rewrites the whole
--- panel buffer on every re-render. Everything is pcall-guarded: if a diffview change
--- breaks an assumption, the marks silently vanish rather than erroring a review.

local state = require("ai-review.state")
local M = {}

local ns = vim.api.nvim_create_namespace("pip_prreview_reviewed")
-- Each attach() bumps `gen` and captures it; an on_lines closure stops firing once
-- its captured generation is stale. This is robust to re-attaching the same buffer
-- (doesn't rely on Neovim never reusing a buffer number), unlike a bufid-equality check.
local gen = 0
local attached_buf = nil -- panel bufid we placed marks in, for detach's namespace clear

--- Re-derive the reviewed set from disk and (re)place ✓ signs on the visible panel lines.
---@param pr prreview.PR
function M.refresh(pr)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end
  pcall(function()
    local view = lib.get_current_view()
    local bufid = view and view.panel and view.panel.bufid
    if not bufid or not vim.api.nvim_buf_is_valid(bufid) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufid, ns, 0, -1)
    local comp = view.panel.components and view.panel.components.comp
    if not comp then
      return
    end
    local set = {}
    for _, p in ipairs(state.load_or_init_batch(pr).reviewed or {}) do
      set[p] = true
    end
    comp:deep_some(function(c)
      -- only file leaves carry a reviewable path; guarding on name avoids trusting a
      -- coincidental .path on a dir/title/margin component node
      if c.name == "file" and c.context and c.context.path and set[c.context.path] and c.lstart then
        pcall(vim.api.nvim_buf_set_extmark, bufid, ns, c.lstart, 0, {
          sign_text = "✓",
          sign_hl_group = "DiagnosticOk",
        })
      end
      return false -- visit every node
    end)
  end)
end

--- Attach to the current view's panel buffer so every diffview re-render re-applies marks.
---@param pr prreview.PR
function M.attach(pr)
  M.detach()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end
  pcall(function()
    local view = lib.get_current_view()
    local bufid = view and view.panel and view.panel.bufid
    if not bufid then
      return
    end
    gen = gen + 1
    local my_gen = gen
    attached_buf = bufid
    vim.api.nvim_buf_attach(bufid, false, {
      on_lines = function()
        if gen ~= my_gen then
          return true -- a newer attach (or a detach) superseded us: stop the callback
        end
        vim.schedule(function()
          M.refresh(pr)
        end)
      end,
    })
    M.refresh(pr)
  end)
end

--- Stop decorating and clear our marks. Idempotent.
function M.detach()
  if attached_buf and vim.api.nvim_buf_is_valid(attached_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, attached_buf, ns, 0, -1)
  end
  attached_buf = nil
  gen = gen + 1 -- invalidate any live on_lines closure so it detaches on next fire
end

return M
