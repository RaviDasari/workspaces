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

