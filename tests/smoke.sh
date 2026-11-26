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
grep -q 'site--feature-pay *wt *feature/pay *[^ ]* *dirty (1 files)' "$tmp/status" || fail "status: $(cat "$tmp/status")"
grep -q 'site *clone *main *[^ ]* *dirty (1 files)' "$tmp/status" || fail "status clone: $(cat "$tmp/status")"
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

# ---- v2: workspace numbers, menu, --json, --exec, --fetch, status flags, worktree options ----
ln -s "$ws" "$tmp/bin/ws"   # completion shells out to `ws --config root`
"$ws" --create aaa >/dev/null
out=$("$ws" --list); grep -q '^ *1  aaa ' <<<"$out" && grep -q '^ *2  multi ' <<<"$out" || fail "list numbering: $out"
[[ "$("$ws" --show 2)" == "$("$ws" --show multi)" ]] || fail "--show 2 should equal --show multi"
"$ws" --code 1 >/dev/null
[[ "$(cat "$tmp/code.out")" == "$WS_ROOT/aaa/aaa.code-workspace" ]] || fail "--code 1 opened $(cat "$tmp/code.out")"
"$ws" --show 99 >/dev/null 2>"$tmp/err" && fail "--show 99 should fail" || true
grep -q "no workspace number 99" "$tmp/err" || fail "bad number message: $(cat "$tmp/err")"
"$ws" --show 0 >/dev/null 2>&1 && fail "--show 0 should fail" || true
# A directory that is literally named with digits wins over the index.
mkdir "$WS_ROOT/7"; "$ws" --sync 7 >/dev/null
[[ -d "$WS_ROOT/7/.ws" ]] || fail "numeric workspace name not honored"
printf 'y\n' | "$ws" --delete 7 >/dev/null
# No name and no terminal: usage error, never a hang.
"$ws" --code </dev/null >/dev/null 2>"$tmp/err" && fail "--code with no name should fail" || true
grep -q "usage" "$tmp/err" || fail "no-name usage: $(cat "$tmp/err")"
# Menu at a real terminal (pty): choosing 1 opens the first workspace.
rm -f "$tmp/code.out"
python3 - "$ws" <<'PYEOF'
import os, pty, subprocess, sys
m, s = pty.openpty()
p = subprocess.Popen([sys.argv[1], "--code"], stdin=s, stderr=s, stdout=subprocess.DEVNULL)
os.close(s)
os.write(m, b"1\n")
assert p.wait(timeout=30) == 0
PYEOF
[[ "$(cat "$tmp/code.out")" == "$WS_ROOT/aaa/aaa.code-workspace" ]] || fail "menu pick: $(cat "$tmp/code.out" 2>&1)"
printf 'y\n' | "$ws" --delete aaa >/dev/null

"$ws" --list --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert [w["name"] for w in d] == ["multi"] and d[0]["index"] == 1 and d[0]["projects"] >= 2, d'
"$ws" --show multi --json | python3 -c '
import json, sys
d = {e["name"]: e for e in json.load(sys.stdin)}
assert d["site"]["kind"] == "clone" and d["notes"]["kind"] == "local", d'
"$ws" --status multi --json | python3 -c '
import json, sys
d = {e["name"]: e for e in json.load(sys.stdin)}
s = d["site"]
assert s["git"] is True and s["branch"] == "main" and s["type"] == "clone" and s["dirty_files"] >= 0, s
assert s["merged"] is False and s["upstream_gone"] is False and s["last_commit_age_seconds"] >= 0, s
assert d["notes"]["git"] is False, d["notes"]'

"$ws" --fetch multi >/dev/null || fail "fetch"
out=$("$ws" --exec multi --git-only -- git rev-parse --abbrev-ref HEAD); grep -q '=== site ===' <<<"$out" && ! grep -q '=== notes ===' <<<"$out" || fail "exec git-only: $out"
out=$("$ws" --exec multi --only notes -- pwd); grep -q "notes$" <<<"$out" || fail "exec cwd: $out"
"$ws" --exec multi --only site -- sh -c 'exit 3' >/dev/null 2>"$tmp/err" && fail "exec should propagate failure" || true
grep -q "failed in 1 of 1" "$tmp/err" || fail "exec failure summary: $(cat "$tmp/err")"
"$ws" --exec multi --only nope -- true >/dev/null 2>&1 && fail "exec with no match should fail" || true
"$ws" --exec multi >/dev/null 2>&1 && fail "exec without command should fail" || true

