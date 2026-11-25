#!/usr/bin/env bats

setup() {
  export TEST_ROOT
  TEST_ROOT="$(mktemp -d "${BATS_TMPDIR}/werksfeer.XXXXXX")"
  export XDG_DATA_HOME="${TEST_ROOT}/xdg"
  export XDG_CACHE_HOME="${TEST_ROOT}/cache"
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
  cat > "${MAIN_REPO}/.gitignore" <<'EOF_GITIGNORE'
/_build
/deps
/node_modules
/priv/static
.worktree.local.toml
.envrc
EOF_GITIGNORE
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[services]
enabled = ["postgres"]

[database]
base_name = "example"

[cache]
# Most tests exercise the legacy main-checkout path in isolation. Tests for
# managed caches replace this fixture and verify the default-on behavior.
auto_warm = false

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add mix.exs .gitignore .worktree.toml
  git -C "$MAIN_REPO" commit -qm initial
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WORKTREE_ONE" HEAD
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WORKTREE_TWO" HEAD
}

teardown() {
  # Stop any private clusters a test started, even when it failed midway.
  local worktree
  for worktree in "$WORKTREE_ONE" "$WORKTREE_TWO"; do
    [ -f "${worktree}/.pg_data/postmaster.pid" ] || continue
    (cd "$worktree" && "$WERKSFEER" services stop >/dev/null 2>&1) || true
  done
  rm -rf "$TEST_ROOT"
}

@test "loads service modules from a development checkout" {
  run "$WERKSFEER" --version

  [ "$status" -eq 0 ]
  [ "$output" = "werksfeer 0.4.0" ]
}

@test "runs with the system Bash used by macOS" {
  run env PATH="/usr/bin:/bin" "$WERKSFEER" --version

  [ "$status" -eq 0 ]
  [ "$output" = "werksfeer 0.4.0" ]
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

@test "initializes PostgreSQL with the standard UTF-8 locale" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"
  fake_initdb="${TEST_ROOT}/initdb"
  command_log="${TEST_ROOT}/initdb-arguments.log"

  cat > "$fake_initdb" <<'EOF_INITDB'
#!/usr/bin/env bash
printf 'LC_ALL=%s\n' "$LC_ALL" > "$COMMAND_ENV_LOG"
printf '%s\n' "$@" > "$COMMAND_LOG"
EOF_INITDB
  chmod +x "$fake_initdb"

  run env COMMAND_LOG="$command_log" COMMAND_ENV_LOG="${TEST_ROOT}/initdb-environment.log" LC_ALL=C bash -c '
    toml_get() { printf "%s\n" "$3"; }
    log_info() { :; }
    source "$1"
    POSTGRES_INITDB="$2"
    postgres_initialize_cluster "$3"
  ' _ "$provider" "$fake_initdb" "${TEST_ROOT}/postgres-data"

  [ "$status" -eq 0 ]
  grep -Fqx -- '--encoding=UTF8' "$command_log"
  grep -Fqx -- '--locale=en_US.UTF-8' "$command_log"
  grep -Fqx -- 'LC_ALL=en_US.UTF-8' "${TEST_ROOT}/initdb-environment.log"
}

@test "starts PostgreSQL with the configured cluster locale" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"

  run env LC_ALL=C bash -c '
    toml_get() { printf "%s\n" "$3"; }
    source "$1"
    postgres_run_with_locale sh -c '\''printf "%s\n" "$LC_ALL"'\''
  ' _ "$provider"

  [ "$status" -eq 0 ]
  [ "$output" = "en_US.UTF-8" ]
}

@test "accepts equivalent PostgreSQL locale spellings" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"
  fake_psql="${TEST_ROOT}/psql"

  cat > "$fake_psql" <<'EOF_PSQL'
#!/usr/bin/env bash
printf 'UTF8|en_US.utf8|en_US.utf8\n'
EOF_PSQL
  chmod +x "$fake_psql"

  run bash -c '
    toml_get() { printf "%s\n" "$3"; }
    log_error() { printf "%s\n" "$*" >&2; }
    source "$1"
    POSTGRES_PSQL="$2"
    postgres_socket_directory() { printf "/tmp/example\n"; }
    postgres_check_cluster_metadata "$3" "$3/.pg_data"
  ' _ "$provider" "$fake_psql" "$WORKTREE_ONE"

  [ "$status" -eq 0 ]
}

@test "rejects an existing PostgreSQL cluster with incompatible metadata" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"
  fake_psql="${TEST_ROOT}/psql"

  cat > "$fake_psql" <<'EOF_PSQL'
#!/usr/bin/env bash
printf 'UTF8|C|C\n'
EOF_PSQL
  chmod +x "$fake_psql"

  run bash -c '
    toml_get() { printf "%s\n" "$3"; }
    log_error() { printf "%s\n" "$*" >&2; }
    source "$1"
    POSTGRES_PSQL="$2"
    postgres_socket_directory() { printf "/tmp/example\n"; }
    postgres_check_cluster_metadata "$3" "$3/.pg_data"
  ' _ "$provider" "$fake_psql" "$WORKTREE_ONE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"uses UTF8/C/C"* ]]
  [[ "$output" == *"Expected UTF8/en_US.UTF-8/en_US.UTF-8"* ]]
}

@test "main checkout local config opts all worktrees out of private PostgreSQL" {
  cat > "${MAIN_REPO}/.worktree.local.toml" <<'EOF_LOCAL_CONFIG'
[postgres]
enabled = false
EOF_LOCAL_CONFIG

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" services env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=/usr/bin:/bin \"$WERKSFEER\" services doctor"
  [ "$status" -eq 0 ]
  [ "$output" = "enabled=false" ]
}

@test "worktree local config and environment can override the main preference" {
  cat > "${MAIN_REPO}/.worktree.local.toml" <<'EOF_MAIN_CONFIG'
[postgres]
enabled = false
EOF_MAIN_CONFIG
  cat > "${WORKTREE_ONE}/.worktree.local.toml" <<'EOF_WORKTREE_CONFIG'
[postgres]
enabled = true
EOF_WORKTREE_CONFIG

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" services env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DATABASE_SOCKET_DIR=/tmp/werksfeer-pg-"* ]]

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\" services env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid local PostgreSQL preferences fail clearly" {
  cat > "${MAIN_REPO}/.worktree.local.toml" <<'EOF_LOCAL_CONFIG'
[postgres]
enabled = maybe
EOF_LOCAL_CONFIG

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" services start"
  [ "$status" -eq 2 ]
  [[ "$output" == *"postgres.enabled must be true, false, 1, or 0"* ]]
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

@test "exec composes direnv with the repository Mise toolchain" {
  fake_bin="${TEST_ROOT}/project-environment-bin"
  command_log="${TEST_ROOT}/mise-arguments.log"
  mkdir -p "$fake_bin"
  printf 'elixir 1.20.0-otp-29\n' > "${WORKTREE_ONE}/.tool-versions"
  printf '# managed environment\n' > "${WORKTREE_ONE}/.envrc"

  cat > "${fake_bin}/direnv" <<'EOF_DIRENV'
#!/usr/bin/env bash
[ "$1" = "exec" ] && [ "$2" = "." ] || exit 2
shift 2
exec "$@"
EOF_DIRENV
  cat > "${fake_bin}/mise" <<'EOF_MISE'
#!/usr/bin/env bash
if [ "$1" = "bin-paths" ]; then
  dirname "$0"
  exit 0
fi
printf '%s\n' "$@" > "$COMMAND_LOG"
[ "$1" = "exec" ] && [ "$2" = "--" ] || exit 2
shift 2
export TEST_MISE_ACTIVE=1
exec "$@"
EOF_MISE
  cat > "${fake_bin}/print-toolchain" <<'EOF_TOOLCHAIN'
#!/usr/bin/env bash
printf 'mise=%s\n' "$TEST_MISE_ACTIVE"
EOF_TOOLCHAIN
  chmod +x "${fake_bin}/direnv" "${fake_bin}/mise" "${fake_bin}/print-toolchain"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" WERKSFEER_POSTGRES=false \"$WERKSFEER\" exec print-toolchain"

  [ "$status" -eq 0 ]
  [ "$output" = "mise=1" ]
  [ "$(sed -n '1p' "$command_log")" = "exec" ]
  [ "$(sed -n '2p' "$command_log")" = "--" ]
  [ "$(sed -n '3p' "$command_log")" = "env" ]
  grep -Fq "PATH=${fake_bin}:" "$command_log"
  [ "$(tail -n 1 "$command_log")" = "print-toolchain" ]
}

@test "exec falls back to asdf for .tool-versions repositories" {
  fake_bin="${TEST_ROOT}/asdf-environment-bin"
  asdf_data_dir="${TEST_ROOT}/asdf-data"
  mkdir -p "$fake_bin" "${asdf_data_dir}/shims"
  printf 'elixir 1.20.0-otp-29\n' > "${WORKTREE_ONE}/.tool-versions"
  printf '# managed environment\n' > "${WORKTREE_ONE}/.envrc"

  cat > "${fake_bin}/direnv" <<'EOF_DIRENV'
#!/usr/bin/env bash
[ "$1" = "exec" ] && [ "$2" = "." ] || exit 2
shift 2
exec "$@"
EOF_DIRENV
  cat > "${fake_bin}/asdf" <<'EOF_ASDF'
#!/usr/bin/env bash
exit 2
EOF_ASDF
  cat > "${asdf_data_dir}/shims/print-toolchain" <<'EOF_TOOLCHAIN'
#!/usr/bin/env bash
printf 'asdf=1\n'
EOF_TOOLCHAIN
  chmod +x \
    "${fake_bin}/direnv" \
    "${fake_bin}/asdf" \
    "${asdf_data_dir}/shims/print-toolchain"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" ASDF_DATA_DIR=\"$asdf_data_dir\" WERKSFEER_POSTGRES=false \"$WERKSFEER\" exec print-toolchain"

  [ "$status" -eq 0 ]
  [ "$output" = "asdf=1" ]
}

@test "warms an isolated managed Elixir cache without changing the main checkout" {
  fake_bin="${TEST_ROOT}/cache-bin"
  command_log="${TEST_ROOT}/cache-commands.log"
  mkdir -p "$fake_bin"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"

[setup]
node_install = "npm install"

[hooks]
post_dependencies = "npm run-script build"
EOF_CONFIG
  printf '{"scripts":{"build":"true"}}\n' > "${MAIN_REPO}/package.json"
  git -C "$MAIN_REPO" add .worktree.toml package.json
  git -C "$MAIN_REPO" commit -qm "configure managed cache"
  main_head="$(git -C "$MAIN_REPO" rev-parse HEAD)"
  worktree_count="$(git -C "$MAIN_REPO" worktree list --porcelain | grep -c '^worktree ')"

  cat > "${fake_bin}/mix" <<'EOF_MIX'
#!/usr/bin/env bash
printf 'mix:%s:%s\n' "${MIX_ENV:-dev}" "$*" >> "$COMMAND_LOG"
mkdir -p "_build/${MIX_ENV:-dev}" deps/example
printf 'build\n' > "_build/${MIX_ENV:-dev}/value"
printf 'dependency\n' > deps/example/value
EOF_MIX
  cat > "${fake_bin}/npm" <<'EOF_NPM'
#!/usr/bin/env bash
printf 'npm:%s\n' "$*" >> "$COMMAND_LOG"
if [ "$1" = "install" ]; then
  mkdir -p node_modules/example
  printf 'package\n' > node_modules/example/value
elif [ "$1" = "run-script" ]; then
  mkdir -p priv/static
  printf 'asset\n' > priv/static/app.js
fi
EOF_NPM
  chmod +x "${fake_bin}/mix" "${fake_bin}/npm"

  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Managed build cache is ready"* ]]

  expected="${TEST_ROOT}/expected-cache-commands.log"
  cat > "$expected" <<'EOF_EXPECTED'
mix:dev:deps.get
mix:test:deps.get
mix:dev:deps.compile
mix:test:deps.compile
mix:dev:compile
mix:test:compile
npm:install
npm:run-script build
EOF_EXPECTED
  diff -u "$expected" "$command_log"

  cp "$command_log" "${command_log}.before-noop"
  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Managed build cache is already warm"* ]]
  diff -u "${command_log}.before-noop" "$command_log"

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache_commit=${main_head}"* ]]
  [[ "$output" == *"ready=true"* ]]
  [[ "$output" == *"current=true"* ]]
  cache_root="$(printf '%s\n' "$output" | sed -n 's/^cache_root=//p')"

  mkdir "${cache_root}/.warm.lock"
  printf '2147483647\n' > "${cache_root}/.warm.lock/pid"
  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing stale managed build cache lock"* ]]
  [[ "$output" == *"Managed build cache is already warm"* ]]
  [ ! -e "${cache_root}/.warm.lock" ]

  [ -f "${cache_root}/checkout/_build/dev/value" ]
  [ -f "${cache_root}/checkout/_build/test/value" ]
  [ -f "${cache_root}/checkout/deps/example/value" ]
  [ -f "${cache_root}/checkout/node_modules/example/value" ]
  [ -f "${cache_root}/checkout/priv/static/app.js" ]
  [ "$(git -C "$MAIN_REPO" rev-parse HEAD)" = "$main_head" ]
  [ -z "$(git -C "$MAIN_REPO" status --porcelain --untracked-files=all)" ]
  [ "$(git -C "$MAIN_REPO" worktree list --porcelain | grep -c '^worktree ')" = "$worktree_count" ]

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache clean"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing managed build cache"* ]]
  [ ! -e "$cache_root" ]
}

