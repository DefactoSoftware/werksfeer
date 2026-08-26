#!/usr/bin/env bash

# A private PostgreSQL cluster per linked worktree. The durable cluster lives
# in the checkout; its disposable Unix socket uses a short deterministic path
# so deeply nested agent worktrees do not exceed sockaddr_un limits.

postgres_setting_enabled() {
  local project_root="$1"

  case "${WERKSFEER_POSTGRES:-}" in
    "") [ -f "${project_root}/.git" ] ;;
    1|true) return 0 ;;
    0|false) return 1 ;;
    *)
      log_error "WERKSFEER_POSTGRES must be true, false, 1, or 0"
      return 2
      ;;
  esac
}

postgres_enabled_value() {
  local project_root="$1"

  if postgres_setting_enabled "$project_root"; then
    printf 'true\n'
    return 0
  fi

  local status=$?
  [ "$status" -eq 1 ] || return "$status"
  printf 'false\n'
}

postgres_sha256() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    log_error "openssl, shasum, or sha256sum is required to identify this worktree"
    return 1
  fi
}

postgres_worktree_identity() {
  local project_root="$1"

  if [ -f "${project_root}/.git" ]; then
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${project_root}/.git" | tr -d '\n'
  else
    printf '%s' "$project_root"
  fi
}

postgres_socket_directory() {
  local project_root="$1"
  local fingerprint socket_root
  fingerprint="$(postgres_worktree_identity "$project_root" | postgres_sha256)"
  socket_root="$(toml_get "postgres" "socket_root" "/tmp")"

  case "$socket_root" in
    /*) ;;
    *)
      log_error "postgres.socket_root must be an absolute path: $socket_root"
      return 1
      ;;
  esac
  case "$socket_root" in
    *"'"*)
      log_error "postgres.socket_root must not contain a single quote"
      return 1
      ;;
  esac

  printf '%s/werksfeer-pg-%s-%s\n' "${socket_root%/}" "$(id -u)" "${fingerprint:0:12}"
}

postgres_data_directory() {
  local project_root="$1"
  local configured
  configured="$(toml_get "postgres" "data_dir" ".pg_data")"

  case "$configured" in
    ""|.|./|/*|..|../*|*/../*|*/..)
      log_error "postgres.data_dir must be a worktree-relative path without '..': $configured"
      return 1
      ;;
  esac

  printf '%s/%s\n' "${project_root%/}" "${configured#./}"
}

postgres_port() {
  local port
  port="$(toml_get "postgres" "port" "5432")"

  case "$port" in
    ""|*[!0-9]*)
      log_error "postgres.port must be an integer: $port"
      return 1
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    log_error "postgres.port must be between 1 and 65535: $port"
    return 1
  fi

  printf '%s\n' "$port"
}

postgres_user() {
  toml_get "postgres" "user" "postgres"
}

postgres_resolve_pg_config() {
  if [ -n "${PG_CONFIG:-}" ] && [ -x "${PG_CONFIG}" ]; then
    printf '%s\n' "${PG_CONFIG}"
  elif command -v pg_config >/dev/null 2>&1; then
    command -v pg_config
  else
    return 1
  fi
}

postgres_resolve_tool() {
  local tool_name="$1"
  local pg_config_path="${2:-}"

  if [ -n "$pg_config_path" ]; then
    local postgres_bindir
    postgres_bindir="$(${pg_config_path} --bindir)"

    if [ -x "${postgres_bindir}/${tool_name}" ]; then
      printf '%s\n' "${postgres_bindir}/${tool_name}"
      return 0
    fi
  fi

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  return 1
}

