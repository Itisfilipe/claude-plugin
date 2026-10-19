// release-tower-check.mjs — the verdict behind the `release-tower` check: may THIS pull request
// into the production branch merge now?
//
// Written into a repository by `/devstride:setup ci` (as .github/scripts/release-tower-check.mjs)
// beside release-tower.yaml, which runs it with Node 22 and installs nothing: it imports only
// node: builtins. The repository's `.claude/ds-config.json` supplies every name and pattern, so
// the file is identical everywhere and is never edited by hand.
//
// The rule, in order:
//   base is not the production branch          → ALLOWED (this check guards production only)
//   the override label is on the pull request  → ALLOWED, naming the label
//   the head matches the hotfix pattern        → ALLOWED (nothing ever blocks a hotfix)
//   the head is a release head                 → ALLOWED when it is the OLDEST open release pull
//                                                request (lowest number), else BLOCKED: that one
//                                                is on final and this release waits
//   anything else                              → BLOCKED with the retarget line
//
// A release head is a name matching `release.releaseBranchPattern`, or — with no pattern — the
// release source branch itself. Patterns follow the plugin's branch-patterns rule (anchored; `*`
// one segment, `**` across segments, `<YY-MM-DD>`, a trailing `[-n]`).
//
//   node release-tower-check.mjs check --head <ref> --base <ref> --number <n> [--labels a,b]
//        --config <path> --open-prs <path>       one line, exit 0 ALLOWED / 1 BLOCKED / 2 usage
//   node release-tower-check.mjs reruns --event-head <ref> --number <n> --config <path>
//        --open-prs <path> --runs <path>         one run id per line: the newest finished
//                                                release-tower run of each OTHER open release
//                                                pull request, to re-run now that the queue changed
//
// `--open-prs` is `gh pr list --base <production> --state open --json number,headRefName[,headRefOid]`
// (the check fails closed when the list is as long as its limit); `--runs` is the Actions API's
// workflow runs as { databaseId, headSha, headBranch, status, pullRequests: [number] }.
import { readFileSync } from 'node:fs';

const DATE_TOKEN = /^<[A-Z]{2}-[A-Z]{2}-[A-Z]{2}>/;
/** `gh pr list --limit` in the workflow; a list this long may be truncated, so the check refuses. */
export const PR_LIST_LIMIT = 500;

export function patternToRegExp(pattern) {
  let source = '';
  let rest = pattern;
  while (rest) {
    if (rest.startsWith('**')) {
      source += '.+';
      rest = rest.slice(2);
    } else if (rest.startsWith('*')) {
      source += '[^/]+';
      rest = rest.slice(1);
    } else if (rest === '[-n]') {
      source += '(-[0-9]+)?';
      rest = '';
    } else if (DATE_TOKEN.test(rest)) {
      source += '[0-9]{2}-[0-9]{2}-[0-9]{2}';
      rest = rest.replace(DATE_TOKEN, '');
    } else {
      source += rest[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      rest = rest.slice(1);
    }
  }
  return new RegExp(`^${source}$`);
}

function record(value, what) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`.claude/ds-config.json: ${what} is missing or not an object`);
  }
  return value;
}

function text(value, what, fallback) {
  if (typeof value === 'string' && value) return value;
  if (fallback !== undefined) return fallback;
  throw new Error(`.claude/ds-config.json: ${what} is missing`);
}

/** The keys the check reads, with the plugin's shipped defaults where a key is optional. */
export function readTowerConfig(raw) {
  const config = record(raw, 'the file');
  const release = record(config.release, 'release');
  const tower = config.releaseTower === undefined ? {} : record(config.releaseTower, 'releaseTower');
  return {
    productionBranch: text(release.productionBranch, 'release.productionBranch', 'master'),
    releaseSource: text(release.releaseSource, 'release.releaseSource', 'develop'),
    baseBranch: text(config.baseBranch, 'baseBranch', text(release.releaseSource, 'release.releaseSource', 'develop')),
    releaseBranchPattern: typeof release.releaseBranchPattern === 'string' && release.releaseBranchPattern ? release.releaseBranchPattern : null,
    overrideLabel: text(tower.overrideLabel, 'releaseTower.overrideLabel', 'release-tower-override'),
    hotfixPattern: text(tower.hotfixPattern, 'releaseTower.hotfixPattern', '*/hotfix/**'),
  };
}

