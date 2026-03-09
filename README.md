# werksfeer

Universal git worktree setup tool. Automatically provisions isolated development environments when creating git worktrees — copies env files, symlinks build directories, clones databases, and runs setup commands.

Designed to run unattended for AI coding agents, but works great for humans too.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/werksfeer/main/install.sh | sh
```

Or manually:

```sh
curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/werksfeer/main/werksfeer -o ~/.local/bin/werksfeer
chmod +x ~/.local/bin/werksfeer
```

## Quick start

1. Add a `.worktree.toml` to your project root (can be empty — defaults are auto-detected):

```sh
touch .worktree.toml
```

2. Set up werksfeer for your workflow (see [Setup](#setup) below).

3. Create a worktree — werksfeer runs automatically:

```
[werksfeer] ==> Setting up worktree
[werksfeer] Copied .env
[werksfeer] Symlinked node_modules -> /path/to/main/node_modules
[werksfeer] Cloning myapp_development -> worktree_feature_branch_my_feature
[werksfeer] ==> Worktree setup complete!
```

## What it does

When a new worktree is created, werksfeer:

1. **Copies env files** (`.env`, `.envrc`, `.tool-versions`) from the main worktree
2. **Symlinks build directories** (`node_modules`, `_build`, `deps`, etc.) to avoid redundant installs
3. **Clones PostgreSQL databases** using `CREATE DATABASE ... WITH TEMPLATE` for instant isolation
4. **Writes DB overrides** to `.env.local` (Rails) or appends to `.envrc` (Elixir)
5. **Runs setup commands** (`bin/setup`, `mix deps.get`, `pip install`, etc.)

Everything is idempotent — safe to re-run.

## Setup

### Git hooks

The included `post-checkout` hook triggers werksfeer automatically on `git worktree add`. It only activates for worktree creation (not regular branch checkouts) and only when `.worktree.toml` exists.

```sh
# Global — all repos (note: replaces per-repo hooks):
git config --global core.hooksPath ~/.local/share/werksfeer/hooks

# Single repo:
cp ~/.local/share/werksfeer/hooks/post-checkout .git/hooks/
```

### Claude Code / Claude Desktop

Claude Code's `WorktreeCreate` hook replaces the default worktree creation, so the hook must create the worktree itself and print its path to stdout.

Add to `.claude/settings.json` (or `.claude/settings.local.json`):

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'set -e; NAME=$(cat | jq -r .name); DIR=\"$CLAUDE_PROJECT_DIR/.worktrees/$NAME\"; git worktree add \"$DIR\" --detach HEAD >&2; cd \"$DIR\" && werksfeer >&2; echo \"$DIR\"'"
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'cat | jq -r .worktree_path | xargs werksfeer --cleanup'"
          }
        ]
      }
    ]
  }
}
```

The `WorktreeRemove` hook drops the worktree's cloned databases when the session ends.

### Codex App

Create `.codex/setup.sh` in your project:

```sh
#!/usr/bin/env bash
werksfeer
```

Then select it as your Local Environment setup script in the Codex app settings.

### Cursor

Add to `.cursor/worktrees.json`:

```json
{
  "setup-worktree": [
    "werksfeer"
  ]
}
```

### Other agents / manual use

Run werksfeer after creating a worktree:

```sh
git worktree add ../my-feature feature-branch
cd ../my-feature
werksfeer
```

If your agent supports post-worktree hooks or setup scripts, point them at `werksfeer`. It is idempotent and runs fully unattended.

### Cleanup on worktree removal

Only Claude Code has a worktree removal hook (`WorktreeRemove`), shown above. For Cursor, Codex, and other tools that lack removal hooks, use `werksfeer --prune` periodically to clean up orphaned databases from deleted worktrees.

You can also clean up a specific worktree's databases manually:

```sh
werksfeer --cleanup /path/to/worktree
```

## Supported project types

| Type | Detected by | Symlinked dirs | Setup command | DB pattern |
|------|------------|----------------|---------------|------------|
| Rails | `Gemfile` + `config/database.yml` | `node_modules`, `.bundle`, `tmp/cache` | `bin/setup` | `{name}_development` / `{name}_test` |
| Elixir | `mix.exs` | `_build`, `deps`, `node_modules` | `mix deps.get` | `{name}_dev` / `{name}_test` |
| Python | `pyproject.toml` / `requirements.txt` | `.venv`, `__pycache__` | `uv sync` / `pip install` | — |
| Node | `package.json` | `node_modules`, `.next`, etc. | `npm ci` / `yarn` / `pnpm` / `bun` | — |

## Configuration

Create `.worktree.toml` in your project root. All settings are optional:

```toml
[database]
# Override base database name (default: lowercase directory name)
base_name = "myapp"
# Override suffixes
dev_suffix = "_development"
test_suffix = "_test"

[sync]
# Override directories to symlink
symlink = ["node_modules", "_build", "deps"]
# Override files to copy
copy = [".env", ".envrc"]
# Directories to skip
skip = ["tmp"]

[setup]
# Override setup command
command = "make setup"

[hooks]
# Run after setup completes
post_setup = "echo done"
```

## Pruning orphaned databases

When worktrees are deleted, their cloned databases remain. Werksfeer can clean them up:

```sh
# Prune current project (only drops DBs of deleted worktrees)
werksfeer --prune

# Prune all registered projects
werksfeer --prune-all
```

Smart pruning compares `worktree_*` databases against `git worktree list` — only orphaned databases are dropped.

## How the git hook works

The `post-checkout` hook fires on every `git checkout` and `git worktree add`. Werksfeer only activates when all three conditions are met:

1. It's a branch checkout (not a file checkout)
2. The previous HEAD is the null ref (new worktree, not a branch switch)
3. `.git` is a file (we're in a worktree, not the main checkout or a fresh clone)

If `.worktree.toml` doesn't exist in the repo, the hook exits silently.

## Requirements

- **bash** 3.2+ (ships with macOS, Linux, WSL)
- **git** 2.5+ (worktree support)
- **psql** (optional — only needed for database cloning)
- **curl** (only for installation)

## Debug

```sh
WERKSFEER_DEBUG=1 werksfeer
```

## License

MIT