postgres_load_tools() {
  POSTGRES_PG_CONFIG="$(postgres_resolve_pg_config)" || {
    log_error "pg_config was not found; install PostgreSQL and add pg_config to PATH"
    return 1
  }

  POSTGRES_INITDB="$(postgres_resolve_tool initdb "$POSTGRES_PG_CONFIG")" || {
    log_error "initdb was not found next to $(${POSTGRES_PG_CONFIG} --bindir)"
    return 1
  }
  POSTGRES_PG_CTL="$(postgres_resolve_tool pg_ctl "$POSTGRES_PG_CONFIG")" || {
    log_error "pg_ctl was not found next to $(${POSTGRES_PG_CONFIG} --bindir)"
    return 1
  }
  POSTGRES_PG_ISREADY="$(postgres_resolve_tool pg_isready "$POSTGRES_PG_CONFIG")" || {
    log_error "pg_isready was not found next to $(${POSTGRES_PG_CONFIG} --bindir)"
    return 1
  }
  POSTGRES_PSQL="$(postgres_resolve_tool psql "$POSTGRES_PG_CONFIG")" || {
    log_error "psql was not found next to $(${POSTGRES_PG_CONFIG} --bindir)"
    return 1
  }
  POSTGRES_SERVER="$(postgres_resolve_tool postgres "$POSTGRES_PG_CONFIG")" || {
    log_error "postgres was not found next to $(${POSTGRES_PG_CONFIG} --bindir)"
    return 1
  }
}

postgres_check_required_extensions() {
  local extensions_directory extension_name extensions
  extensions_directory="$(${POSTGRES_PG_CONFIG} --sharedir)/extension"
  extensions="$(toml_get_array "postgres" "required_extensions")"
  [ -z "$extensions" ] && return 0

  while IFS= read -r extension_name; do
    [ -z "$extension_name" ] && continue
    case "$extension_name" in
      *[!a-zA-Z0-9_-]*)
        log_error "Invalid PostgreSQL extension name: $extension_name"
        return 1
        ;;
    esac
    if [ ! -f "${extensions_directory}/${extension_name}.control" ]; then
      log_error "PostgreSQL extension ${extension_name} is missing from ${extensions_directory}"
      log_error "Install it for $(${POSTGRES_PG_CONFIG} --version) before provisioning this worktree"
      return 1
    fi
  done <<EOF_EXTENSIONS
$extensions
EOF_EXTENSIONS
}

