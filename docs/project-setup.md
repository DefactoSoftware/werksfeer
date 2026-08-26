# Project setup guide

Werksfeer automatically provisions worktree environments (databases, ports, Redis, env files), but your project needs to read the environment variables it sets. This guide covers the required changes per framework.

Werksfeer writes the following env vars per worktree:

| Variable | Written to | Description |
|----------|-----------|-------------|
| `PORT` | `.envrc` plus framework dotenv files | Unique web server port |
| `DATABASE_NAME` | `.envrc` plus framework dotenv files | Dev database name |
| `TEST_DATABASE_NAME` | `.envrc` plus framework dotenv files | Test database name |
| `REDIS_URL` | `.envrc` plus framework dotenv files | Redis URL with unique port and DB number (Rails) |
| `REDIS_PORT` | `.envrc` plus framework dotenv files | Unique Redis server port (Rails) |
| `DATABASE_SOCKET_DIR` | `.envrc` plus framework dotenv files | Private PostgreSQL Unix socket directory |
| `PGHOST`, `PGPORT`, `PGUSER` | `.envrc` plus framework dotenv files | Standard libpq connection settings |

## Ruby on Rails

### 1. Port

Make the dev server read `PORT` from the environment.

**`Procfile.dev`:**
```diff
-web: bin/rails server -p 3000
+web: bin/rails server -p ${PORT:-3000}
```

Or if you use `bin/dev` without a Procfile, ensure `puma` reads the PORT (it does by default via `ENV.fetch("PORT", 3000)` in `config/puma.rb`).

### 2. Database

Rails projects using `dotenv-rails` typically read `DATABASE_URL` or use `database.yml`. Werksfeer writes `DATABASE_NAME` and `TEST_DATABASE_NAME` to `.env.local` (dev) and `.env.test.local` (test).

Your `database.yml` should reference these:

```yaml
development:
  database: <%= ENV.fetch("DATABASE_NAME", "myapp_development") %>
  host: <%= ENV.fetch("DATABASE_HOST", "localhost") %>
  port: <%= ENV.fetch("DATABASE_PORT", 5432) %>
  username: <%= ENV.fetch("DATABASE_USER", "postgres") %>

test:
  database: <%= ENV.fetch("TEST_DATABASE_NAME", "myapp_test") %>
  host: <%= ENV.fetch("DATABASE_HOST", "localhost") %>
  port: <%= ENV.fetch("DATABASE_PORT", 5432) %>
  username: <%= ENV.fetch("DATABASE_USER", "postgres") %>
```

> **Note:** `dotenv-rails` does NOT load `.env.local` in the test environment, which is why werksfeer also writes `TEST_DATABASE_NAME` to `.env.test.local`.

Werksfeer runs `bin/rails db:prepare` for development and test during worktree
setup. In an interactive direnv shell, the generated `.envrc` starts configured
services automatically. Use `werksfeer exec bin/rails COMMAND` from an agent or
other non-interactive process; no werksfeer code is needed in `bin/rails`.

### 3. Session cookie

Without this, two worktrees on different ports share the same session cookie on localhost, causing login conflicts.

**`config/initializers/session_store.rb`:**
```ruby
session_key = "_myapp_session"
session_key = "#{session_key}_#{ENV['PORT']}" if Rails.env.development? && ENV['PORT']

Rails.application.config.session_store :cache_store,
  key: session_key,
  secure: Rails.env.production?,
  expire_after: 90.minutes
```

This only modifies the cookie name in development when PORT is set. Production is unaffected.

### 4. Redis

Rails apps usually read `REDIS_URL` already (Sidekiq, Action Cable, cache store). Werksfeer writes a `REDIS_URL` with a unique port and database number (e.g. `redis://localhost:6380/2`).

If your `Procfile.dev` starts Redis, use the `REDIS_PORT` variable:

```diff
-redis: redis-server
+redis: redis-server --port ${REDIS_PORT:-6379}
```

No other project changes needed if you already use `ENV["REDIS_URL"]`.

### 5. Gitignore

If your project symlinks `node_modules`, update `.gitignore` to match symlinks too:

```diff
-/node_modules/
+/node_modules
```

A trailing `/` only matches directories, not symlinks.

## Elixir / Phoenix

### 1. Port

Read `PORT` in `config/runtime.exs` so it's picked up at startup — not baked in at compile time. This is important because werksfeer copies `_build` between worktrees, and compile-time env vars would be stale.

**`config/runtime.exs`:**
```elixir
# Add this outside any prod-only block (applies to all environments):
config :myapp, MyAppWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")]
```