@test "managed cache updates incrementally when dependency inputs are unchanged" {
  fake_bin="${TEST_ROOT}/incremental-cache-bin"
  command_log="${TEST_ROOT}/incremental-cache-commands.log"
  mkdir -p "$fake_bin"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"

[setup]
node_install = "npm install"
EOF_CONFIG
  printf '{"name":"example"}\n' > "${MAIN_REPO}/package.json"
  git -C "$MAIN_REPO" add .worktree.toml package.json
  git -C "$MAIN_REPO" commit -qm "configure managed cache"

  cat > "${fake_bin}/mix" <<'EOF_MIX'
#!/usr/bin/env bash
printf 'mix:%s:%s\n' "${MIX_ENV:-dev}" "$*" >> "$COMMAND_LOG"
mkdir -p "_build/${MIX_ENV:-dev}" deps/example
EOF_MIX
  cat > "${fake_bin}/npm" <<'EOF_NPM'
#!/usr/bin/env bash
printf 'npm:%s\n' "$*" >> "$COMMAND_LOG"
mkdir -p node_modules/example
EOF_NPM
  chmod +x "${fake_bin}/mix" "${fake_bin}/npm"

  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  grep -Fqx 'npm:install' "$command_log"

  printf 'application change\n' > "${MAIN_REPO}/feature.ex"
  git -C "$MAIN_REPO" add feature.ex
  git -C "$MAIN_REPO" commit -qm "change application source"
  : > "$command_log"

  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Node dependency inputs are unchanged"* ]]
  ! grep -q '^npm:' "$command_log"
  grep -Fqx 'mix:dev:compile' "$command_log"
  grep -Fqx 'mix:test:compile' "$command_log"
}

@test "worktree setup copies exact managed caches without sharing mutable files" {
  fake_bin="${TEST_ROOT}/restore-cache-bin"
  command_log="${TEST_ROOT}/restore-cache-commands.log"
  mkdir -p "$fake_bin"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"

[setup]
node_install = "npm install"
EOF_CONFIG
  printf '{"name":"example"}\n' > "${MAIN_REPO}/package.json"
  git -C "$MAIN_REPO" add .worktree.toml package.json
  git -C "$MAIN_REPO" commit -qm "configure managed cache"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  cat > "${fake_bin}/mix" <<'EOF_MIX'
#!/usr/bin/env bash
mkdir -p "_build/${MIX_ENV:-dev}" deps/example
printf 'build\n' > "_build/${MIX_ENV:-dev}/value"
printf 'dependency\n' > deps/example/value
EOF_MIX
  cat > "${fake_bin}/npm" <<'EOF_NPM'
#!/usr/bin/env bash
mkdir -p node_modules/example
printf 'cache package\n' > node_modules/example/value
EOF_NPM
  cat > "${fake_bin}/elixir" <<'EOF_ELIXIR'
#!/usr/bin/env bash
exit 0
EOF_ELIXIR
  chmod +x "${fake_bin}/mix" "${fake_bin}/npm" "${fake_bin}/elixir"

  run bash -c "cd \"$MAIN_REPO\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache status"
  [ "$status" -eq 0 ]
  cache_root="$(printf '%s\n' "$output" | sed -n 's/^cache_root=//p')"

  cat > "${WORKTREE_ONE}/.worktree.local.toml" <<'EOF_LOCAL_CONFIG'
[setup]
command = "true"
EOF_LOCAL_CONFIG
  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using managed build cache"* ]]
  [[ "$output" == *"Copied node_modules from managed cache"* ]]
  [ -d "${WORKTREE_ONE}/node_modules" ]
  [ ! -L "${WORKTREE_ONE}/node_modules" ]
  [ -f "${WORKTREE_ONE}/_build/dev/value" ]
  [ -f "${WORKTREE_ONE}/_build/test/value" ]
  [ -f "${WORKTREE_ONE}/deps/example/value" ]

  printf 'worktree package\n' > "${WORKTREE_ONE}/node_modules/example/value"
  [ "$(cat "${cache_root}/checkout/node_modules/example/value")" = "cache package" ]
}

@test "worktree setup warms automatically and prunes abandoned caches" {
  fake_bin="${TEST_ROOT}/automatic-cache-bin"
  mkdir -p "$fake_bin"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"
retention_days = 1
command = "mkdir -p _build/dev && printf 'automatic cache' > _build/dev/value"

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "enable automatic cache warming"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  stale_cache="${XDG_CACHE_HOME}/werksfeer/build-caches/abandoned-cache"
  mkdir -p "$stale_cache"
  printf '%s\n' "${TEST_ROOT}/missing-repository" > "${stale_cache}/OWNER"
  touch -t 202001010000 "${stale_cache}/OWNER"

  cat > "${fake_bin}/elixir" <<'EOF_ELIXIR'
#!/usr/bin/env bash
exit 0
EOF_ELIXIR
  chmod +x "${fake_bin}/elixir"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warming elixir build cache"* ]]
  [[ "$output" == *"Pruning managed build cache unused for more than 1 days"* ]]
  [[ "$output" == *"Using managed build cache"* ]]
  [ "$(cat "${WORKTREE_ONE}/_build/dev/value")" = "automatic cache" ]
  [ ! -e "$stale_cache" ]
  [ -z "$(git -C "$MAIN_REPO" status --porcelain --untracked-files=all)" ]
}

@test "repositories can opt out of automatic cache warming" {
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"
auto_warm = false
command = "mkdir -p _build/dev && printf 'should not exist' > _build/dev/value"

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "disable automatic cache warming"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Warming elixir build cache"* ]]

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready=false"* ]]
}

@test "managed cache follows the latest remote default ref without updating main" {
  remote_repo="${TEST_ROOT}/remote.git"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
command = "mkdir -p _build/dev && printf 'remote cache' > _build/dev/value"
EOF_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "configure remote cache"
  git -C "$MAIN_REPO" branch -M main
  main_head="$(git -C "$MAIN_REPO" rev-parse HEAD)"

  git clone -q --bare "$MAIN_REPO" "$remote_repo"
  git -C "$remote_repo" symbolic-ref HEAD refs/heads/main
  git -C "$MAIN_REPO" remote add origin "$remote_repo"
  git -C "$MAIN_REPO" fetch -q origin
  git -C "$MAIN_REPO" remote set-head origin -a >/dev/null

  git -C "$WORKTREE_TWO" reset -q --hard "$main_head"
  printf 'remote-only revision\n' > "${WORKTREE_TWO}/remote-revision"
  git -C "$WORKTREE_TWO" add remote-revision
  git -C "$WORKTREE_TWO" commit -qm "advance remote default"
  remote_head="$(git -C "$WORKTREE_TWO" rev-parse HEAD)"
  git -C "$WORKTREE_TWO" push -q origin HEAD:main

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fetching origin"* ]]
  [[ "$output" == *"at ${remote_head:0:12}"* ]]
  [ "$(git -C "$MAIN_REPO" rev-parse HEAD)" = "$main_head" ]

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=origin/main"* ]]
  [[ "$output" == *"ref_commit=${remote_head}"* ]]
  [[ "$output" == *"cache_commit=${remote_head}"* ]]
  [[ "$output" == *"current=true"* ]]
}

