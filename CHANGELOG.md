# Changelog

Release notes are published from the matching section below when a `v*` tag is pushed.

## Unreleased

- Inside a workspace, commands that take a workspace use it when you give no name: `ws --status`, `ws --pull`, `ws --wt-add feat-x`. `--delete` and `--rename` still need a name. `ws --sync` there syncs only that workspace. `ws --list` marks the current one with `*` (`"current"` in `--json`).

## 0.5.0

- Workspace checkpoints: `ws --checkpoint <name> [label]` saves every repo's branch, commit, staged and unstaged changes, and untracked files without touching your working tree. `--checkpoint --list [--json]`, `--checkpoint --rm`, and `--restore <name> <label>` (always saves a `pre-restore-*` checkpoint first, so it can be undone). `--only` limits any of them to some projects.
- `ws-skill` knows about checkpoints and will not restore or remove one unless asked.
- CI on every push and PR: build check, smoke tests on Ubuntu and macOS (including macOS `/bin/bash` 3.2), and shellcheck.
- Tagging a release now publishes the GitHub release and updates the Homebrew formula in `RaviDasari/homebrew-tap` automatically.
- README: checkpoints section, CI and release badges, release instructions.

## 0.4.0

- Workspace numbers: use `ws --open 1` instead of the name.
- `--json` output and the `ws-skill` plugin, so agents can drive `ws`.
- `--exec` runs a command in every project, `--fetch` fetches all of them.
- Shell completion for bash, zsh and fish.
- Source split into `src/*.sh`, built into the single `ws` file.

## 0.3.0

- Configurable workspaces folder: default `~/workspaces`, set once with `ws --config root <dir>`, override with `--root` or `WS_ROOT`.