postgres_directory_owner() {
  if stat -f '%u' "$1" >/dev/null 2>&1; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

postgres_prepare_socket_directory() {
  local socket_dir="$1"

  if [ -L "$socket_dir" ]; then
    log_error "Refusing to use symlinked socket directory: $socket_dir"
    return 1
  fi

  if [ -e "$socket_dir" ]; then
    [ -d "$socket_dir" ] || {
      log_error "Socket path exists and is not a directory: $socket_dir"
      return 1
    }
    [ "$(postgres_directory_owner "$socket_dir")" = "$(id -u)" ] || {
      log_error "Socket directory is not owned by the current user: $socket_dir"
      return 1
    }
  else
    (umask 077 && mkdir "$socket_dir")
  fi

  chmod 700 "$socket_dir"
}

postgres_major_version() {
  "$POSTGRES_SERVER" --version | sed -E 's/.* ([0-9]+)(\..*)?$/\1/'
}

postgres_check_data_directory() {
  local data_directory="$1"

  if [ -L "$data_directory" ]; then
    log_error "Refusing to use symlinked PostgreSQL data directory: $data_directory"
    return 1
  fi

  if [ -e "$data_directory" ]; then
    [ -d "$data_directory" ] || {
      log_error "PostgreSQL data path is not a directory: $data_directory"
      return 1
    }
    [ "$(postgres_directory_owner "$data_directory")" = "$(id -u)" ] || {
      log_error "PostgreSQL data directory is not owned by the current user: $data_directory"
      return 1
    }
  fi

  if [ -f "${data_directory}/PG_VERSION" ]; then
    local data_version binary_version
    data_version="$(sed -E 's/^([0-9]+).*/\1/' "${data_directory}/PG_VERSION")"
    binary_version="$(postgres_major_version)"

    if [ "$data_version" != "$binary_version" ]; then
      log_error "$data_directory uses PostgreSQL $data_version, but the active binaries are PostgreSQL $binary_version"
      log_error "Stop the old server and remove this worktree's data directory to rebuild it"
      return 1
    fi
  fi
}

postgres_initialize_cluster() {
  local data_directory="$1"
  [ -f "${data_directory}/PG_VERSION" ] && return 0

  if [ -d "$data_directory" ] && [ -n "$(find "$data_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    log_error "$data_directory exists but is not an initialized PostgreSQL cluster"
    return 1
  fi

  log_info "Initializing PostgreSQL in $data_directory"
  "$POSTGRES_INITDB" \
    --pgdata="$data_directory" \
    --username="$(postgres_user)" \
    --encoding=UTF8 \
    --auth-local=trust \
    --auth-host=reject \
    --no-instructions
}

postgres_ensure_cluster_include() {
  local data_directory="$1"
  local include_line="include_if_exists = 'werksfeer.conf'"
  [ -f "${data_directory}/postgresql.conf" ] || return 1
  grep -Fqx "$include_line" "${data_directory}/postgresql.conf" && return 0

  cat >> "${data_directory}/postgresql.conf" <<'POSTGRES_CONFIG'

# Worktree-local settings managed by werksfeer
include_if_exists = 'werksfeer.conf'
POSTGRES_CONFIG
}

postgres_write_cluster_config() {
  local data_directory="$1"
  local socket_dir="$2"

  cat > "${data_directory}/werksfeer.conf" <<POSTGRES_CONFIG
# Generated by werksfeer. Rewritten on every start.
listen_addresses = ''
port = $(postgres_port)
unix_socket_directories = '${socket_dir}'
unix_socket_permissions = 0700
POSTGRES_CONFIG
}

postgres_cluster_running() {
  local data_directory="$1"
  "$POSTGRES_PG_CTL" status --pgdata="$data_directory" >/dev/null 2>&1
}

werksfeer_service_postgres_start() {
  local project_root="$1"
  if postgres_setting_enabled "$project_root"; then
    :
  else
    local enabled_status=$?
    [ "$enabled_status" -eq 1 ] && return 0
    return "$enabled_status"
  fi

  local data_directory socket_dir
  data_directory="$(postgres_data_directory "$project_root")"
  socket_dir="$(postgres_socket_directory "$project_root")"

  postgres_load_tools
  postgres_check_required_extensions
  postgres_check_data_directory "$data_directory"
  postgres_prepare_socket_directory "$socket_dir"
  postgres_initialize_cluster "$data_directory"
  postgres_ensure_cluster_include "$data_directory"
  postgres_write_cluster_config "$data_directory" "$socket_dir"

  if postgres_cluster_running "$data_directory"; then
    if "$POSTGRES_PG_ISREADY" --quiet --host="$socket_dir" --port="$(postgres_port)"; then
      log_info "PostgreSQL is already running at $socket_dir"
      return 0
    fi

    log_error "pg_ctl reports a running cluster, but it is not ready at $socket_dir"
    return 1
  fi

  log_info "Starting PostgreSQL at $socket_dir"
  "$POSTGRES_PG_CTL" start \
    --pgdata="$data_directory" \
    --log="${data_directory}/postgres.log" \
    --wait \
    --timeout=30

  "$POSTGRES_PG_ISREADY" --quiet --host="$socket_dir" --port="$(postgres_port)" || {
    log_error "PostgreSQL started but did not become ready at $socket_dir"
    return 1
  }
}

werksfeer_service_postgres_prepare() {
  werksfeer_service_postgres_start "$1"
}

werksfeer_service_postgres_stop() {
  local project_root="$1"
  local data_directory socket_dir
  data_directory="$(postgres_data_directory "$project_root")"
  socket_dir="$(postgres_socket_directory "$project_root")"

  if [ ! -f "${data_directory}/PG_VERSION" ]; then
    log_info "No worktree PostgreSQL cluster has been initialized"
    return 0
  fi

  postgres_load_tools
  postgres_check_data_directory "$data_directory"

  if postgres_cluster_running "$data_directory"; then
    log_info "Stopping PostgreSQL in $data_directory"
    "$POSTGRES_PG_CTL" stop \
      --pgdata="$data_directory" \
      --mode=fast \
      --wait \
      --timeout=30
  else
    log_info "PostgreSQL is already stopped"
  fi

  if [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ]; then
    rmdir "$socket_dir" 2>/dev/null || true
  fi
}

werksfeer_service_postgres_cleanup() {
  werksfeer_service_postgres_stop "$1"
}

werksfeer_service_postgres_status() {
  local project_root="$1"
  local data_directory enabled
  data_directory="$(postgres_data_directory "$project_root")"
  enabled="$(postgres_enabled_value "$project_root")" || return $?

  if [ ! -f "${data_directory}/PG_VERSION" ]; then
    log_info "PostgreSQL is not initialized for this worktree"
    printf 'enabled=%s\ndata_directory=%s\nsocket_directory=%s\n' \
      "$enabled" \
      "$data_directory" \
      "$(postgres_socket_directory "$project_root")"
    return 0
  fi

  postgres_load_tools
  postgres_check_data_directory "$data_directory"

  if postgres_cluster_running "$data_directory"; then
    log_info "PostgreSQL is running"
  else
    log_info "PostgreSQL is stopped"
  fi

  printf 'enabled=%s\ndata_directory=%s\nsocket_directory=%s\npostgres_version=%s\n' \
    "$enabled" \
    "$data_directory" \
    "$(postgres_socket_directory "$project_root")" \
    "$(postgres_major_version)"
}

werksfeer_service_postgres_doctor() {
  local project_root="$1"
  local enabled
  enabled="$(postgres_enabled_value "$project_root")" || return $?

  postgres_load_tools
  postgres_check_required_extensions

  printf 'enabled=%s\ndata_directory=%s\nsocket_directory=%s\npg_config=%s\npostgres=%s\npostgres_version=%s\nextensions=ok\n' \
    "$enabled" \
    "$(postgres_data_directory "$project_root")" \
    "$(postgres_socket_directory "$project_root")" \
    "$POSTGRES_PG_CONFIG" \
    "$POSTGRES_SERVER" \
    "$(postgres_major_version)"
}

werksfeer_service_postgres_env() {
  local project_root="$1"
  if postgres_setting_enabled "$project_root"; then
    :
  else
    local enabled_status=$?
    [ "$enabled_status" -eq 1 ] && return 0
    return "$enabled_status"
  fi

  local socket_dir
  socket_dir="$(postgres_socket_directory "$project_root")"

  printf 'DATABASE_SOCKET_DIR=%s\nDATABASE_HOST=%s\nDATABASE_PORT=%s\nDATABASE_USER=%s\nPGHOST=%s\nPGPORT=%s\nPGUSER=%s\n' \
    "$socket_dir" \
    "$socket_dir" \
    "$(postgres_port)" \
    "$(postgres_user)" \
    "$socket_dir" \
    "$(postgres_port)" \
    "$(postgres_user)"
}

werksfeer_service_postgres_socket_dir() {
  postgres_socket_directory "$1"
}

werksfeer_service_postgres_database_exists() {
  local project_root="$1"
  local database_name="${2:-}"
  [ -n "$database_name" ] || {
    log_error "postgres database-exists requires a database name"
    return 2
  }
  case "$database_name" in
    *[!a-zA-Z0-9_]*)
      log_error "postgres database-exists only accepts letters, numbers, and underscores"
      return 2
      ;;
  esac

  postgres_load_tools

  local result
  result="$("$POSTGRES_PSQL" \
    --host="$(postgres_socket_directory "$project_root")" \
    --port="$(postgres_port)" \
    --username="$(postgres_user)" \
    --dbname=postgres \
    --no-align \
    --tuples-only \
    --command="SELECT 1 FROM pg_database WHERE datname = '${database_name}'")"

  [ "$(echo "$result" | tr -d '[:space:]')" = "1" ]
}