@test "managed cache uses target configuration instead of feature configuration" {
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_MAIN_CONFIG'
[cache]
ref = "HEAD"
command = "mkdir -p _build/dev && printf 'main cache' > _build/dev/value"
EOF_MAIN_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "configure main cache"
  main_head="$(git -C "$MAIN_REPO" rev-parse HEAD)"

  git -C "$WORKTREE_ONE" reset -q --hard "$main_head"
  cat > "${WORKTREE_ONE}/.worktree.toml" <<'EOF_FEATURE_CONFIG'
[cache]
ref = "HEAD"
command = "mkdir -p _build/dev && printf 'feature cache' > _build/dev/value"
EOF_FEATURE_CONFIG
  git -C "$WORKTREE_ONE" add .worktree.toml
  git -C "$WORKTREE_ONE" commit -qm "change cache on feature"

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" cache warm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"at ${main_head:0:12}"* ]]

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" cache status"
  [ "$status" -eq 0 ]
  cache_root="$(printf '%s\n' "$output" | sed -n 's/^cache_root=//p')"
  [ "$(cat "${cache_root}/checkout/_build/dev/value")" = "main cache" ]
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

@test "PostgreSQL snapshot sources accept bare names and connection strings" {
  provider="${BATS_TEST_DIRNAME}/../lib/werksfeer/services/postgres.sh"

  run bash -c 'source "$1"; postgres_snapshot_source_conninfo example_dev' _ "$provider"
  [ "$output" = "dbname=example_dev" ]

  run bash -c 'source "$1"; postgres_snapshot_source_conninfo "host=/tmp port=5432 dbname=example_dev"' _ "$provider"
  [ "$output" = "host=/tmp port=5432 dbname=example_dev" ]

  run bash -c 'source "$1"; postgres_snapshot_source_conninfo postgresql://localhost/example_dev' _ "$provider"
  [ "$output" = "postgresql://localhost/example_dev" ]
}

@test "pinned PostgreSQL snapshots seed new worktrees and can be cleared" {
  command -v pg_config >/dev/null 2>&1 || skip "PostgreSQL is not installed"

  run bash -c "cd \"$MAIN_REPO\" && \"$WERKSFEER\" postgres snapshot --from \"host=/nonexistent dbname=missing\""
  [ "$status" -ne 0 ]
  [[ "$output" == *"previous snapshot, if any, is unchanged"* ]]

  run bash -c "cd \"$WORKTREE_ONE\" && \"$WERKSFEER\" services start && psql -h \"\$(\"$WERKSFEER\" postgres socket-dir)\" -U postgres -qd postgres -c 'CREATE DATABASE example_dev' && \"$WERKSFEER\" postgres snapshot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pinned PostgreSQL snapshot"* ]]

  run bash -c "cd \"$WORKTREE_TWO\" && \"$WERKSFEER\" postgres template-status"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == pinned_snapshot=*/postgres-snapshots/*/current ]]

  run bash -c "cd \"$WORKTREE_TWO\" && \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hydrating PostgreSQL from pinned snapshot"* ]]
  run bash -c "cd \"$WORKTREE_TWO\" && \"$WERKSFEER\" postgres database-exists example_dev"
  [ "$status" -eq 0 ]

  run bash -c "cd \"$WORKTREE_TWO\" && \"$WERKSFEER\" postgres snapshot --clear && \"$WERKSFEER\" postgres template-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned_snapshot="$'\n'* ]]
}

@test "exact clean revisions reuse isolated worktree caches" {
  mkdir -p \
    "${MAIN_REPO}/_build/dev/lib/example/.mix" \
    "${MAIN_REPO}/deps/native/CMakeFiles" \
    "${MAIN_REPO}/node_modules/example" \
    "${MAIN_REPO}/priv/static"
  printf 'build\n' > "${MAIN_REPO}/_build/dev/lib/example/.mix/compile.elixir"
  printf 'absolute source path\n' > "${MAIN_REPO}/deps/native/CMakeCache.txt"
  printf 'generated\n' > "${MAIN_REPO}/deps/native/CMakeFiles/generated"
  printf 'dependency\n' > "${MAIN_REPO}/deps/native/artifact"
  printf 'package\n' > "${MAIN_REPO}/node_modules/example/value"
  printf 'asset\n' > "${MAIN_REPO}/priv/static/app.js"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  [ -f "${WORKTREE_ONE}/_build/dev/lib/example/.mix/compile.elixir" ]
  [ -f "${WORKTREE_ONE}/deps/native/artifact" ]
  [ ! -e "${WORKTREE_ONE}/deps/native/CMakeCache.txt" ]
  [ ! -e "${WORKTREE_ONE}/deps/native/CMakeFiles" ]
  [ -L "${WORKTREE_ONE}/node_modules" ]
  [ -f "${WORKTREE_ONE}/priv/static/app.js" ]

  printf 'worktree\n' > "${WORKTREE_ONE}/deps/native/artifact"
  [ "$(cat "${MAIN_REPO}/deps/native/artifact")" = "dependency" ]
}

@test "clean descendant revisions reuse isolated caches but not shared directories" {
  mkdir -p "${MAIN_REPO}/_build" "${MAIN_REPO}/deps" "${MAIN_REPO}/node_modules/example"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/value"
  printf 'package\n' > "${MAIN_REPO}/node_modules/example/value"

  printf 'new revision\n' > "${WORKTREE_ONE}/revision"
  git -C "$WORKTREE_ONE" add revision
  git -C "$WORKTREE_ONE" commit -qm "new revision"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip shared directories"* ]]
  [[ "$output" != *"Skip build cache"* ]]
  [ -f "${WORKTREE_ONE}/_build/value" ]
  [ -f "${WORKTREE_ONE}/deps/value" ]
  [ ! -e "${WORKTREE_ONE}/node_modules" ]
}

@test "ancestor cache reuse preserves mtimes only for unchanged tracked files" {
  printf 'unchanged\n' > "${MAIN_REPO}/unchanged.ex"
  printf 'main version\n' > "${MAIN_REPO}/changed.ex"
  git -C "$MAIN_REPO" add unchanged.ex changed.ex
  git -C "$MAIN_REPO" commit -qm "add source files"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  touch -t 202001010101.01 "${MAIN_REPO}/unchanged.ex" "${MAIN_REPO}/changed.ex"
  printf 'branch version\n' > "${WORKTREE_ONE}/changed.ex"
  git -C "$WORKTREE_ONE" add changed.ex
  git -C "$WORKTREE_ONE" commit -qm "change source file"
  touch -t 202101010101.01 "${WORKTREE_ONE}/changed.ex"

  mkdir -p "${MAIN_REPO}/_build"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  worktree_changed_mtime_before="$(elixir -e 'IO.write(File.stat!(hd(System.argv()), time: :posix).mtime)' "${WORKTREE_ONE}/changed.ex")"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  main_unchanged_mtime="$(elixir -e 'IO.write(File.stat!(hd(System.argv()), time: :posix).mtime)' "${MAIN_REPO}/unchanged.ex")"
  worktree_unchanged_mtime="$(elixir -e 'IO.write(File.stat!(hd(System.argv()), time: :posix).mtime)' "${WORKTREE_ONE}/unchanged.ex")"
  main_changed_mtime="$(elixir -e 'IO.write(File.stat!(hd(System.argv()), time: :posix).mtime)' "${MAIN_REPO}/changed.ex")"
  worktree_changed_mtime="$(elixir -e 'IO.write(File.stat!(hd(System.argv()), time: :posix).mtime)' "${WORKTREE_ONE}/changed.ex")"

  [ "$worktree_unchanged_mtime" = "$main_unchanged_mtime" ]
  [ "$worktree_changed_mtime" != "$main_changed_mtime" ]
  [ "$worktree_changed_mtime" = "$worktree_changed_mtime_before" ]
}

@test "Mix safely incrementally compiles a cache from a diverged revision" {
  mkdir -p "${MAIN_REPO}/lib"
  cat > "${MAIN_REPO}/mix.exs" <<'EOF_MIX_PROJECT'
defmodule Example.MixProject do
  use Mix.Project

  def project do
    [
      app: :example,
      version: "0.1.0",
      elixirc_options: [check_cwd: false]
    ]
  end
end
EOF_MIX_PROJECT
  cat > "${MAIN_REPO}/lib/unchanged.ex" <<'EOF_UNCHANGED'
defmodule Example.Unchanged do
  def value, do: :unchanged
end
EOF_UNCHANGED
  cat > "${MAIN_REPO}/lib/changed.ex" <<'EOF_CHANGED'
defmodule Example.Changed do
  def value, do: :base
end
EOF_CHANGED
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
auto_warm = false

[setup]
command = "mix compile"
EOF_CONFIG
  git -C "$MAIN_REPO" add mix.exs lib .worktree.toml
  git -C "$MAIN_REPO" commit -qm "add compilable project"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  cat > "${MAIN_REPO}/lib/main_only.ex" <<'EOF_MAIN_ONLY'
defmodule Example.MainOnly do
  def value, do: :main
end
EOF_MAIN_ONLY
  git -C "$MAIN_REPO" add lib/main_only.ex
  git -C "$MAIN_REPO" commit -qm "add main-only module"

  run bash -c "cd \"$MAIN_REPO\" && mix compile"
  [ "$status" -eq 0 ]
  [ -f "${MAIN_REPO}/_build/dev/lib/example/ebin/Elixir.Example.MainOnly.beam" ]

  cat > "${WORKTREE_ONE}/lib/changed.ex" <<'EOF_BRANCH_CHANGED'
defmodule Example.Changed do
  def value, do: :branch
end
EOF_BRANCH_CHANGED
  cat > "${WORKTREE_ONE}/lib/branch_only.ex" <<'EOF_BRANCH_ONLY'
defmodule Example.BranchOnly do
  def value, do: :branch
end
EOF_BRANCH_ONLY
  git -C "$WORKTREE_ONE" add lib
  git -C "$WORKTREE_ONE" commit -qm "change branch modules"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Compiling 2 files (.ex)"* ]]
  [ -f "${WORKTREE_ONE}/_build/dev/lib/example/ebin/Elixir.Example.Unchanged.beam" ]
  [ -f "${WORKTREE_ONE}/_build/dev/lib/example/ebin/Elixir.Example.Changed.beam" ]
  [ -f "${WORKTREE_ONE}/_build/dev/lib/example/ebin/Elixir.Example.BranchOnly.beam" ]
  [ ! -e "${WORKTREE_ONE}/_build/dev/lib/example/ebin/Elixir.Example.MainOnly.beam" ]

  run bash -c "cd \"$WORKTREE_ONE\" && mix compile"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clean diverged revisions reuse isolated worktree caches" {
  mkdir -p "${MAIN_REPO}/_build" "${MAIN_REPO}/deps"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/value"

  printf 'main revision\n' > "${MAIN_REPO}/main-revision"
  git -C "$MAIN_REPO" add main-revision
  git -C "$MAIN_REPO" commit -qm "main revision"
  printf 'worktree revision\n' > "${WORKTREE_ONE}/worktree-revision"
  git -C "$WORKTREE_ONE" add worktree-revision
  git -C "$WORKTREE_ONE" commit -qm "worktree revision"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Skip build cache"* ]]
  [ -f "${WORKTREE_ONE}/_build/value" ]
  [ -f "${WORKTREE_ONE}/deps/value" ]
}

@test "unrelated histories do not reuse worktree caches" {
  mkdir -p "${MAIN_REPO}/_build" "${MAIN_REPO}/deps"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/value"

  git -C "$WORKTREE_ONE" checkout -q --orphan unrelated-history
  git -C "$WORKTREE_ONE" rm -qrf .
  printf 'defmodule Example.MixProject do\nend\n' > "${WORKTREE_ONE}/mix.exs"
  cat > "${WORKTREE_ONE}/.gitignore" <<'EOF_GITIGNORE'
/_build
/deps
/node_modules
/priv/static
.worktree.local.toml
.envrc
EOF_GITIGNORE
  cat > "${WORKTREE_ONE}/.worktree.toml" <<'EOF_CONFIG'
[setup]
command = "true"
EOF_CONFIG
  git -C "$WORKTREE_ONE" add mix.exs .gitignore .worktree.toml
  git -C "$WORKTREE_ONE" commit -qm "unrelated history"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip build cache"* ]]
  [ ! -e "${WORKTREE_ONE}/_build" ]
  [ ! -e "${WORKTREE_ONE}/deps" ]
}

@test "dirty cache sources do not reuse worktree caches" {
  mkdir -p "${MAIN_REPO}/_build" "${MAIN_REPO}/deps"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/value"
  printf 'dirty\n' > "${MAIN_REPO}/untracked-file"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip build cache"* ]]
  [ ! -e "${WORKTREE_ONE}/_build" ]
  [ ! -e "${WORKTREE_ONE}/deps" ]
}

@test "toolchain changes make ancestor build caches ineligible" {
  printf '20.0.0\n' > "${MAIN_REPO}/.nvmrc"
  git -C "$MAIN_REPO" add .nvmrc
  git -C "$MAIN_REPO" commit -qm "pin toolchain"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  mkdir -p "${MAIN_REPO}/_build" "${MAIN_REPO}/deps"
  printf 'build\n' > "${MAIN_REPO}/_build/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/value"
  printf '22.0.0\n' > "${WORKTREE_ONE}/.nvmrc"
  git -C "$WORKTREE_ONE" add .nvmrc
  git -C "$WORKTREE_ONE" commit -qm "upgrade toolchain"

  run bash -c "cd \"$WORKTREE_ONE\" && WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip build cache"* ]]
  [ ! -e "${WORKTREE_ONE}/_build" ]
  [ ! -e "${WORKTREE_ONE}/deps" ]
}

@test "compatible ancestor Elixir caches skip dependency fetching" {
  fake_bin="${TEST_ROOT}/elixir-cache-bin"
  command_log="${TEST_ROOT}/elixir-cache-commands.log"
  mkdir -p "$fake_bin" "${MAIN_REPO}/_build/dev" "${MAIN_REPO}/deps/example"
  printf 'build\n' > "${MAIN_REPO}/_build/dev/value"
  printf 'dependency\n' > "${MAIN_REPO}/deps/example/value"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
auto_warm = false
EOF_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "use automatic setup"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"
  printf 'branch revision\n' > "${WORKTREE_ONE}/revision"
  git -C "$WORKTREE_ONE" add revision
  git -C "$WORKTREE_ONE" commit -qm "branch revision"

  cat > "${fake_bin}/mix" <<'EOF_MIX'
#!/usr/bin/env bash
printf 'mix:%s:%s\n' "${MIX_ENV:-dev}" "$*" >> "$COMMAND_LOG"
EOF_MIX
  cat > "${fake_bin}/elixir" <<'EOF_ELIXIR'
#!/usr/bin/env bash
exit 0
EOF_ELIXIR
  chmod +x "${fake_bin}/mix" "${fake_bin}/elixir"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" COMMAND_LOG=\"$command_log\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]

  expected="${TEST_ROOT}/expected-elixir-cache-commands.log"
  cat > "$expected" <<'EOF_EXPECTED'
mix:dev:deps.loadpaths --no-compile
mix:test:deps.loadpaths --no-compile
mix:dev:compile
mix:dev:ecto.setup
EOF_EXPECTED
  diff -u "$expected" "$command_log"
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

@test "Elixir setup compiles the app before assets and database" {
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
[cache]
auto_warm = false

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

[cache]
auto_warm = false
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

# ---------------------------------------------------------------------------
# Shared PostgreSQL server connection settings
# ---------------------------------------------------------------------------

# Writes a shared-server configuration (no private cluster) to the main
# checkout and both worktrees. Arguments are extra lines for [database].
write_shared_config() {
  local target
  {
    cat <<'EOF_CONFIG'
[cache]
auto_warm = false

[setup]
command = "true"

[database]
base_name = "example"
EOF_CONFIG
    printf '%s\n' "$@"
  } > "${MAIN_REPO}/.worktree.toml"
  for target in "$WORKTREE_ONE" "$WORKTREE_TWO"; do
    cp "${MAIN_REPO}/.worktree.toml" "${target}/.worktree.toml"
  done
}

# Puts fake psql, dropdb and elixir first on PATH. Each psql/dropdb call is
# appended to $PG_LOG with the connection variables it saw. The databases the
# fake server holds are listed in $PG_DBS, one name per line. Create
# $PG_DOWN to make every connection fail.
install_fake_pg() {
  FAKE_BIN="${TEST_ROOT}/fake-pg-bin"
  PG_LOG="${TEST_ROOT}/pg.log"
  PG_DBS="${TEST_ROOT}/pg.dbs"
  PG_DOWN="${TEST_ROOT}/pg.down"
  PG_DROP_FAIL="${TEST_ROOT}/pg.dropfail"
  PG_LIST_FAIL="${TEST_ROOT}/pg.listfail"
  PG_CREATE_RACE="${TEST_ROOT}/pg.createrace"
  PG_LIST_FAIL_AFTER="${TEST_ROOT}/pg.listfailafter"
  export PG_LOG PG_DBS PG_DOWN PG_DROP_FAIL PG_LIST_FAIL PG_CREATE_RACE PG_LIST_FAIL_AFTER
  mkdir -p "$FAKE_BIN"
  : > "$PG_LOG"
  printf '%s\n' example_dev example_test > "$PG_DBS"

  cat > "${FAKE_BIN}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
if [ -e "$PG_DOWN" ]; then
  printf 'psql: error: connection to server at "db.example" failed: Connection refused\n\tIs the server running?\n' >&2
  exit 2
fi
# Like a real server where the user has no database of the same name: a call
# that does not name the maintenance database explicitly fails.
case " $* " in
  *" -d postgres "*) ;;
  *)
    printf 'psql: error: connection failed: FATAL:  database "%s" does not exist\n' "${PGUSER-unknown}" >&2
    exit 2 ;;
esac
printf 'psql PGHOST=%s PGPORT=%s PGUSER=%s PGPASSWORD=%s %s\n' \
  "${PGHOST-<unset>}" "${PGPORT-<unset>}" "${PGUSER-<unset>}" "${PGPASSWORD-<unset>}" "$*" >> "$PG_LOG"
case "$*" in
  *-lqt*)
    # Only the catalog listing fails, the way a dropped connection would.
    [ -e "$PG_LIST_FAIL" ] && exit 2
    # The listing fails from the nth call on; the file holds n.
    if [ -e "$PG_LIST_FAIL_AFTER" ]; then
      calls=$(( $(cat "${PG_LIST_FAIL_AFTER}.count" 2>/dev/null || echo 0) + 1 ))
      echo "$calls" > "${PG_LIST_FAIL_AFTER}.count"
      [ "$calls" -gt "$(cat "$PG_LIST_FAIL_AFTER")" ] && exit 2
    fi
    sed 's/$/ | owner | UTF8/' "$PG_DBS" ;;
  *"CREATE DATABASE"*)
    name="$(printf '%s' "$*" | sed 's/.*CREATE DATABASE "\([^"]*\)".*/\1/')"
    # Another machine creates the database between the check and the CREATE.
    # The file holds a glob for the names it wins.
    if [ -e "$PG_CREATE_RACE" ] && [[ "$name" == $(cat "$PG_CREATE_RACE") ]]; then
      printf '%s\n' "$name" >> "$PG_DBS"
      rm -f "$PG_CREATE_RACE"
      printf 'ERROR:  database "%s" already exists\n' "$name" >&2
      exit 1
    fi
    # A real server cuts identifiers at 63 bytes without an error.
    printf '%s\n' "$name" | LC_ALL=C cut -c1-63 >> "$PG_DBS" ;;
