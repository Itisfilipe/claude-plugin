#!/bin/bash
# skills/release/scripts/clearance-github.sh — the built-in release clearance provider.
#
# One cleared release at a time, for every machine and account that releases this repository,
# with nothing but `gh`. The clearance is a custom git ref in the repository (default
# `refs/clearance/release`) pointing at an annotated tag object whose message is the clearance
# record as JSON. Creating the ref is the atomic claim: GitHub answers 422 "Reference already
# exists" to every claimant but one, so there is no look-then-act. The ref is neither a branch nor
# a tag, so it triggers no workflow, appears in no branch or tag list, and no ruleset pattern
# matches it. The contract every command honours — exit codes, first lines, the local record —
# is skills/release/references/clearance.md, which a repository-supplied provider follows too.
#
#   claim     [--wait] [--purpose <text>]      0 CLEARED · 2 BUSY · 3 STALE (pull request open) · 1 error
#   status    [--short] [--json]               0 when the ref was read (CLEAR or held) · 1 unreadable
#   heartbeat <phase> [--branch b] [--pr n]    0 · 4 NOT HOLDER
#   release   [--force]                        0 · 4 NOT HOLDER
#   adopt     --yes                            0 ADOPTED · 2 not stale · 4 nothing to adopt
#
# Configuration comes from the nearest `.claude/ds-config.json` above the working directory:
# release.clearance.{ref, staleMinutes, waitMinutes}, release.productionBranch,
# release.releaseSource, release.releaseBranchPattern and releaseTower.hotfixPattern. Environment
# overrides exist for tests and for a wrapper: CLEARANCE_REF, CLEARANCE_STALE_MINUTES,
# CLEARANCE_WAIT_MINUTES, CLEARANCE_POLL_SECONDS (default 60), CLEARANCE_RECORD (the local record
# path), CLEARANCE_REPO (owner/name), CLEARANCE_PRODUCTION_BRANCH, CLEARANCE_RELEASE_PATTERN,
# CLEARANCE_HOTFIX_PATTERN, CLEARANCE_NOW (an ISO instant, tests only).
#
# Runs under macOS /bin/bash 3.2: bash only hands over to python3, the toolchain the plugin's
# hooks already assume. `gh` must be signed in with contents write on the repository.
set -u
command -v python3 >/dev/null 2>&1 || { echo "clearance: python3 is required" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "clearance: gh is required (https://cli.github.com)" >&2; exit 1; }
exec python3 - "$@" <<'PY'
import json, os, re, secrets, socket, subprocess, sys, time
from datetime import datetime, timezone

RECORD_VERSION = 1
DEFAULT_REF = "refs/clearance/release"
DEFAULT_STALE_MINUTES = 20
DEFAULT_WAIT_MINUTES = 180
DEFAULT_HOTFIX_PATTERN = "*/hotfix/**"
DEFAULT_RELEASE_PATTERN = "release/<YY-MM-DD>[-n]"


def fail(message, code=1):
    print("ERROR: " + message)
    sys.exit(code)


