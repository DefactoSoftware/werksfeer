# werksfeer

Universal git worktree setup tool. Automatically provisions isolated development environments when creating git worktrees — copies env files, syncs build directories, manages per-worktree services, provisions databases, and runs setup commands.

Designed to run unattended for AI coding agents, but works great for humans too.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/werksfeer/main/install.sh | sh
```

For a local checkout under development:

```sh
git clone https://github.com/DefactoSoftware/werksfeer.git
./werksfeer/install.sh
```

When executed from a checkout, `install.sh` installs that local version. When
piped from the published URL, it downloads the matching files from `main`.

The installer keeps the executable on `PATH` and installs its service modules
under `${XDG_DATA_HOME:-~/.local/share}/werksfeer`.

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
4. **Provisions PostgreSQL** by cloning databases on a shared server or starting a private cluster on a Unix socket
5. **Allocates a unique port and Redis database** per worktree, tracked in a registry
6. **Writes overrides** to a shared `.envrc` contract plus framework dotenv files where useful
7. **Runs framework setup** (dependencies, database preparation, migrations, and first-time seeds)

Everything is idempotent — safe to re-run. Private services are opt-in, so
existing repositories retain the shared-server cloning behavior.

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

| Type | Detected by | Symlinked | Copied | Setup command | Shared DB pattern |
|------|------------|-----------|--------|---------------|------------|
| Rails | `Gemfile` + `config/database.yml` | `node_modules` | `.bundle`, `tmp/cache` | `bundle install`, `db:prepare` | `{name}_development` / `{name}_test` |
| Elixir | `mix.exs` | `node_modules` | `_build`, `deps` | deps, assets, Ecto setup/migrate | `{name}_dev` / `{name}_test` |
| Python | `pyproject.toml` / `requirements.txt` | — | `.venv`, `__pycache__` | `uv sync` / `pip install` | — |
| Node | `package.json` | `node_modules` | `.next`, `.nuxt`, etc. | `npm ci` / `yarn` / `pnpm` / `bun` | — |

## Project setup

Your project needs to read the environment variables werksfeer sets (`PORT`, `DATABASE_NAME`, `TEST_DATABASE_NAME`, `REDIS_URL`, `REDIS_PORT`). See **[docs/project-setup.md](docs/project-setup.md)** for a step-by-step guide with examples for Rails and Elixir/Phoenix.

## Private PostgreSQL per worktree

Werksfeer can run one PostgreSQL server per linked worktree, with durable data
inside the checkout and no TCP listener. Enable the built-in provider:

```toml
[services]
enabled = ["postgres"]

[postgres]
required_extensions = ["citext", "pg_trgm", "pgcrypto", "vector"]

[database]
base_name = "myapp"
```

The provider uses a short, deterministic `/tmp/werksfeer-pg-...` Unix socket
because agent-managed worktree paths can exceed Unix socket path limits. Its
directory is owned by the current user with mode `0700`; PostgreSQL TCP
listening is disabled.

Application frameworks still own database creation, schema, migrations, and
seeds. Werksfeer invokes their normal commands: `bin/rails db:prepare` for
Rails and Ecto tasks for Phoenix. It manages the server process and writes
connection variables:

- libpq: `PGHOST`, `PGPORT`, `PGUSER`;
- framework-neutral: `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`;
- Postgrex-specific convenience: `DATABASE_SOCKET_DIR`.

Lifecycle commands are shared across frameworks and agent harnesses:

```sh
werksfeer services start
werksfeer services stop
werksfeer services status
werksfeer services doctor
werksfeer services env
werksfeer postgres socket-dir
werksfeer postgres database-exists myapp_development
werksfeer postgres template-status
werksfeer exec bin/rails db:prepare
```

The generated `.envrc` starts configured services when a direnv-enabled shell
enters the worktree. `werksfeer exec COMMAND` does the same for non-interactive
agent and harness commands before loading the worktree environment.

### Seeded template cache

Private PostgreSQL setup maintains a cold, content-addressed template cache
under `${XDG_CACHE_HOME:-$HOME/.cache}/werksfeer/postgres-templates`. A new
worktree clones the newest cached ancestor with identical committed seed inputs,
using copy-on-write on APFS and supported Linux filesystems, and then runs the
application's pending migrations.

The cache refresh is demand-driven rather than clock-driven:

1. the first worktree at the current remote default ref is prepared normally;
2. after setup succeeds, werksfeer stops its new cluster, snapshots it, and
   restarts it;
3. subsequent worktrees clone that immutable snapshot;
4. new migrations reuse and advance an older compatible snapshot;
5. changed seed inputs force one fresh seed before publishing a new snapshot.

Only a database newly created during unattended setup can be published, and
only when `HEAD` exactly matches the configured remote ref and the worktree is
clean. Existing developer databases, uncommitted changes, and feature-branch
commits are never cached. Three templates are kept by default. Inspect the
current selection with:

```sh
werksfeer postgres template-status
```

`werksfeer --cleanup` stops configured services before releasing allocations.
Set `WERKSFEER_POSTGRES=false` to opt one worktree out, or `true` to run the
configured service from a main checkout.

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

[services]
# Built-in lifecycle providers. Omit this section to keep shared DB cloning.
enabled = ["postgres"]

[postgres]
# Worktree-relative durable cluster path (default: .pg_data)
data_dir = ".pg_data"
# Short parent for Unix sockets (default: /tmp)
socket_root = "/tmp"
port = 5432
user = "postgres"
# Validate extension control files before initializing or starting the cluster
required_extensions = ["citext", "pg_trgm", "vector"]
# Seeded cold-cluster cache (defaults shown)
template_cache = true
# Auto-detected from origin/HEAD, then origin/main or origin/master
# template_ref = "origin/main"
template_retention = 3

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

[hooks]
# Run after setup completes
post_setup = "echo done"
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

Private PostgreSQL processes must be stopped before their checkout is removed,
because their control files live in that checkout. Configure
`werksfeer --cleanup` as the harness teardown/archive command. Paseo,
Conductor, and other harnesses with lifecycle hooks can all use the same command.
`--prune` remains the recovery path for shared-server clones and stale
port/Redis allocations.

## How the git hook works

The `post-checkout` hook fires on every `git checkout` and worktree creation (via `wt switch -c` or `git worktree add`). Werksfeer only activates when all three conditions are met:

1. It's a branch checkout (not a file checkout)
2. The previous HEAD is the null ref (new worktree, not a branch switch)
3. `.git` is a file (we're in a worktree, not the main checkout or a fresh clone)

If `.worktree.toml` doesn't exist in the repo, the hook exits silently.

## Requirements

- **bash** 3.2+ (ships with macOS, Linux, WSL)
- **git** 2.5+ (worktree support) — [WorkTrunk](https://github.com/max-sixty/worktrunk) (`wt`) recommended for worktree management
- **PostgreSQL client tools** (optional — needed for database cloning)
- **PostgreSQL server tools** (optional — needed for the private provider;
  `pg_config` must resolve the matching `initdb`, `pg_ctl`, and `postgres`)
- **direnv** (recommended — automatically loads each worktree environment and
  starts its configured services in interactive shells)
- **curl** (only for installation)

## Development

The CLI and service-provider tests use Bats; shell sources are checked with
ShellCheck:

```sh
test/run
shellcheck -x werksfeer install.sh hooks/post-checkout lib/werksfeer/*.sh lib/werksfeer/services/*.sh
```

## Debug

```sh
WERKSFEER_DEBUG=1 werksfeer
```

## License

MIT
