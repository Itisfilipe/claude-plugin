#!/bin/bash
# Tests for skills/release/scripts/clearance-github.sh — the built-in release clearance provider,
# against a fake `gh` (scripts/tests/fixtures/clearance/fake-gh.py) served from a state directory.
# No network, no real repository, no file outside a private TMPDIR.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; P="$ROOT/skills/release/scripts/clearance-github.sh"
FX="$ROOT/scripts/tests/fixtures/clearance"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"; printf '#!/bin/bash\nexec python3 "%s/fake-gh.py" "$@"\n' "$FX" > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home"; mkdir -p "$HOME"

# fresh NAME — a new state directory and local record; the provider then runs as session me-1.
fresh() {
  STATE="$WORK/$1"; rm -rf "$STATE"; mkdir -p "$STATE/tags"
  export FAKE_GH_STATE="$STATE" CLEARANCE_RECORD="$WORK/$1.record.json" CLEARANCE_REPO=o/r \
         CLEARANCE_PRODUCTION_BRANCH=master CLEARANCE_RELEASE_PATTERN='release/<YY-MM-DD>[-n]' \
         CLEARANCE_POLL_SECONDS=1 CLEARANCE_WAIT_MINUTES=1 CLEARANCE_STALE_MINUTES=20 \
         CLEARANCE_NOW=2026-10-18T10:05:00Z CLAUDE_CODE_SESSION_ID=me-1
  unset DEVSTRIDE_LEASE_TOKEN CODEX_THREAD_ID
  rm -f "$CLEARANCE_RECORD"
}
# held HOLDER PHASE BRANCH PR [HEARTBEAT] — seed a clearance held by someone (record JSON in a tag)
held() {
  local pr="null"; [ "$4" != "-" ] && pr="$4"
  local branch="null"; [ "$3" != "-" ] && branch="\"$3\""
  printf '{"v":1,"repo":"o/r","holder":"%s","user":"bob","machine":"m9","purpose":"release","phase":"%s","branch":%s,"pr":%s,"takenAt":"2026-10-18T09:50:00Z","heartbeatAt":"%s"}' \
    "$1" "$2" "$branch" "$pr" "${5:-2026-10-18T10:00:00Z}" > "$STATE/tags/seed1"
  printf 'seed1' > "$STATE/ref"
}
record() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE/tags/$(cat "$STATE/ref")" "$1" 2>/dev/null; }
run() { OUT="$(bash "$P" "$@" 2>&1)"; RC=$?; }

# (1) a claim on a clear ref wins: CLEARED, the ref exists, the local record names the repo, 0600
fresh one
run claim --purpose release
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1 2026-10-18T10:05:00Z' && [ -f "$STATE/ref" ] \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["holder"])' "$CLEARANCE_RECORD")" = "o/r claude:me-1" ] \
   && [ "$(stat -f %Lp "$CLEARANCE_RECORD" 2>/dev/null || stat -c %a "$CLEARANCE_RECORD")" = 600 ] \
   && [ "$(record phase)" = claimed ] && [ "$(record user)" = alice ]; then
  ok "(1) claim wins → CLEARED <holder> <takenAt>; ref created; local record {repo, holder} mode 0600"
else bad "(1) rc=$RC: $OUT"; fi

# (2) a second claim by the same session is idempotent
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already held by this session'; then ok "(2) claiming again from the holder session is CLEARED, not BUSY"; else bad "(2) rc=$RC: $OUT"; fi

# (3) a claim while another fresh session holds it: BUSY with the holder line, exit 2, and no tag
#     object was created for the lost attempt (the provider reads before it creates)
fresh two; held claude:other review release/26-10-18 3981
run claim
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY held by bob on m9 since 2026-10-18T09:50:00Z, phase review, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && ! grep -q 'git/tags$' "$STATE/calls.log" && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(3) claim loses → BUSY held by <user> on <machine> since …, phase, heartbeat age; exit 2; no tag object made"
else bad "(3) rc=$RC: $OUT"; fi

