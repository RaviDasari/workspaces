# Make `ws` a superset of filipealva/virtual-workspace

## Gap analysis

| virtual-workspace feature | `ws` today | Plan |
| --- | --- | --- |
| Create workspace from git URLs (clone, `name\|url\|branch`) | symlink existing dirs only | `ws --create <name> [url...]`, `ws --clone <name> <url> [dir] [-b branch]` |
| `workspace.conf` manifest (REPOS array, clones + worktrees) | `.ws/projects.tsv` (derived) | Add `.ws/workspace.conf` recording clones/worktrees, so `ws --bootstrap` rebuilds a workspace on a new machine |
| `bootstrap.sh`: clone missing, relink, prune dead links | none | `ws --bootstrap <name>` (idempotent) |
| Aggregate `.claude/{agents,commands,skills,hooks}` as `<repo>--<item>` symlinks | none | Done in every sync; relative links; dead links pruned |
| Aggregate `.codex/{agents,skills}` | none | Same |
| `assistant-support.sh codex\|claude\|both` (convert agents/skills between tools) | none | `ws --assistants <name> codex\|claude\|both` |
| `pull-all.sh` (ff-only) | none | `ws --pull <name>` (reports failures, continues) |
| `worktree-create.sh <branch> [repos]` | none | `ws --wt-add <name> <branch> [repo...]` |
| `worktree-remove.sh` (refuses dirty, never deletes branches) | none | `ws --wt-rm <name> <branch> [repo...]` |
| `worktree-status.sh` table (clone/wt, branch, dirty, ahead/behind) | `--show` only lists links | `ws --status <name>`, and `--show` stays |
| Generated `CLAUDE.md`, `AGENTS.md`, `README.md`, `.gitignore` for the shell | none | Generated once, not overwritten if edited (marker) |
| Publish shell repo (`gh repo create`) | none | `ws --publish <name> [url]` (private by default, asks first) |
| Codex support | none | `.codex` aggregation + `AGENTS.md` |
| Plugin/skill packaging | none | `skills/ws/SKILL.md` so Claude can drive `ws` (stretch) |

`ws` keeps what vw lacks: linking existing dirs, `.code-workspace` for VS Code and Cursor, `settings.local.json`, `--add-dir` launcher with `--repo`, tmux/herdr `--open`, `--cd`, `--list`, `--rename`, `--delete`, `--setup`.

## Design decisions
- Keep one bash script `ws`, flag style (`--x`), same conventions.
- Fix vw's known portability bug: no `sed -i ''`; edit manifest by rewrite-and-mv.
- Worktrees are real dirs inside the workspace, so existing `collect_projects` picks them up for the editor and Claude configs.
- `--delete` must treat the new generated files and worktrees/clones safely: refuse if real clones/worktrees exist.
- Extend `tests/smoke.sh` for every new command (local bare repos as "remotes", no network).