export function isReleaseHead(head, config) {
  return config.releaseBranchPattern ? patternToRegExp(config.releaseBranchPattern).test(head) : head === config.releaseSource;
}

export function isHotfixHead(head, config) {
  return patternToRegExp(config.hotfixPattern).test(head);
}

/**
 * The verdict for one pull request. `openPullRequests` are the open pull requests into the
 * production branch ({ number, headRefName }); this pull request may or may not be among them.
 */
export function checkReleaseTower({ head, base, number, labels, config, openPullRequests }) {
  const allow = (reason) => ({ allowed: true, line: `ALLOWED: ${reason}` });
  const block = (reason) => ({ allowed: false, line: `BLOCKED: ${reason}` });
  if (base !== config.productionBranch) return allow(`base is ${base}, not ${config.productionBranch} (this check guards ${config.productionBranch} only)`);
  if (labels.includes(config.overrideLabel)) return allow(`override label ${config.overrideLabel} present`);
  if (isHotfixHead(head, config)) return allow(`${head} is a hotfix (${config.hotfixPattern}); a hotfix is never held`);
  if (isReleaseHead(head, config)) {
    const releases = openPullRequests
      .filter((pr) => Number.isInteger(pr.number) && typeof pr.headRefName === 'string' && isReleaseHead(pr.headRefName, config))
      .filter((pr) => pr.number !== number)
      .sort((a, b) => a.number - b.number);
    const ahead = releases.find((pr) => pr.number < number);
    if (!ahead) return allow(`${head} (#${number}) is the oldest open release pull request — on final`);
    return block(`${ahead.headRefName} (#${ahead.number}) is on final; this release waits. It turns green by itself when #${ahead.number} merges or closes.`);
  }
  const shape = config.releaseBranchPattern ? `a release branch (${config.releaseBranchPattern})` : `the release source (${config.releaseSource})`;
  return block(
    `Pull requests into ${config.productionBranch} come from ${shape} or a hotfix branch (${config.hotfixPattern}). ` +
      `Retarget at ${config.baseBranch}: gh pr edit ${number} --base ${config.baseBranch}; an owner-approved exception asks for the ${config.overrideLabel} label.`
  );
}

/**
 * When the queue changes — a release pull request opened, reopened, closed or retargeted — the run
 * ids to re-run: for each OTHER open release pull request into the production branch, its newest
 * finished release-tower run for its current head. A run is matched to a pull request by the
 * pull-request numbers the Actions API records on it, else by its head branch (when that is not
 * the production branch), else by its head sha — never by sha alone while a branch is known, since
 * two release branches can share a commit. A pull request whose current head has a run still in
 * progress is left alone: that run posts the fresh verdict. Nothing when the event's head was not
 * a release head (a hotfix or a stray feature branch changes no ordering); an empty event head
 * (a manual dispatch) re-settles every open release pull request. `runs` come newest first as
 * { databaseId, headSha, headBranch, status, pullRequests: [number] }.
 */
const RUNNING = new Set(['in_progress', 'queued', 'waiting', 'pending', 'requested']);