# (4) a lost race: the ref appears between the read and the create → the loser reports BUSY
fresh race
printf '{"v":1,"holder":"claude:other","user":"bob","machine":"m9","phase":"claimed","branch":null,"pr":null,"takenAt":"2026-10-18T10:04:00Z","heartbeatAt":"2026-10-18T10:04:00Z"}' > "$STATE/tags/racer"
printf 'racer' > "$STATE/race"
run claim
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY held by bob' && [ "$(cat "$STATE/ref")" = racer ]; then
  ok "(4) the ref created under a claimant → it loses with BUSY naming the winner (the POST decided)"
else bad "(4) rc=$RC: $OUT"; fi

# (5) stale clearance whose pull request merged → reclaimed and CLEARED
fresh stale-merged; held claude:other merging release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"MERGED","mergedAt":"2026-10-18T09:40:00Z"}]' > "$STATE/prs.json"
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'stale clearance reclaimed' && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1' && [ "$(record holder)" = claude:me-1 ]; then
  ok "(5) stale (35 min) + merged pull request → reclaimed, then CLEARED for this session"
else bad "(5) rc=$RC: $OUT"; fi

# (6) stale with no pull request ever opened → reclaimed too
fresh stale-none; held claude:other cut release/26-10-17 - 2026-10-18T09:30:00Z
run claim
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'never opened' && [ "$(record holder)" = claude:me-1 ]; then
  ok "(6) stale with no pull request recorded → reclaimed"
else bad "(6) rc=$RC: $OUT"; fi

# (7) stale with its pull request still OPEN → STALE, exit 3, nothing touched
fresh stale-open; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z
printf '[{"number":3970,"headRefName":"release/26-10-17","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:35:00Z"}]' > "$STATE/prs.json"
run claim
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^STALE held by bob .* — STALE — pull request #3970 still open — adopt or wait$' && [ "$(record holder)" = claude:other ]; then
  ok "(7) stale + open pull request → STALE … pull request #n still open — adopt or wait; exit 3; untouched"
else bad "(7) rc=$RC: $OUT"; fi

# (8) adopt --yes takes over a stale clearance; the phase, branch and pull request survive
run adopt --yes
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ADOPTED release/26-10-17 #3970$' && printf '%s' "$OUT" | grep -q '^Resume: branch release/26-10-17, pull request #3970, phase review$' \
   && [ "$(record holder)" = claude:me-1 ] && [ "$(record heartbeatAt)" = 2026-10-18T10:05:00Z ] && [ "$(record takenAt)" = 2026-10-18T09:50:00Z ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pr"])' "$CLEARANCE_RECORD")" = 3970 ]; then
  ok "(8) adopt --yes → holder rewritten, heartbeat now, takenAt kept; Resume line names branch, pull request, phase"
else bad "(8) rc=$RC: $OUT"; fi

# (9) adopt refuses a fresh clearance; without --yes it refuses to run at all
fresh adopt-fresh; held claude:other review release/26-10-18 3981
run adopt --yes; A="$RC:$OUT"
run adopt; B="$RC"
if [ "${A%%:*}" -eq 2 ] && printf '%s' "$A" | grep -q 'not stale, nothing to adopt' && [ "$B" -eq 1 ] && [ "$(record holder)" = claude:other ]; then
  ok "(9) adopt on a fresh clearance → BUSY … not stale (exit 2); adopt without --yes → error"
else bad "(9) got: $A / $B"; fi

# (10) heartbeat by a non-holder exits 4 and changes nothing; by the holder it updates phase/branch/pr
fresh beat; held claude:other review release/26-10-18 3981
run heartbeat cut --branch release/26-10-18; A="$RC"
[ "$(record phase)" = review ] && SAME=1 || SAME=0
fresh beat2; run claim; run heartbeat pr --branch release/26-10-18 --pr 3990
if [ "$A" -eq 4 ] && [ "$SAME" = 1 ] && [ "$RC" -eq 0 ] && [ "$(record phase)" = pr ] && [ "$(record branch)" = release/26-10-18 ] && [ "$(record pr)" = 3990 ] \
   && printf '%s' "$OUT" | grep -q '^HEARTBEAT pr 2026-10-18T10:05:00Z$' \
   && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["branch"], d["pr"])' "$CLEARANCE_RECORD")" = "release/26-10-18 3990" ]; then
  ok "(10) heartbeat: non-holder → exit 4, record untouched; holder → phase/branch/pr written to the ref and the local record"
