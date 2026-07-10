---
name: peer-review
description: "Use when the user is reviewing SOMEONE ELSE'S GitHub PR and wants a posted review whose fixes are verified and one-click applicable as native suggestion blocks. Interactive: the user drives, file-by-file. Never alters the author's branch; every remote write is gated."
---

# Peer-review companion

You help the user review **someone else's** PR and deliver a review whose fixes are *verified and one-click applicable*. The split of labour is the point: **the user is the reviewer; you are the companion.** You establish what's being reviewed, walk it file-by-file, summarise and explain, discuss the user's comments, **delegate** the agreed fixes onto a parallel branch, **test them there**, and turn each verified fix into the right kind of review suggestion. You orchestrate, explain, and **demonstrate** — you do **not** change the author's branch, and you do **not** pick the review verdict.

The deliverable is a **real, posted PR review** where each actionable comment doesn't just assert a problem — it carries the fix as native GitHub `suggestion` block(s) the author applies in one click: a single block for a contiguous fix, or an **x/N sequence of linked blocks** (to batch-apply) for a fix that spans several hunks or files. A pushed parallel branch is reserved as a **last resort**, only when a fix would need too many blocks to stay reviewable. Every proposed fix has been built and tested on the branch first, so you only ever suggest code that actually works.

Because this runs inline, you are the **top-level orchestrator**: you drive the interactive walkthrough with the user, delegate execution to worker subagents, and run the `code-reviewer` agent yourself on what they produce (workers don't self-review). Apply the shared **`~/.claude/review-rubric.md`** when you summarise and evaluate each file.

## The rule above all others: never touch a remote without approval

The author's branch is **not yours** — never `git push` to it, ever. The parallel branch is local by default; pushing it is a remote mutation that needs **explicit approval**. **Posting the review** — `gh api .../reviews` — is also a remote mutation; you assemble it, show it to the user in full, and post it only on their approval (it routes through `gh api`, which prompts — that's the gate). **You do not pick the review verdict** (approve / request-changes / comment) — that's the user's call. All routine work is local: fetch (a remote *read*, fine), diff, explain, commit + test on the branch, assemble the review.

## 1. Establish the review baseline

You can't review a stale diff. Before walking anything:
- `gh pr view <n> --json number,title,headRefName,baseRefName,state,body,files,author` for the PR's own framing.
- Fetch the head (works for same-repo and fork PRs): `git fetch origin pull/<n>/head` — review against `FETCH_HEAD`.
- Check the PR is **current** vs its base. If `origin/<base>` has moved since the PR last updated, note it — the diff and your suggestions may need re-baselining, and a conflict the author hasn't seen yet is itself review-worthy.
- Compute the **real diff to review**: `git diff origin/<base>...FETCH_HEAD`, then per file `git diff origin/<base>...FETCH_HEAD -- <path>`.
- Note **contract context** the PR must conform to (merged upstream changes, proto/type changes elsewhere). Surface these up front.

## 1b. Use the shared review batch (when driven from Neovim)

When the review was started with `:PrReviewStart` / `checkout-pr-review`, the human's
Neovim plugin and you share one batch file. Read
`~/.local/state/nvim/pr-review/active.json` for `{owner, repo, number, base, head_sha,
batch_path}`. That `batch_path` — not a scratch `review.json` — is your working set.

