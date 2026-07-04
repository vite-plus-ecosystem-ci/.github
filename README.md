# .github

Org-level configuration and testing docs for [`vite-plus-ecosystem-ci`](https://github.com/vite-plus-ecosystem-ci), the catalog of real-world app forks used to smoke-test [vite-plus](https://github.com/voidzero-dev/vite-plus) pre-releases.

| File | Purpose |
| --- | --- |
| [`TESTING.md`](./TESTING.md) | Testing rules and guidelines: how to verify a release candidate locally, fork setup rules, CI caveats, and how to add/remove a repo. **Canonical source; vite-plus links here.** |
| [`ecosystem.json`](./ecosystem.json) | Machine-readable catalog of forks (name, upstream, tracked branch, package manager). Source of truth for tooling. |
| [`profile/README.md`](./profile/README.md) | Org profile shown on the [org landing page](https://github.com/vite-plus-ecosystem-ci). |
| [`scripts/setup-local.sh`](./scripts/setup-local.sh) | Clone a fork (or all) locally on its tracked branch with `origin`/`source` remotes, from the manifest. |
| [`scripts/enable-actions.sh`](./scripts/enable-actions.sh) | Enable GitHub Actions on a fork, including workflows parked in `disabled_fork`. |

Start with [`TESTING.md`](./TESTING.md).
