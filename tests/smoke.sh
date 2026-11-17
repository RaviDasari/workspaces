#!/usr/bin/env bash
# Exercise ws against a temporary WS_ROOT. No editors or network.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
ws=$root/ws
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

export WS_ROOT="$tmp/workspaces"
mkdir -p "$WS_ROOT" "$tmp/src/api" "$tmp/src/web" "$tmp/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$tmp/bin/code" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$tmp/code.out"
EOF
cat > "$tmp/bin/cursor" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$tmp/cursor.out"
EOF
cat > "$tmp/bin/claude" <<EOF
#!/bin/sh
{
  echo "cwd=\$(pwd)"
  echo "md=\${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD-}"
  echo "args=\$*"
} > "$tmp/claude.out"
EOF
chmod +x "$tmp/bin/code" "$tmp/bin/cursor" "$tmp/bin/claude"

export PATH="$tmp/bin:$PATH"
export WS_CODE_BIN=code
export WS_CURSOR_BIN=cursor

"$ws" --create demo >/dev/null
"$ws" --add demo "$tmp/src/api" >/dev/null
"$ws" --add demo "$tmp/src/web" web >/dev/null
mkdir -p "$WS_ROOT/demo/notes"
ln -s "$tmp/src/missing" "$WS_ROOT/demo/missing"
"$ws" --sync demo >/dev/null

python3 - "$WS_ROOT/demo/demo.code-workspace" "$tmp/src/api" "$tmp/src/web" <<'PY'
import json, sys
ws_file, api, web = sys.argv[1:]
data = json.load(open(ws_file))
folders = {f["name"]: f["path"] for f in data["folders"]}
assert folders["api"] == api, folders
assert folders["web"] == web, folders
assert "notes" in folders, folders
assert "missing" not in folders, folders
assert data["settings"]["git.autoRepositoryDetection"] is True
PY

python3 - "$WS_ROOT/demo/.claude/settings.local.json" "$tmp/src/api" "$tmp/src/web" <<'PY'
import json, sys
settings, api, web = sys.argv[1:]
dirs = json.load(open(settings))["permissions"]["additionalDirectories"]
assert api in dirs and web in dirs, dirs
assert any(p.endswith("/notes") for p in dirs), dirs
PY

"$ws" --code demo >/dev/null
[[ "$(cat "$tmp/code.out")" == "$WS_ROOT/demo/demo.code-workspace" ]] || fail "code opened the wrong file"

"$ws" --cursor demo >/dev/null
[[ "$(cat "$tmp/cursor.out")" == "$WS_ROOT/demo/demo.code-workspace" ]] || fail "cursor opened the wrong file"

"$ws" --claude demo -- --print hi
grep -q '^cwd='"$WS_ROOT/demo"'$' "$tmp/claude.out" || fail "claude cwd: $(cat "$tmp/claude.out")"
grep -q '^md=1$' "$tmp/claude.out" || fail "claude md env: $(cat "$tmp/claude.out")"
grep -q -- "--add-dir $tmp/src/api" "$tmp/claude.out" || fail "missing api add-dir"
grep -q -- "--add-dir $tmp/src/web" "$tmp/claude.out" || fail "missing web add-dir"
grep -q -- "--print hi" "$tmp/claude.out" || fail "claude args not passed"

"$ws" --claude demo --repo web
grep -q '^cwd='"$tmp/src/web"'$' "$tmp/claude.out" || fail "repo cwd: $(cat "$tmp/claude.out")"
grep -q -- "--add-dir $tmp/src/api" "$tmp/claude.out" || fail "repo mode dropped api"
if grep -q -- "--add-dir $tmp/src/web" "$tmp/claude.out"; then
  fail "repo mode also added the cwd"
fi

if "$ws" --claude demo --repo nope >/dev/null 2>"$tmp/err"; then
  fail "--repo nope should fail"
fi
grep -q "not a project" "$tmp/err" || fail "bad --repo message: $(cat "$tmp/err")"

"$ws" --remove demo web >/dev/null
python3 - "$WS_ROOT/demo/.claude/settings.local.json" "$tmp/src/web" <<'PY'
import json, sys
settings, web = sys.argv[1:]
dirs = json.load(open(settings))["permissions"]["additionalDirectories"]
assert web not in dirs, dirs
PY

"$ws" --rename demo demo2 >/dev/null
[[ -f "$WS_ROOT/demo2/demo2.code-workspace" ]] || fail "renamed workspace file missing"
[[ ! -e "$WS_ROOT/demo2/demo.code-workspace" ]] || fail "old workspace file still present"
[[ ! -e "$WS_ROOT/demo" ]] || fail "old workspace dir still present"

# A hand-written Claude settings file must survive sync.
echo '{"permissions":{"allow":["Bash"]}}' > "$WS_ROOT/demo2/.claude/settings.local.json"
rm -f "$WS_ROOT/demo2/.ws/generated-claude-settings"
"$ws" --sync demo2 >/dev/null
grep -q Bash "$WS_ROOT/demo2/.claude/settings.local.json" || fail "user settings were overwritten"

