---
load: contract
---
# Review once, test once — the opt-in release economies

**Goal:** a repository that already reviews and tests every change fully on its way into
`releaseSource` can stop paying for the same review and the same test again on the way to
`productionBranch`. Every key here is OPTIONAL; with none set, `release` behaves exactly as its
SKILL.md says (every engine on the production PR, every `releaseOnly` check unconditionally).

## `release.productionReview` — review once

```json
"productionReview": {
  "reviewIdenticalTree": false,
  "highRiskPaths": ["src/auth/**", "migrations/**"],
  "highRiskEngine": "codex"
}
```

With `reviewIdenticalTree: false`, step 2 compares the release head's tree with the tree a full
review last settled at a pull request into `releaseSource` (the support-train pull request, an
epic release pull request): `git rev-parse <sha>^{tree}`. A hotfix merged into the release branch
under `release-branch.md` §4 was reviewed on its own pull request and does not count as a
difference.

- **Identical** → no merge-gate review on the production pull request. Instead, run ONE pass of
  `highRiskEngine` (the configured local CLI when it names that engine) scoped to the files the
  release changes under `highRiskPaths`; none changed → no pass at all, said so. Its findings take
  the usual route (verify, fix on the release branch under the fix-exclusion check, reply).
- **Different** (a fix landed on the release branch) → a contextual review of exactly that
  difference, carrying the settled ledger — never a fresh full review.
- Absent, or `reviewIdenticalTree` not `false` → step 2 runs as written.

Say which path the release took in the step-4 recap, with the two tree hashes.

## `release.lightRelease` — the light release

```json
"lightRelease": { "disqualifyingPaths": ["migrations/**", "infra/**"] }
```

A release whose diff against `productionBranch` touches none of `disqualifyingPaths` is LIGHT:
the support-train (or epic) pull request into `releaseSource` gets ONE review round — another
only for a verified P1 or serious P2 — and the production pull request follows
`productionReview` as above. Any match → the full release. Never skipped by a light release:
the required CI, the release clearance, the owner's go-ahead and deploy approval, the
post-deploy check, documentation and any owed customer reply. Decide it in step 0, from the
delta, and report it with the paths checked.

## `pathGlobs` on a `releaseOnly` check

A `releaseOnly` `preShipChecks` entry with EMPTY `pathGlobs` runs at every release, as before. A
NON-EMPTY `pathGlobs` runs it only when the release diff (`origin/<productionBranch>...<sourceHead>`)
touches a matching path; otherwise step 2b reports it skipped with that reason (never silently).
A diff that cannot be computed runs the check.

## A train that carries reviewed release units

With `epicIntegrationBranches.releaseTarget` set to the support train's branch, a finished epic
reaches the train through its own release pull request — its full review. The train pull request
(`release-branch.md` §1 step 4) then reviews only what no pull request has reviewed: the commits
the fast one-offs brought, NOT the commits a merged, reviewed release pull request brought (list
those in the scope manifest as already reviewed, with their pull request numbers). CI still runs
once over the whole train.

## Cited by

- `skills/release/SKILL.md` — steps 0, 2 and 2b.
- `skills/release/references/release-branch.md` — §1 step 4.
