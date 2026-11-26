usage() {
  cat <<EOF
Usage: ws <option> [args]

Anywhere <name> is a workspace, you can give its number from "ws --list" instead (ws --open 1).
Run --open, --code, --cursor, --claude, --cd, --show, --status, --pull or --fetch with no name at a
terminal to pick from a menu.

  --setup                         Create the workspaces folder (sudo only if it needs it)
  --config [root [<dir>|--unset]] Show settings, print the workspaces folder, or set it once
  --root <dir> <command> ...      Use <dir> as the workspaces folder for this run only
  --create <name>                 Create an empty workspace and its editor/Claude configs
  --add <name> <path> [linkname]  Symlink <path> into workspace <name>
  --remove <name> <linkname>      Remove a symlink from workspace <name> (target untouched)
  --rename <old> <new>            Rename a workspace
  --delete <name>                 Delete a workspace (symlinks and generated configs only)
  --list [--json]                 List all workspaces, numbered
  --show <name> [--json]          Show the entries in a workspace (broken links flagged)
  --sync [name]                   Regenerate editor and Claude configs (every workspace if omitted)
  --open <name>                   Open workspace in herdr (if installed), else tmux
  --code <name>                   Open the multi-root workspace in VS Code
  --cursor <name>                 Open the multi-root workspace in Cursor
  --claude <name> [--repo <link>] [--] [claude args...]
                                  Start Claude Code with every project passed to --add-dir
  --cd <name>                     cd into workspace (works via the 'ws' shell function)

Clone-based workspaces (record repos in workspace.conf, rebuild anywhere):
  --create <name> [url...]        ...also clones each url into the new workspace
  --clone <name> <url> [dir] [-b branch]
                                  Clone a repo into the workspace and record it
  --bootstrap <name>              Clone anything missing, recreate worktrees, relink
  --pull <name>                   git pull --ff-only in every project (keeps going on failure)
  --fetch <name>                  git fetch --all --prune in every project
  --status <name> [--json]        Table of projects: type, branch, age, dirty, ahead/behind,
                                  upstream-gone, merged (local data; run --fetch first)
  --exec <name> [--only a,b] [--git-only] -- <command...>
                                  Run a command in every project (exit 1 if any fails)
  --wt-add <name> <branch> [--run <cmd>] [--copy <f,f>] [repo...]
                                  Add a worktree <repo>--<branch> per repo (default: every repo);
                                  --copy brings untracked files (.env) over, --run runs a setup command
  --wt-rm <name> <branch> [--delete-branch] [repo...]
                                  Remove those worktrees (skips dirty ones); --delete-branch also
                                  drops each branch git considers merged
  --assistants <name> codex|claude|both
                                  Copy agents/skills between .claude and .codex in each project
  --publish <name> [git-url]      Commit the workspace shell and push it (gh private repo if no url)
  --completion bash|zsh|fish      Print a shell completion script
  -h, --help                      Show this help

Generated inside each workspace (overwritten by --add, --remove, --rename, --sync,
--code, --cursor, and --claude):

  <name>.code-workspace           VS Code and Cursor. Folders use real paths so Git
                                  is detected. Open this file, not the symlink folder.
  .claude/settings.local.json     permissions.additionalDirectories, so a plain
                                  "claude" started in the workspace can read projects.
  .ws/claude.sh                   Launcher used by "ws --claude". Passes --add-dir
                                  so Claude also loads each project's skills.
  .claude/{agents,commands,skills,hooks}/<project>--<item>
  .codex/{agents,skills}/<project>--<item>
                                  Symlinks that merge every project's assistant config
                                  into one session started in the workspace directory.
  workspace.conf                  Clones and worktrees (name|url|branch, name|worktree:src|branch)
  CLAUDE.md AGENTS.md README.md   Written once; yours to edit afterwards
  .gitignore                      Regenerated; lets the workspace shell be its own git repo

Environment:
  WS_ROOT         Workspaces folder (overrides the config file; default ~/workspaces)
  WS_CONFIG       Config file (default ~/.config/ws/config)
  WS_CODE_BIN     VS Code command (default code)
  WS_CURSOR_BIN   Cursor command (default cursor)
  WS_CLAUDE_BIN   Claude Code command (default claude)

Workspaces folder (now: $WS_ROOT, from $ROOT_SOURCE):
  one-time:   ws --config root ~/code/workspaces
  per run:    ws --root /tmp/ws-test --list      or      WS_ROOT=/tmp/ws-test ws --list

Examples:
  ws --create shop
  ws --add shop ~/src/api
  ws --add shop ~/src/web
  ws --cursor shop
  ws --code shop
  ws --claude shop
  ws --claude shop --repo web
  ws --create shop git@github.com:acme/api.git git@github.com:acme/web.git
  ws --wt-add shop feature/checkout
  ws --status shop
  ws --open 1                      # the first workspace in "ws --list"
  ws --exec shop --git-only -- git log -1 --oneline
  ws --wt-add shop feature/checkout --copy .env --run "npm ci"
  ws --wt-rm shop feature/checkout --delete-branch
  eval "$(ws --completion bash)"
EOF
}

