# neovim-ai-review-plugin

An in-Neovim GitHub PR-review tool, paired with a Claude Code skill so a human
and an AI reviewer can work the same PR together.

- `:PrReviewStart <url>` opens a [diffview.nvim](https://github.com/sindrets/diffview.nvim)
  split for the PR and starts a local JSON **batch** — the shared review draft.
- `:PrComment` / `:PrSuggest` add line comments and suggestion blocks to the
  batch as you read the diff.
- `:PrReviewSubmit` opens the **review sheet** — the whole batch as one editable
  document in its own tab, with the branch code beside it — and the post happens
  from in there, never straight to GitHub.
- The paired Claude Code skill (`skills/peer-review`) reads and writes the
  *same* batch file: it verifies your draft suggestions (builds + tests them
  on a scratch branch) and can add its own, without ever touching the PR
  author's branch directly. `:PrReviewStart` runs it for you as an in-Neovim
  terminal (`:PrClaude` jumps to it).
- `bin/checkout-pr-review <pr-url>` is a one-line launcher: it starts Neovim
  straight into `:PrReviewStart`, which brings up both halves.

The point of the batch model: comments and suggestions are just data
(`~/.local/state/nvim/pr-review/<owner>__<repo>__pr<n>.json`) until you
explicitly submit. Either side can add to it, nothing goes to GitHub until you
confirm the post from the review sheet, and only entries marked
`status: "verified"` are included.

## The review sheet

`:PrReviewSubmit` (or `:PrReviewSheet`) opens a tab with the branch file on the
left and the batch rendered as one markdown document on the right. Moving the
cursor in the sheet scrolls the code pane to that comment's anchor.

- Edit any comment's body, its `path:line`, its kind, or the `# verdict:` line
  directly in the document. **Delete a whole `@@@` section to drop that
  comment** — there is no other "drop" gesture; the pre-post confirm names the
  count.
- `:w` folds the sheet back into the batch. It is a merge, not an overwrite:
  anything Claude wrote to the batch while you were editing (a new comment, a
  `draft → verified` flip) survives your save and is reported.
- `<leader>p` posts. It first asks Claude to re-anchor every entry against the
  current PR head, waits for it to write the batch back, re-renders the sheet
  and tells you how many anchors moved — then **stops**. A second `<leader>p`
  brings up the confirm and publishes. Claude is held to the anchors: if the
  re-anchor changed a body, the verdict, or the set of comments, the post is
  refused and the offending ids are named.
- If the PR head moved since you started, `<leader>p` asks first, then rebases
  the review worktree onto the new head before Claude re-anchors, so the posted
  `commit_id` and the anchors agree. A conflicting rebase is aborted and nothing
  is posted.

## Install

Requires [diffview.nvim](https://github.com/sindrets/diffview.nvim) and the
[`gh` CLI](https://cli.github.com/) authenticated against your GitHub account.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
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
| `:PrReviewSheet` | | Opens the review sheet (the batch as one editable document, code beside it) |
| `:PrReviewSubmit` | | Runs the pre-flight warnings, then opens the review sheet — the post happens from there |
| `:PrClaude` | | Jumps to the Claude `/peer-review` terminal tab |
| `:PrReviewClose` | | Ends the review: removes the worktree, closes the sheet, tree and Claude pane |

Default keymaps (from the lazy spec above): `<leader>rc` comment,
`<leader>rs` suggest (visual), `<leader>rr` refresh, `<leader>rS` submit.
Inside the review sheet, `<leader>p` is the two-press post (see above).

## The `checkout-pr-review` launcher

`bin/checkout-pr-review <pr-url>` starts Neovim straight into
`:PrReviewStart <url>`, which opens the diff, the file tree and a Claude
`/peer-review` terminal in its own tab — one command to pair up a human+AI
review of the same PR. Put `bin/` on your `PATH`, and run it from inside a
clone of the PR's repo (`:PrReviewStart` refuses a URL whose owner/repo
doesn't match the local `origin`).

## Installing the paired Claude skill

Copy `skills/peer-review/` into `~/.claude/skills/peer-review/` so `claude`
picks it up as the `/peer-review` slash command. That skill is what reads and
verifies the batch file, and `:PrReviewStart` seeds a session with it. It is
half of the contract — the plugin's re-anchor request and the skill's §5c
trigger on it are a matched pair, so keep the two in step.

## Batch / state location

Everything lives under `~/.local/state/nvim/pr-review/`:

- `active.json` — the currently-open review (owner/repo/PR number, base,
  `head_sha`, batch path, and the shared review worktree the skill re-uses).
- `<owner>__<repo>__pr<n>.json` — the batch itself: verdict, overall body, and
  the list of comments/suggestions with `status: "draft"` or `"verified"` and
  `origin: "human"` or `"claude"`.

## Status

Working end to end: launch, comments, branch-edited suggestions, the AI
verification cycle, and the review sheet with its gated, re-anchored post.
