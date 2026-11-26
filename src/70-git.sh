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

