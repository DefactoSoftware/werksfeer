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

```sh
wt switch -c my-feature
```

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
2. **Symlinks shared directories** (`node_modules`) to avoid redundant installs
3. **Copies build directories** (`_build`, `deps`, `.bundle`, etc.) from the main worktree
4. **Clones PostgreSQL databases** using `CREATE DATABASE ... WITH TEMPLATE` for instant isolation
5. **Allocates a unique port and Redis database** per worktree, tracked in a registry
6. **Writes overrides** (DB names, port, Redis URL) to `.env.local` (Rails) or `.envrc` (Elixir)
7. **Runs setup commands** (`bin/setup`, `mix deps.get`, `pip install`, etc.)

Everything is idempotent — safe to re-run.

## Setup

### Git hooks

The included `post-checkout` hook triggers werksfeer automatically on worktree creation (via `wt switch -c` or `git worktree add`). It only activates for worktree creation (not regular branch checkouts) and only when `.worktree.toml` exists.

```sh
# Global — all repos (note: replaces per-repo hooks):
git config --global core.hooksPath ~/.local/share/werksfeer/hooks

# Single repo:
cp ~/.local/share/werksfeer/hooks/post-checkout .git/hooks/
```

### Claude Code (CLI)

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

The `WorktreeRemove` hook drops the worktree's cloned databases when the session ends. Note that Claude Code does not always fire this hook reliably (e.g. when the worktree directory is already deleted before the hook runs). Use `werksfeer --prune` periodically to catch any missed cleanups.

### Claude Desktop