Remove any hardcoded or compile-time port from `config/dev.exs`:
```diff
 config :myapp, MyAppWeb.Endpoint,
-  http: [port: 4000],
+  # port is set in runtime.exs
   debug_errors: true,
```

### 2. Database

Use separate env vars for dev and test databases in `config/runtime.exs`. Remove any hardcoded database name from `config/dev.exs`:

**`config/dev.exs`:**
```diff
 config :myapp, MyApp.Repo,
   adapter: Ecto.Adapters.Postgres,
-  database: "myapp_dev",
+  # database is set in runtime.exs via DATABASE_NAME env var
   pool_size: 10
```

**`config/runtime.exs`:**
```elixir
config :myapp, MyApp.Repo,
  username: Env.get_string("DATABASE_USER", "postgres"),
  password: Env.get_string("DATABASE_PASS", "postgres"),
  hostname: Env.get_string("DATABASE_HOST", "localhost"),
  database:
    if(config_env() == :test,
      do: Env.get_string("TEST_DATABASE_NAME", "myapp_test"),
      else: Env.get_string("DATABASE_NAME", "myapp_dev")
    )
```

When the private PostgreSQL provider is enabled, add its socket option:

```elixir
repo_config =
  case System.get_env("DATABASE_SOCKET_DIR") do
    nil -> repo_config
    socket_dir -> Keyword.put(repo_config, :socket_dir, socket_dir)
  end
```

Werksfeer runs the normal Ecto setup/migration tasks while provisioning the
worktree. In an interactive direnv shell, the generated `.envrc` starts services
automatically. Use `werksfeer exec mix COMMAND` from an agent or another
non-interactive process. The Mix project and runtime configuration do not need
to execute werksfeer themselves.

If you use plain `System.get_env` instead of a custom `Env` module:

```elixir
database:
  if(config_env() == :test,
    do: System.get_env("TEST_DATABASE_NAME", "myapp_test"),
    else: System.get_env("DATABASE_NAME", "myapp_dev")
  )
```

Werksfeer writes these env vars to `.envrc`, adds the generic service-start
hook, and runs `direnv allow`.

### Seed/template behavior

For a new private cluster, werksfeer first looks for a cached template whose
commit is an ancestor of the new worktree and whose committed seed inputs are
identical. When found, it clones that stopped cluster and Ecto only applies
pending migrations. When seed inputs changed, the first worktree performs the
normal `ecto.setup`; werksfeer then publishes its clean result for later
worktrees at the same remote base. Publication also requires a clean Git
worktree, so delayed setup cannot share uncommitted migrations or seeds.

The same rule applies to Rails, using `db/seeds.rb`/`db/seeds` as seed inputs
and `db:prepare` as the framework setup command. Custom `[setup] command`
configurations disable template publication by default because their database
semantics are unknown; explicitly set `postgres.template_cache = true` only
when that setup remains safe to snapshot.

### 3. Session cookie

Append the port to the session cookie key in development so worktrees on different ports don't share sessions.

**Endpoint module (e.g. `lib/myapp_web/endpoint.ex`):**

If your endpoint has a compile-time branch for dev sessions:
```diff
 @session_options [
   store: :ets,
-  key: "_myapp_dev",
+  key: "_myapp_dev_#{System.get_env("PORT", "4000")}",
   table: :session
 ]
```

Or if the session plug is inline:
```diff
-plug Plug.Session, store: :ets, key: "_myapp_dev", table: :session
+plug Plug.Session, store: :ets, key: "_myapp_dev_#{System.get_env("PORT", "4000")}", table: :session
```

Production session config should remain unchanged.

### 4. Gitignore

Same as Rails — if your project symlinks `node_modules`:

```diff
-/node_modules/
+/node_modules
```

### 5. .envrc.example

Document the new env vars so other developers know they exist:

```sh
# export DATABASE_NAME="myapp_dev"
# export TEST_DATABASE_NAME="myapp_test"
```

## Checklist

- [ ] Web server reads `PORT` env var
- [ ] Dev database name reads `DATABASE_NAME` env var
- [ ] Test database name reads `TEST_DATABASE_NAME` env var
- [ ] Session cookie key includes port in development
- [ ] `.gitignore` matches `node_modules` symlinks (no trailing `/`)
- [ ] `.worktree.toml` exists in project root (can be empty)
- [ ] Agent and harness commands use `werksfeer exec`, or explicitly load `.envrc` with direnv
- [ ] `.pg_data/` is ignored when the private PostgreSQL provider is enabled
