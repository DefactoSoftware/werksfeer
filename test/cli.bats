#!/usr/bin/env bats

setup() {
  export TEST_ROOT
  TEST_ROOT="$(mktemp -d "${BATS_TMPDIR}/werksfeer.XXXXXX")"
  export XDG_DATA_HOME="${TEST_ROOT}/xdg"
  export WERKSFEER_LIB_DIR="${BATS_TEST_DIRNAME}/../lib/werksfeer"
  WERKSFEER="${BATS_TEST_DIRNAME}/../werksfeer"

  MAIN_REPO="${TEST_ROOT}/example"
  WORKTREE_ONE="${TEST_ROOT}/worktrees/one"
  WORKTREE_TWO="${TEST_ROOT}/worktrees/two"

  mkdir -p "$MAIN_REPO" "$(dirname "$WORKTREE_ONE")"
  git -C "$MAIN_REPO" init -q
  git -C "$MAIN_REPO" config user.email test@example.com
  git -C "$MAIN_REPO" config user.name "Werksfeer Test"

  printf 'defmodule Example.MixProject do\nend\n' > "${MAIN_REPO}/mix.exs"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[services]
enabled = ["postgres"]

[database]
base_name = "example"

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add mix.exs .worktree.toml
  git -C "$MAIN_REPO" commit -qm initial
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WORKTREE_ONE" HEAD
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WORKTREE_TWO" HEAD
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "loads service modules from a development checkout" {
  run "$WERKSFEER" --version

  [ "$status" -eq 0 ]
  [ "$output" = "werksfeer 0.2.0" ]
}

@test "runs with the system Bash used by macOS" {
  run env PATH="/usr/bin:/bin" "$WERKSFEER" --version

  [ "$status" -eq 0 ]
  [ "$output" = "werksfeer 0.2.0" ]
}

@test "derives a stable short socket path for each worktree" {
  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" postgres socket-dir"
  [ "$status" -eq 0 ]
  first_socket="$output"

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" postgres socket-dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$first_socket" ]

  run bash -c "cd \"$WORKTREE_TWO\" && \"$WERKSFEER\" postgres socket-dir"
  [ "$status" -eq 0 ]
  [ "$output" != "$first_socket" ]
  [ "${#output}" -lt 70 ]
}

@test "prints framework-neutral PostgreSQL connection environment" {
  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" services env"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DATABASE_SOCKET_DIR=/tmp/werksfeer-pg-"* ]]
  [[ "$output" == *"DATABASE_HOST=/tmp/werksfeer-pg-"* ]]
  [[ "$output" == *"PGHOST=/tmp/werksfeer-pg-"* ]]
  [[ "$output" == *"PGPORT=5432"* ]]
  [[ "$output" == *"PGUSER=postgres"* ]]
}

@test "explicit opt-out makes service startup a no-op" {
  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\" services start"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid PostgreSQL opt-out values fail clearly" {
  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=maybe \"$WERKSFEER\" services start"

  [ "$status" -eq 2 ]
  [[ "$output" == *"WERKSFEER_POSTGRES must be true, false, 1, or 0"* ]]
}

@test "exec starts configured services before running a command" {
  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=maybe \"$WERKSFEER\" exec true"

  [ "$status" -eq 2 ]
  [[ "$output" == *"WERKSFEER_POSTGRES must be true, false, 1, or 0"* ]]
}

@test "PostgreSQL template fingerprints only committed seed inputs" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"

  run bash -c "source \"$provider\"; postgres_template_seed_fingerprint \"$WORKTREE_ONE\" elixir"
  [ "$status" -eq 0 ]
  initial_fingerprint="$output"

  mkdir -p "${WORKTREE_ONE}/priv/repo/seeds"
  printf ':ok\n' > "${WORKTREE_ONE}/priv/repo/seeds/seeds.exs"
  run bash -c "source \"$provider\"; postgres_template_seed_fingerprint \"$WORKTREE_ONE\" elixir"
  [ "$status" -eq 0 ]
  [ "$output" = "$initial_fingerprint" ]

  git -C "$WORKTREE_ONE" add priv/repo/seeds/seeds.exs
  git -C "$WORKTREE_ONE" commit -qm seeds
  run bash -c "source \"$provider\"; postgres_template_seed_fingerprint \"$WORKTREE_ONE\" elixir"
  [ "$status" -eq 0 ]
  [ "$output" != "$initial_fingerprint" ]
}

@test "custom setup commands require an explicit PostgreSQL template opt-in" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"

  run bash -c 'toml_get() { if [ "$1.$2" = "setup.command" ]; then printf "custom\n"; else printf "%s\n" "$3"; fi; }; source "$1"; postgres_template_cache_enabled' _ "$provider"
  [ "$status" -eq 1 ]

  run bash -c 'toml_get() { case "$1.$2" in setup.command) printf "custom\n" ;; postgres.template_cache) printf "true\n" ;; *) printf "%s\n" "$3" ;; esac; }; source "$1"; postgres_template_cache_enabled' _ "$provider"
  [ "$status" -eq 0 ]
}

