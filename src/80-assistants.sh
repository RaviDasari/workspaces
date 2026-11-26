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

