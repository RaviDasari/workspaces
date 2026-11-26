
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
