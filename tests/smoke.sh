#!/usr/bin/env bash
# Exercise ws against a temporary WS_ROOT. No editors or network.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
ws=$root/ws
tmp=$(mktemp -d)
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

echo "ok"