else bad "(10) a=$A same=$SAME rc=$RC: $OUT"; fi

# (11) release by a non-holder exits 4; --force releases and says whose it was; by the holder it
#      deletes the ref and removes the local record
fresh rel; held claude:other review release/26-10-18 3981
run release; A="$RC"; [ -f "$STATE/ref" ] && KEPT=1 || KEPT=0
run release --force; B="$RC:$OUT"; [ -f "$STATE/ref" ] && GONE=0 || GONE=1
fresh rel2; run claim; run release; C="$RC:$OUT"
if [ "$A" -eq 4 ] && [ "$KEPT" = 1 ] && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q 'forcing release of a clearance held by bob' && [ "$GONE" = 1 ] \
   && [ "${C%%:*}" -eq 0 ] && printf '%s' "$C" | grep -q 'RELEASED' && [ ! -f "$STATE/ref" ] && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(11) release: non-holder → exit 4; --force → released, naming the holder; holder → ref deleted, local record removed"
else bad "(11) a=$A kept=$KEPT b=$B c=$C"; fi

# (12) release on a clear ref is a no-op that still clears a leftover local record
fresh rel3; printf '{"repo":"o/r","holder":"claude:me-1"}' > "$CLEARANCE_RECORD"
run release
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^CLEAR (nothing to release)' && [ ! -f "$CLEARANCE_RECORD" ]; then
  ok "(12) release with nothing held → CLEAR (nothing to release), stale local record removed"
else bad "(12) rc=$RC: $OUT"; fi

# (13) status: the clearance line, On final / Waiting (oldest open release pull request first by
#      number), Hotfix landed since takenAt only (an earlier hotfix is not listed); exit 0
fresh st; held claude:other ci release/26-10-18 3981
cat > "$STATE/prs.json" <<'J'
[{"number":3985,"headRefName":"release/26-10-18-2","state":"OPEN","isDraft":true,"createdAt":"2026-10-18T09:58:00Z"},
 {"number":3981,"headRefName":"release/26-10-18","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"},
 {"number":3983,"headRefName":"phil/hotfix/26-10-18/I1-fix","state":"MERGED","mergedAt":"2026-10-18T10:01:00Z"},
 {"number":3960,"headRefName":"phil/hotfix/26-10-17/I2-old","state":"MERGED","mergedAt":"2026-10-18T09:00:00Z"},
 {"number":3984,"headRefName":"phil/26-10-18/I3-feature","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T10:02:00Z"}]
J
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^Clearance: held by bob on m9 since 2026-10-18T09:50:00Z, phase ci, heartbeat 5 min ago — release/26-10-18 #3981$' \
   && printf '%s' "$OUT" | grep -q '^On final: #3981 release/26-10-18$' && printf '%s' "$OUT" | grep -q '^Waiting: #3985 release/26-10-18-2 (draft)$' \
   && printf '%s' "$OUT" | grep -q '^Hotfix landed: #3983 phil/hotfix/26-10-18/I1-fix 2026-10-18T10:01:00Z$' && ! printf '%s' "$OUT" | grep -q '#3960' && ! printf '%s' "$OUT" | grep -q '#3984'; then
  ok "(13) status → Clearance line, On final (oldest release pull request), Waiting (draft), Hotfix landed since takenAt only"
else bad "(13) rc=$RC: $OUT"; fi

# (14) status --short is one token line for the status line; --json carries the record and facts
run status --short; A="$RC:$OUT"
run status --json; B="$OUT"
J="$(printf '%s' "$B" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["stale"], d["record"]["holder"], d["onFinal"]["number"], len(d["waiting"]), d["hotfixesLanded"][0]["number"], d["staleMinutes"])' 2>/dev/null)"
if [ "$A" = "0:release/26-10-18 · bob · ci" ] && [ "$J" = "held False claude:other 3981 1 3983 20" ]; then
  ok "(14) status --short → 'release/26-10-18 · bob · ci'; --json → state, stale, record, onFinal, waiting, hotfixesLanded"
else bad "(14) short=$A json=$J"; fi

