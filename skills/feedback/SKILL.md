---
name: feedback
description: Log what a delivery-loop run on one item cost and where it went wrong, with a suggested plugin fix per problem
when_to_use: When build-item ends a run with `feedback: true` in the config, or the user runs /devstride:feedback after a build-item, review or release run, naming its work items (e.g. I107 I108).
argument-hint: "<items, e.g. I107 I108> [notes on what the user had to correct]"
context: fork
model: sonnet
effort: medium
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Record one devstride run in the feedback log. Arguments: $ARGUMENTS

The leading arguments are the run's work items, e.g. `I107 I108`; set `ITEM` to them joined by `|`. The rest are
notes. Append a `## <items> <date> <time>` section to `$(git rev-parse --git-common-dir)/devstride-feedback.md`, which git never
tracks. Under 60 lines, facts only:

- **Metrics.** Run the command below from the repo root. It prints one row per transcript and model for every
  session in this project that mentions an item (the main session, each fork, each agent): name, model, elapsed
  seconds from the first to the last call, calls, and input, cache-write, cache-read and output tokens. Output is an
  estimate (transcripts store partial counts, hidden thinking is missing); input and cache counts are exact. Codex
  and other local CLI usage is not in it; say whether one ran. Sum per skill and for the run, with the model mix.
  No rows → write `Metrics unavailable:` with the error and keep going. Call out heavy cache writes on a session's
  own row (idle gaps, model switches), a skill or review round that ran more than once, and agents whose input was
  large next to their output.
- **Flow.** From the transcripts: the skills in order, review rounds, verify reruns on an unchanged tree, hard stops,
  and how long each wait for the user took.
- **Problems and suggested fixes.** First everything the user had to notice, correct or redo, from the transcripts
  and the notes: those are quality misses. Then checks skipped or passed with a workaround, work redone (the same
  files read by several forks, tests rerun with no change in between), dismissed review findings with their lens,
  and review depth or a model that was more or less than the change needed. For each: what happened, what it cost
  (tokens, minutes, user effort, a wrong result), the skill it started in, and a concrete fix naming the file to
  change: a plugin file by its path under `${CLAUDE_PLUGIN_ROOT}`, or the repository's `.claude/ds-config.json`.
  Suggest only; never edit either.

```
C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; for S in $(grep -lE "$ITEM" "$C/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"/*.jsonl); do for f in "$S" "${S%.jsonl}"/subagents/*.jsonl; do [ -e "$f" ] || continue; jq -rs --arg f "$(basename "$f" .jsonl)" 'def secs: sub("\\.[0-9]+Z$"; "Z") | fromdate; (map(select(.type == "user"))[0].message.content | if type == "array" then map(.text? // "") | join(" ") else . end) as $p | (if ($f | startswith("agent-")) then ($p | capture("Base directory for this skill: \\S*/skills/(?<s>[a-z-]+)").s // ($p[0:40] | gsub("\\s+"; " "))) else "session \($f[0:8])" end) as $name | [.[] | select(.type == "assistant" and .message.usage)] | group_by(.message.id) | map({u: last.message.usage, model: last.message.model, ts: map(.timestamp | secs), chars: (map([.message.content[]? | (.text // .thinking // (.input | tostring)) | length] | add // 0) | add)}) | group_by(.model)[] as $c | [$name, $c[0].model, ($c | map(.ts[]) | max - min), ($c | length), ($c | map(.u.input_tokens) | add), ($c | map(.u.cache_creation_input_tokens // 0) | add), ($c | map(.u.cache_read_input_tokens // 0) | add), ($c | map([.u.output_tokens, (.chars / 4 | floor)] | max) | add)] | @tsv' "$f"; done; done
```

Reply with the path of the feedback log and one line: the run's total tokens and its biggest problem.
