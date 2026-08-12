# vite-plus ecosystem-ci: testing rules and guidelines

Canonical guidance for smoke-testing [vite-plus](https://github.com/voidzero-dev/vite-plus) pre-releases against real-world apps. This org holds forks of real projects; a release candidate is validated by upgrading these forks to the candidate and confirming they still install, build, and test.

This document is the source of truth. The vite-plus `release-manager` skill links here and stays minimal, so the catalog and the setup rules can change here without touching vite-plus.

## Mandatory rule: test PRs target the fork, never the upstream

**Every test / submission PR must be opened against the `vite-plus-ecosystem-ci` fork, never against the original upstream repo.** This is a hard rule with no exceptions. A smoke-test PR is a vite-plus version bump; opening it against `vuejs/core`, `cloudflare/vinext`, `varletjs/varlet`, etc. spams real maintainers with noise and can leak a prerelease.

The trap: `gh pr create` inside a fork **defaults its base repo to the parent (upstream)**, and these clones carry a `source` remote pointing at the upstream, so the wrong target is one careless Enter away. Guard against it:

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

Confirm the target before and after submitting; the URL must be under `vite-plus-ecosystem-ci`, never the upstream owner:

```bash
gh pr view --repo vite-plus-ecosystem-ci/$name --json url --jq .url
```

`scripts/setup-local.sh` runs `gh repo set-default` on every clone it sets up, so `gh pr create` defaults to the fork.

## Catalog

[`ecosystem.json`](./ecosystem.json) is the machine-readable list of forks. Each entry:

| field | meaning |
| --- | --- |
| `name` | fork repo name under this org |
| `upstream` | original `owner/repo` the fork tracks |
| `branch` | the branch to test (**often NOT the fork default branch**) |
| `packageManager` | `pnpm` \| `npm` \| `yarn` \| `bun` \| `node` (no committed lockfile) \| `other` (non-JS) |
| `monorepo` | workspace / `packages` layout present |
| `notes` | free-form (e.g. "CI runs on push only") |

The set changes over time (repos are added and removed). Treat `ecosystem.json` as authoritative and keep it in sync with the actual org repos (`scripts/setup-local.sh` and `scripts/enable-actions.sh` read it; a drift check is in "Maintaining the catalog" below).

## Why a plain `gh repo clone` is not enough

Three properties of these forks are easy to miss:

1. **The tracked branch is often not the default branch.** `gh repo clone` lands on the fork's default branch (inherited from upstream). For several repos that is the wrong branch to test (e.g. `vue-core` tracks `minor`, `varlet` tracks `dev`, `Ivy-Framework` tracks `development`, `media-processors` tracks `develop`, `vueleaflet` tracks `next`, and seven track `master`). Always check out `branch` from `ecosystem.json`.
2. **The fork name can differ from the upstream repo name.** Forks are created with `--fork-name` to keep a stable, unambiguous name (e.g. `vue-core` from `vuejs/core`, `oxc-playground` from `oxc-project/playground`, `dotabod-backend` from `dotabod/backend`).
3. **GitHub Actions must be enabled on the fork** or fork CI never runs. New forks start with Actions off, and scheduled/cron workflows stay `disabled_fork` even after the repo-level toggle is on (they are not auto-activated).

## Verify locally

### 1. Get a local checkout on the right branch

Clone under a single directory so the whole test environment cleans up in one step, and set two remotes: `origin` (the fork) and `source` (the upstream).

```bash
DEST=~/git/github.com/vite-plus-ecosystem-ci
name=<name>; branch=<branch>; upstream=<owner/repo>   # from ecosystem.json

git clone git@github.com:vite-plus-ecosystem-ci/$name.git "$DEST/$name"
git -C "$DEST/$name" checkout "$branch"                 # REQUIRED: land on the tracked branch
git -C "$DEST/$name" remote add source git@github.com:$upstream.git
```

Or do it straight from the manifest for one repo or all of them:

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

Equivalent by hand:

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

Use the vite-plus harness against the local checkout (see the `release-manager` skill for release-specific arguments):

```bash
# from a vite-plus checkout:
.github/scripts/test-pkg-pr-new-migrate.sh <PR#> ~/git/github.com/vite-plus-ecosystem-ci/<name> --no-interactive
```

**Choosing a target.** Pick a fork whose stack matches the release's risk area, using `ecosystem.json`:

```bash
jq -r '.repos[] | select(.packageManager=="bun") | .name' ecosystem.json          # bun install-path changes
jq -r '.repos[] | select(.monorepo) | .name' ecosystem.json                       # catalog / workspace changes
jq -r '.repos[] | select(.packageManager=="other") | "\(.name) (\(.upstream))"' ecosystem.json  # native / non-JS
```

Prefer a fork whose pinned `vite-plus` version is the immediately previous release, so migrate does a real upgrade rather than a no-op.

## Smoke-test via a fork PR (CI)

To validate a prerelease against a project's real CI (not just a local `vp migrate`), open a draft PR on the fork and let its CI run. The mandatory rule above still applies: the PR targets the fork, never upstream.

### 1. Sync from source, then branch

Always start the test branch from the latest upstream code, not the (possibly stale) fork branch. Sync the tracked branch from the `source` remote and branch off it:

```bash
name=<name>; branch=<tracked-branch>; version=<vite-plus-prerelease>   # branch from ecosystem.json; version = the build under test
cd ~/git/github.com/vite-plus-ecosystem-ci/$name
git fetch source
git switch -c "update-vite-plus-prerelease-test-$version" "source/$branch"
```

**Fast-forward the fork's tracked branch to upstream first.** Branching off `source/$branch` is not enough on its own: the PR is based on the *fork's* branch, so if that branch is stale the PR carries every upstream commit since the last sync instead of just the upgrade. Sync it before opening PRs, and skip any fork whose branch has commits upstream does not have rather than clobbering it:

```bash
git rev-list --left-right --count "origin/$branch...source/$branch"   # left = fork-only commits; must be 0 to sync
git push --no-verify origin "source/$branch:refs/heads/$branch"
```

If PRs were already opened against a stale base, GitHub does not recompute their merge base when the base branch moves. Close and reopen each PR to force it (a reopened draft stays a draft).

Branch name convention (required): **`update-vite-plus-prerelease-test-{version}`**, where `{version}` is the vite-plus prerelease under test (a preview build `0.0.0-commit.<sha>`, or a tagged prerelease like `0.2.3-alpha.1`).

Some projects enforce their own branch-name policy in CI and will reject that name. When a `Validate branch name`-style check fails, read the pattern out of the job log and rename the branch to satisfy it for that project only; the convention above still applies everywhere else. A conventional-commit pattern such as `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)/[a-z0-9]+(-[a-z0-9]+)*$` rejects the dots in `0.0.0-commit.<sha>`, so drop the dotted version and keep the bare sha:

```bash
git branch -f "test/vite-plus-prerelease-<sha>" "update-vite-plus-prerelease-test-$version"
git push --no-verify -f origin "test/vite-plus-prerelease-<sha>"
```

A PR's head branch cannot be changed after creation, so close the original PR and open a new one from the renamed branch. Renaming also unblocks any jobs the branch-name gate was skipping, which may then surface their own failures.

### 2. Apply the upgrade

Upgrade vite-plus on that branch (e.g. `vp migrate` from the preview build; see the release-manager skill or the local harness). Commit only what the upgrade changes, typically `package.json` and the bridge `.npmrc` (force-add it if the project gitignores `.npmrc`); never commit `node_modules`. Projects that commit no lockfile install fresh in CI.

**Run `vp fmt` before committing.** Projects whose CI runs `vp check` (or `vp fmt --check`) fail on formatting the upgrade introduces: a new oxfmt version formats files the previous one left alone, so code untouched by the upgrade suddenly fails the check. Running `vp fmt` first auto-corrects those files and folds them into the upgrade commit, leaving only genuine failures in CI:

```bash
vp fmt
git add -A && git commit --amend --no-edit --no-verify
```

`vp migrate` installs Vite+ git hooks, so the project's own pre-commit/pre-push checks run against the test commit and can block it for pre-existing lint or type errors unrelated to the upgrade. Use `--no-verify` on both `git commit` and `git push` for these test commits.

### 3. Draft PR on the fork, assigned to the release manager

Open the PR **as a draft**, based on the tracked branch, under `vite-plus-ecosystem-ci`, and **assign it to the release manager**:

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

Once all PRs are open, list them in a table for review (project, PR link, base, prerelease, assignee, CI status), then check each PR's CI for **upgrade-related** failures:

```bash
gh pr checks <PR#> --repo vite-plus-ecosystem-ci/$name
```

Distinguish an upgrade failure (the prerelease does not resolve, build, or test, and the error references the prerelease version) from pre-existing or infra flakiness (missing DB service, network, unrelated lint). When a job fails at install, read its log: `gh api repos/vite-plus-ecosystem-ci/$name/actions/jobs/<job-id>/logs`.

## Filtering irrelevant fork-CI failures

Across the full catalog most red checks say nothing about the release. Sort every failure into one of these before drawing a conclusion, and report the tally by cause rather than "N failed". Known per-repo cases are recorded in `notes` in `ecosystem.json`, so check there first.

**1. Registry-bridge fetch flakes (re-runnable, and the most common false alarm).** The bridge occasionally drops tarball requests under load. pnpm reports `error (23). Will retry`, or the install fails with `ECONNRESET  aborted`. The dangerous variant is the platform binding: `@voidzero-dev/vite-plus-<platform>` is an **optional** dependency, so when its download exhausts pnpm's retries, pnpm skips it and still reports a successful install. The job then dies much later, at the first command that loads the binding:

```
Error: Cannot find native binding. npm has a bug related to optional dependencies
(https://github.com/npm/cli/issues/4828). Please try `npm i` again after removing
both package-lock.json and node_modules directory.
  cause: Cannot find module '@voidzero-dev/vite-plus-linux-x64-gnu'
```

**Read this carefully: it is a local `node_modules` resolution failure, not a statement about the registry.** Node is reporting that the package is absent from this install; nothing here checked whether it was published. The "npm has a bug related to optional dependencies" sentence is boilerplate that NAPI's generated loader appends to every binding-load failure, and it steers readers toward a packaging or publishing explanation that is almost always wrong here. The bridge publishes every platform package for every commit build, and the packument URL will serve it fine while CI is failing this way.

Confirm rather than assume:

```bash
VERSION=0.0.0-commit.<sha>
curl -s "https://registry-bridge.viteplus.dev/@voidzero-dev%2fvite-plus-linux-x64-gnu" \
  | python3 -c "import json,sys; print('$VERSION' in json.load(sys.stdin)['versions'])"
```

`True` means the package was published and the install dropped it, so the failure is a flake: re-run the job (`gh run rerun <run-id> --failed --repo vite-plus-ecosystem-ci/$name`). Only `False` would point at a publishing problem. Always grep the install step for `error (23)` and `ECONNRESET` before classifying this failure as anything else.

**2. Preview-build artifacts.** Caused by the `0.0.0-commit.<sha>` version string itself, so they cannot happen for a real npm release: pnpm `ERR_PNPM_TRUST_DOWNGRADE` ("possible package takeover"), npm `ETARGET`/`notarget` and bun/pnpm minimum-release-age (`ERR_PNPM_NO_MATURE_MATCHING_VERSION`), `ERR_PNPM_TARBALL_URL_MISMATCH` or a failed supply-chain policy check against the bridge tarball URLs, `ERR_PNPM_INVALID_PEER_DEPENDENCY_SPECIFICATION` where a project declares `vite` as a peer, and Docker builds whose context does not carry the bridge `.npmrc`.

**3. Fork infrastructure.** The fork is not the upstream repo and lacks its secrets and app installations. Recurring cases: `The app https://github.com/apps/pkg-pr-new is not installed on vite-plus-ecosystem-ci/<repo>`, `Failed to replace env in config: ${NODE_AUTH_TOKEN}`, `Password required` from a container-registry login, and third-party services such as CodSpeed returning `401 Unauthorized`. None of these are worth fixing per release; record them in `notes`.

**4. Project policy checks that a bot PR can never satisfy.** For example a `check-label` job requiring a `changelog:***` label, a commitlint rule that rejects the long `test: upgrade vite-plus to prerelease 0.0.0-commit.<sha>` subject, a `Validate branch name` job that rejects the dots in the required `update-vite-plus-prerelease-test-<version>` branch name (see "Smoke-test via a fork PR" for the per-project rename), or `knip`/`check-overrides` meta-checks that fail whenever dependencies change.

**5. Project-side breakage exposed by regenerating the lockfile.** The harness deletes the lockfile, so packages that only ever resolved a dependency through hoisting now fail once it is regenerated. The project never declared the dependency. Not a vite-plus problem. **Grep for both phrasings**, because the wording depends on the module system and it is easy to match only one: ESM reports `Cannot find package 'oxfmt' imported from ...`, CJS reports `Cannot find module 'esbuild'`. The importer is not always the project's own code: a third-party package can import a bare specifier that only resolved through hoisting before.

**6. Stale pins.** A fork pinned several releases back (e.g. `0.1.x`) does not test the release under review: `vp migrate` performs a multi-release jump and any resulting type errors are evidence about that jump, not about the candidate. **When judging a release, weight the forks pinned to the immediately previous release most heavily**, and re-pin stale forks between releases.

Only a failure that reproduces on the candidate but **not** on the previous release is a regression. Prove it with an isolated control rather than asserting it:

```bash
VP_HOME=$HOME/.cache/vp-control-<prev> VP_VERSION=<prev> VP_NODE_MANAGER=no bash packages/cli/install.sh
cd <project> && VP_HOME=$HOME/.cache/vp-control-<prev> VP_NODE_MANAGER=no \
  PATH="$HOME/.cache/vp-control-<prev>/bin:$PATH" vp migrate <project> --no-interactive
```

Run the control from **inside the project directory**. Running it from a vite-plus checkout makes `vp` resolve the local `packages/cli/dist` instead of the pinned release, which invalidates the comparison.

## Making a fork's CI usable

Two fixes belong on the **test branch only**, never on the tracked branch, which must differ from upstream only by what a release test needs.

### Forks with no PR CI

If a fork's workflows never trigger on `pull_request`, the test PR reports "no checks" and proves nothing. Add a minimal build workflow to the test branch that exercises the pinned vite-plus, matching whatever setup the project already uses:

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

Use `vp run build` so the job goes through the project's own `build` script. Record the repo in `notes`.

### Forks on third-party runners

Self-hosted or third-party runner labels only resolve for the upstream org, so on a fork every job queues forever and the PR never reports a result. Map the labels to GitHub-hosted equivalents on the test branch:

| Third-party label | GitHub-hosted |
| --- | --- |
| `blacksmith-32vcpu-ubuntu-2404` | `ubuntu-24.04` |
| `blacksmith-32vcpu-ubuntu-2404-arm` | `ubuntu-24.04-arm` |
| `blacksmith-32vcpu-windows-2025` | `windows-2025` |
| `blacksmith-12vcpu-macos-15` | `macos-15` |

Replace the longest label first (the `-arm` suffix before the plain label) so you do not leave a partially rewritten string. Runner-specific **actions** need more than a label swap and are usually not worth fixing: `useblacksmith/begin-testbox`, `useblacksmith/run-testbox`, and cache actions tied to the same provider. Leave those jobs failing and note them.

## CI caveats

- Some forks trigger CI on `push` only, not `pull_request` (flagged in `notes`, e.g. `codiff`, `delta-comic`). Opening a PR against them does not run their CI. If PR CI is required, add a `pull_request` trigger to the workflow's `on:` block **inside the ecosystem-ci PR**, not as a standalone commit on the tracked branch, so the fork stays clean against upstream.
- Keep the tracked branch clean: do not land unrelated commits on it. It should differ from upstream only by what a release test needs.
- **Non-standard installers do not resolve preview builds.** The preview-build smoke test needs the project's CI to resolve `vite-plus@0.0.0-commit.<sha>` through the registry bridge written into `.npmrc`. That works for npm/pnpm/yarn/bun; it fails for installers that ignore the `.npmrc` `registry=` or use their own. Known case: `cnpmcore`'s CI installs with `utoo` (`ut`, via `utooland/setup-utoo`), which resolves against public npm and 404s on the commit build (`No matching version found ... from N available versions`). Check a candidate's CI install step before trusting fork-CI results, and record known cases in `notes`.

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

Set `packageManager` from the `packageManager` field in `package.json` when present; only when it is absent, infer from the committed lockfile (`pnpm-lock.yaml` -> pnpm, `bun.lock*` -> bun, `yarn.lock` -> yarn, `package-lock.json` -> npm, package.json only -> node, none -> other). Lockfile presence alone is unreliable: some repos gitignore their lockfile entirely (e.g. `cnpmcore` commits no lockfile and declares `npm`). Also check **how the project's CI installs**, since a non-standard installer can break the preview-build smoke test: `cnpmcore`'s CI installs with `utoo` (`ut`), which does not resolve `vite-plus@0.0.0-commit.<sha>` through the bridge `.npmrc`, so its smoke test fails at dependency resolution (record this in `notes`). Set `monorepo` if a `workspaces` field, `pnpm-workspace.yaml`, or a `packages/` dir is present.

### Remove a repo

Delete its entry from `ecosystem.json`. Optionally delete the fork (`gh repo delete vite-plus-ecosystem-ci/<name>`); keeping it is harmless but the manifest is what tooling reads. Add a line to "Excluded repos" below so the next person does not re-add it and repeat the work.

### Excluded repos

Deliberately out of the catalog. Do not re-add without fixing the underlying reason.

| Repo | Why |
| --- | --- |
| `vize` (`ubugeeei/vize`) | Its CI cannot produce a usable release signal. Every workflow targets Blacksmith runners that do not resolve on a fork, so jobs queue forever until the labels are rewritten; `e2e.yml` also uses `useblacksmith/*` actions that a label swap cannot fix. The remaining `app-readiness` E2E matrix stays red, and upstream moves fast enough (80+ commits in a day) that a fork synced at the start of a release is stale by the time the PR runs. The cost of keeping it green exceeds its value as a signal. |

### Drift check (manifest vs actual org repos)

```bash
comm -3 \
  <(jq -r '.repos[].name' ecosystem.json | sort) \
  <(gh repo list vite-plus-ecosystem-ci --limit 500 --json name --jq '.[].name' | grep -v '^\.github$' | sort)
# left-only  = in manifest but not in org (stale entry)
# right-only = fork exists but is not catalogued
```

## How vite-plus references this

The `release-manager` skill's smoke-test step should link here instead of embedding the catalog or the setup steps:

> Smoke-test targets and local setup: https://github.com/vite-plus-ecosystem-ci/.github/blob/main/TESTING.md . Pick a target from `ecosystem.json`, clone on its tracked branch (`scripts/setup-local.sh <name>`), then run `test-pkg-pr-new-migrate.sh`. To validate in the fork's CI, follow "Smoke-test via a fork PR": branch `update-vite-plus-prerelease-test-<version>` synced from `source`, open a draft PR on the fork assigned to the release manager, then watch CI. Any test PR must be opened against the `vite-plus-ecosystem-ci` fork, never the upstream repo.

That keeps the churn (which repos exist, which branch each tracks) here, and keeps the release process in vite-plus.
