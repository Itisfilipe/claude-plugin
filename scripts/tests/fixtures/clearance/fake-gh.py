#!/usr/bin/env python3
"""A fake `gh` for scripts/tests/clearance-github.sh: the handful of calls the built-in release
clearance provider makes, served from a state directory (FAKE_GH_STATE) and logged to calls.log.

State files:
  ref            the sha the clearance ref points at (absent = the ref does not exist)
  tags/<sha>     the tag object's message (the clearance record JSON)
  prs.json       a list of {number, headRefName, state, isDraft, createdAt, mergedAt}
  user           the signed-in login (default alice)
  fail-ref-create   when present, POST git/refs answers 403 (a ruleset blocking ref creation)
  race           a sha: the next POST git/refs first makes the ref point at it, then answers 422
"""
import hashlib, json, os, sys

STATE = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]


def log(line):
    with open(os.path.join(STATE, "calls.log"), "a") as handle:
        handle.write(line + "\n")


def path(*parts):
    return os.path.join(STATE, *parts)


def read(name, default=None):
    try:
        with open(path(name)) as handle:
            return handle.read()
    except OSError:
        return default


def http_error(status, text):
    sys.stderr.write("gh: %s (HTTP %d)\n" % (text, status))
    sys.exit(1)


def prs():
    try:
        return json.loads(read("prs.json") or "[]")
    except ValueError:
        return []


log(" ".join(args))

if args[:3] == ["repo", "view", "--json"]:
    print("o/r")
    sys.exit(0)

if args[:2] == ["api", "user"]:
    print(read("user", "alice").strip())
    sys.exit(0)

if args[:1] == ["api"]:
    method = "GET"
    rest = args[1:]
    if rest[:1] == ["-X"]:
        method, rest = rest[1], rest[2:]
    endpoint = rest[0]
    body = json.loads(sys.stdin.read() or "{}") if "--input" in rest else {}
    if endpoint == "repos/o/r/git/ref/heads/master" and method == "GET":
        print(json.dumps({"object": {"sha": "c0ffee00"}}))
    elif endpoint == "repos/o/r/git/tags" and method == "POST":
        message = body.get("message", "")
        sha = hashlib.sha1((message + str(os.stat(STATE).st_mtime_ns) + str(len(os.listdir(path("tags")) if os.path.isdir(path("tags")) else []))).encode()).hexdigest()[:12]
        os.makedirs(path("tags"), exist_ok=True)
        with open(path("tags", sha), "w") as handle:
            handle.write(message)
        print(json.dumps({"sha": sha}))
    elif endpoint == "repos/o/r/git/refs" and method == "POST":
        if os.path.exists(path("fail-ref-create")):
            http_error(403, "Resource not accessible by integration")
        if os.path.exists(path("race")):
            # Another claimant won between this caller's read and its create.
            os.rename(path("race"), path("ref"))
        if os.path.exists(path("ref")):
            http_error(422, "Reference already exists")
        with open(path("ref"), "w") as handle:
            handle.write(body["sha"])
        print(json.dumps({"ref": body["ref"], "object": {"sha": body["sha"]}}))
    elif endpoint == "repos/o/r/git/ref/clearance/release" and method == "GET":
        sha = read("ref")
        if sha is None:
            http_error(404, "Not Found")
        print(json.dumps({"ref": "refs/clearance/release", "object": {"sha": sha.strip(), "type": "tag"}}))
    elif endpoint.startswith("repos/o/r/git/tags/") and method == "GET":
        message = read(os.path.join("tags", endpoint.rsplit("/", 1)[1]))
        if message is None:
            http_error(404, "Not Found")
        print(json.dumps({"message": message}))
    elif endpoint == "repos/o/r/git/refs/clearance/release" and method == "PATCH":
        if read("ref") is None:
            http_error(422, "Reference does not exist")
        with open(path("ref"), "w") as handle:
            handle.write(body["sha"])
        print(json.dumps({"object": {"sha": body["sha"]}}))
    elif endpoint == "repos/o/r/git/refs/clearance/release" and method == "DELETE":
        if read("ref") is None:
            http_error(422, "Reference does not exist")
        os.remove(path("ref"))
    else:
        sys.stderr.write("fake gh: unexpected api call: %s %s\n" % (method, endpoint))
        sys.exit(9)
    sys.exit(0)

if args[:2] == ["pr", "view"]:
    number = int(args[2])
    for pr in prs():
        if pr["number"] == number:
            print(pr["state"])
            sys.exit(0)
    http_error(404, "Could not resolve to a PullRequest")

if args[:2] == ["pr", "list"]:
    state = args[args.index("--state") + 1]
    fields = args[args.index("--json") + 1].split(",")
    rows = [{k: pr.get(k) for k in fields} for pr in prs() if pr["state"].lower() == state]
    print(json.dumps(rows))
    sys.exit(0)

sys.stderr.write("fake gh: unexpected call: %s\n" % " ".join(args))
sys.exit(9)
