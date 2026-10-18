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
| `claim [--wait] [--purpose <text>]` | `CLEARED <holder> <takenAt>` | `2` BUSY: `BUSY held by <user> on <machine> since <takenAt>, phase <phase>, heartbeat <age> — <branch> #<pr>` · `3` STALE with its pull request still open: `STALE … pull request #<n> still open — adopt or wait` · `1` error (never proceed uncleared) |
| `status [--short] [--json]` | the clearance line (or `CLEAR`), then `On final: #<n> <head>` for the oldest open release pull request into the production branch, `Waiting: #<n> <head>` for each later one, `Hotfix landed: #<n> <head> <mergedAt>` for each hotfix merged into production since `takenAt` | `1` the ref could not be read: `UNKNOWN (gh: …)` — never shown as clear |
| `heartbeat <phase> [--branch <b>] [--pr <n>]` | `HEARTBEAT <phase> <at>` | `4` NOT HOLDER: another session owns the clearance now — STOP |
| `release [--force]` | `RELEASED <branch>`, or `CLEAR (nothing to release)` | `4` NOT HOLDER (`--force` releases anyway, prints the record first, and is the owner's command) |
| `adopt --yes` | `ADOPTED <branch> #<pr>` then `Resume: branch …, pull request …, phase …` | `2` not stale (nothing to adopt) · `4` nothing held |

- **`claim --wait`** polls every 60 s up to `waitMinutes`, printing the BUSY line each poll, and
  exits 0 the moment it wins. A STALE result ends the wait with exit 3: the skill asks the owner.
- **`status --short`** prints one token line for the status line — `release/26-10-17 · alice · ci`,
  with `· STALE` appended past the stale threshold — or nothing when clear. `--json` prints
  `{ state: clear|held|unknown, stale, record, onFinal, waiting, hotfixesLanded, staleMinutes }`.
- **Stale** = heartbeat older than `staleMinutes`. A stale clearance whose pull request is merged or
  closed, or that never opened one, is reclaimed by the next `claim` on its own. A stale one with an
  OPEN pull request is never deleted: it is ADOPTED (`adopt --yes`, after the owner's yes) and the
  release resumes on the skill's existing adopted-release-branch path.
- **Holder identity** is the same rule as a pool lease, so one identity means one thing everywhere:
  `DEVSTRIDE_LEASE_TOKEN`; else `codex:$CODEX_THREAD_ID` and/or `claude:$CLAUDE_CODE_SESSION_ID`
  joined with `+`; else `token:<random>`, printed once for a plain terminal to export. `user` is
  `gh api user`'s login; `machine` is the hostname.
- **The local record.** On `claim` and `adopt` the provider writes
  `${XDG_CACHE_HOME:-$HOME/.cache}/devstride/release-clearance.json` — `{ repo, holder, user,
  machine, branch, pr, takenAt }`, mode 0600 — updates `branch`/`pr` on each heartbeat, and
  removes it on `release`. A hook answers "does THIS session hold clearance for THIS repository?"
  from that file alone, with no network; the path and shape are part of this contract.
- **Hotfix facts are DERIVED, never recorded.** `status` lists hotfix landings from GitHub's merged
  pull requests; the record holds only clearance state (holder, user, machine, purpose, phase,
  branch, pr, takenAt, heartbeatAt).

## The built-in provider: `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-github.sh`

Needs `gh` signed in with contents write on the repository (true for any account that pushes a
release branch) and python3. Reads the keys above from the nearest `.claude/ds-config.json`.

The clearance is the custom git ref `refs/clearance/release`, pointing at an annotated tag object
whose message is the record as JSON. **Creating the ref is the atomic claim**: GitHub answers 422
"Reference already exists" to every claimant but one, so there is no look-then-act. `heartbeat` and
`adopt` write a new tag object and move the ref; `release` deletes it; a 404 on the ref is CLEAR.
The ref is neither a branch nor a tag, so it triggers no workflow, appears in no branch or tag
list, and no ruleset pattern matches it. **One caveat:** a repository ruleset that restricts ALL
ref creation blocks it — a claim then fails with HTTP 403 and names this finding; `doctor` reports
it. The tag object a lost race leaves behind is unreferenced garbage GitHub collects. A session
that bypasses the commands with raw `gh api` can move the ref: the commands are the speed bump,
the `release-tower` check is the floor.

## Where the release skill calls it

Only when `release.clearance` is set. **0a** `claim --wait --purpose release` before anything
else: `0` continue (say who was waiting when the line said so); `3` ask the owner once — adopt
`<branch>` / `#<n>`, or keep waiting — and on adopt run `adopt --yes` and enter the adopted path
(0b skips the train, 0c skips the cut, step 2 reviews the open pull request); `1` STOP as a
release blocker. **`heartbeat <phase>`** after 0b (`train`), 0c (`cut --branch <b>`), 1
(`pr --pr <n>`), 2 (`review`), 2b (`pre-ship`), 4 (`merging`), 5a (`deploy`), 5b (`docs`) and 6
(`close-out`); exit 4 anywhere → STOP, another session owns this release. **Step 4** appends
`status` to the go-ahead: a `Hotfix landed` line goes to `release-branch.md` §4 first; a `Waiting`
line names who is next. **Close-out:** `release` is the LAST act, after the sync pull request
merged and the release branch is deleted; a failed post-deploy check or an unfinished close-out
KEEPS clearance for the retry, and the recap says so. **`branch-hotfix` and the hotfix path never
claim**, and a hotfix pull request into the production branch merges with no clearance step.

## The floor: the `release-tower` check

`/devstride:setup ci` offers, when `release.clearance` is set, the template
`${CLAUDE_PLUGIN_ROOT}/skills/setup/references/ci-templates/release-tower.yaml` with its checker
`release-tower-check.mjs` (written to `.github/workflows/release-tower.yaml` and
`.github/scripts/release-tower-check.mjs`; GitHub only, Node 22, no dependencies). It runs
`pull_request_target` on the production branch from the default branch (a pull request cannot edit
its own gate; the head is never checked out) and passes a hotfix head, the OLDEST open release
pull request, and a pull request carrying `releaseTower.overrideLabel`; a later release pull
request is held with `<head> (#n) is on final; this release waits` and re-run automatically when
the one ahead closes; any other head gets the retarget line. **Making it REQUIRED on the production
branch's ruleset is the owner's change**, after it has posted green on one real release pull
request — then even an administrator cannot land a second release beside the first.

## Cited by

- `skills/release/SKILL.md` — the clearance floor, steps 0a, 4 and 6.
- `skills/setup/SKILL.md` and `references/ci-cost-patterns.md` §E — the `setup ci` template.
- `skills/doctor/SKILL.md` — the config audit of `release.clearance` and `releaseTower`.
- `skills/setup/references/statusline-segments.md` — the `release` segment.
- `skills/branch-hotfix/SKILL.md` — a hotfix never claims.
