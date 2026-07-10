-- Minimal, reproducible rtp for headless specs: plenary + this repo's lua/.
local function add(p)
  vim.opt.runtimepath:append(p)
end

-- Resolve relative to this file (not vim.fn.getcwd()) so specs work no matter
-- where nvim is launched from, e.g. `nvim -u tests/minimal_init.lua` from
-- another directory.
local this_file = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ":h:h")

add(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
add(repo_root) -- so require("ai-review...") resolves

vim.cmd("runtime plugin/plenary.vim")