# ── time ──
def now():
    forced = os.environ.get("CLEARANCE_NOW")
    if forced:
        return parse_iso(forced)
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_iso(text):
    text = (text or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def age_text(since, at):
    if since is None:
        return "unknown"
    seconds = int((at - since).total_seconds())
    if seconds < 0:
        seconds = 0
    if seconds < 60:
        return "%d s ago" % seconds
    if seconds < 3600:
        return "%d min ago" % (seconds // 60)
    return "%d h %d min ago" % (seconds // 3600, (seconds % 3600) // 60)


# ── the branch-patterns rule (skills/release/references/branch-patterns.md) ──
def pattern_regex(pattern):
    source, rest = "", pattern
    while rest:
        if rest.startswith("**"):
            source += ".+"; rest = rest[2:]
        elif rest.startswith("*"):
            source += "[^/]+"; rest = rest[1:]
        elif rest == "[-n]":
            source += "(-[0-9]+)?"; rest = ""
        elif re.match(r"^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>", rest):
            source += "[0-9]{2}-[0-9]{2}-[0-9]{2}"; rest = rest[10:]
        else:
            source += re.escape(rest[0]); rest = rest[1:]
    return re.compile("^" + source + "$")


# ── configuration ──
def load_config():
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate) as handle:
                    return json.load(handle)
            except (OSError, ValueError):
                return {}
        parent = os.path.dirname(here)
        if parent == here:
            return {}
        here = parent


def section(config, key):
    value = config.get(key)
    return value if isinstance(value, dict) else {}


CONFIG = load_config()
RELEASE = section(CONFIG, "release")
CLEARANCE = RELEASE.get("clearance") if isinstance(RELEASE.get("clearance"), dict) else {}
TOWER = section(CONFIG, "releaseTower")


def setting(env_name, config_value, default, kind=str):
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        raw = config_value
    if raw is None or raw == "":
        return default
    try:
        return kind(raw)
    except (TypeError, ValueError):
        return default


REF = setting("CLEARANCE_REF", CLEARANCE.get("ref"), DEFAULT_REF)
if not REF.startswith("refs/") or REF.count("/") < 2:
    fail("release.clearance.ref must be a fully qualified ref such as refs/clearance/release")
REF_PATH = REF[len("refs/"):]  # what the git refs API takes after /git/ref/ and /git/refs/
STALE_MINUTES = setting("CLEARANCE_STALE_MINUTES", CLEARANCE.get("staleMinutes"), DEFAULT_STALE_MINUTES, int)
WAIT_MINUTES = setting("CLEARANCE_WAIT_MINUTES", CLEARANCE.get("waitMinutes"), DEFAULT_WAIT_MINUTES, int)
POLL_SECONDS = setting("CLEARANCE_POLL_SECONDS", None, 60, int)
PRODUCTION = setting("CLEARANCE_PRODUCTION_BRANCH", RELEASE.get("productionBranch"), "master")
RELEASE_SOURCE = RELEASE.get("releaseSource") or "develop"
RELEASE_PATTERN = setting("CLEARANCE_RELEASE_PATTERN", RELEASE.get("releaseBranchPattern"), "")
HOTFIX_PATTERN = setting("CLEARANCE_HOTFIX_PATTERN", TOWER.get("hotfixPattern"), DEFAULT_HOTFIX_PATTERN)
RECORD_PATH = os.environ.get("CLEARANCE_RECORD") or os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
    "devstride", "release-clearance.json")


def is_release_head(name):
    if RELEASE_PATTERN:
        return bool(pattern_regex(RELEASE_PATTERN).match(name))
    return name == RELEASE_SOURCE


def is_hotfix_head(name):
    return bool(pattern_regex(HOTFIX_PATTERN).match(name))


# ── gh ──
class GhError(Exception):
    def __init__(self, status, text):
        super().__init__(text)
        self.status = status
        self.text = text


def gh(args, body=None):
    """Run gh; on failure raise GhError carrying the HTTP status gh printed."""
    proc = subprocess.run(["gh", *args], input=body, capture_output=True, text=True)
    if proc.returncode == 0:
        return proc.stdout
    text = (proc.stderr or proc.stdout or "").strip()
    match = re.search(r"HTTP (\d{3})", text)
    raise GhError(int(match.group(1)) if match else 0, text)


def gh_json(args, body=None):
    out = gh(args, body)
    try:
        return json.loads(out) if out.strip() else None
    except ValueError:
        raise GhError(0, "gh returned something that is not JSON: " + out[:200])


_repo = None


def repo():
    global _repo
    if _repo is None:
        _repo = os.environ.get("CLEARANCE_REPO") or gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()
        if not re.match(r"^[^/\s]+/[^/\s]+$", _repo):
            fail("could not determine the repository (gh repo view); is this a GitHub checkout?")
    return _repo


def gh_user():
    try:
        return gh(["api", "user", "--jq", ".login"]).strip() or "unknown"
    except GhError:
        return "unknown"


# ── identity (the same rule as a pool lease: one identity means one thing everywhere) ──
def holder():
    token = os.environ.get("DEVSTRIDE_LEASE_TOKEN")
    if token:
        if re.search(r"[|\s]", token):
            fail("DEVSTRIDE_LEASE_TOKEN cannot contain | or whitespace")
        return token, False
    ids = []
    if os.environ.get("CODEX_THREAD_ID"):
        ids.append("codex:" + os.environ["CODEX_THREAD_ID"])
    if os.environ.get("CLAUDE_CODE_SESSION_ID"):
        ids.append("claude:" + os.environ["CLAUDE_CODE_SESSION_ID"])
    if ids:
        return "+".join(ids), False
    return "token:" + secrets.token_hex(12), True


# ── the ref and its record ──
def read_record():
    """The clearance record, or None when the ref does not exist. Raises GhError when unreadable."""
    try:
        ref = gh_json(["api", "repos/%s/git/ref/%s" % (repo(), REF_PATH)])
    except GhError as error:
        if error.status == 404:
            return None
        raise
    sha = ((ref or {}).get("object") or {}).get("sha")
    if not sha:
        raise GhError(0, "the clearance ref has no object")
    tag = gh_json(["api", "repos/%s/git/tags/%s" % (repo(), sha)])
    try:
        record = json.loads((tag or {}).get("message") or "")
    except ValueError:
        record = {}
    if not isinstance(record, dict):
        record = {}
    record["_sha"] = sha
    return record


def write_tag(record):
    """A new tag object carrying the record; returns its sha."""
    clean = {k: v for k, v in record.items() if not k.startswith("_")}
    body = json.dumps({
        "tag": "release-clearance",
        "message": json.dumps(clean, sort_keys=True),
        "object": production_head(),
        "type": "commit",
    })
    created = gh_json(["api", "-X", "POST", "repos/%s/git/tags" % repo(), "--input", "-"], body)
    sha = (created or {}).get("sha")
    if not sha:
        raise GhError(0, "creating the clearance tag object returned no sha")
    return sha


_prod_head = None


def production_head():
    global _prod_head
    if _prod_head is None:
        ref = gh_json(["api", "repos/%s/git/ref/heads/%s" % (repo(), PRODUCTION)])
        _prod_head = ((ref or {}).get("object") or {}).get("sha") or ""
        if not _prod_head:
            raise GhError(0, "could not read the head of %s" % PRODUCTION)
    return _prod_head


def create_ref(sha):
    """True when this call created the ref; False when it already existed (the atomic BUSY)."""
    try:
        gh(["api", "-X", "POST", "repos/%s/git/refs" % repo(), "--input", "-"],
           json.dumps({"ref": REF, "sha": sha}))
        return True
    except GhError as error:
        if error.status == 422 and "already exists" in error.text.lower():
            return False
        if error.status == 403:
            raise GhError(403, "creating %s was refused (HTTP 403): a repository ruleset that restricts "
                               "ref creation blocks the clearance ref — see clearance.md" % REF)
        raise


def move_ref(sha):
    gh(["api", "-X", "PATCH", "repos/%s/git/refs/%s" % (repo(), REF_PATH), "--input", "-"],
       json.dumps({"sha": sha, "force": True}))


def delete_ref():
    try:
        gh(["api", "-X", "DELETE", "repos/%s/git/refs/%s" % (repo(), REF_PATH)])
    except GhError as error:
        if error.status != 404 and "does not exist" not in error.text.lower():
            raise


def is_stale(record, at):
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    return beat is None or (at - beat).total_seconds() > STALE_MINUTES * 60


def pr_state(number):
    try:
        return gh(["pr", "view", str(number), "--json", "state", "--jq", ".state"]).strip().upper()
    except GhError:
        return "UNKNOWN"


# ── the local record (what a hook reads to answer "does THIS session hold clearance?") ──
def write_local(record):
    directory = os.path.dirname(RECORD_PATH)
    os.makedirs(directory, exist_ok=True)
    payload = {
        "repo": repo(), "holder": record.get("holder"), "user": record.get("user"),
        "machine": record.get("machine"), "branch": record.get("branch"), "pr": record.get("pr"),
        "takenAt": record.get("takenAt"),
    }
    tmp = RECORD_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, RECORD_PATH)


