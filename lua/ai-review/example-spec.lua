-- Example lazy.nvim spec for a user's own config. Not required by the plugin
-- itself — copy this into your `lua/plugins/` (or inline it in your lazy
-- setup call) and adjust the keymaps to taste.
return {
  "oxionics-philip-grylls/neovim-ai-review-plugin",
  dependencies = { "sindrets/diffview.nvim" },
  cmd = { "PrReviewStart", "PrComment", "PrSuggest", "PrReviewRefresh", "PrReviewSubmit" },
  keys = {
    { "<leader>rc", "<cmd>PrComment<cr>", mode = { "n", "v" } },
    { "<leader>rs", "<cmd>PrSuggest<cr>", mode = "v" },
    { "<leader>rr", "<cmd>PrReviewRefresh<cr>" },
    { "<leader>rS", "<cmd>PrReviewSubmit<cr>" },
  },
  config = function()
    require("ai-review").setup({})
  end,
}
