#!/usr/bin/env bash
# ws - group project directories into one symlink workspace.
# Writes a VS Code / Cursor multi-root workspace and Claude Code directory access.
set -euo pipefail

# Where workspaces live, first match wins:
#   1. ws --root <dir> <command>      (this run only)
#   2. $WS_ROOT                       (environment)
#   3. root=<dir> in the config file  (set once with: ws --config root <dir>)
#   4. ~/workspaces, or /workspaces if that already exists and ~/workspaces does not
WS_CONFIG="${WS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ws/config}"

config_get() { # key -> value, empty if unset
  local line
  [[ -f "$WS_CONFIG" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == "$1="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done < "$WS_CONFIG"
  return 0
}

# Make a user-typed path absolute: expand a leading ~, anchor relative paths at $PWD.
abs_path() {
  local p=$1
  case "$p" in
    "~") p=$HOME ;;
    "~/"*) p=$HOME/${p#"~/"} ;;
    /*) ;;
    *) p=$PWD/$p ;;
  esac
  printf '%s' "${p%/}"
}

ROOT_SOURCE=""
WS_ROOT_FROM_ENV=${WS_ROOT:+1}
resolve_root() {
  local v
  if [[ -n "${WS_ROOT:-}" ]]; then
    ROOT_SOURCE="WS_ROOT environment variable"
  elif v=$(config_get root) && [[ -n "$v" ]]; then
    WS_ROOT=$v; ROOT_SOURCE="config file $WS_CONFIG"
  elif [[ ! -d "$HOME/workspaces" && -d /workspaces ]]; then
    WS_ROOT=/workspaces; ROOT_SOURCE="legacy default (existing /workspaces)"
  else
    WS_ROOT=$HOME/workspaces; ROOT_SOURCE="default"
  fi
  WS_ROOT=$(abs_path "$WS_ROOT")
}
resolve_root