def remove_local():
    try:
        with open(RECORD_PATH) as handle:
            current = json.load(handle)
    except (OSError, ValueError):
        current = None
    # Only this repository's record is ours to remove.
    if current is None or current.get("repo") in (None, repo()):
        try:
            os.remove(RECORD_PATH)
        except OSError:
            pass


# ── output lines ──
def describe(record, at):
    beat = parse_iso(record.get("heartbeatAt") or record.get("takenAt"))
    line = "held by %s on %s since %s, phase %s, heartbeat %s" % (
        record.get("user") or "?", record.get("machine") or "?", record.get("takenAt") or "?",
        record.get("phase") or "?", age_text(beat, at))
    where = []
    if record.get("branch"):
        where.append(record["branch"])
    if record.get("pr"):
        where.append("#%s" % record["pr"])
    if where:
        line += " — " + " ".join(where)
    if is_stale(record, at):
        line += " — STALE"
    return line


# ── commands ──
def cmd_claim(args):
    wait = "--wait" in args
    purpose = option(args, "--purpose") or "release"
    me, print_token = holder()
    if print_token:
        print("holder token %s — export it as DEVSTRIDE_LEASE_TOKEN for heartbeat and release" % me)
    user = None
    deadline = time.monotonic() + WAIT_MINUTES * 60
    while True:
        at = now()
        # Read first, so a BUSY poll costs one read and leaves no tag object behind; the claim
        # itself is still the ref creation, which only one caller can win.
        current = read_record()
        if current is None:
            if user is None:
                user = gh_user()
            record = {
                "v": RECORD_VERSION, "repo": repo(), "holder": me, "user": user, "machine": socket.gethostname(),
                "purpose": purpose, "phase": "claimed", "branch": None, "pr": None,
                "takenAt": iso(at), "heartbeatAt": iso(at),
            }
            if create_ref(write_tag(record)):
                write_local(record)
                print("CLEARED %s %s" % (me, record["takenAt"]))
                return 0
            continue  # lost the race: read who won
        if current.get("holder") == me:
            write_local(current)
            print("CLEARED %s %s (already held by this session)" % (me, current.get("takenAt")))
            return 0
        if is_stale(current, at):
            number = current.get("pr")
            state = pr_state(number) if number else "NONE"
            if state in ("MERGED", "CLOSED", "NONE"):
                print("stale clearance reclaimed (%s; pull request %s)" % (
                    describe(current, at), ("#%s %s" % (number, state.lower())) if number else "never opened"))
                delete_ref()
                continue
            print("STALE %s — pull request #%s %s — adopt or wait" % (
                describe(current, at), number, "still open" if state == "OPEN" else "state " + state.lower()))
            return 3
        print("BUSY " + describe(current, at), flush=True)
        if not wait or time.monotonic() >= deadline:
            return 2
        time.sleep(POLL_SECONDS)