@test "PostgreSQL template trees clone without sharing mutable files" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"
  source_dir="${TEST_ROOT}/template-source"
  destination="${TEST_ROOT}/template-copy"
  mkdir -p "$source_dir/base"
  printf 'template\n' > "$source_dir/base/value"

  run bash -c "log_error() { printf '%s\\n' \"\$*\" >&2; }; source \"$provider\"; postgres_copy_tree \"$source_dir\" \"$destination\""
  [ "$status" -eq 0 ]
  [ "$(cat "${destination}/base/value")" = "template" ]

  printf 'worktree\n' > "${destination}/base/value"
  [ "$(cat "${source_dir}/base/value")" = "template" ]
}

@test "setup writes one replaceable managed environment block" {
  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  run grep -c '^# >>> werksfeer managed environment >>>$' "${WORKTREE_ONE}/.envrc"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  grep -q 'export DATABASE_NAME="example_dev"' "${WORKTREE_ONE}/.envrc"
  grep -q 'export TEST_DATABASE_NAME="example_test"' "${WORKTREE_ONE}/.envrc"
  grep -q 'werksfeer services start' "${WORKTREE_ONE}/.envrc"
}

@test "Elixir setup compiles dependencies before app, assets, and database" {
  fake_bin="${TEST_ROOT}/elixir-bin"
  command_log="${TEST_ROOT}/elixir-commands.log"
  mkdir -p "$fake_bin"
  cat > "${fake_bin}/mix" <<'EOF_MIX'
#!/usr/bin/env bash
printf 'mix:%s:%s\n' "${MIX_ENV:-dev}" "$*" >> "$COMMAND_LOG"
EOF_MIX
  cat > "${fake_bin}/npm" <<'EOF_NPM'
#!/usr/bin/env bash
printf 'npm:%s\n' "$*" >> "$COMMAND_LOG"
EOF_NPM
  chmod +x "${fake_bin}/mix" "${fake_bin}/npm"
  cat > "${WORKTREE_ONE}/.worktree.toml" <<'EOF_CONFIG'
[setup]
node_install = "npm install"

[hooks]
post_dependencies = "npm run-script build"
EOF_CONFIG
  printf '{"scripts":{"build":"true"}}\n' > "${WORKTREE_ONE}/package.json"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  expected="${TEST_ROOT}/expected-elixir-commands.log"
  cat > "$expected" <<'EOF_EXPECTED'
mix:dev:deps.get
mix:test:deps.get
mix:dev:deps.compile
mix:dev:compile
npm:install
npm:run-script build
mix:dev:ecto.setup
EOF_EXPECTED
  diff -u "$expected" "$command_log"
}

@test "Rails setup writes development and test dotenv files" {
  rails_main="${TEST_ROOT}/rails-app"
  rails_worktree="${TEST_ROOT}/worktrees/rails"
  fake_bin="${TEST_ROOT}/bin"
  command_log="${TEST_ROOT}/rails-commands.log"
  mkdir -p "${rails_main}/config" "${rails_main}/bin" "$fake_bin"
  git -C "$rails_main" init -q
  git -C "$rails_main" config user.email test@example.com
  git -C "$rails_main" config user.name "Werksfeer Test"
  printf 'source "https://rubygems.org"\n' > "${rails_main}/Gemfile"
  printf 'development:\n  adapter: postgresql\n' > "${rails_main}/config/database.yml"
  cat > "${fake_bin}/bundle" <<'EOF_BUNDLE'
#!/usr/bin/env bash
printf 'bundle:%s\n' "$*" >> "$COMMAND_LOG"
EOF_BUNDLE
  cat > "${rails_main}/bin/rails" <<'EOF_RAILS'
#!/usr/bin/env bash
printf 'rails:%s:%s\n' "${RAILS_ENV:-development}" "$*" >> "$COMMAND_LOG"
EOF_RAILS
  chmod +x "${fake_bin}/bundle" "${rails_main}/bin/rails"
  cat > "${rails_main}/.worktree.toml" <<'EOF_CONFIG'
[services]
enabled = ["postgres"]

[database]
base_name = "rails_example"
EOF_CONFIG
  git -C "$rails_main" add Gemfile bin/rails config/database.yml .worktree.toml
  git -C "$rails_main" commit -qm initial
  git -C "$rails_main" -c core.hooksPath=/dev/null worktree add -q --detach "$rails_worktree" HEAD

  run bash -c "cd \"$rails_worktree\" && PATH=\"$fake_bin:\$PATH\" COMMAND_LOG=\"$command_log\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  grep -q '^bundle:install$' "$command_log"
  grep -q '^rails:development:db:prepare$' "$command_log"
  grep -q '^rails:test:db:prepare$' "$command_log"
  grep -q 'DATABASE_NAME="rails_example_development"' "${rails_worktree}/.env.local"
  grep -q 'TEST_DATABASE_NAME="rails_example_test"' "${rails_worktree}/.env.local"
  grep -q 'TEST_DATABASE_NAME="rails_example_test"' "${rails_worktree}/.env.test.local"
  grep -q 'export DATABASE_NAME="rails_example_development"' "${rails_worktree}/.envrc"
  grep -q 'werksfeer services start' "${rails_worktree}/.envrc"
}
