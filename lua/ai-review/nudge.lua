---@mod ai-review.nudge Claude-pane discovery + debounced send-keys nudge.

local M = {}

local SHELLS = { nvim = true, fish = true, bash = true, zsh = true, sh = true }

--- Pick the claude pane id from `tmux list-panes -F '#{pane_id} #{pane_current_command}'`.
--- Prefer a pane running `claude`; else the first non-shell/non-nvim pane; else nil.
---@param list_output string
---@return string?
function M.pick_pane(list_output)
  local fallback = nil
  for line in (list_output .. "\n"):gmatch("(.-)\n") do
    local id, cmd = line:match("^(%%%d+)%s+(%S+)")
    if id then
      if cmd == "claude" then
        return id
      elseif not SHELLS[cmd] and not fallback then
        fallback = id
      end
    end
  end
  return fallback
end

---@param pane_id string
---@param msg string
---@return string[]
function M.nudge_cmd(pane_id, msg)
  return { "tmux", "send-keys", "-t", pane_id, msg, "Enter" }
end

--- Build a debounced nudger. `request()` arms a single trailing timer; further requests
--- while armed are no-ops (coalescing). On fire: nudge only if there are drafts and a pane.
---@param opts { delay_ms: integer, msg: string, count_drafts: fun():integer, find_pane: fun():string?, send: fun(cmd:string[]), schedule: fun(ms:integer, fn:fun()) }
---@return { request: fun() }
function M.make(opts)
  local armed = false
  local function fire()
    armed = false
    if opts.count_drafts() > 0 then
      local pane = opts.find_pane()
      if pane then
        opts.send(M.nudge_cmd(pane, opts.msg))
      end
    end
  end
  return {
    request = function()
      if armed then
        return
      end
      armed = true
      opts.schedule(opts.delay_ms, fire)
    end,
  }
end

return M