# (15) status when clear: CLEAR, --short prints nothing, --json state clear; a stale one says STALE
fresh clear; run status; A="$RC:$OUT"; run status --short; B="$RC:$OUT"
run status --json; C="$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["record"])')"
fresh stale-st; held claude:other review release/26-10-17 3970 2026-10-18T09:30:00Z; run status --short; D="$OUT"
if [ "$A" = "0:CLEAR" ] && [ "$B" = "0:" ] && [ "$C" = "clear None" ] && [ "$D" = "release/26-10-17 · bob · review · STALE" ]; then
  ok "(15) clear → CLEAR / nothing / state clear; a stale clearance renders '· STALE'"
else bad "(15) a=$A b=$B c=$C d=$D"; fi

# (16) status that cannot read the ref is UNKNOWN with exit 1 — never shown as clear
fresh unknown; printf '#!/bin/bash\necho "gh: not logged in" >&2; exit 1\n' > "$WORK/bin/gh"
run status; A="$RC:$OUT"; run status --json; B="$OUT"
printf '#!/bin/bash\nexec python3 "%s/fake-gh.py" "$@"\n' "$FX" > "$WORK/bin/gh"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q 'UNKNOWN (gh: gh: not logged in)' && printf '%s' "$B" | grep -q '"state": "unknown"'; then
  ok "(16) gh failing → UNKNOWN (gh: …) exit 1, --json state unknown; a failure is never CLEAR"
else bad "(16) a=$A b=$B"; fi

# (17) claim --wait polls (1 s here) and returns 0 when the holder releases
fresh wait; held claude:other review release/26-10-18 3981
( sleep 2; rm -f "$STATE/ref" ) &
START=$(date +%s); run claim --wait; END=$(date +%s)
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^BUSY')" -ge 1 ] && printf '%s' "$OUT" | grep -q '^CLEARED claude:me-1' && [ $((END - START)) -ge 2 ] && [ $((END - START)) -le 20 ]; then
  ok "(17) claim --wait prints BUSY each poll and returns CLEARED when the clearance frees ($((END - START)) s)"
else bad "(17) rc=$RC in $((END - START)) s: $OUT"; fi

# (18) claim --wait gives up at waitMinutes with BUSY, exit 2 (a one-minute wait here, polled at 1 s: the deadline is checked after each poll)
fresh waitout; held claude:other review release/26-10-18 3981
export CLEARANCE_WAIT_MINUTES=0
run claim --wait
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUSY'; then ok "(18) claim --wait past waitMinutes → BUSY, exit 2"; else bad "(18) rc=$RC: $OUT"; fi

# (19) a 403 on ref creation names the ruleset finding, exit 1
fresh forbidden; : > "$STATE/fail-ref-create"
run claim
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'ruleset that restricts ref creation'; then
  ok "(19) HTTP 403 creating the ref → ERROR naming the ruleset finding, exit 1"
else bad "(19) rc=$RC: $OUT"; fi

# (20) identity: DEVSTRIDE_LEASE_TOKEN wins; codex+claude join with +; neither → a printed token
fresh ident; export DEVSTRIDE_LEASE_TOKEN=tok-1; run claim; A="$(record holder)"
fresh ident2; export CODEX_THREAD_ID=c-9; run claim; B="$(record holder)"
fresh ident3; unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID; run claim; C="$(record holder)"; D="$OUT"
if [ "$A" = tok-1 ] && [ "$B" = "codex:c-9+claude:me-1" ] && printf '%s' "$C" | grep -q '^token:[0-9a-f]\{24\}$' && printf '%s' "$D" | grep -q "holder token $C — export it as DEVSTRIDE_LEASE_TOKEN"; then
  ok "(20) holder = DEVSTRIDE_LEASE_TOKEN, else codex:…+claude:…, else token:<random> printed once"
else bad "(20) a=$A b=$B c=$C d=$D"; fi

# (21) a release pattern absent: the release source itself is the release head for On final
fresh nopattern; export CLEARANCE_RELEASE_PATTERN=''
printf '[{"number":12,"headRefName":"develop","state":"OPEN","isDraft":false,"createdAt":"2026-10-18T09:52:00Z"}]' > "$STATE/prs.json"
run status
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^On final: #12 develop$'; then ok "(21) no releaseBranchPattern → a pull request headed by the release source is the release"; else bad "(21) rc=$RC: $OUT"; fi

exit $FAIL