# status flags: a branch contained in main is "merged"; --delete-branch only drops merged branches
git -C "$WS_ROOT/multi/site" branch old HEAD~1
"$ws" --wt-add multi old site >/dev/null
"$ws" --status multi | grep -q 'site--old .*merged' || fail "merged flag: $("$ws" --status multi)"
"$ws" --wt-rm multi old site --delete-branch >/dev/null
git -C "$WS_ROOT/multi/site" show-ref --verify -q refs/heads/old && fail "merged branch should be deleted" || true
"$ws" --wt-add multi wip site >/dev/null
git -C "$WS_ROOT/multi/site--wip" commit -q --allow-empty -m unmerged
"$ws" --wt-rm multi wip site --delete-branch >/dev/null
git -C "$WS_ROOT/multi/site" show-ref --verify -q refs/heads/wip || fail "unmerged branch must be kept"

# upstream deleted on the remote shows as upstream-gone after a fetch
git -C "$WS_ROOT/multi/site" push -q origin main:topic
git -C "$WS_ROOT/multi/site" checkout -q -b topic --track origin/topic
git -C "$tmp/remote-web.git" branch -q -D topic
"$ws" --fetch multi >/dev/null
"$ws" --status multi | grep -q 'site .*topic .*upstream-gone' || fail "upstream-gone: $("$ws" --status multi)"
git -C "$WS_ROOT/multi/site" checkout -q main

# --copy and --run on worktree creation
echo SECRET=1 > "$WS_ROOT/multi/site/.env"
"$ws" --wt-add multi envtest site --copy .env,missing.txt --run "touch ran.flag" >/dev/null
[[ "$(cat "$WS_ROOT/multi/site--envtest/.env")" == SECRET=1 && -f "$WS_ROOT/multi/site--envtest/ran.flag" ]] || fail "--copy/--run"
"$ws" --wt-add multi evil site --copy ../../etc/passwd >/dev/null 2>"$tmp/err"
grep -q "unsafe" "$tmp/err" || fail "--copy path traversal not refused"
rm -f "$WS_ROOT/multi/site/.env"
"$ws" --wt-rm multi evil site >/dev/null
rm -f "$WS_ROOT/multi/site--envtest/.env" "$WS_ROOT/multi/site--envtest/ran.flag"
"$ws" --wt-rm multi envtest site >/dev/null

# ---- checkpoints: save everything, let an "agent" wreck it, restore exactly, undo the restore ----
s=$WS_ROOT/multi/site a=$WS_ROOT/multi/remote-api
"$ws" --wt-add multi cpwt site >/dev/null
wt=$WS_ROOT/multi/site--cpwt
printf '*.log\n' >> "$s/.git/info/exclude"
echo staged > "$s/st.txt"; git -C "$s" add st.txt; echo unstaged >> "$s/st.txt"
echo new > "$s/untracked.txt"; echo keep > "$s/debug.log"; echo wt > "$wt/w.txt"
git -C "$s" status --porcelain > "$tmp/cp.before"
head_s=$(git -C "$s" rev-parse HEAD); head_a=$(git -C "$a" rev-parse HEAD)
"$ws" --checkpoint multi before > "$tmp/out" || fail "checkpoint: $(cat "$tmp/out")"
grep -q 'site: main @ .*, [0-9]* changed' "$tmp/out" || fail "checkpoint summary: $(cat "$tmp/out")"
git -C "$s" status --porcelain | cmp -s - "$tmp/cp.before" || fail "checkpoint touched the working tree"
"$ws" --checkpoint multi before >/dev/null 2>&1 && fail "duplicate label accepted" || true
"$ws" --checkpoint multi --bad >/dev/null 2>&1 && fail "bad checkpoint flag accepted" || true

git -C "$s" add -A && git -C "$s" commit -q -m agent
echo junk > "$s/junk.txt"; rm "$wt/w.txt"
git -C "$a" checkout -q -b scratch && git -C "$a" commit -q --allow-empty -m scratch
git -C "$s" gc -q --prune=now   # the checkpoint must survive garbage collection
"$ws" --restore multi before > "$tmp/out" || fail "restore: $(cat "$tmp/out")"
[[ "$(git -C "$s" rev-parse HEAD)" == "$head_s" ]] || fail "site HEAD not restored"
git -C "$s" status --porcelain | cmp -s - "$tmp/cp.before" || fail "site state: $(git -C "$s" status --porcelain)"
[[ "$(cat "$s/st.txt")" == $'staged\nunstaged' && "$(git -C "$s" show :st.txt)" == staged ]] || fail "staged/unstaged split"
[[ ! -e $s/junk.txt && -f $s/debug.log && -f $wt/w.txt ]] || fail "untracked removed, ignored kept, worktree restored"
[[ "$(git -C "$a" branch --show-current)" == main && "$(git -C "$a" rev-parse HEAD)" == "$head_a" ]] || fail "api branch"

