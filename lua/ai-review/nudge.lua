---@mod ai-review.nudge Debounced nudge-message builder for the Claude terminal.

local M = {}

--- Build a debounced nudger. `request()` arms a single trailing timer; further requests
--- while armed coalesce. On fire: if there are drafts, send the message (send() itself
--- no-ops when Claude isn't reachable).
---@param opts { delay_ms: integer, msg: string, count_drafts: fun():integer, send: fun(msg: string), schedule: fun(ms: integer, fn: fun()) }
---@return { request: fun() }
function M.make(opts)
  local armed = false
  local function fire()
    armed = false
    if opts.count_drafts() > 0 then
      opts.send(opts.msg)
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

--- The message asking Claude to re-anchor the batch before it's posted. The contract is
--- deliberately narrow — anchors only — because the sheet the human just edited is the
--- source of truth for everything else.
---@param batch_path string
---@return string
function M.reanchor_request_msg(batch_path)
  return (
    "prreview: I've finished editing the review sheet. Please re-anchor the batch at %s: "
    .. "for every entry confirm `path`/`line`/`start_line`/`side` still identify the intended "
    .. "code on the PR head and fix them where they drifted. Do NOT change any `body`, the "
    .. "`verdict`, or the set of ids. Write the batch back and tell me it's ready."
  ):format(batch_path)
end

return M