esac
exit 0
EOF_PSQL

  cat > "${FAKE_BIN}/dropdb" <<'EOF_DROPDB'
#!/usr/bin/env bash
printf 'dropdb PGHOST=%s PGPORT=%s PGUSER=%s PGPASSWORD=%s %s\n' \
  "${PGHOST-<unset>}" "${PGPORT-<unset>}" "${PGUSER-<unset>}" "${PGPASSWORD-<unset>}" "$*" >> "$PG_LOG"
[ -e "$PG_DROP_FAIL" ] && exit 1
grep -vxF "$(printf '%s' "${!#}" | LC_ALL=C cut -c1-63)" "$PG_DBS" > "${PG_DBS}.new" || true
mv "${PG_DBS}.new" "$PG_DBS"
EOF_DROPDB

  printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/elixir"
  chmod +x "${FAKE_BIN}/psql" "${FAKE_BIN}/dropdb" "${FAKE_BIN}/elixir"
}

run_in_worktree() {
  local worktree="$1"
  shift
  run bash -c "cd \"$worktree\" && PATH=\"$FAKE_BIN:/usr/bin:/bin:\$PATH\" \"\$@\"" _ "$@"
}

@test "shared server settings reach psql when cloning databases" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'port = 5433' 'user = "agent"'
  printf '[database]\npassword = "s3cret-pw"\n' > "${MAIN_REPO}/.worktree.local.toml"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'psql PGHOST=db.example PGPORT=5433 PGUSER=agent PGPASSWORD=s3cret-pw .*CREATE DATABASE "worktree_.*_one_[0-9a-f]\{10\}" WITH TEMPLATE "example_dev"' "$PG_LOG"
  grep -q 'CREATE DATABASE "worktree_.*_one_[0-9a-f]\{10\}_test" WITH TEMPLATE "example_test"' "$PG_LOG"
  run grep -qv 'PGHOST=db.example PGPORT=5433 PGUSER=agent PGPASSWORD=s3cret-pw' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "shared server settings that are not set leave the environment alone" {
  install_fake_pg
  write_shared_config 'user = "agent"'

  run_in_worktree "$WORKTREE_ONE" env PGHOST=env-host PGPORT=6000 PGUSER=env-user PGPASSWORD=env-pw "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'psql PGHOST=env-host PGPORT=6000 PGUSER=agent PGPASSWORD=env-pw ' "$PG_LOG"
  run grep -q 'PGUSER=env-user' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "shared server settings win over the environment" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'port = 5433' 'user = "agent"' 'password = "file-pw"'

  run_in_worktree "$WORKTREE_ONE" env PGHOST=env-host PGPORT=6000 PGUSER=env-user PGPASSWORD=env-pw "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'PGHOST=db.example PGPORT=5433 PGUSER=agent PGPASSWORD=file-pw ' "$PG_LOG"
  run grep -q 'env-host\|env-user\|env-pw\|PGPORT=6000' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "an unconfigured shared server keeps using the environment" {
  install_fake_pg
  write_shared_config

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'psql PGHOST=<unset> PGPORT=<unset> PGUSER=<unset> PGPASSWORD=<unset> ' "$PG_LOG"
}

@test "cleanup drops worktree databases with the shared server settings" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"' 'password = "file-pw"'
  printf '%s\n' example_dev "worktree_head_one" "worktree_head_one_test" > "$PG_DBS"
  # The server is remote: only a worktree's own environment vouches for old names.
  printf 'export DATABASE_NAME="worktree_head_one"\nexport TEST_DATABASE_NAME="worktree_head_one_test"\n' > "${WORKTREE_ONE}/.envrc"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"

  [ "$status" -eq 0 ]
  grep -q 'dropdb PGHOST=db.example PGPORT=<unset> PGUSER=agent PGPASSWORD=file-pw --if-exists worktree_head_one$' "$PG_LOG"
  grep -q 'dropdb .* --if-exists worktree_head_one_test$' "$PG_LOG"
  [ "$(cat "$PG_DBS")" = "example_dev" ]
}

@test "prune drops orphaned databases with the shared server settings" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"' 'password = "file-pw"'
  printf '%s\n' example_dev "worktree_gone_branch_gone" > "$PG_DBS"
  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  printf '%s\n' "$MAIN_REPO" > "${XDG_DATA_HOME}/werksfeer/projects"
  # The server is remote: only databases recorded on this machine are dropped.
  printf '%s\t%s\tdev\t%s\n' "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" worktree_gone_branch_gone > "${XDG_DATA_HOME}/werksfeer/databases"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -q 'dropdb PGHOST=db.example PGPORT=<unset> PGUSER=agent PGPASSWORD=file-pw --if-exists worktree_gone_branch_gone$' "$PG_LOG"
}

@test "cleanup finds the shared server settings after the worktree is removed" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"'
  printf '[database]\npassword = "file-pw"\n' > "${MAIN_REPO}/.worktree.local.toml"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  # A remote server: the machine-specific name from the start.
  grep -q 'worktree_example_head_one_[0-9a-f]\{10\}$' "$PG_DBS"
  git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_ONE"
  [ ! -d "$WORKTREE_ONE" ]
  : > "$PG_LOG"

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  grep -q 'dropdb PGHOST=db.example PGPORT=<unset> PGUSER=agent PGPASSWORD=file-pw --if-exists worktree_example_head_one_[0-9a-f]\{10\}$' "$PG_LOG"
  grep -q 'dropdb .* --if-exists worktree_example_head_one_[0-9a-f]\{10\}_test$' "$PG_LOG"
  [ "$(cat "$PG_DBS")" = "$(printf 'example_dev\nexample_test')" ]
}

@test "cleanup after removal falls back to the checkout it runs from" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"' 'password = "file-pw"'
  printf '%s\n' example_dev "worktree_head_one" > "$PG_DBS"
  # The server is remote: without a record nothing is dropped, so record it.
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev worktree_head_one
  git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_ONE"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  grep -q 'dropdb PGHOST=db.example PGPORT=<unset> PGUSER=agent PGPASSWORD=file-pw --if-exists worktree_head_one$' "$PG_LOG"
}

@test "an unreachable shared server gives a warning and the run still succeeds" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"' 'password = "s3cret-pw"'
  touch "$PG_DOWN"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'WARNING: Cannot reach the PostgreSQL server: psql: error: connection to server at "db.example" failed: Connection refused'* ]]
  [[ "$output" != *"Is the server running?"* ]]
  [[ "$output" == *"Set host, user and password under [database]"* ]]
  [[ "$output" == *".worktree.local.toml"* ]]
  [[ "$output" != *"Template database"* ]]
  [[ "$output" != *"s3cret-pw"* ]]

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_TWO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot reach the PostgreSQL server"* ]]
  [[ "$output" == *"Skipping database cleanup"* ]]

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot reach the PostgreSQL server"* ]]
  [[ "$output" == *"Skipping database prune"* ]]
  [[ "$output" != *"s3cret-pw"* ]]
}

@test "the shared server password never appears in werksfeer output" {
  install_fake_pg
  write_shared_config 'host = "db.example"' 'user = "agent"' 'password = "s3cret-pw"'
  printf '%s\n' example_dev "worktree_head_two" > "$PG_DBS"

  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_DEBUG=1 "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cret-pw"* ]]

  run_in_worktree "$MAIN_REPO" env WERKSFEER_DEBUG=1 "$WERKSFEER" --cleanup "$WORKTREE_TWO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cret-pw"* ]]

  run_in_worktree "$MAIN_REPO" env WERKSFEER_DEBUG=1 "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cret-pw"* ]]
}

# ---------------------------------------------------------------------------
# Pruning with several projects on one PostgreSQL server
# ---------------------------------------------------------------------------

# Creates a second project ("other") with one linked worktree ("bone") and
# registers both projects, the way running werksfeer in each would.
setup_second_project() {
  OTHER_REPO="${TEST_ROOT}/other"
  OTHER_WORKTREE="${TEST_ROOT}/worktrees/bone"
  mkdir -p "$OTHER_REPO"
  git -C "$OTHER_REPO" init -q
  git -C "$OTHER_REPO" config user.email test@example.com
  git -C "$OTHER_REPO" config user.name "Werksfeer Test"
  printf 'defmodule Other.MixProject do\nend\n' > "${OTHER_REPO}/mix.exs"
  printf '[database]\nbase_name = "other"\n' > "${OTHER_REPO}/.worktree.toml"
  git -C "$OTHER_REPO" add mix.exs .worktree.toml
  git -C "$OTHER_REPO" commit -qm initial
  git -C "$OTHER_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$OTHER_WORKTREE" HEAD

  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  printf '%s\n' "$MAIN_REPO" "$OTHER_REPO" > "${XDG_DATA_HOME}/werksfeer/projects"
}

# One server holds the databases of both projects' active worktrees and one
# orphaned pair per project.
seed_two_project_server() {
  printf '%s\n' \
    example_dev \
    worktree_head_one worktree_head_one_test \
    worktree_head_bone worktree_head_bone_test \
    worktree_head_gone_a worktree_head_gone_a_test \
    worktree_head_gone_b worktree_head_gone_b_test > "$PG_DBS"
}

@test "prune in one project keeps the databases of other registered projects" {
  install_fake_pg
  setup_second_project
  seed_two_project_server

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_one worktree_head_one_test worktree_head_bone worktree_head_bone_test)" ]
  grep -q 'dropdb .* --if-exists worktree_head_gone_a$' "$PG_LOG"
  grep -q 'dropdb .* --if-exists worktree_head_gone_a_test$' "$PG_LOG"
  grep -q 'dropdb .* --if-exists worktree_head_gone_b$' "$PG_LOG"
  grep -q 'dropdb .* --if-exists worktree_head_gone_b_test$' "$PG_LOG"
  run grep -E 'dropdb .*worktree_head_(one|bone)' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "prune-all drops only databases that no registered project owns" {
  install_fake_pg
  setup_second_project
  seed_two_project_server

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --prune-all
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_one worktree_head_one_test worktree_head_bone worktree_head_bone_test)" ]
  run grep -E 'dropdb .*worktree_head_(one|bone)' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "prune counts the current project even when it is not registered yet" {
  install_fake_pg
  setup_second_project
  printf '%s\n' "$OTHER_REPO" > "${XDG_DATA_HOME}/werksfeer/projects"
  seed_two_project_server

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_one worktree_head_one_test worktree_head_bone worktree_head_bone_test)" ]
}

@test "a registered project whose directory is gone keeps nothing alive" {
  install_fake_pg
  setup_second_project
  seed_two_project_server
  rm -rf "$OTHER_WORKTREE" "$OTHER_REPO"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_one worktree_head_one_test)" ]
}

@test "prune skips the database part when the project registry is missing" {
  install_fake_pg
  seed_two_project_server
  [ ! -e "${XDG_DATA_HOME}/werksfeer/projects" ]

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"No project registry found"* ]]
  [[ "$output" == *"Skipping database prune"* ]]
  run grep -q 'dropdb' "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PG_DBS")" -eq 9 ]
}

