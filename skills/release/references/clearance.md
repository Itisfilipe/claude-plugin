---
load: contract
---
# Release clearance — one cleared release at a time, across every machine and account

**Goal:** when releases are cut from more than one machine, or by more than one person or agent,
only one is in flight. A session asks for CLEARANCE before it touches anything a release touches
(the support train, the cut, the release pull request), keeps a heartbeat while it works, and hands
clearance back as the last act of its close-out. A second session is told who holds it and waits;
because a release ships everything on the release source at the cut, the next cleared release
carries that session's work, so there is never a reason for two.

Everything here is opt-in through `release.clearance`. **Absent or `null` → nothing is claimed,
nothing is shown, and `release` runs exactly as before.** Nothing ever blocks a hotfix.

## The config block

```json
{ "release": { "clearance": { "provider": "github" } },
  "releaseTower": { "overrideLabel": "release-tower-override", "hotfixPattern": "*/hotfix/**" } }
```

- **`{ "provider": "github" }`** — the built-in provider below. Optional: `"ref"`
  (default `refs/clearance/release`), `"staleMinutes"` (default `20`), `"waitMinutes"` (default
  `180`, how long `claim --wait` polls).
- **`{ "commands": { "claim": "…", "status": "…", "heartbeat": "…", "release": "…", "adopt": "…" } }`**
  — a provider the repository supplies (a shell command per verb, run from the repository root;
  the verb's own arguments, `--wait`, `--short`, `<phase> --branch b --pr n`, `--force`, `--yes`,
  are appended). It honours the same contract. A block with BOTH keys is a config error (`doctor`
  and `setup validate` report it); a `provider` other than `github` is one too.
- **`releaseTower`** — read by the `release-tower` check and by the built-in provider's `status`:
  `overrideLabel` passes a pull request an owner approved by hand; `hotfixPattern` names hotfix
  heads (the branch-patterns rule, `${CLAUDE_PLUGIN_ROOT}/skills/release/references/branch-patterns.md`).
  Absent → those defaults.

## The provider contract — five commands, four exit codes

Every provider prints its verdict as the FIRST line of stdout and exits as follows. The skill
reads the exit code and quotes the line; it never parses further.

