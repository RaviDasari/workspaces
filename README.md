# ws

`ws` groups project directories into one folder of symlinks, then writes the files VS Code, Cursor, and Claude Code need to open that group again.

The symlink folder is for the shell. Editors and Claude Code do not treat that folder as a multi-repo workspace on their own: the folder is not a Git repository, and editor Git discovery skips symlinks. `ws` records the real directory of each project and regenerates:

| File | Used by |
| --- | --- |
| `<name>.code-workspace` | VS Code and Cursor. One workspace folder per project, using the real path so Git is detected. |
| `.claude/settings.local.json` | Claude Code, when you start it in the workspace directory. Grants file access to each project. |
| `.ws/claude.sh` | `ws --claude`. Starts Claude with `--add-dir` for every project so skills are loaded too. |

Those files are rewritten by `--add`, `--remove`, `--rename`, `--sync`, `--code`, `--cursor`, and `--claude`. Edit the symlink list, not the generated files.

## Install

Requires bash and `realpath`.

```bash
git clone https://github.com/<you>/ws.git
cd ws
install -m 755 ws ~/.local/bin/ws
```

Or keep the clone and point the command at it:

```bash
ln -sfn "$PWD/ws" ~/utils/ws
```

Workspaces live in `/workspaces` unless you set `WS_ROOT`.

```bash
ws --setup          # only if /workspaces does not exist yet
```

## Quick start

```bash
ws --create idp
ws --add idp ~/src/api
ws --add idp ~/src/web web
ws --show idp
```

`web` is the name inside the workspace. Omit it to use the directory's basename.

Every child directory is included, whether or not it is a Git repository. Broken symlinks are skipped. Loose files in the workspace folder stay on disk and are not editor roots.

## VS Code and Cursor

Both editors open the same file:

```bash
ws --code idp
ws --cursor idp
```

That runs `code` or `cursor` on `<workspace>/idp.code-workspace`. Set `WS_CODE_BIN` or `WS_CURSOR_BIN` if the command has another name.

Open that file with **File → Open Workspace from File…**. Opening the symlink folder instead shows a single directory and, in Source Control, no repository for the linked projects.

The workspace file stores absolute paths. After you move a project, run `ws --sync idp`.

## Claude Code

Two ways to open the same workspace:

```bash
# File access, skills, and (via an env var) each project's CLAUDE.md.
ws --claude idp

# Git status follows one project. The others are still --add-dir.
ws --claude idp --repo web

# Anything after the name is passed through to claude.
ws --claude idp -- --resume
```

Or start Claude yourself from the workspace directory:

```bash
cd /workspaces/idp
claude
```

That session reads `.claude/settings.local.json`, which lists each project under `permissions.additionalDirectories`. That grants file access only. It does not load `CLAUDE.md`, rules, or skills from those projects. `ws --claude` uses `--add-dir`, which does load skills, and it sets `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` so each project's `CLAUDE.md` and `.claude/rules/` are loaded too.

`ws` will not overwrite a `.claude/settings.local.json` it did not create. Move your own settings aside or merge `additionalDirectories` yourself, then run `ws --sync`.

Claude's Git status follows the directory you start in. The symlink folder is not a repository. Use `--repo <linkname>` when you want Claude's Git view to be one of the projects.

## Commands

```text
ws --setup
ws --create <name>
ws --add <name> <path> [linkname]
ws --remove <name> <linkname>
ws --rename <old> <new>
ws --delete <name>
ws --list
ws --show <name>
ws --sync [name]
ws --open <name>          # herdr, or tmux
ws --code <name>
ws --cursor <name>
ws --claude <name> [--repo <link>] [--] [claude args...]
ws --cd <name>
```

`--delete` removes symlinks and generated configs. It asks first, and it refuses if the workspace contains any other real file or directory. Project directories are never deleted.

`--cd` only changes directory when a shell function wraps `ws`. Otherwise it prints the path.

## License

MIT. See [LICENSE](LICENSE).