@test "prune keeps the databases of a worktree whose path has a space" {
  install_fake_pg
  setup_second_project
  local spaced="${TEST_ROOT}/worktrees/my tree"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$spaced" HEAD
  seed_two_project_server
  printf '%s\n' worktree_head_my_tree worktree_head_my_tree_test >> "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_head_my_tree "$PG_DBS"
  grep -qxF worktree_head_my_tree_test "$PG_DBS"
  grep -qxF worktree_head_one "$PG_DBS"
  grep -qxF worktree_head_bone "$PG_DBS"
  run grep -E 'dropdb .*worktree_head_(my_tree|one|bone|my)' "$PG_LOG"
  [ "$status" -eq 1 ]
  grep -q 'dropdb .* --if-exists worktree_head_gone_a$' "$PG_LOG"
}

@test "prune drops nothing when a registered project cannot list its worktrees" {
  install_fake_pg
  setup_second_project
  seed_two_project_server
  local real_git
  real_git="$(command -v git)"
  cat > "${FAKE_BIN}/git" <<EOF_GIT
#!/usr/bin/env bash
if [ "\$1 \$2" = "worktree list" ] && [ "\$(basename "\$PWD")" = "other" ]; then
  echo "fatal: worktree metadata unreadable" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF_GIT
  chmod +x "${FAKE_BIN}/git"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot read the worktrees of ${OTHER_REPO}"* ]]
  [[ "$output" == *"Skipping database prune"* ]]
  run grep -q 'dropdb' "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PG_DBS")" -eq 9 ]
}

@test "prune keeps the allocation of a worktree whose path has a space" {
  install_fake_pg
  setup_second_project
  local spaced="${TEST_ROOT}/worktrees/my tree"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$spaced" HEAD
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MAIN_REPO" "my tree" 3001 1 6380 \
    "$MAIN_REPO" "gone" 3002 2 6381 \
    "$OTHER_REPO" "gone" 3003 1 6382 > "${XDG_DATA_HOME}/werksfeer/allocations"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qF "$(printf '%s\t%s\t%s\t%s\t%s' "$MAIN_REPO" "my tree" 3001 1 6380)" "${XDG_DATA_HOME}/werksfeer/allocations"
  run grep -F "$(printf '%s\t%s\t' "$MAIN_REPO" gone)" "${XDG_DATA_HOME}/werksfeer/allocations"
  [ "$status" -eq 1 ]
  grep -qF "$(printf '%s\t%s\t%s\t%s\t%s' "$OTHER_REPO" gone 3003 1 6382)" "${XDG_DATA_HOME}/werksfeer/allocations"
}

@test "prune keeps every allocation when the worktree list cannot be read" {
  install_fake_pg
  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  printf '%s\t%s\t%s\t%s\t%s\n' "$MAIN_REPO" "one" 3001 1 6380 > "${XDG_DATA_HOME}/werksfeer/allocations"
  local real_git
  real_git="$(command -v git)"
  cat > "${FAKE_BIN}/git" <<EOF_GIT
#!/usr/bin/env bash
# The first call finds the main checkout; the listing that follows fails.
if [ "\$1 \$2" = "worktree list" ] && [ -e "$TEST_ROOT/git.first" ]; then
  echo "fatal: worktree metadata unreadable" >&2
  exit 128
fi
[ "\$1 \$2" = "worktree list" ] && : > "$TEST_ROOT/git.first"
exec "$real_git" "\$@"
EOF_GIT
  chmod +x "${FAKE_BIN}/git"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [[ "$output" == *"Cannot read the worktrees of ${MAIN_REPO}"* ]]
  grep -qF "$(printf '%s\t%s\t' "$MAIN_REPO" one)" "${XDG_DATA_HOME}/werksfeer/allocations"
}

# ---------------------------------------------------------------------------
# The record of databases werksfeer created
# ---------------------------------------------------------------------------

DB_RECORD() { echo "${XDG_DATA_HOME}/werksfeer/databases"; }

# Appends one line to the database record: project, worktree, role, database.
write_record() {
  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$(DB_RECORD)"
}

@test "setup records the databases it created for the worktree" {
  install_fake_pg
  write_shared_config

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ -f "$(DB_RECORD)" ]
  grep -qxF "$(printf '%s\t%s\tdev\t%s' "$MAIN_REPO" "$WORKTREE_ONE" worktree_example_head_one)" "$(DB_RECORD)"
  grep -qxF "$(printf '%s\t%s\ttest\t%s' "$MAIN_REPO" "$WORKTREE_ONE" worktree_example_head_one_test)" "$(DB_RECORD)"
  [ "$(wc -l < "$(DB_RECORD)")" -eq 2 ]
  [ -z "$(ls "${XDG_DATA_HOME}/werksfeer" | grep '\.tmp')" ]
}

@test "setup records databases of a worktree whose path has a space" {
  install_fake_pg
  local spaced="${TEST_ROOT}/worktrees/my tree"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$spaced" HEAD
  write_shared_config
  cp "${MAIN_REPO}/.worktree.toml" "${spaced}/.worktree.toml"

  run_in_worktree "$spaced" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -qxF "$(printf '%s\t%s\tdev\t%s' "$MAIN_REPO" "$spaced" worktree_example_head_my_tree)" "$(DB_RECORD)"
}

@test "setup does not record databases that were not created" {
  install_fake_pg
  write_shared_config
  printf '%s\n' unrelated > "$PG_DBS"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ ! -e "$(DB_RECORD)" ]
}

@test "running setup again keeps one record per worktree" {
  install_fake_pg
  write_shared_config

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 2 ]
}

@test "prune keeps recorded databases of a worktree that still exists" {
  install_fake_pg
  setup_second_project
  printf '%s\n' example_dev custom_dev_for_one custom_test_for_one worktree_head_gone_a > "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev custom_dev_for_one
  write_record "$MAIN_REPO" "$WORKTREE_ONE" test custom_test_for_one
  printf '%s\n' worktree_custom_dev worktree_custom_test >> "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_TWO" dev worktree_custom_dev
  write_record "$MAIN_REPO" "$WORKTREE_TWO" test worktree_custom_test

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_custom_dev "$PG_DBS"
  grep -qxF worktree_custom_test "$PG_DBS"
  run grep -E 'dropdb .*worktree_custom' "$PG_LOG"
  [ "$status" -eq 1 ]
  grep -q 'dropdb .* --if-exists worktree_head_gone_a$' "$PG_LOG"
  [ "$(wc -l < "$(DB_RECORD)")" -eq 4 ]
}

@test "prune drops the recorded databases of a gone worktree and forgets them" {
  install_fake_pg
  setup_second_project
  printf '%s\n' example_dev worktree_head_one worktree_head_one_test worktree_main_gone_wt worktree_main_gone_wt_test > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone wt" dev worktree_main_gone_wt
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone wt" test worktree_main_gone_wt_test
  write_record "$OTHER_REPO" "$OTHER_WORKTREE" dev worktree_head_bone
  printf '%s\n' worktree_head_bone >> "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  run grep -qE 'worktree_main_gone_wt' "$PG_DBS"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  grep -qF "$OTHER_WORKTREE" "$(DB_RECORD)"
}

@test "prune keeps the record of a gone worktree when its database cannot be dropped" {
  install_fake_pg
  setup_second_project
  printf '%s\n' example_dev worktree_main_gone_wt > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev worktree_main_gone_wt
  touch "$PG_DROP_FAIL"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Failed to drop worktree_main_gone_wt"* ]]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
}

@test "prune never drops a database that an existing worktree also claims" {
  install_fake_pg
  setup_second_project
  printf '%s\n' example_dev worktree_head_one worktree_head_one_test > "$PG_DBS"
  # A worktree that is gone recorded the database an existing worktree uses by
  # its 0.3.1 name (both had a worktree "one" on the same branch).
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone/one" dev worktree_head_one

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_head_one "$PG_DBS"
  grep -qxF worktree_head_one_test "$PG_DBS"
  [ ! -s "$(DB_RECORD)" ]
}

@test "prune leaves the record alone when the project cannot be inspected" {
  install_fake_pg
  setup_second_project
  seed_two_project_server
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev worktree_head_gone_a
  rm -f "${XDG_DATA_HOME}/werksfeer/projects"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping database prune"* ]]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Cleanup goes by the record and never by the end of a name alone
# ---------------------------------------------------------------------------

# Adds a worktree to the second project, outside the first project's folder.
add_other_worktree() {
  git -C "$OTHER_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "${TEST_ROOT}/other-trees/$1" HEAD
}

write_allocations() {
  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  : > "${XDG_DATA_HOME}/werksfeer/allocations"
  while [ "$#" -gt 0 ]; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" 1 "$((6000 + $3))" >> "${XDG_DATA_HOME}/werksfeer/allocations"
    shift 3
  done
}

@test "cleanup of a gone worktree without a record keeps databases another project uses" {
  install_fake_pg
  write_shared_config
  setup_second_project
  add_other_worktree other_fix
  printf '%s\n' example_dev \
    worktree_head_fix worktree_head_fix_test \
    worktree_head_other_fix worktree_head_other_fix_test \
    worktree_head_two > "$PG_DBS"
  local gone="${TEST_ROOT}/worktrees/fix"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$gone"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_other_fix worktree_head_other_fix_test worktree_head_two)" ]
  run grep -E 'dropdb .*other_fix' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "cleanup of a gone worktree keeps a database that an existing worktree shares" {
  install_fake_pg
  write_shared_config
  setup_second_project
  add_other_worktree fix
  printf '%s\n' example_dev worktree_head_fix worktree_head_fix_test > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/fix"
  [ "$status" -eq 0 ]
  grep -qxF worktree_head_fix "$PG_DBS"
  grep -qxF worktree_head_fix_test "$PG_DBS"
  [[ "$output" == *"Keeping worktree_head_fix: another worktree uses it"* ]]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "cleanup of a gone worktree releases the allocation in its own project only" {
  install_fake_pg
  write_shared_config
  setup_second_project
  add_other_worktree fix
  write_allocations "$MAIN_REPO" fix 3001 "$OTHER_REPO" fix 3002 "$MAIN_REPO" two 3003

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/fix"
  [ "$status" -eq 0 ]
  run grep -F "$(printf '%s\t%s\t' "$MAIN_REPO" fix)" "${XDG_DATA_HOME}/werksfeer/allocations"
  [ "$status" -eq 1 ]
  grep -qF "$(printf '%s\t%s\t' "$OTHER_REPO" fix)" "${XDG_DATA_HOME}/werksfeer/allocations"
  grep -qF "$(printf '%s\t%s\t' "$MAIN_REPO" two)" "${XDG_DATA_HOME}/werksfeer/allocations"
}

@test "cleanup with the folder present releases only the allocation of its own project" {
  install_fake_pg
  write_shared_config
  setup_second_project
  add_other_worktree one
  write_allocations "$MAIN_REPO" one 3001 "$OTHER_REPO" one 3002

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${XDG_DATA_HOME}/werksfeer/allocations")" -eq 1 ]
  grep -qF "$(printf '%s\t%s\t' "$OTHER_REPO" one)" "${XDG_DATA_HOME}/werksfeer/allocations"
}

@test "cleanup of a gone worktree with a record drops exactly the recorded databases" {
  install_fake_pg
  write_shared_config
  setup_second_project
  add_other_worktree fix
  local gone="${TEST_ROOT}/worktrees/fix"
  printf '%s\n' example_dev \
    worktree_example_head_fix worktree_example_head_fix_test \
    worktree_other_head_fix worktree_other_head_fix_test \
    worktree_head_fix > "$PG_DBS"
  write_record "$MAIN_REPO" "$gone" dev worktree_example_head_fix
  write_record "$MAIN_REPO" "$gone" test worktree_example_head_fix_test
  write_record "$OTHER_REPO" "${TEST_ROOT}/other-trees/fix" dev worktree_other_head_fix
  write_allocations "$MAIN_REPO" fix 3001 "$OTHER_REPO" fix 3002

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$gone"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_other_head_fix worktree_other_head_fix_test worktree_head_fix)" ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  grep -qF "other-trees/fix" "$(DB_RECORD)"
  [ "$(wc -l < "${XDG_DATA_HOME}/werksfeer/allocations")" -eq 1 ]
}

@test "cleanup of a gone worktree under a path with a space goes by the record" {
  install_fake_pg
  write_shared_config
  setup_second_project
  local spaced="${TEST_ROOT}/worktrees/my tree"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$spaced" HEAD
  write_shared_config
  cp "${MAIN_REPO}/.worktree.toml" "${spaced}/.worktree.toml"
  run_in_worktree "$spaced" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -qxF worktree_example_head_my_tree "$PG_DBS"
  git -C "$MAIN_REPO" worktree remove --force "$spaced"

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --cleanup "$spaced"
  [ "$status" -eq 0 ]
  run grep -q 'worktree_example_head_my_tree' "$PG_DBS"
  [ "$status" -eq 1 ]
  [ ! -s "$(DB_RECORD)" ]
}

@test "cleanup with the folder present drops the recorded databases, not the old names" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev custom_one custom_one_test worktree_head_one worktree_head_one_test > "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev custom_one
  write_record "$MAIN_REPO" "$WORKTREE_ONE" test custom_one_test

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_head_one worktree_head_one_test)" ]
  [ ! -s "$(DB_RECORD)" ]
}

