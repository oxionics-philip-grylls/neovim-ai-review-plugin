# neovim-ai-review-plugin

An in-Neovim GitHub PR-review tool, paired with a Claude Code skill so a human
and an AI reviewer can work the same PR together.

- `:PrReviewStart <url>` opens a [diffview.nvim](https://github.com/sindrets/diffview.nvim)
  split for the PR and starts a local JSON **batch** — the shared review draft.
- `:PrComment` / `:PrSuggest` add line comments and suggestion blocks to the
  batch as you read the diff.
- `:PrReviewSubmit` posts the batch as a real GitHub review via `gh api`.
- The paired Claude Code skill (`skills/peer-review`) reads and writes the
  *same* batch file: it verifies your draft suggestions (builds + tests them
  on a scratch branch) and can add its own, without ever touching the PR
  author's branch directly.
- `bin/checkout-pr-review` is a tmux launcher that opens both halves — Neovim
  and a `claude` pane running `/peer-review` — against the same PR in one
  session.

The point of the batch model: comments and suggestions are just data
(`~/.local/state/nvim/pr-review/<owner>__<repo>__pr<n>.json`) until you
explicitly submit. Either side can add to it, nothing goes to GitHub until
`:PrReviewSubmit`, and only entries marked `status: "verified"` are included.

## Install

Requires [diffview.nvim](https://github.com/sindrets/diffview.nvim) and the
[`gh` CLI](https://cli.github.com/) authenticated against your GitHub account.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "oxionics-philip-grylls/neovim-ai-review-plugin",
  dependencies = { "sindrets/diffview.nvim" },
  cmd = { "PrReviewStart", "PrComment", "PrSuggest", "PrReviewRefresh", "PrReviewSubmit" },
  keys = {
    { "<leader>rc", "<cmd>PrComment<cr>", mode = { "n", "v" }, desc = "PR: comment" },
    { "<leader>rs", "<cmd>PrSuggest<cr>", mode = "v", desc = "PR: suggest" },
    { "<leader>rr", "<cmd>PrReviewRefresh<cr>", desc = "PR: refresh overlay" },
    { "<leader>rS", "<cmd>PrReviewSubmit<cr>", desc = "PR: submit review" },
  },
  config = function()
    require("ai-review").setup({})
  end,
}
```

A copy of this spec also lives at `lua/ai-review/example-spec.lua` for
reference.

## Commands

| Command | Mode | Does |
|---|---|---|
| `:PrReviewStart <url>` | | Fetches the PR, opens the diffview split, creates/loads the batch |
| `:PrComment` | normal/visual | Adds a line (or range) comment to the batch |
| `:PrSuggest` | visual | Opens a scratch buffer to edit the selection; `:w` stages a draft suggestion |
| `:PrReviewRefresh` | | Re-renders the batch's virtual-text overlay on the diff |
| `:PrReviewSubmit` | | Picks a verdict, posts all `verified` batch entries as a GitHub review |

Default keymaps (from the lazy spec above): `<leader>rc` comment,
`<leader>rs` suggest (visual), `<leader>rr` refresh, `<leader>rS` submit.

## The `checkout-pr-review` launcher

`bin/checkout-pr-review <pr-url>` opens a tmux session named `ai-rev-pr<n>`
with Neovim (running `:PrReviewStart <url>`) on top and a `claude` pane
running `/peer-review <url>` below — one command to pair up a human+AI
review of the same PR. Put `bin/` on your `PATH`. Run it from inside a clone
of the PR's repo; re-running it for the same PR number attaches to the
existing session instead of creating a new one.

## Installing the paired Claude skill

Copy `skills/peer-review/` into `~/.claude/skills/peer-review/` so `claude`
picks it up as the `/peer-review` slash command. That skill is what reads and
verifies the batch file that `checkout-pr-review` seeds it with.

## Batch / state location

Everything lives under `~/.local/state/nvim/pr-review/`:

- `active.json` — the currently-open review (owner/repo/PR number/batch path).
- `<owner>__<repo>__pr<n>.json` — the batch itself: verdict, overall body, and
  the list of comments/suggestions with `status: "draft"` or `"verified"` and
  `origin: "human"` or `"claude"`.

## Status

Early — piece 1 of 3 (launch + suggestions + submit work; branch-editing
suggestions and the AI verification cycle are in progress).
