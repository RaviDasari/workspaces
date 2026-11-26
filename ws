#!/usr/bin/env bash
# ws - group project directories into one symlink workspace.
# Writes a VS Code / Cursor multi-root workspace and Claude Code directory access.
set -euo pipefail

# Where workspaces live, first match wins:
#   1. ws --root <dir> <command>      (this run only)
#   2. $WS_ROOT                       (environment)
#   3. root=<dir> in the config file  (set once with: ws --config root <dir>)
#   4. ~/workspaces, or /workspaces if that already exists and ~/workspaces does not
WS_CONFIG="${WS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ws/config}"

config_get() { # key -> value, empty if unset
  local line
  [[ -f "$WS_CONFIG" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == "$1="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done < "$WS_CONFIG"
  return 0
}

# Make a user-typed path absolute: expand a leading ~, anchor relative paths at $PWD.
abs_path() {
  local p=$1
  case "$p" in
    "~") p=$HOME ;;
    "~/"*) p=$HOME/${p#"~/"} ;;
    /*) ;;
    *) p=$PWD/$p ;;
  esac
  printf '%s' "${p%/}"
}

ROOT_SOURCE=""
WS_ROOT_FROM_ENV=${WS_ROOT:+1}
resolve_root() {
  local v
  if [[ -n "${WS_ROOT:-}" ]]; then
    ROOT_SOURCE="WS_ROOT environment variable"
  elif v=$(config_get root) && [[ -n "$v" ]]; then
    WS_ROOT=$v; ROOT_SOURCE="config file $WS_CONFIG"
  elif [[ ! -d "$HOME/workspaces" && -d /workspaces ]]; then
    WS_ROOT=/workspaces; ROOT_SOURCE="legacy default (existing /workspaces)"
  else
    WS_ROOT=$HOME/workspaces; ROOT_SOURCE="default"
  fi
  WS_ROOT=$(abs_path "$WS_ROOT")
}
resolve_root

usage() {
  cat <<EOF
Usage: ws <option> [args]

Anywhere <name> is a workspace, you can give its number from "ws --list" instead (ws --open 1).
Run from inside a workspace, every command except --delete and --rename uses that workspace when
you give no name (ws --status, ws --wt-add feat-x). A first argument that is another workspace's
name or number is taken as the workspace, so type the name out if a repo or branch looks like one.
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
  --checkpoint <name> [label] [--only a,b]
                                  Save every git project's branch, commits, staged and unstaged
                                  changes, and untracked files (not ignored ones); changes nothing
  --checkpoint <name> --list [--json] | --rm <label...>
                                  List or delete checkpoints
  --restore <name> <label> [--only a,b]
                                  Put projects back to a checkpoint (resets branches, removes newer
                                  untracked files); saves the current state first, so it can be undone
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
  ws --checkpoint shop before-refactor
  ws --restore shop before-refactor
  eval "$(ws --completion bash)"
EOF
}

die() { echo "ws: $*" >&2; exit 1; }

need_realpath() {
  command -v realpath >/dev/null 2>&1 || die "realpath is required"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]] \
    || die "invalid name '$1' (use letters, digits, . _ -)"
}

need_ws() {
  valid_name "$1"
  [[ -d "$WS_ROOT/$1" ]] || die "workspace '$1' does not exist"
}

# Every command, and the ones whose first argument is a workspace (those accept a --list
# number; PICK_OPTS also show a menu when run with no name at a terminal).
ALL_OPTS="--setup --config --root --create --add --remove --rename --delete --list --show --sync --open --code --cursor --claude --cd --clone --bootstrap --pull --fetch --status --exec --wt-add --wt-rm --checkpoint --restore --assistants --publish --completion --help"
NAME_OPTS=" --add --remove --rename --delete --show --sync --open --code --cursor --claude --cd --clone --bootstrap --pull --fetch --status --exec --wt-add --wt-rm --checkpoint --restore --assistants --publish "
PICK_OPTS=" --open --code --cursor --claude --cd --show --status --pull --fetch "
# Commands that default to the workspace the shell is in. Not --delete or --rename: they are
# destructive, so they always want an explicit name.
CWD_OPTS=" --add --remove --show --sync --open --code --cursor --claude --cd --clone --bootstrap --pull --fetch --status --exec --wt-add --wt-rm --checkpoint --restore --assistants --publish "

# Workspace names in `ws --list` order; a number N anywhere a <name> is expected means the Nth one.
ws_names() {
  local d
  for d in "$WS_ROOT"/*/; do
    [[ -d "$d" ]] && basename "$d"
  done
  return 0
}

resolve_ws() { # name-or-number -> name
  local ref=$1 n
  if [[ "$ref" =~ ^[0-9]+$ && ! -e "$WS_ROOT/$ref" ]]; then
    n=$(( 10#$ref ))
    [[ "$n" -ge 1 ]] && n=$(ws_names | sed -n "${n}p") || n=""
    [[ -n "$n" ]] || die "no workspace number $ref (see: ws --list)"
    printf '%s' "$n"
  else
    printf '%s' "$ref"
  fi
}

# True if $1 names an existing workspace or is a number within the --list range (never dies).
is_ws_ref() {
  local ref=$1
  if [[ "$ref" =~ ^[0-9]+$ && ! -e "$WS_ROOT/$ref" ]]; then
    [[ $(( 10#$ref )) -ge 1 && $(( 10#$ref )) -le $(ws_names | wc -l) ]]
  else
    [[ "$ref" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ && -d "$WS_ROOT/$ref" ]]
  fi
}

# Name of the workspace the shell is in, if any. Checks the logical $PWD first (a cd through a
# symlinked project stays under the root only logically), then the physical path.
current_ws() {
  local roots=("$WS_ROOT") r p rel n
  r=$(realpath "$WS_ROOT" 2>/dev/null) && roots+=("$r")
  for p in "$PWD" "$(pwd -P)"; do
    for r in "${roots[@]}"; do
      case "$p" in
        "$r"/*)
          rel=${p#"$r"/}; n=${rel%%/*}
          if [[ "$n" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ && -d "$WS_ROOT/$n" ]]; then
            printf '%s' "$n"; return 0
          fi ;;
      esac
    done
  done
  return 1
}

# Menu for commands run without a name. Needs a terminal; a lone workspace is used as is.
pick_ws() {
  local names=() n i ans
  while IFS= read -r n; do names+=("$n"); done < <(ws_names)
  [[ ${#names[@]} -gt 0 ]] || die "no workspaces in $WS_ROOT (create one: ws --create <name>)"
  if [[ ${#names[@]} -eq 1 ]]; then
    echo "ws: using ${names[0]}" >&2
    printf '%s' "${names[0]}"
    return
  fi
  for i in "${!names[@]}"; do printf '%3d  %s\n' $((i + 1)) "${names[$i]}" >&2; done
  read -r -p "Workspace (number or name): " ans || die "no workspace chosen"
  [[ -n "$ans" ]] || die "no workspace chosen"
  resolve_ws "$ans"
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# Print "name<TAB>realpath" for each project directory in a workspace.
# Skips generated metadata, broken links, and duplicate targets.
collect_projects() {
  local dir=$1 entry base target seen=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    base=$(basename "$entry")
    case "$base" in
      .ws|.claude|.codex|.git|.vscode) continue ;;
    esac
    [[ "$base" == *.code-workspace ]] && continue
    if [[ -L "$entry" && ! -e "$entry" ]]; then
      echo "ws: skipping broken link $base" >&2
      continue
    fi
    [[ -d "$entry" ]] || continue
    target=$(realpath "$entry") || { echo "ws: cannot resolve $base" >&2; continue; }
    if [[ -n "$seen" ]] && printf '%s\n' "$seen" | grep -F -x -q -- "$target"; then
      echo "ws: skipping $base (same directory as another entry)" >&2
      continue
    fi
    if [[ -n "$seen" ]]; then
      seen+=$'\n'"$target"
    else
      seen=$target
    fi
    printf '%s\t%s\n' "$base" "$target"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | sort)
}

write_projects() {
  local dir=$1 tsv=$2 tmp
  tmp=$(mktemp)
  collect_projects "$dir" > "$tmp"
  mv "$tmp" "$tsv"
}

write_code_workspace() {
  local ws_name=$1 dir=$2 tsv=$3
  local file="$dir/$ws_name.code-workspace"
  local names=() paths=() name path i comma
  while IFS=$'\t' read -r name path || [[ -n "${name:-}" ]]; do
    [[ -n "${name:-}" && -n "${path:-}" ]] || continue
    names+=("$name")
    paths+=("$path")
  done < "$tsv"
  if [[ ${#names[@]} -eq 0 ]]; then
    names+=("$ws_name")
    paths+=("$(realpath "$dir")")
  fi
  {
    printf '{\n  "folders": [\n'
    for i in "${!names[@]}"; do
      comma=","
      [[ $i -eq $((${#names[@]} - 1)) ]] && comma=""
      printf '    { "name": "%s", "path": "%s" }%s\n' \
        "$(json_escape "${names[$i]}")" \
        "$(json_escape "${paths[$i]}")" \
        "$comma"
    done
    printf '  ],\n'
    printf '  "settings": {\n'
    printf '    "git.autoRepositoryDetection": true,\n'
    printf '    "git.repositoryScanMaxDepth": 1\n'
    printf '  }\n'
    printf '}\n'
  } > "$file"
}

write_claude_settings() {
  local dir=$1 tsv=$2
  local settings="$dir/.claude/settings.local.json"
  local marker="$dir/.ws/generated-claude-settings"
  if [[ -e "$settings" && ! -f "$marker" ]]; then
    echo "ws: leaving existing $settings alone (not created by ws)" >&2
    return 0
  fi
  mkdir -p "$dir/.claude"
  local paths=() name path i comma
  while IFS=$'\t' read -r name path || [[ -n "${name:-}" ]]; do
    [[ -n "${path:-}" ]] || continue
    paths+=("$path")
  done < "$tsv"
  {
    printf '{\n  "permissions": {\n    "additionalDirectories": ['
    if [[ ${#paths[@]} -eq 0 ]]; then
      printf ']\n'
    else
      printf '\n'
      for i in "${!paths[@]}"; do
        comma=","
        [[ $i -eq $((${#paths[@]} - 1)) ]] && comma=""
        printf '      "%s"%s\n' "$(json_escape "${paths[$i]}")" "$comma"
      done
      printf '    ]\n'
    fi
    printf '  }\n}\n'
  } > "$settings"
  printf '%s\n' "generated by ws" > "$marker"
  echo "ws: updated $settings"
}

write_claude_launcher() {
  local dir=$1
  cat > "$dir/.ws/claude.sh" <<'EOF'
#!/usr/bin/env bash
# Generated by ws. Regenerated on ws --add, --remove, --rename, and --sync.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tsv="$here/projects.tsv"
bin=${WS_CLAUDE_BIN:-claude}

if ! command -v "$bin" >/dev/null 2>&1; then
  echo "ws: claude not found (set WS_CLAUDE_BIN or install Claude Code)" >&2
  exit 1
fi

repo=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "ws: --repo needs a project name" >&2; exit 1; }
      repo=$2
      shift 2
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

cwd=$root
found=0
add=()
if [[ -f "$tsv" ]]; then
  while IFS=$'\t' read -r name path || [[ -n "${name:-}" ]]; do
    [[ -n "${name:-}" && -n "${path:-}" ]] || continue
    if [[ -n "$repo" && "$name" == "$repo" ]]; then
      cwd=$path
      found=1
      continue
    fi
    add+=(--add-dir "$path")
  done < "$tsv"
fi

if [[ -n "$repo" && "$found" -eq 0 ]]; then
  echo "ws: '$repo' is not a project in this workspace" >&2
  exit 1
fi

cd "$cwd"
export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
# ${arr[@]+...}: an empty array is an unbound variable under set -u in bash 3.2 (macOS /bin/bash).
exec "$bin" ${add[@]+"${add[@]}"} ${args[@]+"${args[@]}"}
EOF
  chmod +x "$dir/.ws/claude.sh"
}

# ---- manifest (workspace.conf) ---------------------------------------------
# Same shape as virtual-workspace: a bash REPOS=( ... ) array of quoted entries
#   "name|git-url"            clone
#   "name|git-url|branch"     clone of a branch
#   "name|worktree:src|branch" worktree of project src
# ws parses it line by line and never sources it.

conf_init() {
  local f="$1/workspace.conf"
  [[ -f "$f" ]] && return 0
  cat > "$f" <<'EOF'
# Clones and worktrees for this workspace. Managed by ws; safe to edit.
#   "name|git-url"
#   "name|git-url|branch"
#   "name|worktree:<project>|<branch>"   (list the project before its worktrees)
# Rebuild on another machine with: ws --bootstrap <workspace>
REPOS=(
)
EOF
}

conf_list() {
  local f="$1/workspace.conf" line
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([^\"]*)\" ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done < "$f"
  return 0
}

conf_get() { # dir name -> full entry
  local e
  while IFS= read -r e; do
    [[ "${e%%|*}" == "$2" ]] && { printf '%s\n' "$e"; return 0; }
  done < <(conf_list "$1")
  return 1
}

conf_add() { # dir entry
  local dir=$1 entry=$2 f="$1/workspace.conf" tmp line done_=0
  conf_init "$dir"
  conf_get "$dir" "${entry%%|*}" >/dev/null && return 0
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$done_" -eq 0 && "$line" == ")" ]]; then
      printf '  "%s"\n' "$entry"
      done_=1
    fi
    printf '%s\n' "$line"
  done < "$f" > "$tmp"
  [[ "$done_" -eq 1 ]] || { rm -f "$tmp"; die "$f has no closing ')' line"; }
  mv "$tmp" "$f"
}

conf_del() { # dir name
  local f="$1/workspace.conf" tmp line
  [[ -f "$f" ]] || return 0
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\"([^\"|]*)[\"|] && "${BASH_REMATCH[1]}" == "$2" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$f" > "$tmp"
  mv "$tmp" "$f"
}

# Directory name for a git url: last path segment without .git, query, or fragment.
repo_name_from_url() {
  local u=${1%%[?#]*}
  u=${u%/}
  u=${u%.git}
  u=${u##*/}
  u=${u##*:}
  printf '%s' "$u"
}

safe_branch() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }

is_git() { [[ -d "$1/.git" || -f "$1/.git" ]]; }

# ---- merged assistant config (.claude / .codex) ------------------------------
# Link <project>/.claude/<kind>/<item> as .claude/<kind>/<project>--<item>.
# Links are relative and go through the workspace's own project entry, so they
# work for clones, worktrees, and symlinked projects alike.
link_assistant_config() {
  local dir=$1 tsv=$2 tool kinds kind name path item base link
  for tool in claude codex; do
    if [[ $tool == claude ]]; then kinds="agents commands skills hooks"; else kinds="agents skills"; fi
    for kind in $kinds; do
      # Drop links ws made earlier (relative, named <project>--<item>); keep anything else.
      if [[ -d "$dir/.$tool/$kind" ]]; then
        while IFS= read -r link; do
          [[ "$(readlink "$link")" == ../../* && "$(basename "$link")" == *--* ]] && rm -f "$link"
        done < <(find "$dir/.$tool/$kind" -mindepth 1 -maxdepth 1 -type l)
      fi
      while IFS=$'\t' read -r name path || [[ -n "${name:-}" ]]; do
        [[ -n "${name:-}" && -d "$path/.$tool/$kind" ]] || continue
        for item in "$path/.$tool/$kind"/*; do
          [[ -e "$item" ]] || continue
          base=$(basename "$item")
          mkdir -p "$dir/.$tool/$kind"
          ln -sfn "../../$name/.$tool/$kind/$base" "$dir/.$tool/$kind/$name--$base"
        done
      done < "$tsv"
      rmdir "$dir/.$tool/$kind" 2>/dev/null || true
    done
    rmdir "$dir/.$tool" 2>/dev/null || true
  done
}

GEN_MARK="generated by ws"

write_gitignore() {
  local dir=$1 tsv=$2 f="$1/.gitignore" name path
  if [[ -f "$f" ]] && ! head -1 "$f" | grep -q "$GEN_MARK"; then
    return 0
  fi
  {
    echo "# $GEN_MARK. Regenerated by ws --sync; the workspace shell never tracks project contents."
    while IFS=$'\t' read -r name path || [[ -n "${name:-}" ]]; do
      [[ -n "${name:-}" ]] && printf '/%s\n' "$name"
    done < "$tsv"
    printf '%s\n' "/.ws/" "/.claude/" "/.codex/" "/*.code-workspace" ".DS_Store"
  } > "$f"
}

write_docs() {
  local dir=$1 name=$2 f
  f="$dir/CLAUDE.md"
  [[ -e "$f" ]] || cat > "$f" <<EOF
<!-- $GEN_MARK; written once, edit freely -->
# $name workspace

This directory is a workspace shell, not a project. It holds several projects side by side
(real clones, git worktrees, or symlinks to repos elsewhere on disk).

## Layout
- Each top-level directory is a project with its own git history. Commit inside the project.
- \`.claude/\` and \`.codex/\` hold symlinks named \`<project>--<item>\` that merge every project's
  agents, commands, skills, and hooks. Never edit through them; change the project's own file.
- \`workspace.conf\` lists the clones and worktrees. \`ws --bootstrap $name\` rebuilds them.

## Working across projects
- Read each project's own CLAUDE.md / AGENTS.md before changing it.
- Make one commit per project; there is no cross-project commit.

## Worktrees
1. \`ws --wt-add $name <branch>\` creates \`<project>--<branch>\` for every project.
2. Work and commit inside each worktree directory.
3. Push each worktree's branch, open a PR per project.
4. \`ws --status $name\` shows state; \`ws --wt-rm $name <branch>\` cleans up (branches are kept).
EOF
  f="$dir/AGENTS.md"
  [[ -e "$f" ]] || sed -e "1s/.*/<!-- $GEN_MARK; written once, edit freely -->/" \
    -e 's#CLAUDE\.md / AGENTS\.md#AGENTS.md / CLAUDE.md#' "$dir/CLAUDE.md" > "$f"
  f="$dir/README.md"
  [[ -e "$f" ]] || cat > "$f" <<EOF
<!-- $GEN_MARK; written once, edit freely -->
# $name

A multi-project workspace managed by [ws](https://github.com/).

## Set up on a new machine
\`\`\`bash
git clone <this-repo-url> "\$(ws --config root)/$name"
ws --bootstrap $name      # clones the repos in workspace.conf, recreates worktrees, relinks
ws --claude $name         # or: ws --code $name, ws --cursor $name
\`\`\`

## Daily use
\`\`\`bash
ws --pull $name           # fast-forward every project
ws --status $name         # branch, dirty state, ahead/behind
ws --wt-add $name feature/x   # a worktree per project, same branch name
ws --wt-rm  $name feature/x
\`\`\`

Add a repo with \`ws --clone $name <url>\` (or \`ws --add $name <path>\` for one already on disk).
EOF
}

sync_one() {
  local name=$1 dir tsv
  need_ws "$name"
  dir="$WS_ROOT/$name"
  mkdir -p "$dir/.ws"
  tsv="$dir/.ws/projects.tsv"
  write_projects "$dir" "$tsv"
  write_code_workspace "$name" "$dir" "$tsv"
  write_claude_settings "$dir" "$tsv"
  write_claude_launcher "$dir"
  conf_init "$dir"
  link_assistant_config "$dir" "$tsv"
  write_gitignore "$dir" "$tsv"
  write_docs "$dir" "$name"
  echo "ws: updated $dir/$name.code-workspace"
}

open_editor() {
  local bin=$1 name=$2 file
  [[ $# -eq 2 ]] || die "usage: ws --code|--cursor <name>"
  need_ws "$name"
  sync_one "$name" >/dev/null
  file="$WS_ROOT/$name/$name.code-workspace"
  command -v "$bin" >/dev/null 2>&1 || die "$bin not on PATH (open $file yourself)"
  echo "ws: $bin $file"
  "$bin" "$file"
}

cmd_setup() {
  if [[ -d "$WS_ROOT" && -w "$WS_ROOT" ]]; then
    echo "$WS_ROOT already set up."
    return
  fi
  if ! mkdir -p "$WS_ROOT" 2>/dev/null; then
    sudo mkdir -p "$WS_ROOT"
    sudo chown "$(id -u):$(id -g)" "$WS_ROOT"
  fi
  echo "Set up $WS_ROOT"
}

cmd_config() {
  case "${1:-}" in
    "")
      echo "root     $WS_ROOT"
      echo "         ($ROOT_SOURCE)"
      echo "config   $WS_CONFIG$([[ -f "$WS_CONFIG" ]] || echo ' (not created yet)')"
      ;;
    root)
      shift
      if [[ $# -eq 0 ]]; then
        printf '%s\n' "$WS_ROOT"
      elif [[ "$1" == "--unset" && $# -eq 1 ]]; then
        if [[ -f "$WS_CONFIG" ]]; then
          local tmp line; tmp=$(mktemp)
          while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == root=* ]] || printf '%s\n' "$line"
          done < "$WS_CONFIG" > "$tmp"
          mv "$tmp" "$WS_CONFIG"
        fi
        echo "Cleared the saved workspaces folder; falling back to the default."
      elif [[ $# -eq 1 ]]; then
        local new tmp line
        new=$(abs_path "$1")
        [[ -e "$new" && ! -d "$new" ]] && die "$new exists and is not a directory"
        mkdir -p "$(dirname "$WS_CONFIG")"
        tmp=$(mktemp)
        { [[ -f "$WS_CONFIG" ]] && while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == root=* ]] || printf '%s\n' "$line"
          done < "$WS_CONFIG"
          printf 'root=%s\n' "$new"; } > "$tmp" || true
        mv "$tmp" "$WS_CONFIG"
        echo "Workspaces folder set to $new"
        [[ -d "$new" ]] || echo "It does not exist yet; run: ws --setup"
        [[ -z "${WS_ROOT_FROM_ENV:-}" ]] || echo "Note: \$WS_ROOT is set in your environment and overrides this."
      else
        die "usage: ws --config root [<dir>|--unset]"
      fi
      ;;
    *) die "usage: ws --config [root [<dir>|--unset]]" ;;
  esac
}

cmd_create() {
  [[ $# -ge 1 ]] || die "usage: ws --create <name> [git-url...]"
  valid_name "$1"
  [[ -w "$WS_ROOT" ]] || die "$WS_ROOT missing or not writable; run: ws --setup"
  [[ ! -e "$WS_ROOT/$1" ]] || die "'$1' already exists"
  mkdir "$WS_ROOT/$1"
  echo "Created $WS_ROOT/$1"
  sync_one "$1"
  local name=$1 url
  shift
  for url in "$@"; do cmd_clone "$name" "$url"; done
}

cmd_add() {
  [[ $# -ge 2 && $# -le 3 ]] || die "usage: ws --add <name> <path> [linkname]"
  need_ws "$1"
  [[ -e "$2" ]] || die "path '$2' does not exist"
  local target link
  target="$(realpath "$2")"
  link="${3:-$(basename "$target")}"
  valid_name "$link"
  [[ ! -e "$WS_ROOT/$1/$link" && ! -L "$WS_ROOT/$1/$link" ]] \
    || die "'$link' already exists in '$1' (give a different linkname)"
  ln -s "$target" "$WS_ROOT/$1/$link"
  echo "$WS_ROOT/$1/$link -> $target"
  sync_one "$1"
}

cmd_remove() {
  [[ $# -eq 2 ]] || die "usage: ws --remove <name> <linkname>"
  need_ws "$1"
  valid_name "$2"
  [[ -L "$WS_ROOT/$1/$2" ]] || die "'$2' is not a symlink in '$1'"
  rm "$WS_ROOT/$1/$2"
  echo "Removed link $2 from $1"
  sync_one "$1"
}

cmd_rename() {
  [[ $# -eq 2 ]] || die "usage: ws --rename <old> <new>"
  need_ws "$1"
  valid_name "$2"
  [[ ! -e "$WS_ROOT/$2" ]] || die "'$2' already exists"
  mv "$WS_ROOT/$1" "$WS_ROOT/$2"
  rm -f "$WS_ROOT/$2/$1.code-workspace"
  echo "Renamed $1 -> $2"
  sync_one "$2"
}

# True when this entry is a config ws itself generated.
is_generated_entry() {
  local dir=$1 entry=$2 base
  base=$(basename "$entry")
  [[ -L "$entry" ]] && return 1
  [[ "$base" == "$(basename "$dir").code-workspace" ]] && return 0
  [[ "$base" == ".ws" && -d "$entry" ]] && return 0
  [[ "$base" == "workspace.conf" && -f "$entry" && -z "$(conf_list "$dir")" ]] && return 0
  case "$base" in
    CLAUDE.md|AGENTS.md|README.md)
      [[ -f "$entry" ]] && head -1 "$entry" | grep -q "$GEN_MARK" && return 0 ;;
    .gitignore)
      [[ -f "$entry" ]] && head -1 "$entry" | grep -q "$GEN_MARK" && return 0 ;;
  esac
  if [[ "$base" == .claude && -d "$entry" && -f "$dir/.ws/generated-claude-settings" ]] || [[ "$base" == .codex && -d "$entry" ]]; then
    # Only ws-made config: no regular files besides the settings file we wrote.
    [[ -z "$(find "$entry" -type f ! -name settings.local.json)" ]] && return 0
  fi
  return 1
}

cmd_delete() {
  [[ $# -eq 1 ]] || die "usage: ws --delete <name>"
  need_ws "$1"
  local dir="$WS_ROOT/$1" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ -L "$entry" ]] && continue
    if is_generated_entry "$dir" "$entry"; then
      continue
    fi
    die "'$1' contains real files or directories besides symlinks and ws configs; refusing to delete"
  done < <(find "$dir" -mindepth 1 -maxdepth 1)
  read -r -p "Delete workspace '$1' (symlinks and generated configs only, targets are kept)? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Aborted."; return; }
  local label
  while IFS= read -r label; do cp_drop "$1" "$label"; done < <(cp_labels "$1")
  find "$dir" -mindepth 1 -maxdepth 1 -type l -delete
  rm -f "$dir/$1.code-workspace" "$dir/workspace.conf"
  local g
  for g in CLAUDE.md AGENTS.md README.md .gitignore; do
    [[ -f "$dir/$g" ]] && head -1 "$dir/$g" | grep -q "$GEN_MARK" && rm -f "$dir/$g"
  done
  if [[ -f "$dir/.ws/generated-claude-settings" ]]; then
    rm -f "$dir/.claude/settings.local.json"
  fi
  rm -rf "$dir/.claude" "$dir/.codex" "$dir/.ws"
  rmdir "$dir"
  echo "Deleted $1"
}

cmd_list() {
  [[ -d "$WS_ROOT" ]] || die "$WS_ROOT missing; run: ws --setup"
  local json=0 n i=0 count sep="" cur mark
  cur=$(current_ws || true)
  [[ "${1:-}" == "--json" ]] && json=1
  [[ $# -le 1 && ( $# -eq 0 || $json -eq 1 ) ]] || die "usage: ws --list [--json]"
  [[ $json -eq 0 ]] || printf '['
  while IFS= read -r n; do
    i=$((i + 1))
    count=$(collect_projects "$WS_ROOT/$n" 2>/dev/null | wc -l | tr -d ' ')
    if [[ $json -eq 1 ]]; then
      [[ "$n" == "$cur" ]] && mark=true || mark=false
      printf '%s{"index":%d,"name":"%s","path":"%s","projects":%d,"current":%s}' \
        "$sep" "$i" "$(json_escape "$n")" "$(json_escape "$WS_ROOT/$n")" "$count" "$mark"
      sep=","
    else
      [[ "$n" == "$cur" ]] && mark='*' || mark=' '
      printf '%3d%s %-24s %s project(s)\n' "$i" "$mark" "$n" "$count"
    fi
  done < <(ws_names)
  [[ $json -eq 0 ]] || printf ']\n'
}

# One row per entry in a workspace: name<TAB>kind<TAB>detail
# kind is link, broken, worktree, clone or local; detail is the link target, worktree source or clone url.
show_rows() {
  local dir="$WS_ROOT/$1" l b e
  for l in "$dir"/*; do
    b=$(basename "$l")
    if [[ -L "$l" ]]; then
      if [[ -e "$l" ]]; then printf '%s\tlink\t%s\n' "$b" "$(readlink "$l")"
      else printf '%s\tbroken\t%s\n' "$b" "$(readlink "$l")"; fi
    elif [[ -d "$l" ]]; then
      e=$(conf_get "$dir" "$b" || true)
      case "$e" in
        *'|worktree:'*) printf '%s\tworktree\t%s\n' "$b" "$(cut -d'|' -f2 <<<"$e" | sed 's/^worktree://')" ;;
        '') printf '%s\tlocal\t\n' "$b" ;;
        *) printf '%s\tclone\t%s\n' "$b" "$(cut -d'|' -f2 <<<"$e")" ;;
      esac
    fi
  done
}

cmd_show() {
  [[ $# -ge 1 && $# -le 2 && ( $# -eq 1 || "$2" == "--json" ) ]] || die "usage: ws --show <name> [--json]"
  need_ws "$1"
  local name kind detail sep=""
  if [[ $# -eq 2 ]]; then
    printf '['
    while IFS=$'\t' read -r name kind detail; do
      printf '%s{"name":"%s","kind":"%s","detail":"%s"}' "$sep" "$(json_escape "$name")" "$kind" "$(json_escape "$detail")"
      sep=","
    done < <(show_rows "$1")
    printf ']\n'
    return
  fi
  while IFS=$'\t' read -r name kind detail; do
    case "$kind" in
      link)     printf '%-24s -> %s\n' "$name" "$detail" ;;
      broken)   printf '%-24s -> %s  [BROKEN]\n' "$name" "$detail" ;;
      worktree) printf '%-24s    worktree of %s\n' "$name" "$detail" ;;
      clone)    printf '%-24s    cloned\n' "$name" ;;
      *)        printf '%-24s    local directory\n' "$name" ;;
    esac
  done < <(show_rows "$1")
  echo
  local file="$WS_ROOT/$1/$1.code-workspace"
  if [[ -f "$file" ]]; then
    echo "editor: $file"
  else
    echo "editor: $file (run: ws --sync $1)"
  fi
  echo "claude: ws --claude $1"
}

cmd_sync() {
  [[ $# -le 1 ]] || die "usage: ws --sync [name]"
  if [[ $# -eq 1 ]]; then
    sync_one "$1"
    return
  fi
  [[ -d "$WS_ROOT" ]] || die "$WS_ROOT missing; run: ws --setup"
  local d found=0
  for d in "$WS_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    found=1
    sync_one "$(basename "$d")"
  done
  [[ "$found" -eq 1 ]] || echo "ws: no workspaces in $WS_ROOT"
}

cmd_open() {
  [[ $# -eq 1 ]] || die "usage: ws --open <name>"
  need_ws "$1"
  local dir="$WS_ROOT/$1"
  if command -v herdr >/dev/null 2>&1; then
    herdr workspace create --cwd "$dir" --label "$1" --focus
  elif command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$1" 2>/dev/null; then
      :
    else
      tmux new-session -d -s "$1" -c "$dir"
    fi
    if [[ -n "${TMUX:-}" ]]; then tmux switch-client -t "$1"; else tmux attach -t "$1"; fi
  else
    die "neither herdr nor tmux found"
  fi
}

cmd_code() {
  [[ $# -eq 1 ]] || die "usage: ws --code <name>"
  open_editor "${WS_CODE_BIN:-code}" "$1"
}

cmd_cursor() {
  [[ $# -eq 1 ]] || die "usage: ws --cursor <name>"
  open_editor "${WS_CURSOR_BIN:-cursor}" "$1"
}

cmd_claude() {
  [[ $# -ge 1 ]] || die "usage: ws --claude <name> [--repo <link>] [--] [claude args...]"
  local name=$1
  shift
  need_ws "$name"
  sync_one "$name" >/dev/null
  exec "$WS_ROOT/$name/.ws/claude.sh" "$@"
}

cmd_cd() {
  # A script can't change the parent shell's directory; the bashrc 'ws'
  # function intercepts --cd. Reaching here means it isn't loaded.
  [[ $# -eq 1 ]] || die "usage: ws --cd <name>"
  need_ws "$1"
  echo "$WS_ROOT/$1"
  echo "(tip: open a new shell so the 'ws' function from ~/.bashrc is loaded)" >&2
}

cmd_clone() {
  [[ $# -ge 2 ]] || die "usage: ws --clone <name> <url> [dir] [-b branch]"
  local name=$1 url=$2 d="" branch=""
  shift 2
  need_ws "$name"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch) [[ $# -ge 2 ]] || die "-b needs a branch"; branch=$2; shift 2 ;;
      *) [[ -z "$d" ]] || die "unexpected argument '$1'"; d=$1; shift ;;
    esac
  done
  [[ -n "$d" ]] || d=$(repo_name_from_url "$url")
  [[ -n "$d" ]] || die "cannot derive a directory name from '$url'; pass one"
  valid_name "$d"
  local dest="$WS_ROOT/$name/$d"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if is_git "$dest" && [[ "$(git -C "$dest" remote get-url origin 2>/dev/null)" == "$url" ]]; then
      echo "ws: $d already cloned from $url"
    else
      die "'$d' already exists in '$name' (give a different dir)"
    fi
  else
    git clone ${branch:+-b "$branch"} -- "$url" "$dest" || die "clone of $url failed"
  fi
  conf_add "$WS_ROOT/$name" "$d|$url${branch:+|$branch}"
  sync_one "$name"
}

# Resolve the directory of a project named in the workspace.
project_dir() { realpath "$WS_ROOT/$1/$2"; }

# Create the worktree <wtdir> of git dir <src> on <branch> (creating the branch if needed).
make_worktree() {
  local src=$1 wt=$2 branch=$3
  git -C "$src" fetch --quiet 2>/dev/null || true
  if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$src" worktree add "$wt" "$branch"
  elif git -C "$src" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$src" worktree add -b "$branch" "$wt" "origin/$branch"
  else
    git -C "$src" worktree add -b "$branch" "$wt"
  fi
}

cmd_bootstrap() {
  [[ $# -eq 1 ]] || die "usage: ws --bootstrap <name>"
  need_ws "$1"
  local dir="$WS_ROOT/$1" e name spec branch src
  while IFS= read -r e; do
    IFS='|' read -r name spec branch <<<"$e"
    if [[ "$spec" == worktree:* ]]; then
      src=${spec#worktree:}
      if [[ -e "$dir/$name" ]]; then echo "ws: $name present"; continue; fi
      if ! is_git "$dir/$src"; then
        echo "ws: skipping worktree $name: source project '$src' is not in this workspace" >&2
        continue
      fi
      make_worktree "$(realpath "$dir/$src")" "$dir/$name" "$branch" >/dev/null
      echo "ws: worktree $name ($branch)"
    else
      if is_git "$dir/$name"; then echo "ws: $name present"; continue; fi
      [[ ! -e "$dir/$name" ]] || die "'$name' exists but is not a git checkout"
      git clone ${branch:+-b "$branch"} -- "$spec" "$dir/$name" || die "clone of $spec failed"
    fi
  done < <(conf_list "$dir")
  sync_one "$1"
  echo "Bootstrap complete."
}

cmd_pull() {
  [[ $# -eq 1 ]] || die "usage: ws --pull <name>"
  need_ws "$1"
  local name path failed=0
  while IFS=$'\t' read -r name path; do
    echo "=== $name ==="
    if ! is_git "$path"; then echo "  (not a git repo, skipping)"; continue; fi
    git -C "$path" pull --ff-only || { echo "  (pull failed: no upstream or not fast-forwardable)"; failed=$((failed + 1)); }
  done < <(collect_projects "$WS_ROOT/$1" 2>/dev/null)
  [[ "$failed" -eq 0 ]] || { echo "ws: $failed project(s) did not pull" >&2; return 1; }
}

# wt, link or clone
project_type() { # dir name
  local e
  e=$(conf_get "$1" "$2" || true)
  if [[ "$e" == *'|worktree:'* ]]; then echo wt
  elif [[ -L "$1/$2" ]]; then echo link
  else echo clone; fi
}

# Seconds -> 5m, 3h, 12d, 4mo, 2y
fmt_age() {
  local s=$1
  if [[ "$s" -lt 3600 ]]; then echo "$((s / 60))m"
  elif [[ "$s" -lt 86400 ]]; then echo "$((s / 3600))h"
  elif [[ "$s" -lt 2592000 ]]; then echo "$((s / 86400))d"
  elif [[ "$s" -lt 31536000 ]]; then echo "$((s / 2592000))mo"
  else echo "$((s / 31536000))y"; fi
}

# Fill INFO_* for a git project. Uses local data only, so run ws --fetch first for fresh remote state.
project_info() { # path
  local path=$1 counts def head defsha ct
  INFO_BRANCH=$(git -C "$path" branch --show-current 2>/dev/null || true)
  [[ -n "$INFO_BRANCH" ]] || INFO_BRANCH=detached
  INFO_DIRTY=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  INFO_AHEAD=0; INFO_BEHIND=0; INFO_GONE=0; INFO_MERGED=0; INFO_AGE_SECS=""
  if counts=$(git -C "$path" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null); then
    read -r INFO_BEHIND INFO_AHEAD <<<"$counts"
  fi
  if [[ "$INFO_BRANCH" != detached ]]; then
    [[ "$(git -C "$path" for-each-ref --format='%(upstream:track)' "refs/heads/$INFO_BRANCH" 2>/dev/null)" == *gone* ]] && INFO_GONE=1
    def=$(git -C "$path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -z "$def" ]]; then
      for def in main master; do git -C "$path" show-ref --verify --quiet "refs/heads/$def" && break || def=""; done
    fi
    if [[ -n "$def" && "$def" != "$INFO_BRANCH" && "$def" != "origin/$INFO_BRANCH" ]]; then
      head=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
      defsha=$(git -C "$path" rev-parse "$def" 2>/dev/null || true)
      # Merged means fully contained in the default branch, not merely a fresh branch cut from it.
      if [[ -n "$head" && "$head" != "$defsha" ]] && git -C "$path" merge-base --is-ancestor HEAD "$def" 2>/dev/null; then
        INFO_MERGED=1
      fi
    fi
  fi
  ct=$(git -C "$path" log -1 --format=%ct 2>/dev/null || true)
  [[ -z "$ct" ]] || INFO_AGE_SECS=$(( $(date +%s) - ct ))
  [[ -z "$INFO_AGE_SECS" || "$INFO_AGE_SECS" -ge 0 ]] || INFO_AGE_SECS=0
}

cmd_status() {
  [[ $# -ge 1 && $# -le 2 && ( $# -eq 1 || "$2" == "--json" ) ]] || die "usage: ws --status <name> [--json]"
  need_ws "$1"
  local dir="$WS_ROOT/$1" name path type st age json=0 sep=""
  [[ $# -eq 2 ]] && json=1
  if [[ $json -eq 1 ]]; then
    printf '['
  else
    printf '%-30s %-6s %-25s %-5s %s\n' DIRECTORY TYPE BRANCH AGE STATUS
    printf '%-30s %-6s %-25s %-5s %s\n' ------------------------------ ------ ------------------------- ----- ------
  fi
  while IFS=$'\t' read -r name path; do
    type=$(project_type "$dir" "$name")
    if ! is_git "$path"; then
      if [[ $json -eq 1 ]]; then
        printf '%s{"name":"%s","type":"%s","path":"%s","git":false}' "$sep" "$(json_escape "$name")" "$type" "$(json_escape "$path")"
        sep=","
      else
        printf '%-30s %-6s %-25s %-5s %s\n' "$name" "$type" "-" "-" "(not a git repo)"
      fi
      continue
    fi
    project_info "$path"
    if [[ $json -eq 1 ]]; then
      printf '%s{"name":"%s","type":"%s","path":"%s","git":true,"branch":"%s","dirty_files":%d,"ahead":%d,"behind":%d,"upstream_gone":%s,"merged":%s,"last_commit_age_seconds":%s}' \
        "$sep" "$(json_escape "$name")" "$type" "$(json_escape "$path")" "$(json_escape "$INFO_BRANCH")" \
        "$INFO_DIRTY" "$INFO_AHEAD" "$INFO_BEHIND" \
        "$([[ $INFO_GONE -eq 1 ]] && echo true || echo false)" "$([[ $INFO_MERGED -eq 1 ]] && echo true || echo false)" \
        "${INFO_AGE_SECS:-null}"
      sep=","
      continue
    fi
    if [[ "$INFO_DIRTY" -eq 0 ]]; then st=clean; else st="dirty ($INFO_DIRTY files)"; fi
    [[ "$INFO_AHEAD" -eq 0 && "$INFO_BEHIND" -eq 0 ]] || st+=" [+$INFO_AHEAD/-$INFO_BEHIND]"
    [[ "$INFO_GONE" -eq 0 ]] || st+=" upstream-gone"
    [[ "$INFO_MERGED" -eq 0 ]] || st+=" merged"
    age="-"; [[ -z "$INFO_AGE_SECS" ]] || age=$(fmt_age "$INFO_AGE_SECS")
    printf '%-30s %-6s %-25s %-5s %s\n' "$name" "$type" "$INFO_BRANCH" "$age" "$st"
  done < <(collect_projects "$dir" 2>/dev/null)
  [[ $json -eq 0 ]] || printf ']\n'
}

# git fetch --all --prune in every project; keeps going on failure.
cmd_fetch() {
  [[ $# -eq 1 ]] || die "usage: ws --fetch <name>"
  need_ws "$1"
  local name path failed=0
  while IFS=$'\t' read -r name path; do
    echo "=== $name ==="
    if ! is_git "$path"; then echo "  (not a git repo, skipping)"; continue; fi
    git -C "$path" fetch --all --prune --quiet || { echo "  (fetch failed)"; failed=$((failed + 1)); }
  done < <(collect_projects "$WS_ROOT/$1" 2>/dev/null)
  [[ "$failed" -eq 0 ]] || { echo "ws: $failed project(s) did not fetch" >&2; return 1; }
}

# Run a command in every project: ws --exec <name> [--only a,b] [--git-only] -- <cmd...>
cmd_exec() {
  local usage="usage: ws --exec <name> [--only repo,repo] [--git-only] -- <command...>"
  [[ $# -ge 3 ]] || die "$usage"
  local name=$1 only="" gitonly=0 p path failed=0 ran=0
  shift
  need_ws "$name"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) [[ $# -ge 2 ]] || die "$usage"; only=",$2,"; shift 2 ;;
      --git-only) gitonly=1; shift ;;
      --) shift; break ;;
      *) die "$usage" ;;
    esac
  done
  [[ $# -gt 0 ]] || die "$usage"
  while IFS=$'\t' read -r p path; do
    [[ -z "$only" || "$only" == *",$p,"* ]] || continue
    if [[ "$gitonly" -eq 1 ]] && ! is_git "$path"; then continue; fi
    echo "=== $p ==="
    ran=$((ran + 1))
    (cd "$path" && "$@") || { echo "  (exit status $?)"; failed=$((failed + 1)); }
  done < <(collect_projects "$WS_ROOT/$name" 2>/dev/null)
  [[ "$ran" -gt 0 ]] || die "no matching projects in '$name'"
  [[ "$failed" -eq 0 ]] || { echo "ws: command failed in $failed of $ran project(s)" >&2; return 1; }
}

cmd_wt_add() {
  local usage="usage: ws --wt-add <name> <branch> [--run <cmd>] [--copy <file,file>] [repo...]"
  [[ $# -ge 2 ]] || die "$usage"
  local name=$1 branch=$2 dir safe repos=() r wt created=0 run="" copy="" f
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run)  [[ $# -ge 2 ]] || die "$usage"; run=$2; shift 2 ;;
      --copy) [[ $# -ge 2 ]] || die "$usage"; copy=$2; shift 2 ;;
      *) repos+=("$1"); shift ;;
    esac
  done
  need_ws "$name"
  dir="$WS_ROOT/$name"
  safe=$(safe_branch "$branch")
  if [[ ${#repos[@]} -eq 0 ]]; then
    # Every project that is a primary checkout (a .git directory, not a worktree).
    while IFS=$'\t' read -r r _; do
      [[ -d "$(project_dir "$name" "$r")/.git" ]] && repos+=("$r")
    done < <(collect_projects "$dir" 2>/dev/null)
  fi
  [[ ${#repos[@]} -gt 0 ]] || die "no git projects in '$name'"
  for r in "${repos[@]}"; do
    [[ -d "$dir/$r" && -d "$(project_dir "$name" "$r")/.git" ]] \
      || die "'$r' is not a primary git checkout in '$name' (a worktree cannot have worktrees)"
  done
  for r in "${repos[@]}"; do
    wt="$r--$safe"
    if [[ -e "$dir/$wt" ]]; then echo "Skipping $wt (already exists)"; continue; fi
    make_worktree "$(project_dir "$name" "$r")" "$dir/$wt" "$branch" >/dev/null \
      || die "could not create worktree for $r on '$branch'"
    conf_add "$dir" "$wt|worktree:$r|$branch"
    echo "Created $wt ($branch)"
    # Untracked config the new checkout needs (.env and the like), copied from the source repo.
    if [[ -n "$copy" ]]; then
      while IFS= read -r f; do
        [[ -n "$f" && "$f" != /* && "$f" != *..* ]] || { echo "  skipping unsafe --copy path '$f'" >&2; continue; }
        if [[ -e "$(project_dir "$name" "$r")/$f" ]]; then
          mkdir -p "$dir/$wt/$(dirname "$f")"
          cp -R "$(project_dir "$name" "$r")/$f" "$dir/$wt/$f"
          echo "  copied $f"
        fi
      done < <(tr ',' '\n' <<<"$copy")
    fi
    if [[ -n "$run" ]]; then
      echo "  running: $run"
      (cd "$dir/$wt" && sh -c "$run") || echo "  WARNING: '$run' failed in $wt" >&2
    fi
    created=$((created + 1))
  done
  if [[ "$created" -eq 0 ]]; then echo "No new worktrees created."; return; fi
  sync_one "$name" >/dev/null
  echo "Done. Run: ws --status $name"
}

cmd_wt_rm() {
  local usage="usage: ws --wt-rm <name> <branch> [--delete-branch] [repo...]"
  [[ $# -ge 2 ]] || die "$usage"
  local name=$1 branch=$2 dir safe repos=() e wn spec b r wt removed=0 src delbranch=0
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-branch) delbranch=1; shift ;;
      *) repos+=("$1"); shift ;;
    esac
  done
  need_ws "$name"
  dir="$WS_ROOT/$name"
  safe=$(safe_branch "$branch")
  if [[ ${#repos[@]} -eq 0 ]]; then
    while IFS= read -r e; do
      IFS='|' read -r wn spec b <<<"$e"
      [[ "$spec" == worktree:* && "$b" == "$branch" ]] && repos+=("${spec#worktree:}")
    done < <(conf_list "$dir")
  fi
  if [[ ${#repos[@]} -eq 0 ]]; then echo "No worktrees found for branch '$branch'."; return; fi
  for r in "${repos[@]}"; do
    wt="$r--$safe"
    if [[ ! -d "$dir/$wt" ]]; then echo "Skipping $wt (not found)"; continue; fi
    if [[ -n "$(git -C "$dir/$wt" status --porcelain 2>/dev/null)" ]]; then
      echo "WARNING: $wt has uncommitted changes; skipping (commit, stash, or remove it by hand)" >&2
      continue
    fi
    src=$(project_dir "$name" "$r") || { echo "Skipping $wt (source '$r' missing)" >&2; continue; }
    git -C "$src" worktree remove "$dir/$wt" 2>/dev/null || git -C "$src" worktree remove --force "$dir/$wt"
    conf_del "$dir" "$wt"
    echo "Removed $wt"
    removed=$((removed + 1))
    # -d, not -D: git refuses unless the branch is merged, so unmerged work is never lost.
    if [[ "$delbranch" -eq 1 ]]; then
      if git -C "$src" branch -d "$branch" >/dev/null 2>&1; then
        echo "  deleted merged branch $branch in $r"
      else
        echo "  kept branch $branch in $r (not merged, or checked out elsewhere)"
      fi
    fi
  done
  sync_one "$name" >/dev/null
  echo "Removed $removed worktree(s)."
  if [[ "$delbranch" -eq 0 ]]; then
    for r in "${repos[@]}"; do
      [[ -d "$dir/$r--$safe" ]] || echo "  branch kept; delete with: ws --wt-rm $name $branch --delete-branch, or: git -C $dir/$r branch -d $branch"
    done
  fi
}


# ---- checkpoints ---------------------------------------------------------------
# A checkpoint saves every git project's branch, HEAD, staged changes, and working files
# (untracked included, ignored excluded) without touching them. Each project gets one commit
# shaped like a stash: its tree is the working files, parent 1 is HEAD, parent 2 holds the
# staged tree. A ref under refs/ws-checkpoints/ keeps that commit from being garbage collected.
# .ws/checkpoints/<label> lists the projects: name<TAB>commit<TAB>branch (empty if detached).

CP_REF=refs/ws-checkpoints

cp_file() { printf '%s' "$WS_ROOT/$1/.ws/checkpoints/$2"; }

valid_label() {
  valid_name "$1"
  [[ "$1" != -* && "$1" != .* ]] || die "invalid checkpoint label '$1' (cannot start with - or .)"
}

# Why the project at <path> cannot be checkpointed or restored right now; empty if it can.
cp_blocker() {
  local f
  git -C "$1" rev-parse -q --verify HEAD >/dev/null || { echo "no commits yet"; return 0; }
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [[ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path "$f")" ]]; then
      echo "a merge, rebase, or cherry-pick is in progress"
      return 0
    fi
  done
}

# Print a snapshot commit of the project at <path>. Reads the repo, changes nothing in it.
cp_snapshot() ( # path message
  p=$1 msg=$2
  export GIT_AUTHOR_NAME=ws GIT_AUTHOR_EMAIL=ws@localhost GIT_COMMITTER_NAME=ws GIT_COMMITTER_EMAIL=ws@localhost
  itree=$(git -C "$p" write-tree) || exit 1
  icommit=$(git -C "$p" commit-tree -p HEAD -m "$msg (staged)" "$itree") || exit 1
  # Stage everything into a throwaway copy of the index, so the real one is left alone.
  tmpi=$(mktemp) || exit 1
  trap 'rm -f "$tmpi"' EXIT
  idx=$(git -C "$p" rev-parse --path-format=absolute --git-path index) || exit 1
  if [[ -f "$idx" ]]; then cp "$idx" "$tmpi"; else rm -f "$tmpi"; fi
  GIT_INDEX_FILE=$tmpi git -C "$p" add -A || exit 1
  wtree=$(GIT_INDEX_FILE=$tmpi git -C "$p" write-tree) || exit 1
  git -C "$p" commit-tree -p HEAD -p "$icommit" -m "$msg" "$wtree"
)

# Save checkpoint <label> of workspace <name>; <only> is ",a,b," or empty for every project.
# Returns 0 if every git project was saved, 1 if some were skipped, 2 if none were.
cp_create() { # name label only
  local name=$1 label=$2 only=$3 file p path why c branch rows="" saved=0 skipped=0 n
  file=$(cp_file "$name" "$label")
  [[ ! -e "$file" ]] || die "checkpoint '$label' already exists in '$name'"
  while IFS=$'\t' read -r p path; do
    [[ -z "$only" || "$only" == *",$p,"* ]] || continue
    is_git "$path" || continue
    why=$(cp_blocker "$path")
    if [[ -n "$why" ]]; then
      echo "  $p: skipped ($why)" >&2; skipped=$((skipped + 1)); continue
    fi
    if ! c=$(cp_snapshot "$path" "ws checkpoint $name/$label: $p") \
       || ! git -C "$path" update-ref "$CP_REF/$c" "$c"; then
      echo "  $p: skipped (could not save)" >&2; skipped=$((skipped + 1)); continue
    fi
    branch=$(git -C "$path" branch --show-current)
    rows+="$p"$'\t'"$c"$'\t'"$branch"$'\n'
    saved=$((saved + 1))
    n=$(git -C "$path" status --porcelain | wc -l | tr -d ' ')
    echo "  $p: ${branch:-detached} @ $(git -C "$path" rev-parse --short HEAD), $n changed file(s)"
  done < <(collect_projects "$WS_ROOT/$name" 2>/dev/null)
  [[ "$saved" -gt 0 ]] || return 2
  mkdir -p "$(dirname "$file")"
  { echo "# created $(date +%s)"; printf '%s' "$rows"; } > "$file.tmp" && mv "$file.tmp" "$file"
  [[ "$skipped" -eq 0 ]] || return 1
}

cp_rows() { grep -v '^#' "$1" || true; }
cp_created() { sed -n 's/^# created //p' "$1" | head -1; }

# Delete checkpoint files and their refs. Refs in projects that are gone are left behind.
cp_drop() { # name label...
  local name=$1 label file p c b path
  shift
  for label in "$@"; do
    file=$(cp_file "$name" "$label")
    [[ -f "$file" ]] || die "no checkpoint '$label' in '$name'"
    while IFS=$'\t' read -r p c b; do
      path="$WS_ROOT/$name/$p"
      is_git "$path" && git -C "$path" update-ref -d "$CP_REF/$c" 2>/dev/null || true
    done < <(cp_rows "$file")
    rm -f "$file"
  done
}

# Labels in creation order.
cp_labels() { # name
  local d="$WS_ROOT/$1/.ws/checkpoints" f
  [[ -d "$d" ]] || return 0
  for f in "$d"/*; do
    [[ -f "$f" && "$f" != *.tmp ]] && printf '%s\t%s\n' "$(cp_created "$f")" "$(basename "$f")"
  done | sort -n | cut -f2
}

cp_list() { # name [--json]
  local name=$1 json=0 label file now sep="" psep p c b count
  [[ $# -le 2 && ( $# -eq 1 || "$2" == "--json" ) ]] || die "usage: ws --checkpoint <name> --list [--json]"
  [[ $# -eq 2 ]] && json=1
  now=$(date +%s)
  if [[ $json -eq 1 ]]; then
    printf '['
    while IFS= read -r label; do
      file=$(cp_file "$name" "$label")
      printf '%s{"label":"%s","created":%s,"projects":[' "$sep" "$(json_escape "$label")" "$(cp_created "$file")"
      psep=""
      while IFS=$'\t' read -r p c b; do
        printf '%s{"name":"%s","commit":"%s","branch":"%s"}' "$psep" "$(json_escape "$p")" "$c" "$(json_escape "$b")"
        psep=","
      done < <(cp_rows "$file")
      printf ']}'
      sep=","
    done < <(cp_labels "$name")
    printf ']\n'
    return
  fi
  if [[ -z "$(cp_labels "$name")" ]]; then echo "No checkpoints in '$name'."; return; fi
  printf '%-32s %-5s %s\n' LABEL AGE PROJECTS
  while IFS= read -r label; do
    file=$(cp_file "$name" "$label")
    count=$(cp_rows "$file" | wc -l | tr -d ' ')
    printf '%-32s %-5s %s\n' "$label" "$(fmt_age $((now - $(cp_created "$file"))))" "$count"
  done < <(cp_labels "$name")
}

cmd_checkpoint() {
  local usage="usage: ws --checkpoint <name> [label] [--only repo,repo]
       ws --checkpoint <name> --list [--json]
       ws --checkpoint <name> --rm <label...>"
  [[ $# -ge 1 ]] || die "$usage"
  local name=$1 label="" only="" rc=0
  shift
  need_ws "$name"
  case "${1:-}" in
    --list) shift; cp_list "$name" "$@"; return ;;
    --rm) shift; [[ $# -ge 1 ]] || die "$usage"; cp_drop "$name" "$@"; echo "Removed $# checkpoint(s)."; return ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) [[ $# -ge 2 ]] || die "$usage"; only=",$2,"; shift 2 ;;
      -*) die "$usage" ;;
      *) [[ -z "$label" ]] || die "$usage"; label=$1; shift ;;
    esac
  done
  [[ -n "$label" ]] || label=$(date +%Y%m%d-%H%M%S)
  valid_label "$label"
  echo "Checkpoint '$label' of $name:"
  cp_create "$name" "$label" "$only" || rc=$?
  [[ "$rc" -ne 2 ]] || die "nothing to checkpoint (no git projects with commits${only:+ matching --only})"
  echo "Restore with: ws --restore $name $label"
  return "$rc"
}

# Put the project at <path> back to snapshot <commit> on <branch> (empty: detached HEAD).
cp_apply() { # path commit branch
  local p=$1 c=$2 b=$3 head
  head=$(git -C "$p" rev-parse "$c^1") || return 1
  if [[ -z "$b" ]]; then
    git -C "$p" checkout -q -f --detach "$head" || return 1
  elif [[ "$(git -C "$p" branch --show-current)" != "$b" ]]; then
    if git -C "$p" show-ref --verify -q "refs/heads/$b"; then
      git -C "$p" checkout -q -f "$b" || return 1
    else
      git -C "$p" checkout -q -f -b "$b" "$head" || return 1
    fi
  fi
  # Untracked files made since the checkpoint are removed (ignored ones are kept); the
  # pre-restore checkpoint holds them, so nothing here is lost for good.
  git -C "$p" reset -q --hard "$head" \
    && git -C "$p" clean -fdq \
    && git -C "$p" read-tree -u --reset "$c^{tree}" \
    && git -C "$p" read-tree "$c^2^{tree}"
}

cmd_restore() {
  local usage="usage: ws --restore <name> <label> [--only repo,repo]"
  [[ $# -ge 2 ]] || die "$usage"
  local name=$1 label=$2 only="" file p c b path targets="" undo rc=0 restored=0 failed=0
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) [[ $# -ge 2 ]] || die "$usage"; only=",$2,"; shift 2 ;;
      *) die "$usage" ;;
    esac
  done
  need_ws "$name"
  valid_label "$label"
  file=$(cp_file "$name" "$label")
  [[ -f "$file" ]] || die "no checkpoint '$label' in '$name' (see: ws --checkpoint $name --list)"
  while IFS=$'\t' read -r p c b; do
    [[ -z "$only" || "$only" == *",$p,"* ]] || continue
    path="$WS_ROOT/$name/$p"
    if ! is_git "$path"; then echo "  $p: skipped (no longer in the workspace)" >&2; failed=$((failed + 1)); continue; fi
    if ! git -C "$path" cat-file -e "$c^{commit}" 2>/dev/null; then
      echo "  $p: skipped (saved commit is missing)" >&2; failed=$((failed + 1)); continue
    fi
    targets+="$p,"
  done < <(cp_rows "$file")
  [[ -n "$targets" ]] || die "nothing to restore from '$label'"

  undo="pre-restore-$(date +%Y%m%d-%H%M%S)"
  [[ ! -e "$(cp_file "$name" "$undo")" ]] || undo="$undo-$$"
  echo "Saving current state as '$undo':"
  cp_create "$name" "$undo" ",$targets" || rc=$?
  [[ "$rc" -ne 2 ]] || die "could not save the current state; nothing was restored"

  echo "Restoring '$label':"
  while IFS=$'\t' read -r p c b; do
    # Only projects whose current state is safely in the pre-restore checkpoint.
    [[ ",$targets" == *",$p,"* ]] || continue
    if ! cp_rows "$(cp_file "$name" "$undo")" | cut -f1 | grep -F -x -q -- "$p"; then
      echo "  $p: not restored (its current state could not be saved)" >&2; failed=$((failed + 1)); continue
    fi
    path=$(project_dir "$name" "$p")
    if cp_apply "$path" "$c" "$b"; then
      echo "  $p: ${b:-detached} @ $(git -C "$path" rev-parse --short HEAD)"
      restored=$((restored + 1))
    else
      echo "  $p: restore failed (see the git error above)" >&2; failed=$((failed + 1))
    fi
  done < <(cp_rows "$file")
  echo "Restored $restored project(s). Undo with: ws --restore $name $undo"
  [[ "$failed" -eq 0 ]] || { echo "ws: $failed project(s) not restored" >&2; return 1; }
}
copy_skill_file() { # md-file dest-skill-dir : wrap a bare markdown skill with frontmatter
  local f=$1 d=$2 base title
  base=$(basename "$f" .md)
  mkdir -p "$d"
  if [[ "$(head -1 "$f")" == "---" ]]; then
    cp "$f" "$d/SKILL.md"
  else
    title=$(sed -n 's/^# //p' "$f" | head -1)
    { printf -- '---\nname: %s\ndescription: %s\n---\n\n' "$base" "${title:-$base}"; cat "$f"; } > "$d/SKILL.md"
  fi
}

assist_project() { # path mode
  local p=$1 mode=$2 f d
  if [[ "$mode" == codex || "$mode" == both ]]; then
    for f in "$p"/.claude/agents/*.md; do
      [[ -f "$f" ]] || continue
      mkdir -p "$p/.codex/agents"; cp "$f" "$p/.codex/agents/"; echo "codex agent: $f"
    done
    for f in "$p"/.claude/skills/*.md; do
      [[ -f "$f" ]] || continue
      copy_skill_file "$f" "$p/.codex/skills/$(basename "$f" .md)"; echo "codex skill: $f"
    done
    for d in "$p"/.claude/skills/*/; do
      [[ -f "$d/SKILL.md" ]] || continue
      mkdir -p "$p/.codex/skills"; rm -rf "$p/.codex/skills/$(basename "$d")"
      cp -R "$d" "$p/.codex/skills/$(basename "$d")"; echo "codex skill: $d"
    done
  fi
  if [[ "$mode" == claude || "$mode" == both ]]; then
    for f in "$p"/.codex/agents/*.md; do
      [[ -f "$f" ]] || continue
      mkdir -p "$p/.claude/agents"; cp "$f" "$p/.claude/agents/"; echo "claude agent: $f"
    done
    for d in "$p"/.codex/skills/*/; do
      [[ -f "$d/SKILL.md" ]] || continue
      mkdir -p "$p/.claude/skills"; rm -rf "$p/.claude/skills/$(basename "$d")"
      cp -R "$d" "$p/.claude/skills/$(basename "$d")"; echo "claude skill: $d"
    done
  fi
}

cmd_assistants() {
  [[ $# -eq 2 ]] || die "usage: ws --assistants <name> codex|claude|both"
  need_ws "$1"
  case "$2" in codex|claude|both) ;; *) die "usage: ws --assistants <name> codex|claude|both" ;; esac
  local name path
  while IFS=$'\t' read -r name path; do
    echo "--- $name ---"
    assist_project "$path" "$2"
  done < <(collect_projects "$WS_ROOT/$1" 2>/dev/null)
  sync_one "$1" >/dev/null
  echo "ws: relinked $WS_ROOT/$1/.claude and .codex"
}

cmd_publish() {
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: ws --publish <name> [git-url]"
  need_ws "$1"
  local dir="$WS_ROOT/$1" url=${2:-} ans
  sync_one "$1" >/dev/null
  echo "Will commit .gitignore CLAUDE.md AGENTS.md README.md workspace.conf in $dir"
  if [[ -n "$url" ]]; then echo "and push to $url"; else echo "and create a private GitHub repo with gh"; fi
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Aborted."; return; }
  [[ -d "$dir/.git" ]] || git -C "$dir" init -q -b main
  git -C "$dir" add .gitignore CLAUDE.md AGENTS.md README.md workspace.conf
  git -C "$dir" diff --cached --quiet || git -C "$dir" commit -q -m "Update workspace shell"
  if [[ -n "$url" ]]; then
    git -C "$dir" remote get-url origin >/dev/null 2>&1 || git -C "$dir" remote add origin "$url"
    git -C "$dir" push -u origin main
  else
    command -v gh >/dev/null 2>&1 || die "gh not found; pass a git-url instead"
    (cd "$dir" && gh repo create "$(gh api user --jq .login)/$1" --private --source=. --push)
  fi
}


# ---- shell completion ---------------------------------------------------------
# ws --completion bash|zsh|fish prints a script. Workspace and project names are read
# from disk at completion time, so they stay current.

cmd_completion() {
  [[ $# -eq 1 ]] || die "usage: ws --completion bash|zsh|fish"
  case "$1" in
    bash) completion_bash ;;
    zsh)  completion_zsh ;;
    fish) completion_fish ;;
    *) die "usage: ws --completion bash|zsh|fish" ;;
  esac
}

completion_bash() {
  cat <<EOS
# bash completion for ws. Add to ~/.bashrc:  eval "\$(ws --completion bash)"
_ws() {
  local cur=\${COMP_WORDS[COMP_CWORD]} cmd=\${COMP_WORDS[1]} root
  root=\$(command ws --config root 2>/dev/null)
  COMPREPLY=()
  if [[ \$COMP_CWORD -eq 1 ]]; then
    COMPREPLY=(\$(compgen -W "$ALL_OPTS" -- "\$cur")); return
  fi
  case "\$cmd" in
    --root) [[ \$COMP_CWORD -eq 2 ]] && { COMPREPLY=(\$(compgen -d -- "\$cur")); return; } ;;
    --completion) COMPREPLY=(\$(compgen -W "bash zsh fish" -- "\$cur")); return ;;
    --config) COMPREPLY=(\$(compgen -W "root" -- "\$cur")); return ;;
  esac
  if [[ "$NAME_OPTS" == *" \$cmd "* ]]; then
    if [[ \$COMP_CWORD -eq 2 ]]; then
      COMPREPLY=(\$(compgen -W "\$(ls "\$root" 2>/dev/null)" -- "\$cur")); return
    fi
    local ws=\${COMP_WORDS[2]}
    case "\$cmd" in
      --add) [[ \$COMP_CWORD -eq 3 ]] && COMPREPLY=(\$(compgen -d -- "\$cur")); return ;;
      --assistants) COMPREPLY=(\$(compgen -W "codex claude both" -- "\$cur")); return ;;
      --wt-add) COMPREPLY=(\$(compgen -W "--run --copy \$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --wt-rm) COMPREPLY=(\$(compgen -W "--delete-branch \$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --exec) COMPREPLY=(\$(compgen -W "--only --git-only --" -- "\$cur")); return ;;
      --checkpoint) COMPREPLY=(\$(compgen -W "--list --rm --only --json \$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)" -- "\$cur")); return ;;
      --restore) COMPREPLY=(\$(compgen -W "--only \$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)" -- "\$cur")); return ;;
      --remove|--claude) COMPREPLY=(\$(compgen -W "\$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --show|--status) COMPREPLY=(\$(compgen -W "--json" -- "\$cur")); return ;;
    esac
  fi
  [[ "\$cmd" == --list ]] && COMPREPLY=(\$(compgen -W "--json" -- "\$cur"))
}
complete -F _ws ws
EOS
}

completion_zsh() {
  cat <<EOS
#compdef ws
# zsh completion for ws. Add to ~/.zshrc:  eval "\$(ws --completion zsh)"
_ws() {
  local root cmd=\$words[2]
  root=\$(command ws --config root 2>/dev/null)
  if (( CURRENT == 2 )); then
    compadd -- ${ALL_OPTS}
    return
  fi
  case "\$cmd" in
    --root) (( CURRENT == 3 )) && { _files -/; return; } ;;
    --completion) compadd -- bash zsh fish; return ;;
    --config) compadd -- root; return ;;
  esac
  if [[ "$NAME_OPTS" == *" \$cmd "* ]]; then
    if (( CURRENT == 3 )); then
      compadd -- \${(f)"\$(ls "\$root" 2>/dev/null)"}
      return
    fi
    local ws=\$words[3]
    local -a projects; projects=(\${(f)"\$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)"})
    case "\$cmd" in
      --add) (( CURRENT == 4 )) && _files -/; return ;;
      --assistants) compadd -- codex claude both ;;
      --wt-add) compadd -- --run --copy \$projects ;;
      --wt-rm) compadd -- --delete-branch \$projects ;;
      --exec) compadd -- --only --git-only -- ;;
      --checkpoint) compadd -- --list --rm --only --json \${(f)"\$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)"} ;;
      --restore) compadd -- --only \${(f)"\$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)"} ;;
      --remove|--claude) compadd -- \$projects ;;
      --show|--status) compadd -- --json ;;
    esac
    return
  fi
  [[ "\$cmd" == --list ]] && compadd -- --json
}
compdef _ws ws
EOS
}

completion_fish() {
  local o names=""
  for o in $NAME_OPTS; do names+=" ${o#--}"; done
  cat <<EOS
# fish completion for ws. Save as ~/.config/fish/completions/ws.fish:  ws --completion fish > ~/.config/fish/completions/ws.fish
function __ws_workspaces
    ls (command ws --config root 2>/dev/null) 2>/dev/null
end
function __ws_projects
    set -l ws (commandline -opc)[3]
    cut -f1 (command ws --config root)/\$ws/.ws/projects.tsv 2>/dev/null
end
function __ws_checkpoints
    set -l ws (commandline -opc)[3]
    ls (command ws --config root)/\$ws/.ws/checkpoints 2>/dev/null
end
function __ws_at_name
    set -l t (commandline -opc)
    test (count \$t) -eq 2; and contains -- (string replace -- '--' '' \$t[2]) $names
end
EOS
  for o in $ALL_OPTS; do
    printf 'complete -c ws -n "test (count (commandline -opc)) -eq 1" -a %s\n' "$o"
  done
  cat <<'EOS'
complete -c ws -n '__ws_at_name' -a '(__ws_workspaces)'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --remove --claude' -a '(__ws_projects)'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --wt-add' -a '(__ws_projects) --run --copy'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --wt-rm' -a '(__ws_projects) --delete-branch'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --checkpoint' -a '(__ws_checkpoints) --list --rm --only --json'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --restore' -a '(__ws_checkpoints) --only'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --assistants' -a 'codex claude both'
complete -c ws -n 'contains -- (commandline -opc)[2] --show --status --list' -a '--json'
complete -c ws -n 'contains -- (commandline -opc)[2] --completion' -a 'bash zsh fish'
EOS
}
need_realpath
if [[ "${1:-}" == "--root" ]]; then
  [[ $# -ge 3 ]] || die "usage: ws --root <dir> <command> [args]"
  WS_ROOT=$(abs_path "$2"); ROOT_SOURCE="--root flag"
  shift 2
fi
[[ $# -ge 1 ]] || { usage; exit 1; }
opt="$1"; shift

# Commands whose first argument is a workspace: accept its --list number. With no workspace
# given, CWD_OPTS use the one the shell is in; PICK_OPTS offer a menu at a terminal.
if [[ "$NAME_OPTS" == *" $opt "* ]]; then
  cur=""
  if [[ "$CWD_OPTS" == *" $opt "* ]]; then cur=$(current_ws || true); fi
  if [[ $# -ge 1 ]] && { [[ -z "$cur" ]] || is_ws_ref "$1"; }; then
    first=$(resolve_ws "$1") || exit 1
    shift
    set -- "$first" "$@"
  elif [[ -n "$cur" ]]; then
    echo "ws: using $cur (current directory)" >&2
    set -- "$cur" "$@"
  elif [[ $# -eq 0 && "$PICK_OPTS" == *" $opt "* && -t 0 && -t 2 ]]; then
    first=$(pick_ws) || exit 1
    set -- "$first"
  fi
fi
case "$opt" in
  --setup)  cmd_setup "$@" ;;
  --config) cmd_config "$@" ;;
  --create) cmd_create "$@" ;;
  --add)    cmd_add "$@" ;;
  --remove) cmd_remove "$@" ;;
  --rename) cmd_rename "$@" ;;
  --delete) cmd_delete "$@" ;;
  --list)   cmd_list "$@" ;;
  --show)   cmd_show "$@" ;;
  --sync)   cmd_sync "$@" ;;
  --open)   cmd_open "$@" ;;
  --code)   cmd_code "$@" ;;
  --cursor) cmd_cursor "$@" ;;
  --claude) cmd_claude "$@" ;;
  --cd)     cmd_cd "$@" ;;
  --clone)  cmd_clone "$@" ;;
  --bootstrap) cmd_bootstrap "$@" ;;
  --pull)   cmd_pull "$@" ;;
  --fetch)  cmd_fetch "$@" ;;
  --exec)   cmd_exec "$@" ;;
  --completion) cmd_completion "$@" ;;
  --status) cmd_status "$@" ;;
  --wt-add) cmd_wt_add "$@" ;;
  --wt-rm)  cmd_wt_rm "$@" ;;
  --checkpoint) cmd_checkpoint "$@" ;;
  --restore) cmd_restore "$@" ;;
  --assistants) cmd_assistants "$@" ;;
  --publish) cmd_publish "$@" ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