# Put ws back in charge, then confirm delete refuses a real file and accepts a clean workspace.
rm -rf "$WS_ROOT/demo2/.claude" "$WS_ROOT/demo2/.ws"
"$ws" --sync demo2 >/dev/null
echo keep > "$WS_ROOT/demo2/keep.txt"
if printf 'y\n' | "$ws" --delete demo2 >/dev/null 2>"$tmp/err"; then
  fail "delete should refuse a real file"
fi
grep -q "refusing" "$tmp/err" || fail "delete message: $(cat "$tmp/err")"
[[ -f "$WS_ROOT/demo2/keep.txt" ]] || fail "refused delete removed files"
rm "$WS_ROOT/demo2/keep.txt"
rmdir "$WS_ROOT/demo2/notes"
printf 'y\n' | "$ws" --delete demo2 >/dev/null
[[ ! -e "$WS_ROOT/demo2" ]] || fail "workspace was not deleted"
[[ -d "$tmp/src/api" ]] || fail "delete removed a project target"

# ---- clone-based workspaces, worktrees, merged assistant config ----
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkremote() { # name : bare remote with one commit carrying a Claude agent and a bare-md skill
  local seed="$tmp/seed-$1"
  git init -q -b main "$seed"
  mkdir -p "$seed/.claude/agents" "$seed/.claude/skills"
  echo "# $1 agent" > "$seed/.claude/agents/helper.md"
  printf '# Deploy %s\nsteps\n' "$1" > "$seed/.claude/skills/deploy.md"
  git -C "$seed" add -A && git -C "$seed" commit -q -m init
  git clone -q --bare "$seed" "$tmp/remote-$1.git"
}
mkremote api; mkremote web

"$ws" --create multi "$tmp/remote-api.git" >/dev/null
"$ws" --clone multi "$tmp/remote-web.git" site -b main >/dev/null
[[ -d $WS_ROOT/multi/remote-api/.git && -d $WS_ROOT/multi/site/.git ]] || fail "clones missing"
grep -q '"remote-api|' "$WS_ROOT/multi/workspace.conf" || fail "conf missing api"
grep -q '"site|.*|main"' "$WS_ROOT/multi/workspace.conf" || fail "conf missing branch"
"$ws" --clone multi "$tmp/remote-web.git" site >/dev/null || fail "same-url reclone should be a no-op"
"$ws" --clone multi "$tmp/remote-api.git" site >/dev/null 2>&1 && fail "different url into existing dir should fail" || true

# merged .claude links, relative, resolving
l="$WS_ROOT/multi/.claude/agents/site--helper.md"
[[ -L $l && "$(readlink "$l")" == ../../site/.claude/agents/helper.md && -e $l ]] || fail "agent link: $(readlink "$l")"
[[ -e $WS_ROOT/multi/.claude/skills/remote-api--deploy.md ]] || fail "skill link"
# generated shell files and gitignore (no trailing slash so symlinked projects match too)
[[ -f $WS_ROOT/multi/CLAUDE.md && -f $WS_ROOT/multi/AGENTS.md && -f $WS_ROOT/multi/README.md ]] || fail "docs"
grep -qx '/site' "$WS_ROOT/multi/.gitignore" || fail "gitignore"

# --assistants: claude -> codex wraps frontmatter-less skills
"$ws" --assistants multi codex >/dev/null
head -1 "$WS_ROOT/multi/site/.codex/skills/deploy/SKILL.md" | grep -q '^---$' || fail "codex skill frontmatter"
grep -q 'description: Deploy web' "$WS_ROOT/multi/site/.codex/skills/deploy/SKILL.md" || fail "codex skill description"
[[ -e $WS_ROOT/multi/.codex/agents/site--helper.md ]] || fail "codex agent link"
"$ws" --assistants multi bogus >/dev/null 2>&1 && fail "bad mode accepted" || true

# worktrees
"$ws" --wt-add multi feature/pay >/dev/null
[[ -d $WS_ROOT/multi/site--feature-pay && -d $WS_ROOT/multi/remote-api--feature-pay ]] || fail "worktrees"
[[ "$(git -C "$WS_ROOT/multi/site--feature-pay" branch --show-current)" == feature/pay ]] || fail "wt branch"
grep -q 'site--feature-pay|worktree:site|feature/pay' "$WS_ROOT/multi/workspace.conf" || fail "wt conf"
[[ -e $WS_ROOT/multi/.claude/agents/site--feature-pay--helper.md ]] || fail "wt agent link"
out=$("$ws" --wt-add multi feature/pay 2>&1); grep -q "No new worktrees" <<<"$out" || fail "wt-add not idempotent"
"$ws" --code multi >/dev/null
grep -q 'site--feature-pay' "$WS_ROOT/multi/multi.code-workspace" || fail "wt not an editor folder"
"$ws" --wt-add multi x site--feature-pay >/dev/null 2>&1 && fail "worktree of worktree" || true

