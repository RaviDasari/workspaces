# Changelog

Release notes are published from the matching section below when a `v*` tag is pushed.

## 0.4.1

- CI on every push and PR: build check, smoke tests on Ubuntu and macOS (including macOS `/bin/bash` 3.2), and shellcheck.
- Tagging a release now publishes the GitHub release and updates the Homebrew formula in `RaviDasari/homebrew-tap` automatically.
- README: CI badge and release instructions. No changes to `ws` itself.

## 0.4.0

- Workspace numbers: use `ws --open 1` instead of the name.
- `--json` output and the `ws-skill` plugin, so agents can drive `ws`.
- `--exec` runs a command in every project, `--fetch` fetches all of them.
- Shell completion for bash, zsh and fish.
- Source split into `src/*.sh`, built into the single `ws` file.

## 0.3.0

- Configurable workspaces folder: default `~/workspaces`, set once with `ws --config root <dir>`, override with `--root` or `WS_ROOT`.
