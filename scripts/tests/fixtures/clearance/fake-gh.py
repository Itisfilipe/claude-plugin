#!/usr/bin/env python3
"""A fake `gh` for scripts/tests/clearance-github.sh: the few calls the built-in release clearance
provider makes to GitHub beyond git itself, served from a state directory (FAKE_GH_STATE) and
logged to calls.log. The ref, the tag objects and every push go to a real bare repository.

State files:
  prs.json       a list of {number, headRefName, state, isDraft, createdAt, mergedAt}
  user           the signed-in login (default alice)
"""
import json, os, sys

STATE = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]


def log(line):
    with open(os.path.join(STATE, "calls.log"), "a") as handle:
        handle.write(line + "\n")


def read(name, default=None):
    try:
        with open(os.path.join(STATE, name)) as handle:
            return handle.read()
    except OSError:
        return default


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

if args[:2] == ["pr", "view"]:
    number = int(args[2])
    for pr in prs():
        if pr["number"] == number:
            print(pr["state"])
            sys.exit(0)
    sys.stderr.write("gh: Could not resolve to a PullRequest (HTTP 404)\n")
    sys.exit(1)

if args[:2] == ["pr", "list"]:
    state = args[args.index("--state") + 1]
    fields = args[args.index("--json") + 1].split(",")
    rows = [{k: pr.get(k) for k in fields} for pr in prs() if pr["state"].lower() == state]
    print(json.dumps(rows))
    sys.exit(0)

sys.stderr.write("fake gh: unexpected call: %s\n" % " ".join(args))
sys.exit(9)
