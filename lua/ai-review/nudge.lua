---@mod ai-review.nudge Debounced nudge-message builder for the Claude terminal.

local M = {}

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

return M
