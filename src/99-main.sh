need_realpath
if [[ "${1:-}" == "--root" ]]; then
  [[ $# -ge 3 ]] || die "usage: ws --root <dir> <command> [args]"
  WS_ROOT=$(abs_path "$2"); ROOT_SOURCE="--root flag"
  shift 2
fi
[[ $# -ge 1 ]] || { usage; exit 1; }
opt="$1"; shift

# Commands whose first argument is a workspace: accept its --list number, and for the
# ones in PICK_OPTS offer a menu when no name is given at a terminal.
if [[ "$NAME_OPTS" == *" $opt "* ]]; then
  if [[ $# -ge 1 ]]; then
    first=$(resolve_ws "$1") || exit 1
    shift
    set -- "$first" "$@"
  elif [[ "$PICK_OPTS" == *" $opt "* && -t 0 && -t 2 ]]; then
    first=$(pick_ws) || exit 1
    set -- "$first"
  fi
fi
case "$opt" in
  --setup)  cmd_setup "$@" ;;
  --config) cmd_config "$@" ;;
  --create) cmd_create "$@" ;;
  --add)    cmd_add "$@" ;;
  --remove) cmd_remove "$@" ;;
  --rename) cmd_rename "$@" ;;
  --delete) cmd_delete "$@" ;;
  --list)   cmd_list "$@" ;;
  --show)   cmd_show "$@" ;;
  --sync)   cmd_sync "$@" ;;
  --open)   cmd_open "$@" ;;
  --code)   cmd_code "$@" ;;
  --cursor) cmd_cursor "$@" ;;
  --claude) cmd_claude "$@" ;;
  --cd)     cmd_cd "$@" ;;
  --clone)  cmd_clone "$@" ;;
  --bootstrap) cmd_bootstrap "$@" ;;
  --pull)   cmd_pull "$@" ;;
  --fetch)  cmd_fetch "$@" ;;
  --exec)   cmd_exec "$@" ;;
  --completion) cmd_completion "$@" ;;
  --status) cmd_status "$@" ;;
  --wt-add) cmd_wt_add "$@" ;;
  --wt-rm)  cmd_wt_rm "$@" ;;
  --checkpoint) cmd_checkpoint "$@" ;;
  --restore) cmd_restore "$@" ;;
  --assistants) cmd_assistants "$@" ;;
  --publish) cmd_publish "$@" ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
