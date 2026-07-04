# vite-plus ecosystem-ci

Real-world app forks used to smoke-test [vite-plus](https://github.com/voidzero-dev/vite-plus) pre-releases. Each repo here is a fork of an upstream project; a release candidate is validated by upgrading these apps to it and confirming they still install, build, and test.

- **Testing rules and guidelines:** [`.github/TESTING.md`](https://github.com/vite-plus-ecosystem-ci/.github/blob/main/TESTING.md)
- **Catalog of forks (source of truth):** [`.github/ecosystem.json`](https://github.com/vite-plus-ecosystem-ci/.github/blob/main/ecosystem.json)

The set of repos changes over time. `ecosystem.json` is authoritative: it records each fork's upstream, the branch to test (often not the default branch), and its package manager.