def list_prs(state):
    fields = "number,headRefName,isDraft,createdAt,mergedAt"
    try:
        rows = gh_json(["pr", "list", "--base", PRODUCTION, "--state", state, "--limit", "50", "--json", fields]) or []
    except GhError:
        return None
    return [row for row in rows if isinstance(row, dict)]


def derive(record, at):
    """What GitHub says about release pull requests and hotfix landings — never recorded."""
    out = {"onFinal": None, "waiting": [], "hotfixesLanded": [], "derived": True}
    open_prs = list_prs("open")
    if open_prs is None:
        out["derived"] = False
        return out
    releases = sorted((p for p in open_prs if is_release_head(p.get("headRefName", ""))), key=lambda p: p["number"])
    if releases:
        first = releases[0]
        out["onFinal"] = {"number": first["number"], "head": first["headRefName"], "draft": bool(first.get("isDraft"))}
        out["waiting"] = [{"number": p["number"], "head": p["headRefName"], "draft": bool(p.get("isDraft"))} for p in releases[1:]]
    if record:
        since = parse_iso(record.get("takenAt"))
        merged = list_prs("merged")
        if merged is None:
            out["derived"] = False
        else:
            for p in merged:
                when = parse_iso(p.get("mergedAt"))
                if is_hotfix_head(p.get("headRefName", "")) and when and since and when >= since:
                    out["hotfixesLanded"].append({"number": p["number"], "head": p["headRefName"], "mergedAt": p.get("mergedAt")})
    return out


