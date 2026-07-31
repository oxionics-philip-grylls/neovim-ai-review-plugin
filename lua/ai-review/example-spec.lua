-- Example lazy.nvim spec for a user's own config. Not required by the plugin
-- itself — copy this into your `lua/plugins/` (or inline it in your lazy
-- setup call) and adjust the keymaps to taste.
return {
  "oxionics-philip-grylls/neovim-ai-review-plugin",
  dependencies = { "sindrets/diffview.nvim" },
  cmd = {
    "PrReviewStart",
    "PrComment",
    "PrSuggest",
    "PrReviewRefresh",
    "PrReviewSubmit",
    "PrReviewSheet",
    "PrClaude",
  },
  keys = {
    { "<leader>rc", "<cmd>PrComment<cr>", mode = { "n", "v" } },
    { "<leader>rs", "<cmd>PrSuggest<cr>", mode = "v" },
    { "<leader>rr", "<cmd>PrReviewRefresh<cr>" },
    { "<leader>rS", "<cmd>PrReviewSubmit<cr>" },
    { "<leader>rv", "<cmd>PrReviewSheet<cr>" }, -- reopen the review sheet without re-running submit
    { "<leader>rC", "<cmd>PrClaude<cr>" }, -- jump to the Claude tab
  },
  config = function()
    require("ai-review").setup({})
  end,
}