| Command | Exit 0 | Other exits |
| --- | --- | --- |
| `claim [--wait] [--purpose <text>]` | `CLEARED <holder> <takenAt>` | `2` BUSY: `BUSY held by <user> on <machine> since <takenAt>, phase <phase>, heartbeat <age> — <branch> #<pr>` · `3` STALE with a pull request still open, or merged but never closed out: `STALE … pull request #<n> still open — adopt or wait` · `1` error, a killed call included (never proceed uncleared) |
| `status [--short] [--json]` | the clearance line (or `CLEAR`), then `On final: #<n> <head>` for the oldest open release pull request into the production branch, `Waiting: #<n> <head>` for each later one, `Hotfix landed: #<n> <head> <mergedAt>` for each hotfix merged into production since `takenAt` | `1` the ref could not be read: `UNKNOWN (gh: …)` — never shown as clear |
| `heartbeat <phase> [--branch <b>] [--pr <n>]` | `HEARTBEAT <phase> <at>` | `4` NOT HOLDER: another session owns the clearance now — STOP |
| `release [--force]` | `RELEASED <branch>`, or `CLEAR (nothing to release)` | `4` NOT HOLDER (`--force` releases anyway, prints the record first, and is the owner's command) |
| `adopt --yes` | `ADOPTED <branch> #<pr>` then `Resume: branch …, pull request …, phase …` | `2` not stale (nothing to adopt) · `4` nothing held |

- **`claim --wait`** polls every 60 s up to `waitMinutes`, printing the BUSY line each poll on
  stderr, and exits 0 the moment it wins. A STALE result ends the wait with exit 3: the skill asks
  the owner. **It runs in the background with a long timeout**, as a pre-ship check does: a
  foreground call a tool kills at its own timeout yields no verdict, and no verdict is `1`.
  Progress lines (polls, a generated token, a takeover note) go to stderr; stdout's first line is
  the verdict.
- **`status --short`** prints one token line for the status line — `release/26-10-17 · alice · ci`,
  with `· STALE` appended past the stale threshold — or nothing when clear. `--json` prints
  `{ state: clear|held|unknown, stale, record, onFinal, waiting, hotfixesLanded, staleMinutes }`.
- **Stale** = heartbeat older than `staleMinutes`. A stale clearance that never opened a pull
  request, or whose pull request was CLOSED unmerged, is taken over by the next `claim` on its own
  (one compare-and-swap on the stale object, so two takers cannot both win). A stale one whose
  pull request is OPEN, or MERGED but never closed out (its session died between the merge and the
  end of step 6, so production may not be synced into the source), is never taken silently: it is
  ADOPTED (`adopt --yes`, after the owner's yes) and the release resumes on the skill's existing
  adopted-release-branch path — at close-out, for a merged one. A pull-request state that cannot be
  read is an error (`1`), never a `3`.
- **Liveness is the keeper's job.** `claim` and `adopt` start a detached keeper that re-stamps the
  heartbeat every `staleMinutes/3` for as long as the agent process that claimed is alive and the
  local record still names this holder; `release` stops it. So a release whose review or deploy
  wait runs for an hour stays fresh, and a crashed or killed agent goes stale on schedule. The
  skill's own `heartbeat <phase>` calls record progress and prove ownership; they do not keep the
  clearance alive. When no owning process can be found the provider says so, and the skill
  heartbeats at least every `staleMinutes` itself.
- **Holder identity** is the same rule as a pool lease, so one identity means one thing everywhere:
  `DEVSTRIDE_LEASE_TOKEN`; else `codex:$CODEX_THREAD_ID` and/or `claude:$CLAUDE_CODE_SESSION_ID`
  joined with `+`; else `token:<random>`, printed once (stderr) for a plain terminal to export.
  `user` is `gh api user`'s login; `machine` is the hostname. A claim or adoption by the session
  that already holds it renews the heartbeat.
- **The local record.** On `claim` and `adopt` the provider writes
  `${XDG_CACHE_HOME:-$HOME/.cache}/devstride/release-clearance/<owner>__<repo>.json` (one file
  per repository, so two repositories claimed under one account never overwrite each other's) —
  `{ repo, holder, user, machine, branch, pr, takenAt, keeperPid }`, mode 0600 — updates
  `branch`/`pr` on each heartbeat, and removes it on `release` — and on any `NOT HOLDER`, so a
  session that lost the clearance is not still vouched for. A hook answers "does THIS session hold clearance for THIS repository?" from
  that file alone, with no network; it is an observation, refreshed by every provider call, not
  proof against the ref itself. The path and shape are part of this contract.
- **Hotfix facts are DERIVED, never recorded.** `status` lists hotfix landings from GitHub's merged
  pull requests; the record holds only clearance state (holder, user, machine, purpose, phase,
  branch, pr, takenAt, heartbeatAt).

## The built-in provider: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-github.sh`

Needs a checkout whose `origin` can push (any account that pushes a release branch can), `gh`
signed in (pull-request facts, the user name) and python3. Reads the keys above from the nearest
`.claude/ds-config.json`; a config file that exists but cannot be read or parsed is an error,
never a fallback to the defaults (that would claim a different ref than the one configured).

The clearance is the custom git ref `refs/clearance/release`, pointing at an annotated tag object
whose message is the record as JSON. **Every move of the ref is a compare-and-swap**: `git push
--force-with-lease=<ref>:<expected>`, where a claim expects the ref to be absent and a heartbeat,
an adoption or a stale takeover expects exactly the object it read. The server rejects every
caller whose expectation is stale, so there is no look-then-act — not on the claim, not on the
stale path, not on release; a holder's own command whose push the keeper's stamp beat retries on
the stamped object (only a record naming someone else is NOT HOLDER). The push runs no hook of the
repository (`--no-verify`), and the tag points at a blob of its own, so a checkout behind
production still claims. A ref the remote cannot be asked about (not signed in, no network) is
UNKNOWN, never clear; a record that is not valid JSON with a holder and a time is UNREADABLE and
is never taken over except by the owner's `release --force`. The ref is neither a branch nor a tag,
so it triggers no workflow, appears in no branch or tag list, and no ruleset pattern matches it.
**One caveat:** a repository ruleset that restricts ALL ref creation blocks it — the push is then
refused with the server's own words, and `doctor` reports it. A session that bypasses the
commands with raw `git push` can move the ref: the commands are the speed bump, the
`release-tower` check is the floor.

## Where the release skill calls it

Only when `release.clearance` is set. **0a** `claim --wait --purpose release` before anything
else, in the background with a long timeout: `0` continue (say who was waiting when stderr said
so); `3` ask the owner once — adopt `<branch>` / `#<n>`, or keep waiting — and on adopt run
`adopt --yes` and enter the adopted path (0b skips the train, 0c skips the cut, step 2 reviews the
open pull request; a merged one resumes at step 5a's confirmation and close-out); `1` STOP as a
release blocker. **`heartbeat <phase>` at the START of each phase**, before its first mutation —
`train` before 0b merges anything, `cut --branch <b>` before 0c pushes, `pr --pr <n>` after step 1
opens it, `review` before 2, `pre-ship` before 2b, `merging` on the owner's yes BEFORE the merge,
`deploy` before 5a, `docs` before 5b, `close-out` before 6 — so a lost clearance (exit 4) stops
the release before it touches anything, never after. **Step 4** appends `status` to the
go-ahead: a `Hotfix landed` line goes to `release-branch.md` §4 first; a `Waiting` line names who
is next; and on the yes, the release pull request must be the one `On final` — otherwise STOP
(the check on GitHub is a snapshot; this is the ordering at the moment of merge). **Close-out:**
`release` is the LAST act, after the sync pull request merged and the release branch is deleted;
a failed post-deploy check or an unfinished close-out KEEPS clearance for the retry, and the recap
says so. **`branch-hotfix` and the hotfix path never claim**, and a hotfix pull request into the
production branch merges with no clearance step.

## The floor: the `release-tower` check

`/devstride:setup ci` offers, when `release.clearance` is set, the template
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-templates/release-tower.yaml` with its checker
`release-tower-check.mjs` (written to `.github/workflows/release-tower.yaml` and
`.github/scripts/release-tower-check.mjs`; GitHub only, Node 22, no dependencies). It runs
`pull_request_target` on the production branch; GitHub runs that event, and checks out its files,
from the repository's DEFAULT branch (since 2025-12-08), so the workflow, the checker and the
config are the default branch's, a pull request cannot edit its own gate (the head is never
checked out), and the check runs from the moment the files reach the default branch. It passes a hotfix head, the OLDEST open release pull request, and a
pull request carrying `releaseTower.overrideLabel`; a later release pull request is held with
`<head> (#n) is on final; this release waits`; any other head gets the retarget line. Whenever a
release pull request opens, reopens, closes or is retargeted onto production, the newest run of
every OTHER open release pull request (matched by the pull-request number the Actions API records
on a run) is re-run, so the queue re-settles without a push. A
release pull request retargeted AWAY from production fires no event there: run
`gh workflow run release-tower.yaml` once, or wait for the next event — and the release skill's
step 4 checks `On final` at the moment of merge regardless. **Making it REQUIRED on the production
branch's ruleset is the owner's change**, after it has posted green on one real release pull
request — then even an administrator cannot land a second release beside the first.

## Cited by

- `skills/release/SKILL.md` — the clearance floor, steps 0a, 4 and 6.
- `skills/setup/SKILL.md` and `references/ci-cost-patterns.md` §E — the `setup ci` template.
- `skills/doctor/SKILL.md` — the config audit of `release.clearance` and `releaseTower`.
- `skills/setup/references/statusline-segments.md` — the `release` segment.
- `skills/branch-hotfix/SKILL.md` — a hotfix never claims.
