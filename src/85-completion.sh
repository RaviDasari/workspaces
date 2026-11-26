
# ---- shell completion ---------------------------------------------------------
# ws --completion bash|zsh|fish prints a script. Workspace and project names are read
# from disk at completion time, so they stay current.

cmd_completion() {
  [[ $# -eq 1 ]] || die "usage: ws --completion bash|zsh|fish"
  case "$1" in
    bash) completion_bash ;;
    zsh)  completion_zsh ;;
    fish) completion_fish ;;
    *) die "usage: ws --completion bash|zsh|fish" ;;
  esac
}

completion_bash() {
  cat <<EOS
# bash completion for ws. Add to ~/.bashrc:  eval "\$(ws --completion bash)"
_ws() {
  local cur=\${COMP_WORDS[COMP_CWORD]} cmd=\${COMP_WORDS[1]} root
  root=\$(command ws --config root 2>/dev/null)
  COMPREPLY=()
  if [[ \$COMP_CWORD -eq 1 ]]; then
    COMPREPLY=(\$(compgen -W "$ALL_OPTS" -- "\$cur")); return
  fi
  case "\$cmd" in
    --root) [[ \$COMP_CWORD -eq 2 ]] && { COMPREPLY=(\$(compgen -d -- "\$cur")); return; } ;;
    --completion) COMPREPLY=(\$(compgen -W "bash zsh fish" -- "\$cur")); return ;;
    --config) COMPREPLY=(\$(compgen -W "root" -- "\$cur")); return ;;
  esac
  if [[ "$NAME_OPTS" == *" \$cmd "* ]]; then
    if [[ \$COMP_CWORD -eq 2 ]]; then
      COMPREPLY=(\$(compgen -W "\$(ls "\$root" 2>/dev/null)" -- "\$cur")); return
    fi
    local ws=\${COMP_WORDS[2]}
    case "\$cmd" in
      --add) [[ \$COMP_CWORD -eq 3 ]] && COMPREPLY=(\$(compgen -d -- "\$cur")); return ;;
      --assistants) COMPREPLY=(\$(compgen -W "codex claude both" -- "\$cur")); return ;;
      --wt-add) COMPREPLY=(\$(compgen -W "--run --copy \$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --wt-rm) COMPREPLY=(\$(compgen -W "--delete-branch \$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --exec) COMPREPLY=(\$(compgen -W "--only --git-only --" -- "\$cur")); return ;;
      --checkpoint) COMPREPLY=(\$(compgen -W "--list --rm --only --json \$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)" -- "\$cur")); return ;;
      --restore) COMPREPLY=(\$(compgen -W "--only \$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)" -- "\$cur")); return ;;
      --remove|--claude) COMPREPLY=(\$(compgen -W "\$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)" -- "\$cur")); return ;;
      --show|--status) COMPREPLY=(\$(compgen -W "--json" -- "\$cur")); return ;;
    esac
  fi
  [[ "\$cmd" == --list ]] && COMPREPLY=(\$(compgen -W "--json" -- "\$cur"))
}
complete -F _ws ws
EOS
}

completion_zsh() {
  cat <<EOS
#compdef ws
# zsh completion for ws. Add to ~/.zshrc:  eval "\$(ws --completion zsh)"
_ws() {
  local root cmd=\$words[2]
  root=\$(command ws --config root 2>/dev/null)
  if (( CURRENT == 2 )); then
    compadd -- ${ALL_OPTS}
    return
  fi
  case "\$cmd" in
    --root) (( CURRENT == 3 )) && { _files -/; return; } ;;
    --completion) compadd -- bash zsh fish; return ;;
    --config) compadd -- root; return ;;
  esac
  if [[ "$NAME_OPTS" == *" \$cmd "* ]]; then
    if (( CURRENT == 3 )); then
      compadd -- \${(f)"\$(ls "\$root" 2>/dev/null)"}
      return
    fi
    local ws=\$words[3]
    local -a projects; projects=(\${(f)"\$(cut -f1 "\$root/\$ws/.ws/projects.tsv" 2>/dev/null)"})
    case "\$cmd" in
      --add) (( CURRENT == 4 )) && _files -/; return ;;
      --assistants) compadd -- codex claude both ;;
      --wt-add) compadd -- --run --copy \$projects ;;
      --wt-rm) compadd -- --delete-branch \$projects ;;
      --exec) compadd -- --only --git-only -- ;;
      --checkpoint) compadd -- --list --rm --only --json \${(f)"\$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)"} ;;
      --restore) compadd -- --only \${(f)"\$(ls "\$root/\$ws/.ws/checkpoints" 2>/dev/null)"} ;;
      --remove|--claude) compadd -- \$projects ;;
      --show|--status) compadd -- --json ;;
    esac
    return
  fi
  [[ "\$cmd" == --list ]] && compadd -- --json
}
compdef _ws ws
EOS
}

completion_fish() {
  local o names=""
  for o in $NAME_OPTS; do names+=" ${o#--}"; done
  cat <<EOS
# fish completion for ws. Save as ~/.config/fish/completions/ws.fish:  ws --completion fish > ~/.config/fish/completions/ws.fish
function __ws_workspaces
    ls (command ws --config root 2>/dev/null) 2>/dev/null
end
function __ws_projects
    set -l ws (commandline -opc)[3]
    cut -f1 (command ws --config root)/\$ws/.ws/projects.tsv 2>/dev/null
end
function __ws_checkpoints
    set -l ws (commandline -opc)[3]
    ls (command ws --config root)/\$ws/.ws/checkpoints 2>/dev/null
end
function __ws_at_name
    set -l t (commandline -opc)
    test (count \$t) -eq 2; and contains -- (string replace -- '--' '' \$t[2]) $names
end
EOS
  for o in $ALL_OPTS; do
    printf 'complete -c ws -n "test (count (commandline -opc)) -eq 1" -a %s\n' "$o"
  done
  cat <<'EOS'
complete -c ws -n '__ws_at_name' -a '(__ws_workspaces)'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --remove --claude' -a '(__ws_projects)'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --wt-add' -a '(__ws_projects) --run --copy'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --wt-rm' -a '(__ws_projects) --delete-branch'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --checkpoint' -a '(__ws_checkpoints) --list --rm --only --json'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --restore' -a '(__ws_checkpoints) --only'
complete -c ws -n 'test (count (commandline -opc)) -ge 3; and contains -- (commandline -opc)[2] --assistants' -a 'codex claude both'
complete -c ws -n 'contains -- (commandline -opc)[2] --show --status --list' -a '--json'
complete -c ws -n 'contains -- (commandline -opc)[2] --completion' -a 'bash zsh fish'
EOS
}
