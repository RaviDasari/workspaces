---
name: ws
description: Drive the `ws` multi-repo workspace manager. Use when the user works across several repos at once, mentions a workspace, or asks to check status, pull, fetch, run a command in every repo, or create or remove a feature branch worktree across repos.
---

# ws

`ws` groups repositories into one workspace folder (symlinks, clones, worktrees). Run it with Bash. Every
command is a flag: `ws --<command> <workspace> [args]`.

## Orient first

```bash
ws --list --json                  # [{"index","name","path","projects"}]
ws --show <workspace> --json      # [{"name","kind":"link|clone|worktree|local|broken","detail"}]
ws --status <workspace> --json    # per project: branch, dirty_files, ahead, behind, upstream_gone, merged, last_commit_age_seconds
```

Prefer `--json` and parse it. The text tables are for humans. A workspace can be named by its `--list`
number (`ws --status 1`), but use the name in anything you write down, because numbers shift when
workspaces are added or removed.

## Read before you write

- `--status` reads local state only. Run `ws --fetch <workspace>` first when remote freshness matters.
- `merged: true` means the branch is fully contained in the default branch; `upstream_gone: true` means
  its remote branch was deleted. Both mark a worktree as a cleanup candidate, not as safe to delete
  without telling the user.

## Common tasks

| Goal | Command |
| --- | --- |
| Update every repo | `ws --pull <ws>` (fast-forward only, keeps going on failure) |
| Run a command in every repo | `ws --exec <ws> [--only a,b] [--git-only] -- <cmd...>` |
| Same branch in several repos | `ws --wt-add <ws> <branch> [repo...] [--copy .env] [--run "<setup cmd>"]` |
| Clean up a finished branch | `ws --wt-rm <ws> <branch> [repo...] [--delete-branch]` |
| Add a repo | `ws --clone <ws> <url>` or `ws --add <ws> <path>` |

`--wt-add` creates `<repo>--<branch>` directories inside the workspace; work and commit in those, one
commit per repo. `--wt-rm` skips worktrees with uncommitted changes, and `--delete-branch` only deletes a
branch git considers merged.

## Rules

- Never pass `--delete`, `--wt-rm`, or `--publish` without the user asking. `--delete` and `--publish`
  prompt on stdin; do not pipe `y` into them on your own.
- `--exec` runs arbitrary commands in every project. Show the user the command first when it writes,
  installs, or deletes anything.
- Do not hand-edit generated files (`<name>.code-workspace`, `.claude/settings.local.json`,
  `.ws/`). Change the workspace with `ws` and it regenerates them.
- `ws --open`, `--code`, `--cursor`, and `--claude` start interactive programs. Do not run them.
