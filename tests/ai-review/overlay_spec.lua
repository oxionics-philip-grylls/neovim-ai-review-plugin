local overlay = require("ai-review.overlay")

describe("ai-review.overlay.decorate", function()
  it("marks a draft with DiagnosticWarn + draft tag", function()
    local hl, tag = overlay.decorate({ status = "draft", kind = "suggestion" })
    assert.are.equal("DiagnosticWarn", hl)
    assert.are.equal(" draft", tag)
  end)
  it("marks a verified suggestion with DiagnosticOk + check", function()
    local hl, tag = overlay.decorate({ status = "verified", kind = "suggestion" })
    assert.are.equal("DiagnosticOk", hl)
    assert.are.equal(" ✓", tag)
  end)
  it("marks a plain comment with Comment + no tag", function()
    local hl, tag = overlay.decorate({ status = "verified", kind = "comment" })
    assert.are.equal("Comment", hl)
    assert.are.equal("", tag)
  end)
end)

describe("ai-review.overlay.render", function()
  it("does not clear pre-existing extmarks when no diffview view is active", function()
    local ns = vim.api.nvim_create_namespace("pip_prreview")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})

    -- diffview isn't on this unit test's rtp; stub the module render() lazily requires.
    local saved_diffview_lib = package.loaded["diffview.lib"]
    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return nil
      end,
    }

    overlay.render({ comments = {} })

    package.loaded["diffview.lib"] = saved_diffview_lib

    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.are.equal(1, #marks)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
