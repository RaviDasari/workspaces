#!/usr/bin/env bash
# ws - group project directories into one symlink workspace.
# Writes a VS Code / Cursor multi-root workspace and Claude Code directory access.
set -euo pipefail

WS_ROOT="${WS_ROOT:-/workspaces}"

usage() {
  cat <<EOF
Usage: ws <option> [args]

  --setup                         Create $WS_ROOT and make it owned by you (uses sudo if needed)
  --create <name>                 Create an empty workspace and its editor/Claude configs
  --add <name> <path> [linkname]  Symlink <path> into workspace <name>
  --remove <name> <linkname>      Remove a symlink from workspace <name> (target untouched)
  --rename <old> <new>            Rename a workspace
  --delete <name>                 Delete a workspace (symlinks and generated configs only)
  --list                          List all workspaces
  --show <name>                   Show the symlinks in a workspace (broken ones flagged)
  --sync [name]                   Regenerate editor and Claude configs (every workspace if omitted)
  --open <name>                   Open workspace in herdr (if installed), else tmux
  --code <name>                   Open the multi-root workspace in VS Code
  --cursor <name>                 Open the multi-root workspace in Cursor
  --claude <name> [--repo <link>] [--] [claude args...]
                                  Start Claude Code with every project passed to --add-dir
  --cd <name>                     cd into workspace (works via the 'ws' shell function)
  -h, --help                      Show this help

Generated inside each workspace (overwritten by --add, --remove, --rename, --sync,
--code, --cursor, and --claude):

  <name>.code-workspace           VS Code and Cursor. Folders use real paths so Git
                                  is detected. Open this file, not the symlink folder.
  .claude/settings.local.json     permissions.additionalDirectories, so a plain
                                  "claude" started in the workspace can read projects.
  .ws/claude.sh                   Launcher used by "ws --claude". Passes --add-dir
                                  so Claude also loads each project's skills.

Environment:
  WS_ROOT         Workspace parent (default /workspaces)
  WS_CODE_BIN     VS Code command (default code)
  WS_CURSOR_BIN   Cursor command (default cursor)
  WS_CLAUDE_BIN   Claude Code command (default claude)

Examples:
  ws --create idp
  ws --add idp ~/src/api
  ws --add idp ~/src/web
  ws --cursor idp
  ws --code idp
  ws --claude idp
  ws --claude idp --repo web
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
      .ws|.claude|.git|.vscode) continue ;;
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
exec "$bin" "${add[@]}" "${args[@]}"
EOF
  chmod +x "$dir/.ws/claude.sh"
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
  sudo mkdir -p "$WS_ROOT"
  sudo chown "$(id -u):$(id -g)" "$WS_ROOT"
  echo "Set up $WS_ROOT"
}

cmd_create() {
  [[ $# -eq 1 ]] || die "usage: ws --create <name>"
  valid_name "$1"
  [[ -w "$WS_ROOT" ]] || die "$WS_ROOT missing or not writable; run: ws --setup"
  [[ ! -e "$WS_ROOT/$1" ]] || die "'$1' already exists"
  mkdir "$WS_ROOT/$1"
  echo "Created $WS_ROOT/$1"
  sync_one "$1"
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
  if [[ "$base" == ".claude" && -d "$entry" && -f "$dir/.ws/generated-claude-settings" ]]; then
    local other
    other=$(find "$entry" -mindepth 1 -maxdepth 1 ! -name settings.local.json | wc -l)
    [[ "$other" -eq 0 && -f "$entry/settings.local.json" ]] && return 0
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
  find "$dir" -mindepth 1 -maxdepth 1 -type l -delete
  rm -f "$dir/$1.code-workspace"
  if [[ -f "$dir/.ws/generated-claude-settings" ]]; then
    rm -f "$dir/.claude/settings.local.json"
    rmdir "$dir/.claude" 2>/dev/null || true
  fi
  rm -rf "$dir/.ws"
  rmdir "$dir"
  echo "Deleted $1"
}

cmd_list() {
  [[ -d "$WS_ROOT" ]] || die "$WS_ROOT missing; run: ws --setup"
  local d n
  for d in "$WS_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    n="$(find "$d" -mindepth 1 -maxdepth 1 -type l | wc -l)"
    printf '%-24s %s link(s)\n' "$(basename "$d")" "$n"
  done
}

cmd_show() {
  [[ $# -eq 1 ]] || die "usage: ws --show <name>"
  need_ws "$1"
  local l file="$WS_ROOT/$1/$1.code-workspace"
  for l in "$WS_ROOT/$1"/*; do
    [[ -L "$l" ]] || continue
    if [[ -e "$l" ]]; then
      printf '%-24s -> %s\n' "$(basename "$l")" "$(readlink "$l")"
    else
      printf '%-24s -> %s  [BROKEN]\n' "$(basename "$l")" "$(readlink "$l")"
    fi
  done
  echo
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

need_realpath
[[ $# -ge 1 ]] || { usage; exit 1; }
opt="$1"; shift
case "$opt" in
  --setup)  cmd_setup "$@" ;;
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
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