@test "cleanup with a relative or slashed path finds the record" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev custom_one > "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev custom_one

  run_in_worktree "${TEST_ROOT}/worktrees" "$WERKSFEER" --cleanup "./one/"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "example_dev" ]
}

@test "cleanup never drops a recorded database that an existing worktree also records" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev shared_db > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev shared_db
  write_record "$OTHER_REPO" "$OTHER_WORKTREE" dev shared_db

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/gone"
  [ "$status" -eq 0 ]
  grep -qxF shared_db "$PG_DBS"
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  grep -qF "$OTHER_WORKTREE" "$(DB_RECORD)"
}

@test "cleanup of a gone worktree drops nothing when another project cannot be inspected" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev worktree_head_fix worktree_head_fix_test > "$PG_DBS"
  local real_git
  real_git="$(command -v git)"
  cat > "${FAKE_BIN}/git" <<EOF_GIT
#!/usr/bin/env bash
if [ "\$1 \$2" = "worktree list" ] && [ "\$(basename "\$PWD")" = "other" ]; then
  echo "fatal: worktree metadata unreadable" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF_GIT
  chmod +x "${FAKE_BIN}/git"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/fix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"werksfeer --prune"* ]]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PG_DBS")" -eq 3 ]
}

@test "cleanup of a gone worktree drops nothing when it cannot tell which project it was" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev worktree_head_fix > "$PG_DBS"

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/fix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"werksfeer --prune"* ]]
  grep -qxF worktree_head_fix "$PG_DBS"
}

# ---------------------------------------------------------------------------
# Database names carry the project
# ---------------------------------------------------------------------------

# Gives the second project a shared-server configuration and a worktree named
# like the first project's "one", and seeds the server with both templates.
prepare_two_projects_with_one() {
  install_fake_pg
  write_shared_config
  setup_second_project
  cat > "${OTHER_REPO}/.worktree.toml" <<'EOF_OTHER'
[cache]
auto_warm = false

[setup]
command = "true"

[database]
base_name = "other"
EOF_OTHER
  git -C "$OTHER_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "${TEST_ROOT}/other-trees/one" HEAD
  cp "${OTHER_REPO}/.worktree.toml" "${TEST_ROOT}/other-trees/one/.worktree.toml"
  printf '%s\n' example_dev example_test other_dev other_test > "$PG_DBS"
}

LONG_BRANCH="feature/this-is-a-very-long-branch-name-to-overflow-the-identifier-limit"

@test "two projects with the same branch and worktree name get different databases" {
  prepare_two_projects_with_one

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run_in_worktree "${TEST_ROOT}/other-trees/one" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev example_test other_dev other_test \
    worktree_example_head_one worktree_example_head_one_test \
    worktree_other_head_one worktree_other_head_one_test)" ]
  grep -q 'CREATE DATABASE "worktree_other_head_one" WITH TEMPLATE "other_dev"' "$PG_LOG"
  grep -q 'DATABASE_NAME="worktree_other_head_one"' "${TEST_ROOT}/other-trees/one/.envrc"
  grep -q 'DATABASE_NAME="worktree_example_head_one"' "${WORKTREE_ONE}/.envrc"
}

@test "a database name another worktree already uses is never taken over" {
  prepare_two_projects_with_one
  # Same project name, branch and folder name in a different folder: the readable
  # name is the same, so the second worktree must get another one.
  local twin="${TEST_ROOT}/elsewhere/example/one"
  mkdir -p "$(dirname "$twin")"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$twin" HEAD
  cp "${MAIN_REPO}/.worktree.toml" "${twin}/.worktree.toml"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run_in_worktree "$twin" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^worktree_' "$PG_DBS")" -eq 4 ]
  [ "$(recorded_database_of "$twin")" != "worktree_example_head_one" ]
  [ "$(recorded_database_of "$WORKTREE_ONE")" = "worktree_example_head_one" ]
  [ "$(recorded_database_of "$twin" | wc -c)" -le 64 ]
}

# Prints the recorded dev database of a worktree path.
recorded_database_of() {
  awk -F'\t' -v wt="$1" '$2 == wt && $3 == "dev" { print $4 }' "$(DB_RECORD)"
}

@test "a worktree set up by 0.3.1 keeps its databases when setup runs again" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev example_test worktree_head_one worktree_head_one_test > "$PG_DBS"
  # What 0.3.1 left in the worktree: the managed environment block.
  printf '\n# >>> werksfeer managed environment >>>\nexport PORT="3001"\nexport DATABASE_NAME="worktree_head_one"\nexport TEST_DATABASE_NAME="worktree_head_one_test"\n# <<< werksfeer managed environment <<<\n' > "${WORKTREE_ONE}/.envrc"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PG_DBS")" -eq 4 ]
  grep -q 'export DATABASE_NAME="worktree_head_one"' "${WORKTREE_ONE}/.envrc"
  grep -q 'export TEST_DATABASE_NAME="worktree_head_one_test"' "${WORKTREE_ONE}/.envrc"
  grep -qxF "$(printf '%s\t%s\tdev\tworktree_head_one' "$MAIN_REPO" "$WORKTREE_ONE")" "$(DB_RECORD)"
  grep -qxF "$(printf '%s\t%s\ttest\tworktree_head_one_test' "$MAIN_REPO" "$WORKTREE_ONE")" "$(DB_RECORD)"

  # And again, now by the record.
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PG_DBS")" -eq 4 ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 2 ]
}

@test "a worktree set up by 0.3.1 is found by its allocation when its environment file is gone" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev example_test worktree_head_one worktree_head_one_test > "$PG_DBS"
  write_allocations "$MAIN_REPO" one 3001

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]
  grep -q 'export DATABASE_NAME="worktree_head_one"' "${WORKTREE_ONE}/.envrc"
}

@test "an old database name from another project is not adopted by a new worktree" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev example_test worktree_head_one worktree_head_one_test > "$PG_DBS"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'CREATE DATABASE "worktree_example_head_one" WITH TEMPLATE "example_dev"' "$PG_LOG"
  grep -q 'export DATABASE_NAME="worktree_example_head_one"' "${WORKTREE_ONE}/.envrc"
  grep -qxF worktree_head_one "$PG_DBS"
}

@test "an old database that another existing worktree uses is not adopted through an allocation" {
  prepare_two_projects_with_one
  printf '%s\n' worktree_head_one worktree_head_one_test >> "$PG_DBS"
  write_allocations "$MAIN_REPO" one 3001

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'export DATABASE_NAME="worktree_example_head_one"' "${WORKTREE_ONE}/.envrc"
}

@test "a database name over 63 bytes is shortened with a hash and stays stable" {
  install_fake_pg
  write_shared_config
  git -C "$WORKTREE_ONE" checkout -q -b "$LONG_BRANCH"
  git -C "$WORKTREE_TWO" checkout -q -b "${LONG_BRANCH}-two"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local dev test_db
  dev="$(recorded_database_of "$WORKTREE_ONE")"
  test_db="$(awk -F'\t' -v wt="$WORKTREE_ONE" '$2 == wt && $3 == "test" { print $4 }' "$(DB_RECORD)")"
  [ "${#dev}" -le 58 ]
  [ "${#test_db}" -le 63 ]
  [ "$test_db" = "${dev}_test" ]
  [[ "$dev" =~ ^worktree_example_feature_this_is_a_very_long_.*_[0-9a-f]{10}$ ]]
  grep -qxF "$dev" "$PG_DBS"
  grep -qxF "$test_db" "$PG_DBS"
  grep -q "export DATABASE_NAME=\"${dev}\"" "${WORKTREE_ONE}/.envrc"

  # Stable: a second run finds the same databases instead of cloning again.
  : > "$PG_LOG"
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Database $dev already exists, skipping"* ]]
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]

  # Unique: a worktree whose branch only differs at the end gets another name.
  run_in_worktree "$WORKTREE_TWO" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(recorded_database_of "$WORKTREE_TWO")" != "$dev" ]
  [ "$(grep -c '^worktree_' "$PG_DBS")" -eq 4 ]

  # Cleanup drops exactly what was recorded.
  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  run grep -qxF "$dev" "$PG_DBS"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^worktree_' "$PG_DBS")" -eq 2 ]
}

@test "a 0.3.1 database whose name the server cut at 63 bytes is adopted and kept by prune" {
  install_fake_pg
  write_shared_config
  git -C "$WORKTREE_ONE" checkout -q -b "$LONG_BRANCH"
  local old_dev="worktree_feature_this_is_a_very_long_branch_name_to_overflow_the_identifier_limit_one"
  local cut_dev cut_test
  cut_dev="$(printf '%s' "$old_dev" | cut -c1-63)"
  cut_test="$(printf '%s' "${old_dev}_test" | cut -c1-63)"
  [ "$cut_dev" = "$cut_test" ]
  printf '%s\n' example_dev example_test "$cut_dev" > "$PG_DBS"
  printf '\n# >>> werksfeer managed environment >>>\nexport DATABASE_NAME="%s"\nexport TEST_DATABASE_NAME="%s_test"\n# <<< werksfeer managed environment <<<\n' "$old_dev" "$old_dev" > "${WORKTREE_ONE}/.envrc"
  mkdir -p "${XDG_DATA_HOME}/werksfeer"
  printf '%s\n' "$MAIN_REPO" > "${XDG_DATA_HOME}/werksfeer/projects"

  # Without a run in between, prune must not drop the cut name.
  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF "$cut_dev" "$PG_DBS"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(recorded_database_of "$WORKTREE_ONE")" = "$cut_dev" ]
  # The test database cannot be the old one (the server cut it to the same
  # name as the development database), so it gets a new name.
  [ "$(awk -F'\t' -v wt="$WORKTREE_ONE" '$2 == wt && $3 == "test" { print $4 }' "$(DB_RECORD)")" != "$cut_dev" ]
  grep -qxF "$cut_dev" "$PG_DBS"
}

@test "a private PostgreSQL cluster writes no record and cleanup leaves the shared server alone" {
  install_fake_pg
  # The default fixture enables the private cluster.
  printf '%s\n' example_dev worktree_example_head_one > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  [ ! -e "$(DB_RECORD)" ]
  run grep -q 'dropdb' "$PG_LOG"
  [ "$status" -eq 1 ]
  grep -qxF worktree_example_head_one "$PG_DBS"
}

# ---------------------------------------------------------------------------
# A PostgreSQL server that other machines use too
# ---------------------------------------------------------------------------

@test "a server is remote unless it is local" {
  local host
  for host in "" "/var/run/postgresql" localhost LOCALHOST 127.0.0.1 ::1; do
    write_shared_config ${host:+"host = \"$host\""}
    run bash -c "unset PGHOST; cd \"$MAIN_REPO\" && source <(sed -n '/^shared_server_host()/,/^}/p;/^shared_server_is_remote()/,/^}/p' \"$WERKSFEER\") && toml_get() { [ \"\$2\" = host ] && echo \"$host\" || echo \"\$3\"; } && ! shared_server_is_remote"
    [ "$status" -eq 0 ]
  done
  for host in db.example 10.0.0.5 pg.internal; do
    run bash -c "unset PGHOST; source <(sed -n '/^shared_server_host()/,/^}/p;/^shared_server_is_remote()/,/^}/p' \"$WERKSFEER\") && toml_get() { [ \"\$2\" = host ] && echo \"$host\" || echo \"\$3\"; } && shared_server_is_remote"
    [ "$status" -eq 0 ]
  done
  # Without [database] host, PGHOST decides.
  run bash -c "source <(sed -n '/^shared_server_host()/,/^}/p;/^shared_server_is_remote()/,/^}/p' \"$WERKSFEER\") && toml_get() { echo \"\$3\"; } && PGHOST=db.example shared_server_is_remote"
  [ "$status" -eq 0 ]
  run bash -c "source <(sed -n '/^shared_server_host()/,/^}/p;/^shared_server_is_remote()/,/^}/p' \"$WERKSFEER\") && toml_get() { echo \"\$3\"; } && PGHOST=/tmp shared_server_is_remote"
  [ "$status" -eq 1 ]
}

@test "prune on a remote server drops only recorded databases of gone worktrees" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  setup_second_project
  printf '%s\n' example_dev worktree_example_head_one worktree_example_head_gone \
    worktree_other_machine_head_x worktree_other_machine_head_y_test > "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev worktree_example_head_one
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev worktree_example_head_gone

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_example_head_one worktree_other_machine_head_x worktree_other_machine_head_y_test)" ]
  [[ "$output" == *"2 worktree databases on db.example have no record on this machine and were left: another machine may use them"* ]]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
}

