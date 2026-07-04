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

## CI caveats

- Some forks trigger CI on `push` only, not `pull_request` (flagged in `notes`, e.g. `codiff`, `delta-comic`). Opening a PR against them does not run their CI. If PR CI is required, add a `pull_request` trigger to the workflow's `on:` block **inside the ecosystem-ci PR**, not as a standalone commit on the tracked branch, so the fork stays clean against upstream.
- Keep the tracked branch clean: do not land unrelated commits on it. It should differ from upstream only by what a release test needs.

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

Set `packageManager` from the `packageManager` field in `package.json` when present (authoritative): some repos commit several lockfiles to test multiple package managers (e.g. `cnpmcore` commits npm, pnpm, yarn, and bun lockfiles but declares `npm`), so lockfile presence alone is misleading. Only when the field is absent, infer from the committed lockfile (`pnpm-lock.yaml` -> pnpm, `bun.lock*` -> bun, `yarn.lock` -> yarn, `package-lock.json` -> npm, package.json only -> node, none -> other). Set `monorepo` if a `workspaces` field, `pnpm-workspace.yaml`, or a `packages/` dir is present.

### Remove a repo

Delete its entry from `ecosystem.json`. Optionally delete the fork (`gh repo delete vite-plus-ecosystem-ci/<name>`); keeping it is harmless but the manifest is what tooling reads.

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

> Smoke-test targets and local setup: https://github.com/vite-plus-ecosystem-ci/.github/blob/main/TESTING.md . Pick a target from `ecosystem.json`, clone on its tracked branch (`scripts/setup-local.sh <name>`), then run `test-pkg-pr-new-migrate.sh`. Any test PR must be opened against the `vite-plus-ecosystem-ci` fork, never the upstream repo.

That keeps the churn (which repos exist, which branch each tracks) here, and keeps the release process in vite-plus.