export function selectReruns({ eventHead, eventNumber, config, openPullRequests, runs }) {
  if (eventHead && !isReleaseHead(eventHead, config)) return [];
  const ids = [];
  for (const pr of openPullRequests) {
    if (pr.number === eventNumber || !isReleaseHead(pr.headRefName ?? '', config)) continue;
    const byNumber = runs.filter((r) => Array.isArray(r.pullRequests) && r.pullRequests.includes(pr.number));
    const byBranch = runs.filter((r) => r.headBranch && r.headBranch !== config.productionBranch && r.headBranch === pr.headRefName);
    const bySha = pr.headRefOid ? runs.filter((r) => r.headSha === pr.headRefOid) : [];
    const candidates = byNumber.length ? byNumber : byBranch.length ? byBranch : bySha;
    const forHead = pr.headRefOid ? candidates.filter((r) => r.headSha === pr.headRefOid) : candidates;
    if (forHead.some((r) => RUNNING.has(r.status ?? ''))) continue;
    const run = forHead.find((r) => Number.isInteger(r.databaseId));
    if (run) ids.push(run.databaseId);
  }
  return [...new Set(ids)];
}

export function parseLabels(value) {
  return (value ?? '')
    .split(',')
    .map((label) => label.trim())
    .filter(Boolean);
}

function parseArgs(argv, allowed) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!allowed.includes(flag) || value === undefined) {
      throw new Error(`usage: unexpected or valueless argument ${flag}`);
    }
    args[flag.slice(2)] = value;
  }
  return args;
}

function readJson(path, what) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    throw new Error(`${what} (${path}): ${error instanceof Error ? error.message : String(error)}`);
  }
}

/** The script entry. Returns { lines, code }. */
export function run(argv, read = readJson) {
  const mode = argv[0];
  try {
    if (mode === 'check') {
      const args = parseArgs(argv.slice(1), ['--head', '--base', '--number', '--labels', '--config', '--open-prs']);
      for (const key of ['head', 'base', 'number', 'config', 'open-prs']) {
        if (!args[key]) return { lines: [`ERROR: --${key} is required`], code: 2 };
      }
      const number = Number(args.number);
      if (!Number.isInteger(number)) return { lines: ['ERROR: --number must be an integer'], code: 2 };
      const config = readTowerConfig(read(args.config, 'config'));
      const openPullRequests = read(args['open-prs'], 'open pull requests');
      if (!Array.isArray(openPullRequests)) return { lines: ['ERROR: --open-prs must hold a JSON array'], code: 2 };
      if (openPullRequests.length >= PR_LIST_LIMIT) {
        return { lines: [`ERROR: ${openPullRequests.length} open pull requests into ${config.productionBranch} — the list may be truncated, so the order cannot be proven`], code: 2 };
      }
      const verdict = checkReleaseTower({ head: args.head, base: args.base, number, labels: parseLabels(args.labels), config, openPullRequests });
      return { lines: [verdict.line], code: verdict.allowed ? 0 : 1 };
    }
    if (mode === 'reruns') {
      const args = parseArgs(argv.slice(1), ['--event-head', '--number', '--config', '--open-prs', '--runs']);
      for (const key of ['config', 'open-prs', 'runs']) {
        if (!args[key]) return { lines: [`ERROR: --${key} is required`], code: 2 };
      }
      const config = readTowerConfig(read(args.config, 'config'));
      const openPullRequests = read(args['open-prs'], 'open pull requests');
      const runs = read(args.runs, 'runs');
      if (!Array.isArray(openPullRequests) || !Array.isArray(runs)) return { lines: ['ERROR: --open-prs and --runs must hold JSON arrays'], code: 2 };
      const ids = selectReruns({
        eventHead: args['event-head'] ?? '',
        eventNumber: args.number === undefined ? undefined : Number(args.number),
        config,
        openPullRequests,
        runs,
      });
      return { lines: ids.map(String), code: 0 };
    }
    return { lines: ['ERROR: usage: release-tower-check.mjs <check|reruns> …'], code: 2 };
  } catch (error) {
    return { lines: [`ERROR: ${error instanceof Error ? error.message : String(error)}`], code: 2 };
  }
}

if (/(^|[/\\])release-tower-check\.mjs$/.test(process.argv[1] ?? '')) {
  const result = run(process.argv.slice(2));
  for (const line of result.lines) console.log(line);
  process.exitCode = result.code;
}