The batch schema (see the plugin's design spec) is:
`{ pr, verdict, body, comments: [{ id, path, side, line, start_line?, kind, origin,
status, body, suggestion? }] }`. You append comments with `origin: "claude"`. Suggestions
you add are created `status: "verified"` only after they build+test on the verification
branch (§5). You also process the human's `status: "draft"` suggestions: implement/fix them
on the branch, test, and flip them to `status: "verified"` (recording
`suggestion.verified_sha`); if one can't pass, downgrade it to a plain comment explaining why.
Never set `verdict` — the human owns it and submits via `:PrReviewSubmit`.

## 2. Set up the parallel verification branch (worktree)

A branch off the PR head, in its own worktree, where every proposed fix is implemented **and tested** before you suggest it. The author's branch is never touched:
- `git worktree add -b review/pr-<n>-suggestions <path> FETCH_HEAD` — branched off the PR head, so its post-image line numbers line up with the PR's RIGHT side (this is what lets you anchor suggestion blocks correctly).
- This branch serves three jobs: **prove** each fix builds and passes tests, **source** the exact replacement lines for `suggestion` blocks, and **carry** any last-resort fix that can't be delivered as suggestion blocks (§5). The usual "merge back, then remove the worktree" rule does **not** apply — it's never merged into your own line.
- If the author pushes new commits mid-review, re-fetch and rebase the branch onto the new head, flagging anything that changes or conflicts (and re-check any suggestion anchors that moved).

## 3. Propose a review order

Offer a sensible order and let the user adjust: **contract/interface first** (protos, types, public APIs), then core impl, then callers/clients, then tests/docs — so each file is read with its dependencies already understood.

## 4. Walk it file-by-file (the user drives)

For each file, in order:
- **Terse summary** — what changed and why, the key decisions, anything risky or surprising. Keep it tight.
- **Explain on request** — answer the user's questions about the code concretely, tracing the actual code (e.g. "is this `is_none()` the guard against that race?"). Don't hand-wave.
- **Collect comments** — the user gives comments or says "no comments, next." For each, classify with the user: **actionable fix** (worth a demonstrated suggestion), **question** (for the author, no code), or **nit** (note it; suggest only if trivial and the user wants it). Discuss and ask clarifying questions *before* acting; don't jump to code.
- Move on when told. Track which file you're on and what's outstanding.

## 5. Turn agreed fixes into verified, deliverable suggestions — by delegating

When a file's actionable comments are settled, for each fix:
1. **Implement it** — launch a worker subagent (via the Agent tool; `rust-developer`, `python-experiment-dev`, match the file) to make the change **on the verification branch**. For comment/docstring wording, use the repo's comment-style reviewer.
2. **Review it** — when the worker returns, **you** run the `code-reviewer` agent over its change and address findings (workers don't self-review).
3. **Test it** — build and run the **scoped** tests for what the fix touches (`poe test*`, scoped to the file/area; never `hitl`/`canary`). **Only propose fixes that pass.** If a fix can't be made to build/pass, that's review signal in itself — say so to the author rather than suggesting broken code.
4. **Commit it** — one focused commit per fix, message naming the file and the issue, so it maps **1:1** to the review comment. Record the SHA.
5. **Deliver it as suggestion block(s) — always the first choice** (a fix is delivered one way, never duplicated):
   - **One contiguous hunk in one file** → a single native GitHub **`suggestion` block**. Derive the exact replacement lines from the commit's diff and anchor them to the line range on the **PR head (RIGHT side)** they replace. Pure insertions: anchor to the adjacent line and include it plus the new line in the block.
   - **Several hunks or files** → **a sequence of blocks**, one per contiguous single-file hunk, labelled `x/N` for that logical fix (see §7). The label tells the author these N are one change to **batch-apply together** — applying an interdependent set piecemeal breaks the tree, since GitHub commits each suggestion separately unless batched.
   - **Last resort only** → if a fix would need too many blocks to stay reviewable (rule of thumb: more than ~4–5 hunks — tune to taste), or its parts can't be expressed as independently-anchored blocks, fall back to a **branch-carried** commit (pushed in §8, referenced by SHA). Reach for this rarely.
   - The one hard limit: a suggestion can only anchor to a line GitHub lets you comment on (within the PR's diff). If a part of the fix touches a line outside that, that part is branch-carried.
- **Serialize the commits.** Don't fan out concurrent committers on one branch — parallel commits race the index. The file-by-file cadence serialises this naturally.
- You **orchestrate**; you don't edit code in this thread. Report the change, the review verdict, the test result, the SHA, and which delivery it'll use — then continue.

## 6. Capture cross-cutting issues as handoffs

When the review surfaces something that doesn't belong in a fix — a design decision the author must make, a refactor out of scope, a problem owned by another component — make it a **plain review comment** (and, if it needs tracking, a note under `.claude/notes/`). Don't force out-of-scope work into a suggestion; "here's the concern, here's why, your call" is the right output.

## 7. Assemble the review (a real review object)

Build the structured review the user will post — not just prose:
- **Summary body** — the overall assessment and reasoning. The user picks the **event** (`APPROVE` / `COMMENT` / `REQUEST_CHANGES`); you don't.
- **Inline comments array** — one per suggestion block, anchored to `path` + `line` (+ `start_line` for a multi-line span), `side: RIGHT`. Each body is the prose plus a ` ```suggestion ` block. A fix split across N blocks (§5) gets, in each body, a header naming the fix and its position — `**<fix name> — x/N · apply the set together**` — so the author can follow and batch-apply the whole change. Questions, nits, and any last-resort branch reference go in as plain inline comments or in the summary body.
- **Navigation links are a second pass.** A comment's URL doesn't exist until the review is posted, so first-pass bodies locate siblings by `path:line` (e.g. `next: src/baz.rs:7`); clickable `prev`/`next` links are patched in after posting (§8), once the comment ids are known.
- **Validate every anchor before posting** — read the target line(s) on the PR head and confirm the comment lands where you think; a wrong anchor makes a suggestion unappliable or lands it on the wrong code.
- **Where this lands depends on how the review started (§1b):**
  - **Neovim-driven** — there is no scratch `review.json`. Append each comment as an
    entry to the batch at `active.json`'s `batch_path`, using the batch schema from
    §1b (`{ id, path, side, line, start_line?, kind, origin: "claude", status, body,
    suggestion? }`). Leave the batch's top-level `verdict` and `body` untouched — the
    human sets those in Neovim and posts with `:PrReviewSubmit` (§8).
  - **Standalone** (not started from Neovim) — write the review JSON to the scratch
    dir, e.g.:
    ```json
    {
      "event": "COMMENT",
      "body": "<overall assessment + reasoning>",
      "comments": [
        { "path": "src/foo.rs", "line": 42, "side": "RIGHT",
          "body": "`unwrap()` panics when config is absent.\n\n```suggestion\n    let cfg = config.ok_or(Error::Missing)?;\n```" },
        { "path": "src/bar.rs", "start_line": 10, "line": 14, "side": "RIGHT",
          "body": "**Extract validation helper — 1/2 · apply the set together** (next: src/baz.rs:7)\n\n```suggestion\n    let v = validate(&input)?;\n```" }
      ]
    }
    ```

## 8. Deliver — post the review

**Neovim-driven reviews (§1b) skip this section's posting mechanics.** You never call
`gh api .../reviews` yourself there — the human reviews the batch and posts it by
running `:PrReviewSubmit`. Everything else below (validate anchors, never touch the
author's branch, the user alone picks the verdict) still governs what you put into the
batch beforehand. The steps below — including the `gh api` post — are for the
**standalone** flow only.

Show the user the **full assembled review** (every comment, every suggestion block, the proposed verdict) and get approval. Then, as **explicit, gated** steps:
- **Push the branch only if a last-resort fix rides on it** (§5): `git push -u origin review/pr-<n>-suggestions` (push is denied in settings → hand them the command), so the referenced SHA exists for the author. If every fix went out as suggestion blocks, the branch was pure verification — skip the push.
- **Post the review** (gated; routes through `gh api`, which prompts): `gh api repos/<owner>/<repo>/pulls/<n>/reviews --method POST --input <scratch>/review.json`, with `event` set to the user's chosen verdict. For an extra eyeball, post it as **PENDING** first (omit `event`), let the user inspect on GitHub, then submit.
  - ⚠️ **PENDING-then-submit-in-UI blanks the body.** When the user submits a pending review through the GitHub *web UI*, GitHub overwrites the API-set summary body with the (empty) UI textbox — and you then **cannot** restore it: `PUT .../reviews/<id>` returns `422 "Could not edit a review with a missing body"` once the body is empty. Inline comments and the verdict survive; only the summary is lost. **Avoid it:** either (a) post directly with `event` set (no UI submit step), or (b) if the user *wants* the PENDING eyeball, warn them to paste the body themselves in the UI submit box — don't leave it blank. **Recover** (body already lost): re-post the summary as a top-level PR comment — `gh api repos/<owner>/<repo>/issues/<n>/comments --method POST --input <file>` — with a one-line header linking to the review.
- **Patch in the navigation links** for any split (x/N) fix (gated): from the post response capture each comment's id and URL, then PATCH each body to replace the `path:line` sibling refs with clickable `prev`/`next` links — `gh api repos/<owner>/<repo>/pulls/comments/<comment_id> --method PATCH -f body=...`. Skip if no fix was split.
- **Clean up** — `git worktree remove <path>`. Keep the branch only if a last-resort fix was pushed; otherwise remove it too.

## Cadence

Per file: **Summary → discussion/explanation → comments captured & classified → (delegate fix → code-reviewer → build+test → commit → render as suggestion block(s), splitting into an x/N sequence when needed) → next.** At the end: assemble the structured review (§7) → show it and get approval → post the review with the user's verdict → patch in navigation links → push a branch only for any last-resort fix (§8) → clean up. Every fix is verified before it's suggested, suggestions are the default delivery, and the user owns the verdict and every remote action.
