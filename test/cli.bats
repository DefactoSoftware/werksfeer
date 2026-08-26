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
}

@test "Rails setup writes development and test dotenv files" {
  rails_main="${TEST_ROOT}/rails-app"
  rails_worktree="${TEST_ROOT}/worktrees/rails"
  mkdir -p "${rails_main}/config"
  git -C "$rails_main" init -q
  git -C "$rails_main" config user.email test@example.com
  git -C "$rails_main" config user.name "Werksfeer Test"
  printf 'source "https://rubygems.org"\n' > "${rails_main}/Gemfile"
  printf 'development:\n  adapter: postgresql\n' > "${rails_main}/config/database.yml"
  cat > "${rails_main}/.worktree.toml" <<'EOF_CONFIG'
[services]
enabled = ["postgres"]

[database]
base_name = "rails_example"

[setup]
command = "true"
EOF_CONFIG
  git -C "$rails_main" add Gemfile config/database.yml .worktree.toml
  git -C "$rails_main" commit -qm initial
  git -C "$rails_main" -c core.hooksPath=/dev/null worktree add -q --detach "$rails_worktree" HEAD

  run bash -c "cd \"$rails_worktree\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  grep -q 'DATABASE_NAME="rails_example_development"' "${rails_worktree}/.env.local"
  grep -q 'TEST_DATABASE_NAME="rails_example_test"' "${rails_worktree}/.env.local"
  grep -q 'TEST_DATABASE_NAME="rails_example_test"' "${rails_worktree}/.env.test.local"
}