def cmd_status(args):
    at = now()
    try:
        record = read_record()
    except GhError as error:
        if "--json" in args:
            print(json.dumps({"state": "unknown", "error": error.text}))
        elif "--short" in args:
            pass
        else:
            print("UNKNOWN (gh: %s)" % error.text.splitlines()[0] if error.text else "UNKNOWN")
        return 1
    stale = bool(record) and is_stale(record, at)
    if "--short" in args:
        if record:
            what = record.get("branch") or record.get("purpose") or "release"
            print("%s · %s · %s%s" % (what, record.get("user") or "?", record.get("phase") or "?", " · STALE" if stale else ""))
        return 0
    facts = derive(record, at)
    if "--json" in args:
        clean = {k: v for k, v in (record or {}).items() if not k.startswith("_")} if record else None
        print(json.dumps({
            "state": "held" if record else "clear", "stale": stale, "staleMinutes": STALE_MINUTES,
            "now": iso(at), "ref": REF, "repo": repo(), "productionBranch": PRODUCTION, "record": clean, **facts,
        }, sort_keys=True))
        return 0
    print("Clearance: " + describe(record, at) if record else "CLEAR")
    if facts["onFinal"]:
        f = facts["onFinal"]
        print("On final: #%s %s%s" % (f["number"], f["head"], " (draft)" if f["draft"] else ""))
    for w in facts["waiting"]:
        print("Waiting: #%s %s%s" % (w["number"], w["head"], " (draft)" if w["draft"] else ""))
    for h in facts["hotfixesLanded"]:
        print("Hotfix landed: #%s %s %s" % (h["number"], h["head"], h["mergedAt"]))
    if not facts["derived"]:
        print("(pull requests into %s could not be listed)" % PRODUCTION)
    return 0


def option(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            fail("%s needs a value" % name, 1)
        return args[i + 1]
    return None


def cmd_heartbeat(args):
    if not args or args[0].startswith("--"):
        fail("heartbeat needs a phase as its first argument", 1)
    phase = args[0]
    me, _ = holder()
    at = now()
    record = read_record()
    if record is None:
        print("NOT HOLDER: no clearance is held (claim first)")
        remove_local()
        return 4
    if record.get("holder") != me:
        print("NOT HOLDER: " + describe(record, at))
        return 4
    record["phase"] = phase
    branch = option(args, "--branch")
    number = option(args, "--pr")
    if branch:
        record["branch"] = branch
    if number:
        record["pr"] = int(number) if number.isdigit() else number
    record["heartbeatAt"] = iso(at)
    move_ref(write_tag(record))
    write_local(record)
    print("HEARTBEAT %s %s" % (phase, record["heartbeatAt"]))
    return 0


def cmd_release(args):
    force = "--force" in args
    me, _ = holder()
    at = now()
    record = read_record()
    if record is None:
        print("CLEAR (nothing to release)")
        remove_local()
        return 0
    if record.get("holder") != me and not force:
        print("NOT HOLDER: " + describe(record, at) + " — the holder releases it, or the owner runs release --force")
        return 4
    if force:
        print("forcing release of a clearance " + describe(record, at))
    delete_ref()
    remove_local()
    print("RELEASED %s" % (record.get("branch") or record.get("purpose") or "release"))
    return 0


def cmd_adopt(args):
    if "--yes" not in args:
        fail("adopt takes --yes: it rewrites the holder of a stale clearance", 1)
    me, print_token = holder()
    at = now()
    record = read_record()
    if record is None:
        print("NOT HOLDER: no clearance to adopt (claim instead)")
        return 4
    if record.get("holder") == me:
        write_local(record)
        print("ADOPTED (already held by this session) %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
        return 0
    if not is_stale(record, at):
        print("BUSY " + describe(record, at) + " — not stale, nothing to adopt")
        return 2
    if print_token:
        print("holder token %s — export it as DEVSTRIDE_LEASE_TOKEN for heartbeat and release" % me)
    record.update({"holder": me, "user": gh_user(), "machine": socket.gethostname(), "heartbeatAt": iso(at)})
    move_ref(write_tag(record))
    write_local(record)
    print("ADOPTED %s %s" % (record.get("branch") or "-", ("#%s" % record["pr"]) if record.get("pr") else "-"))
    print("Resume: branch %s, pull request %s, phase %s" % (
        record.get("branch") or "none cut yet", ("#%s" % record["pr"]) if record.get("pr") else "none opened yet", record.get("phase")))
    return 0


COMMANDS = {"claim": cmd_claim, "status": cmd_status, "heartbeat": cmd_heartbeat, "release": cmd_release, "adopt": cmd_adopt}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: clearance-github.sh <claim [--wait] [--purpose t] | status [--short] [--json] | "
              "heartbeat <phase> [--branch b] [--pr n] | release [--force] | adopt --yes>")
        return 0 if argv else 1
    command = COMMANDS.get(argv[0])
    if command is None:
        fail("unknown command %s" % argv[0], 1)
    try:
        return command(argv[1:])
    except GhError as error:
        print("ERROR: %s" % (error.text.splitlines()[0] if error.text else "gh failed"))
        return 1


sys.exit(main(sys.argv[1:]))
PY
