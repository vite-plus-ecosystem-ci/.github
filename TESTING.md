# vite-plus ecosystem-ci: testing rules and guidelines

This document gives the rules for smoke-testing [vite-plus](https://github.com/voidzero-dev/vite-plus) pre-releases against real-world apps. This org holds forks of real projects. To validate a release candidate, upgrade these forks to that candidate. Then confirm that each fork still installs, builds, and tests.

This document is the source of truth. The vite-plus `release-manager` skill links here and stays minimal. The catalog and the setup rules can therefore change here without a change to vite-plus.

## Mandatory rule: test PRs target the fork, never the upstream

**Open every test PR against the `vite-plus-ecosystem-ci` fork. Never open one against the original upstream repo.** This rule has no exceptions. A smoke-test PR is a vite-plus version bump. A bump opened against `vuejs/core`, `cloudflare/vinext`, or `varletjs/varlet` sends noise to real maintainers, and it can disclose a prerelease.

Two things make the wrong target easy to hit. `gh pr create` inside a fork **uses the parent (upstream) as its default base repo**. These clones also have a `source` remote that points to the upstream. Use these commands to prevent the mistake:

```bash
name=<name>; branch=<tracked-branch>          # from ecosystem.json
cd ~/git/github.com/vite-plus-ecosystem-ci/$name

gh repo set-default vite-plus-ecosystem-ci/$name        # pin gh's base repo to the fork

git switch -c test/bump-vp-<version> "$branch"          # test branch off the tracked branch
# ... apply the vite-plus bump, commit ...
git push -u origin test/bump-vp-<version>

# open the PR explicitly against the fork, base = the tracked branch:
gh pr create --repo vite-plus-ecosystem-ci/$name --base "$branch" \
  --head test/bump-vp-<version> --title "test: vite-plus <version>" --fill
```

Check the target before you submit the PR, and again after you submit it. The URL must contain `vite-plus-ecosystem-ci`. It must never contain the upstream owner:

```bash
gh pr view --repo vite-plus-ecosystem-ci/$name --json url --jq .url
```

`scripts/setup-local.sh` runs `gh repo set-default` on every clone that it sets up. `gh pr create` then uses the fork as its default.

## Catalog

[`ecosystem.json`](./ecosystem.json) is the machine-readable list of forks. Each entry has these fields:

| field | meaning |
| --- | --- |
| `name` | fork repo name under this org |
| `upstream` | original `owner/repo` the fork tracks |
| `branch` | the branch to test (**often NOT the fork default branch**) |
| `packageManager` | `pnpm` \| `npm` \| `yarn` \| `bun` \| `node` (no committed lockfile) \| `other` (non-JS) |
| `monorepo` | workspace / `packages` layout present |
| `notes` | free-form (e.g. "CI runs on push only") |

The set of forks changes over time, because maintainers add repos and remove repos. Use `ecosystem.json` as the authoritative list. Keep it in agreement with the actual org repos. `scripts/setup-local.sh` and `scripts/enable-actions.sh` read this file. "Maintaining the catalog" below gives a drift check.

## Why a plain `gh repo clone` is not enough

These forks have three properties that are easy to miss:

1. **The tracked branch is often not the default branch.** `gh repo clone` checks out the fork's default branch, which the fork inherits from upstream. For several repos that branch is the wrong branch to test. For example, `vue-core` tracks `minor`, `varlet` tracks `dev`, `Ivy-Framework` tracks `development`, `media-processors` tracks `develop`, `vueleaflet` tracks `next`, and seven repos track `master`. Always check out the `branch` value from `ecosystem.json`.
2. **The fork name can differ from the upstream repo name.** Maintainers create forks with `--fork-name` to keep a stable, unambiguous name. For example, `vue-core` comes from `vuejs/core`, `oxc-playground` comes from `oxc-project/playground`, and `dotabod-backend` comes from `dotabod/backend`.
3. **You must enable GitHub Actions on the fork.** If Actions stays off, fork CI never runs. New forks start with Actions off. Scheduled workflows keep the `disabled_fork` state even after you turn on the repo-level setting, because that setting does not activate them.

## Verify locally

### 1. Get a local checkout on the right branch

Clone into one parent directory, so that one step can remove the whole test environment. Set two remotes: `origin` for the fork, and `source` for the upstream.

```bash
DEST=~/git/github.com/vite-plus-ecosystem-ci
name=<name>; branch=<branch>; upstream=<owner/repo>   # from ecosystem.json

git clone git@github.com:vite-plus-ecosystem-ci/$name.git "$DEST/$name"
git -C "$DEST/$name" checkout "$branch"                 # REQUIRED: land on the tracked branch
git -C "$DEST/$name" remote add source git@github.com:$upstream.git
```

The script does the same steps from the manifest, for one repo or for all of them:

```bash
scripts/setup-local.sh <name>     # one repo
scripts/setup-local.sh --all      # every repo in ecosystem.json
# cleanup after a release:
rm -rf ~/git/github.com/vite-plus-ecosystem-ci
```

### 2. Make sure Actions is enabled on the fork

```bash
scripts/enable-actions.sh <name>
```

These commands do the same work by hand:

```bash
name=<name>
gh api -X PUT repos/vite-plus-ecosystem-ci/$name/actions/permissions -F enabled=true -f allowed_actions=all
gh api repos/vite-plus-ecosystem-ci/$name/actions/workflows \
  --jq '.workflows[] | select(.state=="disabled_fork") | .id' \
| while read -r id; do
    gh api -X PUT repos/vite-plus-ecosystem-ci/$name/actions/workflows/$id/enable
  done
gh api repos/vite-plus-ecosystem-ci/$name/actions/workflows \
  --jq '[.workflows[]|select(.state!="active")]|length'   # want 0
```

### 3. Run the smoke test

Run the vite-plus harness against the local checkout. The `release-manager` skill gives the release-specific arguments.

```bash
# from a vite-plus checkout:
.github/scripts/test-pkg-pr-new-migrate.sh <PR#> ~/git/github.com/vite-plus-ecosystem-ci/<name> --no-interactive
```

**How to choose a target.** Select a fork whose stack matches the risk area of the release. Query `ecosystem.json`:

```bash
jq -r '.repos[] | select(.packageManager=="bun") | .name' ecosystem.json          # bun install-path changes
jq -r '.repos[] | select(.monorepo) | .name' ecosystem.json                       # catalog / workspace changes
jq -r '.repos[] | select(.packageManager=="other") | "\(.name) (\(.upstream))"' ecosystem.json  # native / non-JS
```

Select a fork whose pinned `vite-plus` version is the immediately previous release. Migrate then does a real upgrade instead of no work.

**A failed local migrate is a starting point, not a verdict.** When a full-catalog sweep drives this harness, it is tempting to gate the fork-PR step on a clean local run and skip whatever failed. Do not stop there. Most of these failures are one-line config problems in the project, not vite-plus problems: see "Supply-chain gates that reject the preview build" and "Forks pinning an old pnpm". Fix each one on the test branch, rerun the migrate, and open the PR. A skipped fork contributes nothing to the release signal, and the skip is invisible in a pass/fail tally.

## Smoke-test via a fork PR (CI)

A local `vp migrate` does not exercise the project's own CI. To do that, open a draft PR on the fork. The CI of that fork then runs against the prerelease. The mandatory rule above still applies: the PR targets the fork, never the upstream.

### 1. Sync from source, then branch

Always start the test branch from the latest upstream code. Do not start it from the fork branch, which can be stale. First sync the tracked branch from the `source` remote. Then create the test branch from it:

```bash
name=<name>; branch=<tracked-branch>; version=<vite-plus-prerelease>   # branch from ecosystem.json; version = the build under test
cd ~/git/github.com/vite-plus-ecosystem-ci/$name
git fetch source
git switch -c "update-vite-plus-prerelease-test-$version" "source/$branch"
```

**Fast-forward the fork's tracked branch to upstream first.** A branch off `source/$branch` is not sufficient. The PR uses the *fork's* branch as its base. If that base is stale, the PR contains every upstream commit since the last sync, and not only the upgrade. Sync the base before you open PRs. Skip any fork whose branch has commits that the upstream does not have. Do not overwrite such a branch.

```bash
git rev-list --left-right --count "origin/$branch...source/$branch"   # left = fork-only commits; must be 0 to sync
git push --no-verify origin "source/$branch:refs/heads/$branch"
```

GitHub does not calculate the merge base again when the base branch moves. If you already opened a PR against a stale base, close that PR and open it again. This forces a new merge-base calculation. A draft PR stays a draft after you open it again.

**Check the divergence again immediately before you open each PR.** Do not check it only at the start of the run. A full-catalog sweep takes hours. An active upstream can add more than 80 commits in that time. A fork that you synced at the start is therefore stale when its PR runs. A PR on a stale base differs from the release under test in two ways at the same time. You cannot then assign a cause to a failure.

Branch name convention (required): **`update-vite-plus-prerelease-test-{version}`**. The `{version}` value is the vite-plus prerelease under test. It is a preview build `0.0.0-commit.<sha>`, or a tagged prerelease such as `0.2.3-alpha.1`.

Some projects apply their own branch-name policy in CI, and that policy can reject the required name. When a `Validate branch name` check fails, read the required pattern from the job log. Then rename the branch for that project only. The convention above still applies to every other project. For example, a conventional-commit pattern such as `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)/[a-z0-9]+(-[a-z0-9]+)*$` rejects the dots in `0.0.0-commit.<sha>`. Remove the dotted version and keep only the sha:

```bash
git branch -f "test/vite-plus-prerelease-<sha>" "update-vite-plus-prerelease-test-$version"
git push --no-verify -f origin "test/vite-plus-prerelease-<sha>"
```

You cannot change the head branch of a PR after you create it. Close the original PR. Then open a new PR from the renamed branch. The rename also lets jobs run that the branch-name gate had skipped, and those jobs can then report failures of their own.

### 2. Apply the upgrade

Upgrade vite-plus on that branch. For example, run `vp migrate` from the preview build; see the release-manager skill or the local harness. Commit only the files that the upgrade changes. These are usually `package.json` and the bridge `.npmrc`. Force-add `.npmrc` if the project ignores it in `.gitignore`. Never commit `node_modules`. Projects that commit no lockfile do a fresh install in CI.

**Run `vp fmt` before you commit.** A new oxfmt version formats files that the previous version did not format. Code that the upgrade did not touch can therefore fail a check. Projects whose CI runs `vp check` (or `vp fmt --check`) fail this way. `vp fmt` corrects those files first and adds them to the upgrade commit. Only genuine failures then remain in CI:

```bash
vp fmt
git add -A && git commit --amend --no-edit --no-verify
```

`vp migrate` installs Vite+ git hooks. The project's own pre-commit and pre-push checks then run against the test commit. Those checks can block the commit because of lint or type errors that are already in the project. Use `--no-verify` on both `git commit` and `git push` for these test commits.

**Keep the commit subject short.** The obvious subject is `test: upgrade vite-plus to prerelease 0.0.0-commit.<40-char sha>`. It is more than 70 characters, so it fails commitlint's default `header-max-length` of 72 on every project that runs commitlint. That red check comes from the test commit itself, not from the project. Put the version in the commit body instead:

```bash
git commit --no-verify -m "test: upgrade vite-plus prerelease" \
  -m "vite-plus 0.0.0-commit.<sha>, via the ecosystem-ci smoke test."
```

### 3. Draft PR on the fork, assigned to the release manager

Open the PR **as a draft**. Use the tracked branch as the base. Open it under `vite-plus-ecosystem-ci`. **Assign it to the release manager**:

```bash
gh pr create --repo vite-plus-ecosystem-ci/$name --base "$branch" \
  --head "update-vite-plus-prerelease-test-$version" --draft \
  --assignee <release-manager> \
  --title "test: vite-plus prerelease $version" \
  --body "Ecosystem-ci smoke test. Draft / do not merge."

# confirm the PR is within the fork (never upstream):
gh pr view <PR#> --repo vite-plus-ecosystem-ci/$name --json isCrossRepository --jq '.isCrossRepository'   # must be false
```

### 4. Collect links and watch CI

After all PRs are open, list them in a table for review. Give the project, the PR link, the base, the prerelease, the assignee, and the CI status. Then check the CI of each PR for failures that the **upgrade** caused:

```bash
gh pr checks <PR#> --repo vite-plus-ecosystem-ci/$name
```

An upgrade failure has two marks: the prerelease does not resolve, build, or test, and the error text names the prerelease version. Other failures come from the project itself or from the infrastructure. Examples are a missing database service, a network error, or unrelated lint. Read the log when a job fails during install:

```bash
gh api repos/vite-plus-ecosystem-ci/$name/actions/jobs/<job-id>/logs
```

## Filtering irrelevant fork-CI failures

Across the full catalog, most red checks say nothing about the release. Put every failure into one of the classes below before you make a conclusion. Then report the count for each cause. Do not report only "N failed". `ecosystem.json` records the known per-repo cases in `notes`, so read those first.

**1. Registry-bridge fetch flakes.** These are re-runnable, and they are the most common false alarm. The bridge sometimes drops tarball requests under load. pnpm then reports `error (23). Will retry`, or the install fails with `ECONNRESET  aborted`. The platform binding is the dangerous case, because `@voidzero-dev/vite-plus-<platform>` is an **optional** dependency. When its download uses all of pnpm's retries, pnpm skips the package and still reports a successful install. The job then fails much later, at the first command that loads the binding:

```
Error: Cannot find native binding. npm has a bug related to optional dependencies
(https://github.com/npm/cli/issues/4828). Please try `npm i` again after removing
both package-lock.json and node_modules directory.
  cause: Cannot find module '@voidzero-dev/vite-plus-linux-x64-gnu'
```

**Read this message carefully. It reports a local `node_modules` resolution failure. It says nothing about the registry.** Node reports only that the package is absent from this install. Nothing in this message checked the registry. NAPI's generated loader adds the sentence about the npm optional-dependency bug to every binding-load failure. That sentence points the reader to a packaging or publishing cause, which is almost always the wrong cause here. The bridge publishes every platform package for every commit build. The packument URL serves the package correctly while CI fails in this way.

Confirm the state instead of an assumption:

```bash
VERSION=0.0.0-commit.<sha>
curl -s "https://registry-bridge.viteplus.dev/@voidzero-dev%2fvite-plus-linux-x64-gnu" \
  | python3 -c "import json,sys; print('$VERSION' in json.load(sys.stdin)['versions'])"
```

`True` shows that the bridge published the package and that the install dropped it. The failure is then a flake, so re-run the job:

```bash
gh run rerun <run-id> --failed --repo vite-plus-ecosystem-ci/$name
```

Only `False` shows a publishing problem. Always search the install step for `error (23)` and `ECONNRESET` before you give this failure a different cause.

**2. Preview-build artifacts.** The `0.0.0-commit.<sha>` version string itself causes these failures. They cannot occur for a real npm release. The recurring ones are:

- pnpm `ERR_PNPM_TRUST_DOWNGRADE` ("possible package takeover")
- npm `ETARGET` or `notarget`
- bun and pnpm minimum-release-age (`ERR_PNPM_NO_MATURE_MATCHING_VERSION`)
- `ERR_PNPM_TARBALL_URL_MISMATCH`, or a failed supply-chain policy check against the bridge tarball URLs
- `ERR_PNPM_INVALID_PEER_DEPENDENCY_SPECIFICATION`, when a project declares `vite` as a peer dependency
- a Docker build whose context does not contain the bridge `.npmrc`

**3. Fork infrastructure.** The fork is not the upstream repo, so it does not have the secrets and app installations of the upstream. The recurring cases are:

- `The app https://github.com/apps/pkg-pr-new is not installed on vite-plus-ecosystem-ci/<repo>`
- `Failed to replace env in config: ${NODE_AUTH_TOKEN}`
- `Password required` from a container-registry login
- a third-party service such as CodSpeed that returns `401 Unauthorized`

Do not fix these for each release. Record them in `notes`. Most of them are in the "Checks that count as passing" list below, so a fork that fails only these checks scores as a pass.

**4. Project policy checks that a bot PR can never satisfy.** For example:

- a `check-label` job that requires a `changelog:***` label
- a commitlint rule that rejects the long `test: upgrade vite-plus to prerelease 0.0.0-commit.<sha>` subject
- a `Validate branch name` job that rejects the dots in the required `update-vite-plus-prerelease-test-<version>` branch name; "Smoke-test via a fork PR" gives the per-project rename
- a `knip` or `check-overrides` meta-check that fails when dependencies change

**5. Project-side breakage that a regenerated lockfile exposes.** The harness deletes the lockfile. A package that resolved a dependency only through hoisting then fails, because the project never declared that dependency. This is not a vite-plus problem. **Search for both phrasings**, because the wording depends on the module system and one pattern alone is easy to miss. ESM reports `Cannot find package 'oxfmt' imported from ...`. CJS reports `Cannot find module 'esbuild'`. The importer is not always the project's own code. A third-party package can also import a bare specifier that only hoisting resolved before.

**6. Stale pins.** A fork pinned several releases back, for example to `0.1.x`, does not test the release under review. `vp migrate` then does a multi-release jump, and any type error is evidence about that jump instead of the candidate. **Give the most weight to the forks pinned to the immediately previous release.** Re-pin stale forks between releases.

A failure is a regression only when it occurs on the candidate and does **not** occur on the previous release. Prove this with an isolated control. Do not assert it:

```bash
VP_HOME=$HOME/.cache/vp-control-<prev> VP_VERSION=<prev> VP_NODE_MANAGER=no bash packages/cli/install.sh
cd <project> && VP_HOME=$HOME/.cache/vp-control-<prev> VP_NODE_MANAGER=no \
  PATH="$HOME/.cache/vp-control-<prev>/bin:$PATH" vp migrate <project> --no-interactive
```

Run the control from **inside the project directory**. If you run it from a vite-plus checkout, `vp` resolves the local `packages/cli/dist` and not the pinned release. That result is not a valid comparison.

## Making a fork's CI usable

Apply the two fixes below to the **test branch only**. Never apply them to the tracked branch. The tracked branch must differ from upstream only by the changes that a release test needs.

### Forks with no PR CI

Some forks have no workflow that a `pull_request` event triggers. The test PR then reports "no checks", and it proves nothing. Add a minimal build workflow to the test branch. That workflow must exercise the pinned vite-plus, and it must use the setup that the project already uses:

```yaml
# .github/workflows/ecosystem-ci-build.yml
name: ecosystem-ci build
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: voidzero-dev/setup-vp@v1
        with:
          node-version: '24'
          cache: false
          run-install: true
      - run: vp run build
```

Use `vp run build`, so that the job goes through the project's own `build` script. Record the repo in `notes`.

### Forks on third-party runners

A self-hosted or third-party runner label resolves only for the upstream org. On a fork, every job then waits in the queue, and the PR never reports a result. Change the labels to the GitHub-hosted equivalents on the test branch:

| Third-party label | GitHub-hosted |
| --- | --- |
| `blacksmith-32vcpu-ubuntu-2404` | `ubuntu-24.04` |
| `blacksmith-32vcpu-ubuntu-2404-arm` | `ubuntu-24.04-arm` |
| `blacksmith-32vcpu-windows-2025` | `windows-2025` |
| `blacksmith-12vcpu-macos-15` | `macos-15` |

Replace the longest label first. Replace the `-arm` label before the plain label, so that no partly rewritten string remains. Runner-specific **actions** need more work than a label change, and that work is usually not worth the cost. Examples are `useblacksmith/begin-testbox`, `useblacksmith/run-testbox`, and cache actions of the same provider. Leave those jobs in the failed state, and record them in `notes`.

### Supply-chain gates that reject the preview build

A project can configure its package manager to refuse a package that is new or that lacks provenance. The install then fails before any test runs, so the fork produces no signal at all. Do not report these as failures and move on. Fix each one on the test branch, then rerun the migrate. Every fix below is a one-line config change.

| Gate | Error you see | Test-branch fix |
| --- | --- | --- |
| pnpm `trustPolicy: no-downgrade` | `ERR_PNPM_TRUST_DOWNGRADE ... (possible package takeover)` | Add `trustPolicyExclude: [vite-plus, "@voidzero-dev/*"]` to `pnpm-workspace.yaml` |
| pnpm `minimumReleaseAge` | `ERR_PNPM_...` naming a too-new version | Add the same names to `minimumReleaseAgeExclude` |
| pnpm `strictPeerDependencies: true` | `ERR_PNPM_PEER_DEP_ISSUES` | Set `strictPeerDependencies: false` |
| npm `min-release-age=N` in `.npmrc` | `npm error code ETARGET ... with a date before <date>` | Set `min-release-age=0` |
| bun `minimumReleaseAge` in `bunfig.toml` | `was published within minimum release age of N seconds` | Set `minimumReleaseAge = 0` |

Three details that cost time if you do not know them:

- **`trustPolicy` also fires on unrelated third-party packages.** pnpm compares every earlier-published version across **all** majors, so a package whose other major line has provenance trips the check ([pnpm/pnpm#10202](https://github.com/pnpm/pnpm/issues/10202)). `semver@6.3.1` and `cytoscape@3.34.1` are confirmed cases. A regenerated lockfile is what exposes them. Add the offending name to `trustPolicyExclude` too, with a comment pointing at the upstream issue.
- **Glob support differs between the two pnpm settings and bun.** `@voidzero-dev/*` matches in pnpm's `trustPolicyExclude` and `minimumReleaseAgeExclude`. It does **not** match in bun's `minimumReleaseAgeExcludes`; only exact names work there, so set `minimumReleaseAge = 0` rather than listing every platform package.
- **A release-age gate is not purely a preview-build artifact.** `trustPolicy` is, because real releases are published with provenance and bridge builds are not. A release-age gate keys off publish time, so it rejects a *real* `vite-plus@X.Y.Z` on release day too and only clears a few days later. Say which of the two you are looking at when you report it.

### Forks pinning an old pnpm

**pnpm 9.9.0 stalls forever installing through the registry bridge.** The process sits at 0% CPU with no output and no error, which reads like a vite-plus hang and is not one. The same project installs normally with a current pnpm.

Check `packageManager` in `package.json`. If it pins pnpm `<= 9.9.0`, bump it to the latest v9 on the test branch before you conclude anything:

```bash
npm view pnpm@9 version   # latest v9
```

Keep it on the same major, so the lockfile format does not change. Only bump the pin; do not touch the lockfile by hand.

## Fixing lint failures after an oxlint upgrade

A vite-plus release that bumps oxlint makes new rules fire on code that passed before. This is the single largest class of fork-CI failure after a release, and most of it is fixable. Work in this order and stop at the first step that clears the errors:

1. **`vp lint --fix`.** This clears every autofixable rule. On one project it removed 383 of 1099 errors across 160 files.
2. **Fix the code.** Use the rule's `help:` text. Prefer mechanical, behaviour-preserving edits: wrapping a concise arrow body in a block for `no-promise-executor-return`, renaming a deprecated field, rendering a looked-up component through `createElement` for `react/static-components`.
3. **Turn the rule off in the project's own config** when a code fix would change behaviour or fight an idiom the codebase uses deliberately. `.sort()` mutates in place and `toSorted()` does not, so `unicorn/no-array-sort` is not a safe mechanical rewrite. Neither is unpicking `??=` lazy init for `no-multi-assign`, nor restyling several hundred declarations for `one-var` and `sort-vars`.

Step 3 is legitimate rather than a cop-out when the project opts whole categories (`style`, `pedantic`, `restriction`, `nursery`) into `error` and then disables individual rules it disagrees with. That config shape is common, and adding one more entry follows the project's own intent. Check whether it already disables sibling rules such as `sort-imports` and `sort-keys`.

Three traps:

- **A `rules` key added after a spread replaces the whole inherited map.** With `lint: { ...config.lint, rules: { ... } }` you silently drop every rule the shared config disabled; one project went from 5 errors to over 2600. Always spread first: `rules: { ...config.lint?.rules, 'my-rule': 'off' }`.
- **Ignore errors that only exist locally.** `Cannot find module '../../dist/...'`, an unbuilt workspace package, or an ungenerated Prisma client are artifacts of not having run the project's build. CI builds first and never sees them. Do not chase them.
- **Re-lint and re-test after every code fix, and baseline the failures.** Dropping an unused `test.each` callback parameter breaks the callback's arity and produces fresh type errors. Before blaming your edit for a failing test, stash your changes and rerun: several of these projects have pre-existing failures.

## CI caveats

- A `push` event triggers the CI of some forks, and a `pull_request` event does not. `notes` flags these forks; `codiff` and `delta-comic` are examples. A PR against them does not run their CI. If you need PR CI, add a `pull_request` trigger to the `on:` block of the workflow **inside the ecosystem-ci PR**. Do not add it as a separate commit on the tracked branch. The fork then stays clean against upstream.
- Keep the tracked branch clean. Do not commit unrelated changes to it. It must differ from upstream only by the changes that a release test needs.
- **Do not run `vp fmt` blindly before committing.** The advice to run it exists because a newer oxfmt formats files the previous one left alone. On a project that oxfmt has never formatted, it rewrites the whole tree: one commit reached 562 files and 73k lines, which buries the upgrade and makes the PR unreviewable. Check `git diff --stat` first. If the count is far above the file count that `vp migrate` reported as rewritten, drop the `vp fmt` and commit the migration alone.
- **A non-standard installer does not resolve preview builds.** The preview-build smoke test needs the project's CI to resolve `vite-plus@0.0.0-commit.<sha>` through the registry bridge in `.npmrc`. This works for npm, pnpm, yarn, and bun. It fails for an installer that ignores the `registry=` line in `.npmrc` or that uses its own registry. `cnpmcore` is the known case: its CI installs with `utoo` (`ut`, through `utooland/setup-utoo`), which resolves against public npm and returns a 404 for the commit build (`No matching version found ... from N available versions`). Check the CI install step of a candidate repo before you trust its fork-CI result. Record each known case in `notes`.
- **A registry-scanning proxy can also block the bridge.** A CI that installs behind a supply-chain proxy, such as Socket Firewall (`sfw vp install`), can fail to reach `registry-bridge.viteplus.dev` at all and report `ERR_PNPM_META_FETCH_FAIL` / `ERR_PNPM_RESOLVING_NPM_RESOLVER_NETWORK_ERROR`. Confirm the bridge itself is healthy with `curl` before you call it a bridge outage. A real npm release resolves from `registry.npmjs.org` and is unaffected.

## Maintaining the catalog

### Add a repo

```bash
upstream=<owner/repo>; name=<fork-name>; branch=<branch>

# 1. fork with a stable name, keeping all branches so a non-default tracked branch is included
gh repo fork "$upstream" --org vite-plus-ecosystem-ci --fork-name "$name" --clone=false

# 2. enable Actions
scripts/enable-actions.sh "$name"

# 3. add an entry to ecosystem.json (name, upstream, branch, packageManager, monorepo, notes)
```

Set the fields as follows.

- **`packageManager`.** Use the `packageManager` field of `package.json` when the project has one. Only when that field is absent, derive the value from the committed lockfile: `pnpm-lock.yaml` gives pnpm, `bun.lock*` gives bun, `yarn.lock` gives yarn, `package-lock.json` gives npm, a `package.json` alone gives node, and no such file gives other. The lockfile alone is not reliable, because some repos ignore their lockfile in `.gitignore`. For example, `cnpmcore` commits no lockfile and declares `npm`.
- **The CI install step.** Check how the project's CI installs dependencies, because a non-standard installer breaks the preview-build smoke test. `cnpmcore`'s CI installs with `utoo` (`ut`), which does not resolve `vite-plus@0.0.0-commit.<sha>` through the bridge `.npmrc`. Its smoke test therefore fails during dependency resolution. Record this in `notes`.
- **`monorepo`.** Set this field when the project has a `workspaces` field, a `pnpm-workspace.yaml` file, or a `packages/` directory.

### Remove a repo

Delete the entry of the repo from `ecosystem.json`. You can also delete the fork with `gh repo delete vite-plus-ecosystem-ci/<name>`, but the fork does no harm, and tooling reads only the manifest. Add a line to "Excluded repos" below. The next person then does not add the repo again and repeat the work.

### Excluded repos

These repos are deliberately out of the catalog. Do not add one again before you correct the cause.

| Repo | Why |
| --- | --- |
| `vize` (`ubugeeei/vize`) | Its CI cannot give a usable release signal. Every workflow targets Blacksmith runners that do not resolve on a fork, so every job waits in the queue until you rewrite the labels. `e2e.yml` also uses `useblacksmith/*` actions, which a label change cannot fix. The `app-readiness` E2E matrix then stays in the failed state. Upstream also moves fast, more than 80 commits in a day, so a fork synced at the start of a release is stale when the PR runs. The cost to keep this fork green is more than the value of its signal. |
| `cnpmcore` (`cnpm/cnpmcore`) | Its CI installs with `utoo` (`ut`, through `utooland/setup-utoo`). `utoo` ignores the bridge `registry=` line in `.npmrc` and resolves against public npm, so a `0.0.0-commit.<sha>` build returns a 404. Every job then fails, and 135 test files fail, for a cause that cannot occur with a real npm release. Its fork CI gives no information for a preview-build smoke test. |
| `mlx-node` (`huggingface/mlx-node`) | Both failing jobs are Rust jobs (`cargo test`, `-p mlx-core --test kquant_ggml_parity`), and they do not exercise vite-plus. Its JS surface is too small for the triage cost. |
| `tech-interview-handbook` (`yangshun/tech-interview-handbook`) | This Docusaurus site fails its build with a webpack error, `ProgressPlugin ... does not match the API schema`, which is unrelated to vite-plus. It has no passing check to balance that failure. |

### Checks that count as passing

The four classes of failing check below **count as passing** when you score a fork. Each one fails only because the PR is a bot PR on a fork. None of them gives information about the vite-plus release. A fork whose red checks are all in this list is a **pass**, not a partial failure. Do not triage them again for each release. `notes` records the per-repo cases.

| Class | How it presents | Why it never means anything |
| --- | --- | --- |
| `pkg-pr-new` publish jobs | `The app https://github.com/apps/pkg-pr-new is not installed on vite-plus-ecosystem-ci/<repo>`. Often inside a job named `build`, not a job named after the app. | This org deliberately does not install the App. |
| commitlint / commit-message checks | `header-max-length`, `subject may not be longer than ...` | The test commit's own subject causes it, not the project's code. Keep the subject short (see "Apply the upgrade"), and count any remaining hit as a pass. |
| Third-party benchmark and coverage uploads | CodSpeed and similar services that fail with `401 Unauthorized`, or an installer hash-pin mismatch | The fork has no token for the service. |
| Docker image build/push jobs | `Password required`, `buildx failed`, or `ERR_PNPM_TARBALL_URL_MISMATCH` inside an image build | The fork has no registry credentials. A Docker build context also does not contain the bridge `.npmrc`, so a preview build cannot resolve inside the image. |

Every other check still needs triage. These four are deliberately **not** in the list, and you must read them: PR-label gates, branch-name policy jobs, `knip` and `check-overrides` meta-checks, and jobs that need a plain repository token (`Input required and not supplied: token`). They are usually noise, but each one is specific to its project, so read it.

### Classify by the most specific cause, not the first pattern that matches

Match real causes **before** generic infrastructure and policy patterns. A job log often names `commitlint` or `knip` in a step while the job fails for a different reason. A filter that tests the policy patterns first therefore files real findings as noise, and it gives no warning. Use this order, most specific first:

1. `Lint or type issues found` (newer oxlint), `linter rules JSON is out of date` (oxlint ruleset drift)
2. `Cannot find package '<x>'` or `Cannot find module '<x>'` (undeclared dependency, or a third-party package that imports a bare specifier)
3. `error TS...` (project type errors)
4. test-runner and browser failures (`page.waitForSelector: Timeout`, absent spy matchers under Deno)
5. `Cannot find native binding`, `error (23). Will retry`, `ECONNRESET` (bridge flake, re-run the job)
6. then the counts-as-passing classes above, then policy gates, then `The operation was canceled` (fail-fast collateral)

Check each classification against the log of that failing job. Do not use the log of the repo's first failing job. A repo with several red checks usually has several different causes. If you read only the first log, you give every failure the cause of that one job.

### Drift check (manifest vs actual org repos)

**Run this before a release sweep, not only when maintaining the catalog.** Every tool here iterates `ecosystem.json`, so an org fork that is missing from the manifest is skipped in silence and nobody notices until someone asks why a given project has no PR.

```bash
comm -3 \
  <(jq -r '.repos[].name' ecosystem.json | sort) \
  <(gh repo list vite-plus-ecosystem-ci --limit 500 --json name --jq '.[].name' | grep -v '^\.github$' | sort)
# left-only  = in manifest but not in org (stale entry)
# right-only = fork exists but is not catalogued
```

Every right-only name must be either in the manifest or in "Excluded repos" with a reason. Anything else is an accidental gap: add it, or exclude it explicitly. Two names resolve to something benign and are worth knowing: `playground` is the real name of the `oxc-playground` entry (GitHub redirects the old name), and the excluded repos stay in the org on purpose.

### Detached forks

Some org repos report `parent: null`, so GitHub does not treat them as forks. `gh repo fork` cannot re-link one, and `scripts/setup-local.sh` cannot derive its `source` remote. Detect and repair by hand:

```bash
gh repo view vite-plus-ecosystem-ci/<name> --json parent --jq '.parent.nameWithOwner // "DETACHED"'
git -C "$dir" remote add source git@github.com:<upstream>.git
```

Record the upstream in the manifest entry as usual, and note the detachment in `notes` so the next person does not retry `gh repo fork`. These repos drift the furthest, because nothing syncs them: one was 122 commits behind. Fast-forward it before testing, exactly as for a normal fork.

## How vite-plus references this

The smoke-test step of the `release-manager` skill links here. It does not contain the catalog or the setup steps:

> Smoke-test targets and local setup: https://github.com/vite-plus-ecosystem-ci/.github/blob/main/TESTING.md . Pick a target from `ecosystem.json`, clone on its tracked branch (`scripts/setup-local.sh <name>`), then run `test-pkg-pr-new-migrate.sh`. To validate in the fork's CI, follow "Smoke-test via a fork PR": branch `update-vite-plus-prerelease-test-<version>` synced from `source`, open a draft PR on the fork assigned to the release manager, then watch CI. Any test PR must be opened against the `vite-plus-ecosystem-ci` fork, never the upstream repo.

This split keeps the changes that happen often, such as which repos exist and which branch each one tracks, in this document. It keeps the release process in vite-plus.