## Steps
- [x] 1. Manifest (`.ws/workspace.conf`) read/write helpers
- [x] 2. `--clone`, `--create <name> [url...]`, `--bootstrap`
- [x] 3. `.claude`/`.codex` aggregation in sync; fix `--delete`/generated-entry logic
- [x] 4. `--pull`, `--status`
- [x] 5. `--wt-add`, `--wt-rm`
- [x] 6. `--assistants`
- [x] 7. Generated CLAUDE.md / AGENTS.md / README / .gitignore; `--publish`
- [x] 8. Smoke tests for all of the above; run on a clean temp WS_ROOT
- [x] 9. README + `--help` update
- [x] 10. Two screenshots (HTML rendered to PNG, 1731x909 like vw's banner), saved in `assets/`:
  - `assets/overview.png`: banner/architecture: workspace hub, linked and cloned repos, VS Code/Cursor/Claude/Codex outputs, feature list
  - `assets/workflow.png`: worktrees + sync: `ws --status` table, `--wt-add` fan-out, `--pull`, `--assistants` conversion
  - Shown in README; verify by viewing the PNGs
- [x] 11. (stretch, declined) `skills/ws/SKILL.md`

## Review
- All of steps 1-10 done in the single `ws` script; `tests/smoke.sh` passes (original cases plus clone, bootstrap, merged links, assistants, worktrees, status, pull, publish-to-url, delete-guard).
- Fixed a pre-existing test failure on macOS (`/var` vs `/private/var` from `mktemp`).
- Improvement over virtual-workspace: no `sed -i ''` (breaks on GNU sed); manifest and .gitignore are rewritten atomically, and .gitignore uses `/name` so symlinked projects are ignored too.
- Not verified: `--publish` without a url (needs `gh` and a real GitHub account); only the git-url path is tested.
- Behavior change for existing workspaces: next sync adds workspace.conf, CLAUDE.md, AGENTS.md, README.md, .gitignore (and `.claude/`/`.codex/` links if projects have config).
- Screenshots (`assets/overview.png`, `assets/workflow.png`) are rendered from HTML with headless Chrome; the terminal text is representative, not captured output.

---

# Round 2: agent interface, exec, worktree lifecycle, shortcuts, completions, split, README

Skipped by request: SHA pinning (old #3), CI (old #7, done separately on GitHub).

## Design
- **Numeric shortcuts**: anywhere a `<name>` is expected, `N` (1-based index in `ws --list` order) resolves to that workspace. Done once in `need_ws`/a `resolve_ws` helper so every command gets it (`ws --open 1`, `--code 2`, `--claude 1`, `--cd 1`). `--list` prints the index column. Names that are all digits stay literal if a dir with that name exists. Also: no-arg `ws --open`/`--code`/... picks from a numbered prompt when stdin is a TTY (stretch).
- **--json** on `--list`, `--show`, `--status` (hand-rolled via existing `json_escape`; no jq dependency).
- **Agent interface**: `skills/ws/SKILL.md` (so Claude can drive `ws`), plus the plugin entry in `.claude-plugin`. MCP server decision pending (see questions).
- **--exec** `ws --exec <name> [--only repo,repo] [--tag ...] -- <cmd...>`: runs in every project dir (git or not, `--git-only` filter), prints `=== name ===` headers, keeps going, non-zero exit if any failed.
- **Worktree lifecycle**: `--wt-rm --delete-branch` (only if merged, `branch -d`), `--wt-add --run "<cmd>"` post-create hook, `--wt-add --copy .env,.env.local` copies untracked config from the source repo.
- **--fetch** (fetch --all --prune everywhere) and richer `--status`: columns for upstream gone / merged into default branch / last commit age; `--status` stays one table.
- **Completions**: `ws --completion bash|zsh|fish` prints a script; completes flags, workspace names/indexes, repo names, branches.
- **Split**: source in `src/*.sh`, `make build` (a tiny `build.sh`) concatenates into the single `ws` file, which stays committed so `brew`/`install -m 755 ws` still work. Smoke test asserts `ws` is up to date with `src/`.
- **README**: comparison table vs virtual-workspace / Canopy / Grove / mani / Worktrunk, lead with the pitch, new command docs.

## Steps
- [x] 1. Split into `src/` + build script; verify built `ws` is byte-equivalent in behavior (smoke passes)
- [x] 2. Workspace index shortcuts + `--list` index column
- [x] 3. `--json` for list/show/status
- [x] 4. `--exec`
- [x] 5. `--fetch` + richer `--status`
- [x] 6. Worktree lifecycle (`--delete-branch`, `--run`, `--copy`)
- [x] 7. `--completion bash|zsh|fish`
- [x] 8. `skills/ws/SKILL.md` (+ MCP server if chosen)
- [x] 9. Smoke tests for each; run clean
- [x] 10. README rewrite + `--help` update

## Review (round 2)
- Verified: `tests/smoke.sh` passes under bash 5.3 and macOS /bin/bash 3.2; `./build.sh --check` clean; `claude plugin validate .` passes.
- Found and fixed along the way: generated `claude.sh` crashed on bash 3.2 when `args` was empty (unbound under `set -u`).
- Not verified: zsh completion beyond `zsh -n`; fish completion not run at all (no fish installed); `ws --open N` under tmux/herdr (only `--code N` exercised, the number logic is shared).
- Decisions: agent interface is `--json` + `mods/ws-skill` (no MCP server); split is `src/*.sh` -> built single `ws`.
- Lesson: never put `$(...)` in an unquoted heredoc comment (it executes); and write test blocks with a file, not a nested heredoc.

## Backlog
- [ ] **SHA pinning**: `ws --lock <name>` records each clone's and worktree's commit SHA (e.g. in `workspace.lock`); `ws --bootstrap <name> --locked` checks out exactly those SHAs for a reproducible rebuild. Today `workspace.conf` stores only URL and branch, so bootstrap gets whatever is current.
- [x] **CI (GitHub Actions)**: run `tests/smoke.sh` and `./build.sh --check` on macOS and Linux, plus shellcheck on `src/*.sh`. Include macOS `/bin/bash` 3.2, which already caught one bug.