@test "prune drops a recorded database only on the server of its own project" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  setup_second_project
  printf '%s\n' example_dev worktree_other_head_gone > "$PG_DBS"
  write_record "$OTHER_REPO" "${TEST_ROOT}/worktrees/gone" dev worktree_other_head_gone

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_other_head_gone "$PG_DBS"
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
}

@test "prune on a local server still drops every unclaimed worktree database" {
  install_fake_pg
  write_shared_config 'host = "localhost"'
  setup_second_project
  printf '%s\n' example_dev worktree_example_head_one worktree_nobody_head_x > "$PG_DBS"
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev worktree_example_head_one

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev worktree_example_head_one)" ]
  [[ "$output" != *"were left"* ]]
}

@test "prune-all on a remote server keeps unrecorded databases too" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  setup_second_project
  printf '[database]\nbase_name = "other"\nhost = "db.example"\n' > "${OTHER_REPO}/.worktree.toml"
  seed_two_project_server
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev worktree_head_gone_a

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --prune-all
  [ "$status" -eq 0 ]
  run grep -qxF worktree_head_gone_a "$PG_DBS"
  [ "$status" -eq 1 ]
  grep -qxF worktree_head_gone_b "$PG_DBS"
  grep -qxF worktree_head_gone_a_test "$PG_DBS"
}

@test "cleanup without a record on a remote server needs the environment file to name the databases" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  printf '%s\n' example_dev worktree_head_one worktree_head_one_test > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PG_DBS")" -eq 3 ]

  # Only the development database is vouched for by the environment.
  printf 'export DATABASE_NAME="worktree_head_one"\n' > "${WORKTREE_TWO}/.envrc"
  printf '%s\n' example_dev worktree_head_two worktree_head_two_test > "$PG_DBS"
  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_TWO"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$PG_DBS")" -eq 3 ]
}

@test "cleanup of a gone worktree without a record drops nothing on a remote server" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  printf '%s\n' example_dev worktree_head_one worktree_head_one_test > "$PG_DBS"
  git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_ONE"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no record on this machine"* ]]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "two machines with the same paths get different hashed database names" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  git -C "$WORKTREE_ONE" checkout -q -b "$LONG_BRANCH"

  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_MACHINE_ID=machine-a XDG_DATA_HOME="${TEST_ROOT}/xdg-a" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_MACHINE_ID=machine-b XDG_DATA_HOME="${TEST_ROOT}/xdg-b" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local a b
  a="$(awk -F'\t' '$3 == "dev" { print $4 }' "${TEST_ROOT}/xdg-a/werksfeer/databases")"
  b="$(awk -F'\t' '$3 == "dev" { print $4 }' "${TEST_ROOT}/xdg-b/werksfeer/databases")"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" != "$b" ]
  grep -qxF "$a" "$PG_DBS"
  grep -qxF "$b" "$PG_DBS"
}

@test "the same machine derives the same hashed name every time" {
  install_fake_pg
  write_shared_config
  git -C "$WORKTREE_ONE" checkout -q -b "$LONG_BRANCH"
  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_MACHINE_ID=machine-a "$WERKSFEER"
  [ "$status" -eq 0 ]
  local first
  first="$(recorded_database_of "$WORKTREE_ONE")"
  # Start again from an empty server and an empty record.
  rm -f "$(DB_RECORD)" "${WORKTREE_ONE}/.envrc"
  printf '%s\n' example_dev example_test > "$PG_DBS"
  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_MACHINE_ID=machine-a "$WERKSFEER"
  [ "$status" -eq 0 ]
  [ "$(recorded_database_of "$WORKTREE_ONE")" = "$first" ]
}

@test "a readable database name without a record is not reused" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  printf '%s\n' example_dev example_test worktree_example_head_one worktree_example_head_one_test > "$PG_DBS"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local dev
  dev="$(recorded_database_of "$WORKTREE_ONE")"
  [ "$dev" != "worktree_example_head_one" ]
  [[ "$dev" =~ ^worktree_example_head_one_[0-9a-f]{10}$ ]]
  grep -q "CREATE DATABASE \"${dev}\" WITH TEMPLATE \"example_dev\"" "$PG_LOG"
  grep -q "export DATABASE_NAME=\"${dev}\"" "${WORKTREE_ONE}/.envrc"
  [ "$(grep -c '^worktree_example_head_one$' "$PG_DBS")" -eq 1 ]
}

@test "on a remote server an allocation alone does not adopt an old database name" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  printf '%s\n' example_dev example_test worktree_head_one worktree_head_one_test > "$PG_DBS"
  write_allocations "$MAIN_REPO" one 3001

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  grep -q 'export DATABASE_NAME="worktree_example_head_one_[0-9a-f]\{10\}"' "${WORKTREE_ONE}/.envrc"
}

# ---------------------------------------------------------------------------
# Review round: ownership, locking and paths
# ---------------------------------------------------------------------------

@test "a readable name that another worktree records is not taken while its database is absent" {
  install_fake_pg
  write_shared_config
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/elsewhere/one" dev worktree_example_head_one
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/elsewhere/one" test worktree_example_head_one_test
  [ "$(grep -c '^worktree_' "$PG_DBS")" -eq 0 ]

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$(recorded_database_of "$WORKTREE_ONE")" =~ ^worktree_example_head_one_[0-9a-f]{10}$ ]]
  grep -q "export DATABASE_NAME=\"$(recorded_database_of "$WORKTREE_ONE")\"" "${WORKTREE_ONE}/.envrc"
}

@test "concurrent setups of worktrees that would share a readable name get different databases" {
  install_fake_pg
  write_shared_config
  local twin="${TEST_ROOT}/elsewhere/example/one"
  mkdir -p "$(dirname "$twin")"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$twin" HEAD
  cp "${MAIN_REPO}/.worktree.toml" "${twin}/.worktree.toml"

  local i
  for i in 1 2 3; do
    : > "$(DB_RECORD)" 2>/dev/null || { mkdir -p "${XDG_DATA_HOME}/werksfeer"; : > "$(DB_RECORD)"; }
    printf '%s\n' example_dev example_test > "$PG_DBS"
    rm -f "${WORKTREE_ONE}/.envrc" "${twin}/.envrc"
    (cd "$WORKTREE_ONE" && PATH="$FAKE_BIN:$PATH" "$WERKSFEER" > /dev/null 2>&1) &
    (cd "$twin" && PATH="$FAKE_BIN:$PATH" "$WERKSFEER" > /dev/null 2>&1) &
    wait
    [ "$(wc -l < "$(DB_RECORD)")" -eq 4 ]
    [ "$(recorded_database_of "$WORKTREE_ONE")" != "$(recorded_database_of "$twin")" ]
  done
}

@test "concurrent setups lose no record lines and give every worktree its own ports" {
  install_fake_pg
  write_shared_config
  local one_more="${TEST_ROOT}/worktrees/three" i
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$one_more" HEAD
  cp "${MAIN_REPO}/.worktree.toml" "${one_more}/.worktree.toml"

  (cd "$WORKTREE_ONE" && PATH="$FAKE_BIN:$PATH" "$WERKSFEER" > /dev/null 2>&1) &
  (cd "$WORKTREE_TWO" && PATH="$FAKE_BIN:$PATH" "$WERKSFEER" > /dev/null 2>&1) &
  (cd "$one_more" && PATH="$FAKE_BIN:$PATH" "$WERKSFEER" > /dev/null 2>&1) &
  wait
  [ "$(wc -l < "$(DB_RECORD)")" -eq 6 ]
  [ "$(cut -f3 "${XDG_DATA_HOME}/werksfeer/allocations" | sort -u | wc -l)" -eq 3 ]
  [ ! -e "${XDG_DATA_HOME}/werksfeer/state.lock" ]
}

@test "a lock held by a running process makes setup fail loudly" {
  install_fake_pg
  write_shared_config
  mkdir -p "${XDG_DATA_HOME}/werksfeer/state.lock"
  sleep 30 &
  local holder=$!
  printf '%s\n' "$holder" > "${XDG_DATA_HOME}/werksfeer/state.lock/pid"

  run_in_worktree "$WORKTREE_ONE" env WERKSFEER_LOCK_TIMEOUT=1 "$WERKSFEER"
  kill "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not take the werksfeer lock"* ]]
  [ ! -e "$(DB_RECORD)" ]
}

@test "a lock left by a process that is gone is removed" {
  install_fake_pg
  write_shared_config
  mkdir -p "${XDG_DATA_HOME}/werksfeer/state.lock"
  sleep 0 &
  local gone=$!
  wait "$gone"
  printf '%s\n' "$gone" > "${XDG_DATA_HOME}/werksfeer/state.lock/pid"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing stale werksfeer lock"* ]]
  [ -f "$(DB_RECORD)" ]
  [ ! -e "${XDG_DATA_HOME}/werksfeer/state.lock" ]
}

@test "prune keeps a collision-hashed database when the record is lost" {
  install_fake_pg
  write_shared_config
  local twin="${TEST_ROOT}/elsewhere/example/one"
  mkdir -p "$(dirname "$twin")"
  git -C "$MAIN_REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$twin" HEAD
  cp "${MAIN_REPO}/.worktree.toml" "${twin}/.worktree.toml"
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  run_in_worktree "$twin" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local hashed
  hashed="$(recorded_database_of "$twin")"
  [[ "$hashed" =~ _[0-9a-f]{10}$ ]]
  rm -f "$(DB_RECORD)"
  : > "$PG_LOG"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF "$hashed" "$PG_DBS"
  grep -qxF "${hashed}_test" "$PG_DBS"
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "cleanup with a relative path finds the record when the folder and its parent are gone" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev custom_gone > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/vanished/parent/fix" dev custom_gone

  run_in_worktree "$TEST_ROOT" "$WERKSFEER" --cleanup "vanished/./parent/../parent/fix/"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "example_dev" ]
  [ ! -s "$(DB_RECORD)" ]
}

@test "cleanup with a record releases the allocation of the recorded project only" {
  install_fake_pg
  write_shared_config
  setup_second_project
  write_allocations "$MAIN_REPO" fix 3001 "$OTHER_REPO" fix 3002
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/fix" dev worktree_example_head_fix
  printf '%s\n' example_dev worktree_example_head_fix > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/fix"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${XDG_DATA_HOME}/werksfeer/allocations")" -eq 1 ]
  grep -qF "$(printf '%s\t%s\t' "$OTHER_REPO" fix)" "${XDG_DATA_HOME}/werksfeer/allocations"
  [[ "$output" != *"$OTHER_REPO"* ]]
}

# ---------------------------------------------------------------------------
# Review round 2: locks, endpoints, races, canonical paths, failed catalog reads
# ---------------------------------------------------------------------------

# Runs a snippet with the named functions of werksfeer loaded and nothing else.
with_functions() {
  local names="$1" snippet="$2" script=""
  local name
  for name in $names; do
    script="${script}$(sed -n "/^${name}() {/,/^}/p" "$WERKSFEER")
"
  done
  run bash -c "set -euo pipefail; log_info() { :; }; log_warn() { :; }; log_error() { :; }; ${script}
${snippet}"
}

@test "a process that holds no lock never removes one" {
  mkdir -p "${TEST_ROOT}/lock"
  printf '%s\n' 4242 > "${TEST_ROOT}/lock/pid"

  with_functions "state_lock_release state_lock_release_all" "WERKSFEER_LOCK_DEPTH=0; WERKSFEER_LOCK_DIR='${TEST_ROOT}/lock'; state_lock_release_all; state_lock_release"
  [ "$status" -eq 0 ]
  [ -d "${TEST_ROOT}/lock" ]

  # Even with a depth left over, a lock owned by another process stays.
  with_functions "state_lock_release state_lock_release_all" "WERKSFEER_LOCK_DEPTH=1; WERKSFEER_LOCK_DIR='${TEST_ROOT}/lock'; state_lock_release_all"
  [ "$status" -eq 0 ]
  [ -d "${TEST_ROOT}/lock" ]

  # Its own lock goes.
  with_functions "state_lock_release state_lock_release_all" "printf '%s\n' \$\$ > '${TEST_ROOT}/lock/pid'; WERKSFEER_LOCK_DEPTH=1; WERKSFEER_LOCK_DIR='${TEST_ROOT}/lock'; state_lock_release_all"
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_ROOT}/lock" ]
}

