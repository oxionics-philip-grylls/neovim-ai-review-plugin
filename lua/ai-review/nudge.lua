---@mod ai-review.nudge Claude-pane discovery + debounced send-keys nudge.

local M = {}

-- Exact match only — a non-shell fallback used to send-keys into an unrelated pane
-- (a node server, a REPL). Add wrappers here if a setup reports a different command.
local CLAUDE_CMDS = { claude = true }

--- Pick the claude pane id from `tmux list-panes -F '#{pane_id} #{pane_current_command}'`.
--- Returns the first pane whose command is a known claude command; else nil (no guessing).
---@param list_output string
---@return string?
function M.pick_pane(list_output)
  for line in (list_output .. "\n"):gmatch("(.-)\n") do
    local id, cmd = line:match("^(%%%d+)%s+(%S+)")
    if id and CLAUDE_CMDS[cmd] then
      return id
    end
  end
  return nil
end

---@param pane_id string
---@param msg string
---@return string[]
function M.nudge_cmd(pane_id, msg)
  return { "tmux", "send-keys", "-t", pane_id, msg, "Enter" }
end

--- The message to send to the claude pane when the user asks Claude to author the
--- review summary body. `batch_path` tells the /peer-review skill which batch to edit.
---@param batch_path string
---@return string
function M.body_request_msg(batch_path)
  return (
    "prreview: please author the review summary body (overall assessment + reasoning) "
    .. "into the batch's `body` field at %s, then tell me it's ready"
  ):format(batch_path)
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
