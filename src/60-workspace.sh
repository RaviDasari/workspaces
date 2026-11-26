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

