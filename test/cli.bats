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

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add mix.exs .gitignore .worktree.toml
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
  [ "$output" = "werksfeer 0.3.0" ]
}

@test "runs with the system Bash used by macOS" {
  run env PATH="/usr/bin:/bin" "$WERKSFEER" --version

  [ "$status" -eq 0 ]
  [ "$output" = "werksfeer 0.3.0" ]
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

@test "opt-in automatic warming prepares the cache during worktree setup" {
  fake_bin="${TEST_ROOT}/automatic-cache-bin"
  mkdir -p "$fake_bin"
  cat > "${MAIN_REPO}/.worktree.toml" <<'EOF_CONFIG'
[cache]
ref = "HEAD"
auto_warm = true
command = "mkdir -p _build/dev && printf 'automatic cache' > _build/dev/value"

[setup]
command = "true"
EOF_CONFIG
  git -C "$MAIN_REPO" add .worktree.toml
  git -C "$MAIN_REPO" commit -qm "enable automatic cache warming"
  git -C "$WORKTREE_ONE" reset -q --hard "$(git -C "$MAIN_REPO" rev-parse HEAD)"

  cat > "${fake_bin}/elixir" <<'EOF_ELIXIR'
#!/usr/bin/env bash
exit 0
EOF_ELIXIR
  chmod +x "${fake_bin}/elixir"

  run bash -c "cd \"$WORKTREE_ONE\" && PATH=\"$fake_bin:/usr/bin:/bin\" WERKSFEER_POSTGRES=false \"$WERKSFEER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warming elixir build cache"* ]]
  [[ "$output" == *"Using managed build cache"* ]]
  [ "$(cat "${WORKTREE_ONE}/_build/dev/value")" = "automatic cache" ]
  [ -z "$(git -C "$MAIN_REPO" status --porcelain --untracked-files=all)" ]
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
# Use framework defaults without a custom setup command.
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
