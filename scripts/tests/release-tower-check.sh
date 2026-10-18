#!/bin/bash
# Tests for skills/setup/references/ci-templates/release-tower-check.mjs — the verdict the
# `release-tower` check posts on a pull request into the production branch, and the re-run
# selection after a release closes. Pure functions of files; no git, no gh, no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; C="$ROOT/skills/setup/references/ci-templates/release-tower-check.mjs"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
command -v node >/dev/null 2>&1 || { echo "  skip: node is not on PATH (the template needs Node 22 in CI, not here)"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cat > "$W/config.json" <<'J'
{ "baseBranch": "develop",
  "release": { "productionBranch": "master", "releaseSource": "develop", "releaseBranchPattern": "release/<YY-MM-DD>[-n]" },
  "releaseTower": { "overrideLabel": "release-tower-override" } }
J
cat > "$W/open.json" <<'J'
[{"number":3985,"headRefName":"release/26-10-18-2"},{"number":3981,"headRefName":"release/26-10-18"},
 {"number":3984,"headRefName":"phil/26-10-18/I3-feature"},{"number":3990,"headRefName":"release/26-10-19"}]
J
check() { # check HEAD NUMBER [LABELS] [BASE] -> OUT RC
  OUT="$(node "$C" check --head "$1" --base "${4:-master}" --number "$2" --labels "${3:-}" --config "$W/config.json" --open-prs "$W/open.json" 2>&1)"; RC=$?
}

# (1) the oldest open release pull request is on final → ALLOWED
check release/26-10-18 3981
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ALLOWED: release/26-10-18 (#3981) is the oldest open release pull request — on final$'; then
  ok "(1) oldest open release pull request → ALLOWED, on final"; else bad "(1) rc=$RC: $OUT"; fi

# (2) a second release pull request (same day, -2) waits, naming the one on final
check release/26-10-18-2 3985
if [ "$RC" -eq 1 ] && [ "$OUT" = "BLOCKED: release/26-10-18 (#3981) is on final; this release waits. It turns green by itself when #3981 merges or closes." ]; then
  ok "(2) a later release pull request → BLOCKED: <head> (#n) is on final; this release waits"; else bad "(2) rc=$RC: $OUT"; fi

# (3) a third one names the OLDEST, not the one just ahead of it
check release/26-10-19 3990
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^BLOCKED: release/26-10-18 (#3981) is on final'; then
  ok "(3) the third in line is held by the oldest (#3981), not by #3985"; else bad "(3) rc=$RC: $OUT"; fi

# (4) a release pull request not yet in the open list (its own opened event) is judged against the rest
check release/26-10-20 3995
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '(#3981) is on final'; then ok "(4) a brand-new release pull request absent from the list still waits behind #3981"; else bad "(4) rc=$RC: $OUT"; fi
printf '[{"number":3984,"headRefName":"phil/26-10-18/I3-feature"}]' > "$W/open-one.json"
OUT="$(node "$C" check --head release/26-10-20 --base master --number 3995 --config "$W/config.json" --open-prs "$W/open-one.json")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'on final'; then ok "(4b) …and with no other release open it is on final"; else bad "(4b) rc=$RC: $OUT"; fi

# (5) a hotfix head is never held, even behind an open release
check phil/hotfix/26-10-18/I1-fix 3983
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ALLOWED: phil/hotfix/26-10-18/I1-fix is a hotfix (\*/hotfix/\*\*); a hotfix is never held$'; then
  ok "(5) hotfix head → ALLOWED whatever is on final"; else bad "(5) rc=$RC: $OUT"; fi

# (6) a feature head into master gets the retarget line, with the exact command
check phil/26-10-18/I3-feature 3984
if [ "$RC" -eq 1 ] && [ "$OUT" = "BLOCKED: Pull requests into master come from a release branch (release/<YY-MM-DD>[-n]) or a hotfix branch (*/hotfix/**). Retarget at develop: gh pr edit 3984 --base develop; an owner-approved exception asks for the release-tower-override label." ]; then
  ok "(6) a feature head → BLOCKED with the retarget command and the override label"; else bad "(6) rc=$RC: $OUT"; fi

# (7) the override label passes anything, naming the label
check phil/26-10-18/I3-feature 3984 "run-backend-ci,release-tower-override"
if [ "$RC" -eq 0 ] && [ "$OUT" = "ALLOWED: override label release-tower-override present" ]; then ok "(7) override label → ALLOWED, naming it"; else bad "(7) rc=$RC: $OUT"; fi

# (8) a pull request into another base is not this check's business
check phil/26-10-18/I3-feature 3984 "" develop
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ALLOWED: base is develop, not master'; then ok "(8) base develop → ALLOWED (guards master only)"; else bad "(8) rc=$RC: $OUT"; fi

# (9) no releaseBranchPattern: the release source itself is the release head; a dated name is not
cat > "$W/config-nopat.json" <<'J'
{ "baseBranch": "develop", "release": { "productionBranch": "master", "releaseSource": "develop" } }
J
printf '[{"number":12,"headRefName":"develop"}]' > "$W/open-np.json"
A="$(node "$C" check --head develop --base master --number 12 --config "$W/config-nopat.json" --open-prs "$W/open-np.json")"; RA=$?
B="$(node "$C" check --head release/26-10-18 --base master --number 13 --config "$W/config-nopat.json" --open-prs "$W/open-np.json")"; RB=$?
if [ "$RA" -eq 0 ] && printf '%s' "$A" | grep -q 'on final' && [ "$RB" -eq 1 ] && printf '%s' "$B" | grep -q 'come from the release source (develop)'; then
  ok "(9) without a pattern, develop is the release head and a release/… name is retargeted"; else bad "(9) a=$RA:$A b=$RB:$B"; fi

# (10) usage and config errors exit 2 with ERROR, never a silent allow
A="$(node "$C" check --head x --base master --config "$W/config.json" --open-prs "$W/open.json")"; RA=$?
printf '{}' > "$W/bad.json"
B="$(node "$C" check --head x --base master --number 1 --config "$W/bad.json" --open-prs "$W/open.json")"; RB=$?
C2="$(node "$C" nonsense)"; RC2=$?
if [ "$RA" -eq 2 ] && printf '%s' "$A" | grep -q '^ERROR: --number is required' && [ "$RB" -eq 2 ] && printf '%s' "$B" | grep -q 'release is missing' && [ "$RC2" -eq 2 ]; then
  ok "(10) missing argument / missing release block / unknown mode → ERROR, exit 2"; else bad "(10) a=$RA:$A b=$RB:$B c=$RC2:$C2"; fi

# (11) reruns: after a release closes, the newest finished run of each open release pull request,
#      matched by head branch or head sha, skipping in-progress runs; nothing for a closed hotfix
cat > "$W/open-rr.json" <<'J'
[{"number":3985,"headRefName":"release/26-10-18-2","headRefOid":"aaa1"},{"number":3990,"headRefName":"release/26-10-19","headRefOid":"bbb2"},
 {"number":3984,"headRefName":"phil/26-10-18/I3-feature","headRefOid":"ccc3"}]
J
cat > "$W/runs.json" <<'J'
[{"databaseId":901,"headBranch":"release/26-10-18-2","headSha":"aaa1","status":"completed"},
 {"databaseId":900,"headBranch":"release/26-10-18-2","headSha":"aaa0","status":"completed"},
 {"databaseId":902,"headBranch":"master","headSha":"bbb2","status":"in_progress"},
 {"databaseId":899,"headBranch":"master","headSha":"bbb2","status":"completed"},
 {"databaseId":903,"headBranch":"phil/26-10-18/I3-feature","headSha":"ccc3","status":"completed"}]
J
A="$(node "$C" reruns --closed-head release/26-10-18 --config "$W/config.json" --open-prs "$W/open-rr.json" --runs "$W/runs.json" | tr '\n' ' ')"
B="$(node "$C" reruns --closed-head phil/hotfix/26-10-18/I1-fix --config "$W/config.json" --open-prs "$W/open-rr.json" --runs "$W/runs.json" | tr '\n' ' ')"
if [ "$A" = "901 899 " ] && [ "$B" = "" ]; then
  ok "(11) reruns → 901 (newest by head branch) and 899 (by sha, skipping the in-progress 902); a closed hotfix re-runs nothing"
else bad "(11) a='$A' b='$B'"; fi

# (12) the workflow template names the checker path the test exercised, holds the production
#      placeholder exactly once in its trigger, never checks out the head, and carries both jobs
T="$ROOT/skills/setup/references/ci-templates/release-tower.yaml"
if grep -q 'pull_request_target:' "$T" && [ "$(grep -c '{{PRODUCTION_BRANCH}}' "$T")" -eq 1 ] && grep -q 'branches: \[{{PRODUCTION_BRANCH}}\]' "$T" \
   && grep -q 'name: release-tower$' "$T" && grep -q "github.event.action == 'closed'" "$T" && grep -q '.github/scripts/release-tower-check.mjs' "$T" \
   && ! grep -qE 'ref: *\$\{\{ *github\.event\.pull_request\.head' "$T" && grep -q 'release-tower-override' "$T"; then
  ok "(12) release-tower.yaml: pull_request_target, one production placeholder, both jobs, no head checkout"
else bad "(12) the workflow template drifted from the checker"; fi

exit $FAIL
