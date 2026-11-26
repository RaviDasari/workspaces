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