Claude Desktop does **not** fire `WorktreeCreate` or `WorktreeRemove` hooks. Use the [git hooks](#git-hooks) approach instead, and run `werksfeer --prune` to clean up after worktrees are removed.

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

### WorkTrunk (`wt`)

We recommend [WorkTrunk](https://github.com/max-sixty/worktrunk) for managing worktrees. With git hooks configured, werksfeer runs automatically:

```sh
wt switch -c my-feature
```

To launch an AI agent in a new worktree:

```sh
wt switch -x claude -c feature-auth -- 'Add user authentication'
```

### Other agents / manual use

Run werksfeer after creating a worktree:

```sh
wt switch -c my-feature
werksfeer
```

Or with plain git:

```sh
git worktree add ../my-feature feature-branch
cd ../my-feature
werksfeer
```

If your agent supports post-worktree hooks or setup scripts, point them at `werksfeer`. It is idempotent and runs fully unattended.

### Cleanup on worktree removal

When a worktree is removed, `--cleanup` drops its cloned databases and releases its port/redis allocations. You can run this manually from inside a worktree before deleting it, or pass a path.

Most tools either lack removal hooks entirely (Cursor, Codex, Claude Desktop) or don't fire them reliably (Claude Code CLI). Use `werksfeer --prune` periodically to clean up orphaned databases and stale allocations from deleted worktrees — this is the most reliable approach.

```sh
# Clean up current worktree (drops DBs, releases port/redis)
werksfeer --cleanup

# Or specify a path
werksfeer --cleanup /path/to/worktree

# Prune current project — drops orphaned DBs and stale allocations
werksfeer --prune

# Prune all registered projects
werksfeer --prune-all
```

## Supported project types

| Type | Detected by | Symlinked | Copied | Setup command | DB pattern |
|------|------------|-----------|--------|---------------|------------|
| Rails | `Gemfile` + `config/database.yml` | `node_modules` | `.bundle`, `tmp/cache` | `bin/setup` | `{name}_development` / `{name}_test` |
| Elixir | `mix.exs` | `node_modules` | `_build`, `deps` | `mix deps.get` | `{name}_dev` / `{name}_test` |
| Python | `pyproject.toml` / `requirements.txt` | — | `.venv`, `__pycache__` | `uv sync` / `pip install` | — |
| Node | `package.json` | `node_modules` | `.next`, `.nuxt`, etc. | `npm ci` / `yarn` / `pnpm` / `bun` | — |

## Project setup

Your project needs to read the environment variables werksfeer sets (`PORT`, `DATABASE_NAME`, `TEST_DATABASE_NAME`, `REDIS_URL`, `REDIS_PORT`). See **[docs/project-setup.md](docs/project-setup.md)** for a step-by-step guide with examples for Rails and Elixir/Phoenix.

## Port and Redis allocation

Each worktree gets a unique port, Redis port, and Redis database number, so you can run multiple worktrees simultaneously without conflicts.

- **Ports** are allocated sequentially starting from the base port + 1 (e.g. 3001, 3002, ... for Rails). Ports are globally unique across all projects.
- **Redis ports** are allocated sequentially starting from 6380. Each worktree runs its own Redis instance.
- **Redis databases** are allocated per-project from 1–15 for extra isolation.
- Allocations are tracked in a registry at `~/.local/share/werksfeer/allocations` and released on `--cleanup` or `--prune`.

Your project needs to read the `PORT` environment variable for this to work. Examples:

**Rails** — `Procfile.dev`:
```
web: bin/rails server -p ${PORT:-3000}
redis: redis-server --port ${REDIS_PORT:-6379}
```

**Elixir** — `config/dev.exs`:
```elixir
config :myapp, MyAppWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")]
```

## Configuration

Create `.worktree.toml` in your project root. All settings are optional:

```toml
[database]
# Override base database name (default: lowercase directory name)
base_name = "myapp"
# Override suffixes
dev_suffix = "_development"
test_suffix = "_test"

[port]
# Base port for the web server (default: 3000 for Rails/Node, 4000 for Elixir, 8000 for Python)
# Worktrees are allocated ports starting from base+1.
base = 3000

[redis]
# Base Redis URL (default: redis://localhost:6379 for Rails, empty for others)
# Each worktree gets a unique Redis port (starting from 6380) and database number.
url = "redis://localhost:6379"

[sync]
# Override directories to symlink (default: node_modules)
symlink = ["node_modules"]
# Override directories to copy (default: build dirs per project type)
copy_dirs = ["_build", "deps"]
# Override files to copy
copy = [".env", ".envrc"]
# Directories to skip
skip = ["tmp"]

[setup]
# Override setup command
command = "make setup"

[warmup]
# Branch --warmup updates (default: origin's default branch)
branch = "main"
# Override the auto-detected warmup command
command = "bin/setup"
# Skip if the last warmup was less than N minutes ago (default: 0, always run)
min_interval = 45
# Max seconds setup waits for a running warmup (default: 1800)
wait_timeout = 1800

[hooks]
# Run after setup completes
post_setup = "echo done"
```

## Keeping the main worktree warm

New worktrees are only as fresh as the main worktree they copy from: stale
`_build`/`deps` means long compiles, an unmigrated main database means every
clone starts behind. `--warmup` keeps main fresh:

```sh
werksfeer --warmup           # update main: pull, deps, build, migrate
werksfeer --warmup --force   # ignore the min_interval throttle
```

Per project type it runs (override with `[warmup] command`):

| Type | Warmup command |
|------|----------------|
| Rails | `bundle install && bin/rails db:prepare` |
| Elixir | `mix deps.get && mix compile && mix ecto.migrate` (+ JS install if `package.json` exists) |
| Python | `uv sync` / `pipenv install` / `pip install -r requirements.txt` |
| Node | `npm ci` / `yarn` / `pnpm` / `bun` |

Before running the command it checks out the default branch (from
`origin/HEAD`, override with `[warmup] branch`) and pulls with `--ff-only`.
It refuses to touch a main worktree with uncommitted changes.

While a warmup runs it holds a per-project lock under
`~/.local/share/werksfeer/warmup/`. Worktree setup waits on that lock (up to
`[warmup] wait_timeout` seconds, default 1800), so a new worktree never
copies a half-built cache. Stale locks from crashed runs are detected by PID
and cleaned up automatically.

Trigger it however suits you — the `min_interval` throttle makes overlapping
triggers cheap:

```sh
# cron: hourly during work hours (Linux)
0 9-18 * * 1-5 cd ~/projects/myapp && werksfeer --warmup

# macOS: launchd StartCalendarInterval, or simply from your shell startup:
(cd ~/projects/myapp && werksfeer --warmup >/dev/null 2>&1 &)
```

## Pruning orphaned databases

When worktrees are deleted (via `wt remove` or `git worktree remove`), their cloned databases and port/redis allocations remain. Werksfeer can clean them up:

```sh
# Prune current project (drops orphaned DBs, releases stale allocations)
werksfeer --prune

# Prune all registered projects
werksfeer --prune-all
```

Smart pruning compares `worktree_*` databases against active worktrees — only orphaned databases are dropped and only stale allocations are released.

## How the git hook works

The `post-checkout` hook fires on every `git checkout` and worktree creation (via `wt switch -c` or `git worktree add`). Werksfeer only activates when all three conditions are met:

1. It's a branch checkout (not a file checkout)
2. The previous HEAD is the null ref (new worktree, not a branch switch)
3. `.git` is a file (we're in a worktree, not the main checkout or a fresh clone)

If `.worktree.toml` doesn't exist in the repo, the hook exits silently.

## Requirements

- **bash** 3.2+ (ships with macOS, Linux, WSL)
- **git** 2.5+ (worktree support) — [WorkTrunk](https://github.com/max-sixty/worktrunk) (`wt`) recommended for worktree management
- **psql** (optional — only needed for database cloning)
- **curl** (only for installation)

## Debug

```sh
WERKSFEER_DEBUG=1 werksfeer
```

## License

MIT