undo=$(sed -n 's/.*Undo with: ws --restore multi //p' "$tmp/out")
[[ -n "$undo" ]] || fail "no undo label: $(cat "$tmp/out")"
"$ws" --restore multi "$undo" >/dev/null || fail "undo restore"
[[ -f $s/junk.txt && "$(git -C "$s" log -1 --format=%s)" == agent ]] || fail "undo lost the newer state"
[[ "$(git -C "$a" branch --show-current)" == scratch && ! -e $wt/w.txt ]] || fail "undo api/worktree"
"$ws" --restore multi before --only remote-api >/dev/null || fail "restore --only"
[[ "$(git -C "$a" branch --show-current)" == main && -f $s/junk.txt ]] || fail "--only touched other projects"
"$ws" --restore multi nope >/dev/null 2>&1 && fail "restore of a missing label" || true

"$ws" --checkpoint multi --only site one >/dev/null
out=$("$ws" --checkpoint multi --list); grep -q '^one  *[0-9]*m  *1$' <<<"$out" || fail "list: $out"
"$ws" --checkpoint multi --list --json | python3 -c '
import json, sys
d = {c["label"]: c for c in json.load(sys.stdin)}
assert [p["name"] for p in d["one"]["projects"]] == ["site"], d
assert {p["name"] for p in d["before"]["projects"]} == {"remote-api", "site", "site--cpwt"}, d'
labels=()
while read -r label; do labels+=("$label"); done < <("$ws" --checkpoint multi --list | awk 'NR > 1 {print $1}')
"$ws" --checkpoint multi --rm "${labels[@]}" >/dev/null
[[ -z "$(git -C "$s" for-each-ref refs/ws-checkpoints)" && -z "$(git -C "$a" for-each-ref refs/ws-checkpoints)" ]] || fail "--rm left refs"
[[ "$("$ws" --checkpoint multi --list)" == "No checkpoints in 'multi'." ]] || fail "--rm left files"
git -C "$a" checkout -q main
git -C "$s" reset -q --hard "$head_s" && git -C "$s" clean -fdq && rm -f "$s/debug.log"
"$ws" --wt-rm multi cpwt site >/dev/null

# --delete drops checkpoint refs from linked repos it does not own
git init -q -b main "$tmp/src/linked" && git -C "$tmp/src/linked" commit -q --allow-empty -m one
"$ws" --create cpl >/dev/null && "$ws" --add cpl "$tmp/src/linked" >/dev/null
"$ws" --checkpoint cpl >/dev/null
[[ -n "$(git -C "$tmp/src/linked" for-each-ref refs/ws-checkpoints)" ]] || fail "checkpoint ref missing"
printf 'y\n' | "$ws" --delete cpl >/dev/null
[[ -z "$(git -C "$tmp/src/linked" for-each-ref refs/ws-checkpoints)" ]] || fail "--delete left checkpoint refs"

# completions are valid shell and complete flags, workspaces and projects
"$ws" --completion bash | bash -n || fail "bash completion syntax"
if command -v zsh >/dev/null 2>&1; then "$ws" --completion zsh | zsh -n || fail "zsh completion syntax"; fi
out=$("$ws" --completion fish); grep -q -- '-a --wt-add' <<<"$out" || fail "fish completion"
"$ws" --completion nope >/dev/null 2>&1 && fail "bad shell accepted" || true
bash -c '
  eval "$("$1" --completion bash)"
  COMP_WORDS=(ws --stat); COMP_CWORD=1; _ws
  [[ "${COMPREPLY[*]}" == "--status" ]] || { echo "flag: ${COMPREPLY[*]}"; exit 1; }
  COMP_WORDS=(ws --status ""); COMP_CWORD=2; _ws
  [[ " ${COMPREPLY[*]} " == *" multi "* ]] || { echo "workspace: ${COMPREPLY[*]}"; exit 1; }
  COMP_WORDS=(ws --claude multi ""); COMP_CWORD=3; _ws
  [[ " ${COMPREPLY[*]} " == *" site "* ]] || { echo "project: ${COMPREPLY[*]}"; exit 1; }
' _ "$ws" || fail "bash completion behavior"

# the committed ws must match src/
"$root/build.sh" --check || fail "ws is stale; run ./build.sh"

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