echo dirty > "$WS_ROOT/multi/site--feature-pay/f.txt"
"$ws" --status multi > "$tmp/status"
grep -q 'site--feature-pay *wt *feature/pay *dirty (1 files)' "$tmp/status" || fail "status: $(cat "$tmp/status")"
grep -q 'site *clone *main *dirty (1 files)' "$tmp/status" || fail "status clone: $(cat "$tmp/status")"
"$ws" --wt-rm multi feature/pay 2>"$tmp/err" >/dev/null
grep -q "uncommitted" "$tmp/err" || fail "dirty wt not protected"
[[ -d $WS_ROOT/multi/site--feature-pay && ! -e $WS_ROOT/multi/remote-api--feature-pay ]] || fail "wt-rm partial"
rm "$WS_ROOT/multi/site--feature-pay/f.txt"
"$ws" --wt-rm multi feature/pay >/dev/null
[[ ! -e $WS_ROOT/multi/site--feature-pay ]] || fail "wt-rm"
! grep -q '^ *"[^"]*|worktree:' "$WS_ROOT/multi/workspace.conf" || fail "wt conf not cleaned"
git -C "$WS_ROOT/multi/site" show-ref --verify -q refs/heads/feature/pay || fail "branch must be kept"
[[ ! -L $WS_ROOT/multi/.claude/agents/site--feature-pay--helper.md ]] || fail "stale link"

# pull: new upstream commit arrives; a non-git dir is skipped
git -C "$tmp/seed-web" commit -q --allow-empty -m two && git -C "$tmp/seed-web" push -q "$tmp/remote-web.git" HEAD:main
mkdir "$WS_ROOT/multi/notes"
"$ws" --pull multi >/dev/null 2>&1
[[ "$(git -C "$WS_ROOT/multi/site" log --oneline | wc -l | tr -d ' ')" == 2 ]] || fail "pull"

# bootstrap rebuilds from workspace.conf alone (new machine)
"$ws" --wt-add multi hotfix site >/dev/null
cp "$WS_ROOT/multi/workspace.conf" "$tmp/conf.keep"
rm -rf "$WS_ROOT/multi" && mkdir "$WS_ROOT/multi" && cp "$tmp/conf.keep" "$WS_ROOT/multi/workspace.conf"
"$ws" --bootstrap multi >/dev/null
[[ -d $WS_ROOT/multi/site/.git && -d $WS_ROOT/multi/remote-api/.git && -e $WS_ROOT/multi/site--hotfix/.git ]] || fail "bootstrap"
[[ -e $WS_ROOT/multi/.claude/agents/site--helper.md ]] || fail "bootstrap relink"
out=$("$ws" --bootstrap multi 2>&1); grep -q "site present" <<<"$out" || fail "bootstrap not idempotent"

# publish to a plain git url, then delete refuses while real checkouts exist
git init -q --bare "$tmp/shell.git"
printf 'y\n' | "$ws" --publish multi "$tmp/shell.git" >/dev/null 2>&1
git -C "$tmp/shell.git" show main:workspace.conf >/dev/null || fail "publish"
! git -C "$tmp/shell.git" ls-tree -r --name-only main | grep -q '^site' || fail "publish leaked a project"
printf 'y\n' | "$ws" --delete multi >/dev/null 2>&1 && fail "delete should refuse real clones" || true
[[ -d $WS_ROOT/multi/site/.git ]] || fail "refused delete removed a clone"


# ---- workspaces folder: default, config file, env, --root ----
home="$tmp/home"; mkdir -p "$home"
w() { env -u WS_ROOT -u XDG_CONFIG_HOME HOME="$home" "$ws" "$@"; }
[[ "$(w --config root)" == "$home/workspaces" ]] || fail "default root: $(w --config root)"
out=$(w --config); grep -q "default" <<<"$out" || fail "config should name the source"
w --setup >/dev/null; [[ -d $home/workspaces ]] || fail "--setup should create ~/workspaces without sudo"

w --config root "~/code/ws-here" >/dev/null
[[ "$(w --config root)" == "$home/code/ws-here" ]] || fail "saved root: $(w --config root)"
grep -qx "root=$home/code/ws-here" "$home/.config/ws/config" || fail "config file content"
w --setup >/dev/null
w --create one >/dev/null
[[ -d $home/code/ws-here/one ]] || fail "create should use the saved root"
[[ "$(env -u XDG_CONFIG_HOME HOME="$home" WS_ROOT="$tmp/envroot" "$ws" --config root)" == "$tmp/envroot" ]] || fail "env must beat config"
[[ "$(w --root "$tmp/flagroot" --config root)" == "$tmp/flagroot" ]] || fail "--root must win"
w --root "$tmp/flagroot" --setup >/dev/null; w --root "$tmp/flagroot" --create two >/dev/null
[[ -d $tmp/flagroot/two && ! -e $home/code/ws-here/two ]] || fail "--root create"
w --root >/dev/null 2>&1 && fail "--root with no command should fail" || true
w --config root --unset >/dev/null
[[ "$(w --config root)" == "$home/workspaces" ]] || fail "unset root"
! grep -q '^root=' "$home/.config/ws/config" || fail "unset left the line"
w --config bogus >/dev/null 2>&1 && fail "bad --config key" || true


echo "ok"
