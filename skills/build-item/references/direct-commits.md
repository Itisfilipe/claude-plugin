---
load: contract
---
# Direct commits — every leaf lands on the base branch, with no pull request

**Goal:** a repository that works trunk-based — no feature branches, no pull requests — runs the
same loop. Each leaf item is built, reviewed and gated in a checkout of `baseBranch`, then pushed
straight to it.

`directCommits.enabled` absent or `false` → none of this runs. `true` → it replaces the branch,
review, merge and release-unit paths of `build-item` for EVERY leaf, plan story and one-off alike:
`integrationBranch`, `epicIntegrationBranches` and `supportTrain` are ignored, and step 0 names
each one that is set ("ignored under direct commits: …"). `routing.py target` answers
`kind: direct`; an explicit branch other than `baseBranch` is refused. Where the body routes a leaf
elsewhere — the one-off mode's support train and 4b, step 4's path choice, the draft-PR floor —
this file wins.

**Every leaf is a merge boundary.** Nothing reviews the code after it lands, so the full review and
the full local gate move to the leaf, under every profile. Fast mode's deferral (4a) never applies.

## Step 0 — the checkout

- The checkout is on `baseBranch`, clean, and even with `origin/<baseBranch>` after
  `git fetch --prune origin` and `git pull --ff-only`. Dirty, holding unpushed commits, or on
  another branch → name what you found and STOP; never stash, reset or switch on the user's behalf.
- Record `<rangeBase>` = `HEAD`, where the item's commits begin. Every rebase in steps 4 and 5
  moves it to the `origin/<baseBranch>` tip rebased onto, so the range never counts another
  author's commits.
- **`baseBranch` is `release.productionBranch`** (routing answers `production: true`) → every push
  in step 5 is a production merge, and production merges are the owner's. Say so now.

## Step 2 — no branch

Skip `branch-feature`. Say "direct commits: building on `<baseBranch>`".

## Step 3 — build

Invoke `ultracode-build` with `review-moment: pr-boundary`: the full boundary review runs next, in
step 4. It commits locally per coherent step. **Nothing is pushed before step 5.**

## Step 4 — review and gate (4c)

- **Refresh first.** `git fetch origin`; when `origin/<baseBranch>` moved, `git rebase
  origin/<baseBranch>` — it rewrites only this item's unpushed commits, never shared history — and
  moves `<rangeBase>` to that tip. A conflict that is not mechanical → STOP. Then the review range
  is `origin/<baseBranch>..HEAD`.
- **Invoke `review` in DIRECT mode** with the profile, the story review ledger, the verification
  receipt and the dismissed-findings list. The mode is defined in the next section.
- **The gate is the full local suite, whatever the profile**: every `verify.typecheck` command,
  `verify.test` (never only touched suites — no CI runs before the code lands), `verify.lint`
  when the diff touches what it covers, and every `preShipChecks` entry. A firing
  `verify.skipDuringStoryBuilds` suite runs here too. Receipts are reused only per
  `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/verification-receipts.md`. Red is a STOP.

## The DIRECT review mode — `review`'s contract

`review` reads this section when `build-item` names DIRECT mode. There is no pull request: the
base is `origin/<baseBranch>`, the head is the local `HEAD`, and every PR-side step is skipped.

- **Run steps 1, 3, 4, 5 and 6.5.** Skip 0 (no PR to resolve), 2 (no cloud wait), 6 (no threads),
  7 (no ready-flip; CI runs after the push) and 8 (the caller reports).
- **Roster**: Claude adversarial at the profile's merge-boundary breadth, the local CLI when on the
  roster (`<base>` = `origin/<baseBranch>`), and every matched `review.mandatoryLenses` finder.
  Cloud reviewers in `review.automatedReviewers` are SCOPED OUT — announced as "needs a pull
  request", never requested, not degradation.
- **Safety continuation, `fixFloor` and the cycle target hold unchanged.**
- **Fixes commit, never push.** Commit per `commitConventions.reviewFixFormat`; the caller lands
  them. A REFUTED or below-floor dismissal has nowhere to be posted: its one-line rationale returns
  to the caller, who records it in step 6.
- **6.5 MUST write**, and its commit goes onto the local `HEAD` even though `baseBranch` is in
  `protectedBranches`: committing on the base branch is what this mode is. The protection that
  still holds is the push rule — never rebase what is on origin, never force-push.
- **Return** the triaged findings, dismissals with rationales, the untracked-deferral list and the
  lessons tally.

## Step 5 — land it (5c)

- Clean tree, every fix committed. `git fetch origin`; when `origin/<baseBranch>` moved, rebase
  again as in step 4. Compare patches: CHANGED returns to step 4 with the cumulative ledger, never
  a fresh budget; tree-identical keeps the receipt, else the affected checks and the gate rerun.
- **`production: true` → ask before pushing**, every item: show the commit range, the checks that
  ran and what CI will run, and push only on the owner's explicit yes. No yes → stop with the
  commits local and report; never push to wait for an answer.
- `git push origin HEAD:<baseBranch>`. **Never `--force` or `--force-with-lease`.** Rejected as
  non-fast-forward → fetch and repeat this step. Rejected by branch protection → STOP: the
  repository requires pull requests on `baseBranch`, so direct commits cannot work there; say so
  and point at `/devstride:setup`.
- **Observe CI on the pushed SHA** with `review` step 7's background poll, keyed to the commit
  (`gh run list --commit <sha>`) instead of a pull request. No workflow runs on a push → say so.
  Red after landing → STOP and report it with the failing job: the code is already on
  `baseBranch`, so whether to revert or fix forward is the owner's decision. Never revert,
  reset or force-push on your own.

## Step 6 — completion

- `update_item` → **Done**. `startDate` = step 1, `dueDate` = the push.
- **The item points at its code**: `add_comment` with the commit range `<rangeBase>..<pushed SHA>`
  on `<baseBranch>`, the CI result, and each dismissed finding with its rationale. There is no
  pull request to link; never invent one.
- The as-built reconciliation cites that range.

## Step 7 — sync

The checkout is already on `baseBranch`; `git pull --ff-only` and assert a clean tree. Handoff
memory records "`<baseBranch>` — direct commits" instead of an integration branch.

## Step 8 — release unit at zero

There is no integration branch and no release pull request: every leaf is already on
`baseBranch`. When step 7 counts zero remaining leaves under the release unit:

- **Close out**: `add_comment` on the release-unit item listing each leaf and its commit range, and
  move it to Done when lanes are tracked there. `autoRelease` does not apply; say so.
- **Docs stage** exactly as step 8 says, when `docs.updateOnEpicRelease` is true, with the commit
  ranges in place of the release pull request and `live: false`.
- Surface, never perform, the production promotion (`/devstride:release`).

## Why

Many repositories land work straight on one branch: a small team, a solo maintainer, a trunk-based
shop that guards unfinished work with flags instead of branches. The loop's floors are about the
code that reaches users — reviewed, gated, safe to deploy — not about pull requests, which are one
place to hold that gate. With no later boundary to defer to, the gate cannot be split across a
fast story and a release PR, so each leaf carries the whole of it, and CI becomes a check after
landing whose failure the owner decides on.

## Cited by

- `skills/build-item/SKILL.md` — the working-base precedence ("Read … at step 0 when
  `directCommits.enabled` is true").
- `skills/review/SKILL.md` — the DIRECT mode ("Read … §The DIRECT review mode").
- `skills/setup/references/config-defaults.md` — §Direct commits, the contract behind the question.