@test "everything that can redirect the connection counts, and what cannot be classified is remote" {
  local snippet='toml_get() { echo "${TOML_HOST:-}"; }; shared_server_is_remote'
  local fns="shared_server_host shared_server_is_remote"

  with_functions "$fns" "unset PGHOST PGHOSTADDR PGSERVICE; $snippet"
  [ "$status" -eq 1 ]
  with_functions "$fns" "unset PGHOST PGSERVICE; PGHOSTADDR=10.1.2.3; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGSERVICE; PGHOST=localhost; PGHOSTADDR=10.1.2.3; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGHOST PGSERVICE; PGHOSTADDR=127.0.0.1; $snippet"
  [ "$status" -eq 1 ]
  with_functions "$fns" "unset PGHOST PGHOSTADDR; PGSERVICE=prod; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGHOSTADDR PGSERVICE; PGHOST=localhost,db.example; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGHOSTADDR PGSERVICE; PGHOST=/var/run/postgresql; $snippet"
  [ "$status" -eq 1 ]
  with_functions "$fns" "unset PGHOST PGHOSTADDR PGSERVICE; TOML_HOST=db.example; $snippet"
  [ "$status" -eq 0 ]
}

@test "prune leaves unrecorded databases alone when PGHOSTADDR points to another machine" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev worktree_nobody_head_x > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" env PGHOSTADDR=10.9.8.7 "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_nobody_head_x "$PG_DBS"
  [[ "$output" == *"1 worktree databases on 10.9.8.7 have no record on this machine"* ]]
}

@test "a service can redirect the connection, so a database server behind one counts as remote" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev worktree_nobody_head_x > "$PG_DBS"

  run_in_worktree "$MAIN_REPO" env PGSERVICE=prod "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_nobody_head_x "$PG_DBS"
}

@test "on a remote server even a free readable name gets the machine-specific name" {
  install_fake_pg
  write_shared_config 'host = "db.example"'

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$(recorded_database_of "$WORKTREE_ONE")" =~ ^worktree_example_head_one_[0-9a-f]{10}$ ]]
  run grep -qxF worktree_example_head_one "$PG_DBS"
  [ "$status" -eq 1 ]
}

@test "a CREATE DATABASE that loses the race never leaves this worktree using the winner's database" {
  install_fake_pg
  write_shared_config
  printf '%s' 'worktree_example_head_one' > "$PG_CREATE_RACE"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"was created by someone else in the meantime"* ]]
  local dev
  dev="$(recorded_database_of "$WORKTREE_ONE")"
  [[ "$dev" =~ ^worktree_example_head_one_[0-9a-f]{10}$ ]]
  grep -q "export DATABASE_NAME=\"${dev}\"" "${WORKTREE_ONE}/.envrc"
  grep -qxF "$dev" "$PG_DBS"
  # The other database is still there and not recorded for this worktree.
  grep -qxF worktree_example_head_one "$PG_DBS"
  run grep -qxF "$(printf '%s\t%s\tdev\tworktree_example_head_one' "$MAIN_REPO" "$WORKTREE_ONE")" "$(DB_RECORD)"
  [ "$status" -eq 1 ]
}

@test "when the machine-specific name is taken in a race too, no database is used or recorded" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  printf '%s' 'worktree_example_head_one_*' > "$PG_CREATE_RACE"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists and is not this worktree's"* ]]
  run grep -q 'export DATABASE_NAME=' "${WORKTREE_ONE}/.envrc"
  [ "$status" -eq 1 ]
  run grep -qF "$(printf '\tdev\t')" "$(DB_RECORD)"
  [ "$status" -eq 1 ]
}

@test "cleanup resolves symbolic links before it applies .." {
  install_fake_pg
  write_shared_config
  local root
  root="$(cd "$TEST_ROOT" && pwd -P)"
  mkdir -p "${root}/srv/nested"
  ln -s "${root}/srv/nested" "${root}/link"
  printf '%s\n' example_dev db_target db_other > "$PG_DBS"
  write_record "$MAIN_REPO" "${root}/srv/fix" dev db_target
  write_record "$MAIN_REPO" "${root}/fix" dev db_other

  run_in_worktree "$root" "$WERKSFEER" --cleanup "${root}/link/../fix"
  [ "$status" -eq 0 ]
  [ "$(cat "$PG_DBS")" = "$(printf '%s\n' example_dev db_other)" ]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  grep -qF "${root}/fix" "$(DB_RECORD)"
}

@test "a database that an existing worktree still exports is claimed without a record" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev worktree_old_branch_one worktree_nobody_head_x > "$PG_DBS"
  # After a branch switch the environment still names the old database.
  printf 'export DATABASE_NAME="worktree_old_branch_one"\n' > "${WORKTREE_ONE}/.envrc"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  grep -qxF worktree_old_branch_one "$PG_DBS"
  run grep -qxF worktree_nobody_head_x "$PG_DBS"
  [ "$status" -eq 1 ]
}

@test "cleanup keeps a recorded database that another worktree's environment exports" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev shared_db > "$PG_DBS"
  printf 'export TEST_DATABASE_NAME="shared_db"\n' > "${WORKTREE_TWO}/.envrc"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev shared_db

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/gone"
  [ "$status" -eq 0 ]
  grep -qxF shared_db "$PG_DBS"
}

@test "db_exists tells a failed question from a no" {
  local fns="db_exists list_server_databases pg_identifier"
  with_functions "$fns" "shared_pg() { printf ' present | owner\n other | owner\n'; }; db_exists present"
  [ "$status" -eq 0 ]
  with_functions "$fns" "shared_pg() { printf ' present | owner\n'; }; db_exists absent"
  [ "$status" -eq 1 ]
  with_functions "$fns" "shared_pg() { return 2; }; set +e; db_exists present; echo \$?"
  [ "$output" = "2" ]
}

@test "cleanup keeps the record when the databases cannot be listed" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev custom_gone > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev custom_gone
  touch "$PG_LIST_FAIL"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/gone"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot tell whether custom_gone exists"* ]]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "prune skips and keeps the record when the databases cannot be listed" {
  install_fake_pg
  write_shared_config
  setup_second_project
  printf '%s\n' example_dev custom_gone > "$PG_DBS"
  write_record "$MAIN_REPO" "${TEST_ROOT}/worktrees/gone" dev custom_gone
  touch "$PG_LIST_FAIL"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot list the databases"* ]]
  [[ "$output" == *"Skipping database prune"* ]]
  [ "$(wc -l < "$(DB_RECORD)")" -eq 1 ]
}

@test "setup does not clone or record anything when the databases cannot be listed" {
  install_fake_pg
  write_shared_config
  touch "$PG_LIST_FAIL"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot list the databases"* ]]
  [ ! -e "$(DB_RECORD)" ]
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "a registered project that git cannot read keeps every database alive" {
  install_fake_pg
  write_shared_config
  setup_second_project
  seed_two_project_server
  printf 'garbage\n' > "${OTHER_REPO}/.git/HEAD"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot read the worktrees of ${OTHER_REPO}"* ]]
  run grep -q dropdb "$PG_LOG"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PG_DBS")" -eq 9 ]
}

@test "cleanup keeps an allocation when the project of the worktree cannot be read" {
  install_fake_pg
  write_shared_config
  setup_second_project
  write_allocations "$OTHER_REPO" fix 3001
  write_record "$OTHER_REPO" "${TEST_ROOT}/worktrees/gone/fix" dev some_db
  printf '%s\n' example_dev some_db > "$PG_DBS"
  printf 'garbage\n' > "${OTHER_REPO}/.git/HEAD"

  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "${TEST_ROOT}/worktrees/gone/fix"
  [ "$status" -eq 0 ]
  grep -qF "$(printf '%s\t%s\t' "$OTHER_REPO" fix)" "${XDG_DATA_HOME}/werksfeer/allocations"
}

# ---------------------------------------------------------------------------
# Review round 3: lists of hosts, ownership provenance, failed reads
# ---------------------------------------------------------------------------

@test "a list of hosts is remote, also behind a socket directory" {
  local snippet='toml_get() { echo "${TOML_HOST:-}"; }; shared_server_is_remote'
  local fns="shared_server_host shared_server_is_remote"

  with_functions "$fns" "unset PGHOSTADDR PGSERVICE; PGHOST=/var/run/postgresql,db.example; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGHOST PGSERVICE; PGHOSTADDR=127.0.0.1,10.0.0.1; $snippet"
  [ "$status" -eq 0 ]
  with_functions "$fns" "unset PGHOSTADDR PGSERVICE PGHOST; TOML_HOST=/tmp,db.example; $snippet"
  [ "$status" -eq 0 ]
  # A single socket directory stays local, also with a comma-free PGHOSTADDR.
  with_functions "$fns" "unset PGHOSTADDR PGSERVICE; PGHOST=/var/run/postgresql; $snippet"
  [ "$status" -eq 1 ]
}

@test "a hashed name that is occupied and not recorded is never reused" {
  install_fake_pg
  write_shared_config
  # The readable name is taken, so this worktree is given the hashed name.
  printf '%s\n' example_dev example_test worktree_example_head_one worktree_example_head_one_test > "$PG_DBS"
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local hashed
  hashed="$(recorded_database_of "$WORKTREE_ONE")"
  [[ "$hashed" =~ _[0-9a-f]{10}$ ]]

  # The record is lost; the hashed databases are still there, unrecorded.
  rm -f "$(DB_RECORD)" "${WORKTREE_ONE}/.envrc"
  : > "$PG_LOG"
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists and is not this worktree's"* ]]
  [[ "$output" != *"already exists, skipping"* ]]
  [ ! -e "$(DB_RECORD)" ]
  run grep -q 'DATABASE_NAME' "${WORKTREE_ONE}/.envrc"
  [ "$status" -eq 1 ]
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]

  # And cleanup never drops what it does not own.
  run_in_worktree "$MAIN_REPO" "$WERKSFEER" --cleanup "$WORKTREE_ONE"
  grep -qxF "$hashed" "$PG_DBS"
}

@test "a database that exists under a reserved name is not skipped as if it were ours" {
  install_fake_pg
  write_shared_config 'host = "db.example"'
  git -C "$WORKTREE_ONE" checkout -q -b "$LONG_BRANCH"
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local mine
  mine="$(recorded_database_of "$WORKTREE_ONE")"
  rm -f "$(DB_RECORD)"
  : > "$PG_LOG"

  # A remote server: the occupied machine-specific name has no fallback.
  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Database ${mine} already exists, skipping"* ]]
  [ ! -e "$(DB_RECORD)" ]
}

@test "a catalog read that fails after the first one stops setup before the record and environment change" {
  install_fake_pg
  write_shared_config
  printf '%s\n' example_dev example_test worktree_head_one worktree_head_one_test > "$PG_DBS"
  printf '\n# >>> werksfeer managed environment >>>\nexport DATABASE_NAME="worktree_head_one"\nexport TEST_DATABASE_NAME="worktree_head_one_test"\n# <<< werksfeer managed environment <<<\n' > "${WORKTREE_ONE}/.envrc"
  cp "${WORKTREE_ONE}/.envrc" "${TEST_ROOT}/envrc.before"
  # The preflight listing works, the next one fails.
  printf '1' > "$PG_LIST_FAIL_AFTER"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot ask the PostgreSQL server"* ]]
  [ ! -e "$(DB_RECORD)" ]
  cmp "${TEST_ROOT}/envrc.before" "${WORKTREE_ONE}/.envrc"
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "a catalog read that fails while cloning takes the reservation back and writes no environment" {
  install_fake_pg
  write_shared_config
  # Calls: preflight, legacy and readable checks for dev and test (4), then cloning.
  printf '5' > "$PG_LIST_FAIL_AFTER"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot ask the PostgreSQL server"* ]]
  [ ! -e "$(DB_RECORD)" ]
  [ ! -e "${WORKTREE_ONE}/.envrc" ] || ! grep -q 'DATABASE_NAME' "${WORKTREE_ONE}/.envrc"
  run grep -q 'CREATE DATABASE' "$PG_LOG"
  [ "$status" -eq 1 ]
}

@test "a worktree without a database of its own never sets up the default database" {
  with_functions "run_database_setup" "WERKSFEER_DB_UNCONFIGURED=1; run_database_setup elixir /nowhere; run_database_setup rails /nowhere"
  [ "$status" -eq 0 ]
}

@test "a recorded name that someone else takes before the clone is not kept, and its fallback is not adopted" {
  install_fake_pg
  write_shared_config
  write_record "$MAIN_REPO" "$WORKTREE_ONE" dev custom_dev
  printf '%s' 'custom_dev' > "$PG_CREATE_RACE"

  run_in_worktree "$WORKTREE_ONE" "$WERKSFEER"
  [ "$status" -eq 0 ]
  local dev
  dev="$(recorded_database_of "$WORKTREE_ONE")"
  [[ "$dev" =~ ^worktree_example_head_one_[0-9a-f]{10}$ ]]
  grep -q "CREATE DATABASE \"${dev}\" WITH TEMPLATE" "$PG_LOG"
  grep -qxF custom_dev "$PG_DBS"
  run grep -qxF "$(printf '%s\t%s\tdev\tcustom_dev' "$MAIN_REPO" "$WORKTREE_ONE")" "$(DB_RECORD)"
  [ "$status" -eq 1 ]
}
