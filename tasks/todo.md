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
- [ ] 11. (stretch, declined) `skills/ws/SKILL.md`

## Review
- All of steps 1-10 done in the single `ws` script; `tests/smoke.sh` passes (original cases plus clone, bootstrap, merged links, assistants, worktrees, status, pull, publish-to-url, delete-guard).
- Fixed a pre-existing test failure on macOS (`/var` vs `/private/var` from `mktemp`).
- Improvement over virtual-workspace: no `sed -i ''` (breaks on GNU sed); manifest and .gitignore are rewritten atomically, and .gitignore uses `/name` so symlinked projects are ignored too.
- Not verified: `--publish` without a url (needs `gh` and a real GitHub account); only the git-url path is tested.
- Behavior change for existing workspaces: next sync adds workspace.conf, CLAUDE.md, AGENTS.md, README.md, .gitignore (and `.claude/`/`.codex/` links if projects have config).
- Screenshots (`assets/overview.png`, `assets/workflow.png`) are rendered from HTML with headless Chrome; the terminal text is representative, not captured output.
