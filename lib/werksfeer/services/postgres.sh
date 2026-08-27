#!/usr/bin/env bash

# A private PostgreSQL cluster per linked worktree. The durable cluster lives
# in the checkout; its disposable Unix socket uses a short deterministic path
# so deeply nested agent worktrees do not exceed sockaddr_un limits.

postgres_setting_enabled() {
  local project_root="$1"
  local configured

  case "${WERKSFEER_POSTGRES:-}" in
    "") configured="$(toml_get "postgres" "enabled" "")" ;;
    1|true) return 0 ;;
    0|false) return 1 ;;
    *)
      log_error "WERKSFEER_POSTGRES must be true, false, 1, or 0"
      return 2
      ;;
  esac

  case "$configured" in
    "") [ -f "${project_root}/.git" ] ;;
    1|true) return 0 ;;
    0|false) return 1 ;;
    *)
      log_error "postgres.enabled must be true, false, 1, or 0"
      return 2
      ;;
  esac
}

postgres_enabled_value() {
  local project_root="$1"
  local status

  if postgres_setting_enabled "$project_root"; then
    printf 'true\n'
    return 0
  else
    status=$?
  fi

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

postgres_encoding() {
  printf 'UTF8\n'
}

postgres_locale() {
  # Pass the locale explicitly so an invalid inherited LANG cannot make
  # initdb fail before it applies the repository's intended cluster locale.
  toml_get "postgres" "locale" "en_US.UTF-8"
}

postgres_run_with_locale() {
  # PostgreSQL's macOS postmaster can become multithreaded and abort during
  # startup when it inherits an unsuitable locale, even when initdb was given
  # an explicit cluster locale. Keep the tool and server process aligned with
  # the locale used to initialize and validate the cluster.
  LC_ALL="$(postgres_locale)" "$@"
}

postgres_normalize_locale() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_.-'
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

postgres_template_cache_enabled() {
  local configured configured_in_file
  if [ "${WERKSFEER_POSTGRES_TEMPLATE_CACHE+x}" = "x" ]; then
    configured="$WERKSFEER_POSTGRES_TEMPLATE_CACHE"
  else
    configured_in_file="$(toml_get "postgres" "template_cache" "__unset__")"

    # A custom setup can have arbitrary database semantics. Repositories that
    # want caching alongside one must opt back in explicitly.
    if [ -n "$(toml_get "setup" "command" "")" ] &&
        [ "$configured_in_file" = "__unset__" ]; then
      return 1
    fi

    if [ "$configured_in_file" = "__unset__" ]; then
      configured="true"
    else
      configured="$configured_in_file"
    fi
  fi

  case "$configured" in
    1|true) return 0 ;;
    0|false) return 1 ;;
    *)
      log_error "postgres.template_cache must be true, false, 1, or 0"
      return 2
      ;;
  esac
}

postgres_template_ref() {
  local project_root="$1"
  local configured="${WERKSFEER_POSTGRES_TEMPLATE_REF:-$(toml_get "postgres" "template_ref" "")}"

  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
    return 0
  fi

  local main_path remote_head
  main_path="$(cd "$project_root" && get_main_worktree_path)"
  remote_head="$(git -C "$main_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$remote_head" ]; then
    printf '%s\n' "$remote_head"
  elif git -C "$main_path" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'origin/main\n'
  elif git -C "$main_path" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'origin/master\n'
  else
    return 1
  fi
}

postgres_template_seed_paths() {
  case "$1" in
    elixir) printf '%s\n' priv/repo/seeds.exs priv/repo/seeds ;;
    rails) printf '%s\n' db/seeds.rb db/seeds ;;
    *) return 1 ;;
  esac
}

postgres_template_seed_fingerprint() {
  local project_root="$1"
  local project_type="$2"
  local seed_paths
  seed_paths="$(postgres_template_seed_paths "$project_type")" || return 1

  # Hash committed seed inputs rather than timestamps or a mutable working
  # tree. Identical seeds can safely reuse an older ancestor and migrate it.
  local listing=""
  while IFS= read -r seed_path; do
    [ -z "$seed_path" ] && continue
    listing="${listing}$(git -C "$project_root" ls-tree -r HEAD -- "$seed_path")
"
  done <<EOF_SEED_PATHS
$seed_paths
EOF_SEED_PATHS

  printf '%s' "${listing:-no-committed-seeds}" | postgres_sha256
}

postgres_template_repository_key() {
  local project_root="$1"
  local main_path
  main_path="$(cd "$project_root" && get_main_worktree_path)"
  main_path="$(cd "$main_path" && pwd -P)"
  printf '%s' "$main_path" | postgres_sha256
}

postgres_template_version_root() {
  local project_root="$1"
  local repository_key
  repository_key="$(postgres_template_repository_key "$project_root")"
  printf '%s/werksfeer/postgres-templates/%s/pg%s\n' \
    "${XDG_CACHE_HOME:-$HOME/.cache}" \
    "${repository_key:0:16}" \
    "$(postgres_major_version)"
}

postgres_template_compatibility_key() {
  local project_root="$1"
  local project_type="$2"
  local db_names extensions seed_fingerprint
  db_names="$(get_base_db_names "$project_type")" || return 1
  extensions="$(toml_get_array "postgres" "required_extensions")"
  seed_fingerprint="$(postgres_template_seed_fingerprint "$project_root" "$project_type")" || return 1

  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$project_type" \
    "$db_names" \
    "$(postgres_user)" \
    "$(postgres_encoding)" \
    "$(postgres_locale)" \
    "$extensions" \
    "$seed_fingerprint" | postgres_sha256
}

postgres_template_compatibility_root() {
  local project_root="$1"
  local project_type="$2"
  local compatibility_key
  compatibility_key="$(postgres_template_compatibility_key "$project_root" "$project_type")" || return 1
  printf '%s/%s\n' \
    "$(postgres_template_version_root "$project_root")" \
    "${compatibility_key:0:24}"
}

postgres_copy_tree() {
  local source="$1"
  local destination="$2"

  [ -d "$source" ] || return 1
  [ ! -e "$destination" ] || {
    log_error "Refusing to overwrite template copy destination: $destination"
    return 1
  }
  mkdir -p "$(dirname "$destination")"

  if [ "$(uname -s)" = "Darwin" ]; then
    # clonefile-backed copies are copy-on-write on APFS.
    if cp -cR "$source" "$destination" 2>/dev/null; then
      return 0
    fi
  elif cp --reflink=auto -a "$source" "$destination" 2>/dev/null; then
    return 0
  fi

  [ ! -e "$destination" ] || {
    log_error "Copy-on-write template copy left a partial destination: $destination"
    return 1
  }

  cp -Rp "$source" "$destination"
}

postgres_remove_template_staging() {
  local staging="$1"
  local expected_parent="$2"

  case "$staging" in
    "${expected_parent}"/.template-*) rm -rf -- "$staging" ;;
    *)
      log_error "Refusing to remove unexpected template staging path: $staging"
      return 1
      ;;
  esac
}

postgres_find_compatible_template() {
  local project_root="$1"
  local project_type="$2"
  local compatibility_root candidate candidate_commit distance
  local best="" best_distance=""
  compatibility_root="$(postgres_template_compatibility_root "$project_root" "$project_type")" || return 1

  for candidate in "${compatibility_root}"/*; do
    [ ! -L "$candidate" ] || continue
    [ -f "${candidate}/READY" ] || continue
    [ -f "${candidate}/data/PG_VERSION" ] || continue
    [ ! -L "${candidate}/data" ] || continue
    [ "$(postgres_directory_owner "${candidate}/data")" = "$(id -u)" ] || continue
    candidate_commit="$(basename "$candidate")"
    case "$candidate_commit" in
      *[!0-9a-f]*) continue ;;
    esac
    git -C "$project_root" merge-base --is-ancestor "$candidate_commit" HEAD 2>/dev/null || continue
    distance="$(git -C "$project_root" rev-list --count "${candidate_commit}..HEAD")"
    if [ -z "$best_distance" ] || [ "$distance" -lt "$best_distance" ]; then
      best="$candidate"
      best_distance="$distance"
    fi
  done

  [ -n "$best" ] && printf '%s\n' "$best"
}

postgres_hydrate_from_template() {
  local project_root="$1"
  local project_type="$2"
  if postgres_setting_enabled "$project_root"; then
    :
  else
    local setting_status=$?
    [ "$setting_status" -eq 1 ] && return 0
    return "$setting_status"
  fi

  local data_directory template staging
  data_directory="$(postgres_data_directory "$project_root")"

  [ ! -f "${data_directory}/PG_VERSION" ] || return 0
  postgres_template_cache_enabled || {
    local enabled_status=$?
    [ "$enabled_status" -eq 1 ] && return 0
    return "$enabled_status"
  }

  # Only a cluster created as part of this unattended setup may become a
  # shared template. Never snapshot an existing developer database.
  POSTGRES_TEMPLATE_PUBLISH_ELIGIBLE=1

  postgres_load_tools
  template="$(postgres_find_compatible_template "$project_root" "$project_type")" || template=""
  [ -n "$template" ] || {
    log_info "No compatible PostgreSQL template is cached; this worktree will seed a fresh database"
    return 0
  }

  if [ -d "$data_directory" ]; then
    [ -z "$(find "$data_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] || return 0
    rmdir "$data_directory"
  elif [ -e "$data_directory" ]; then
    return 0
  fi

  log_info "Hydrating PostgreSQL from cached template $(basename "$template")"
  staging="${data_directory}.template.$$"
  if ! postgres_copy_tree "${template}/data" "$staging"; then
    case "$staging" in
      "${data_directory}".template.*) rm -rf -- "$staging" ;;
    esac
    log_warn "Could not hydrate the cached PostgreSQL template; initializing a fresh cluster instead"
    return 0
  fi
  if ! mv "$staging" "$data_directory"; then
    case "$staging" in
      "${data_directory}".template.*) rm -rf -- "$staging" ;;
    esac
    log_error "Could not install the hydrated PostgreSQL template"
    return 1
  fi
}

postgres_prune_templates() {
  local version_root="$1"
  local keep
  keep="$(toml_get "postgres" "template_retention" "3")"
  case "$keep" in
    ""|*[!0-9]*)
      log_error "postgres.template_retention must be a positive integer: $keep"
      return 1
      ;;
  esac
  [ "$keep" -ge 1 ] || {
    log_error "postgres.template_retention must be at least 1"
    return 1
  }

  local count=0 created ready template_dir compatibility_dir commit compatibility
  while IFS="$(printf '\t')" read -r created ready; do
    [ -n "$ready" ] || continue
    count=$((count + 1))
    [ "$count" -le "$keep" ] && continue

    template_dir="$(dirname "$ready")"
    compatibility_dir="$(dirname "$template_dir")"
    commit="$(basename "$template_dir")"
    compatibility="$(basename "$compatibility_dir")"
    case "$commit" in
      ""|*[!0-9a-f]*)
        log_warn "Skipping unexpected cached template path: $template_dir"
        continue
        ;;
    esac
    case "$compatibility" in
      ""|*[!0-9a-f]*)
        log_warn "Skipping unexpected cached template path: $template_dir"
        continue
        ;;
    esac
    case "$template_dir" in
      "${version_root}"/*/*)
        log_info "Pruning old PostgreSQL template $commit"
        rm -rf -- "$template_dir"
        rmdir "$compatibility_dir" 2>/dev/null || true
        ;;
      *) log_warn "Skipping template outside cache root: $template_dir" ;;
    esac
  done <<EOF_TEMPLATES
$(find "$version_root" -mindepth 3 -maxdepth 3 -type f -name READY -print 2>/dev/null | while IFS= read -r ready; do
  created="$(sed -n '1p' "$ready")"
  case "$created" in ""|*[!0-9]*) created=0 ;; esac
  printf '%s\t%s\n' "$created" "$ready"
done | sort -rn)
EOF_TEMPLATES
}

postgres_publish_template() {
  local project_root="$1"
  local project_type="$2"
  if postgres_setting_enabled "$project_root"; then
    :
  else
    local setting_status=$?
    [ "$setting_status" -eq 1 ] && return 0
    return "$setting_status"
  fi

  postgres_template_cache_enabled || {
    local enabled_status=$?
    [ "$enabled_status" -eq 1 ] && return 0
    return "$enabled_status"
  }
  [ "${POSTGRES_TEMPLATE_PUBLISH_ELIGIBLE:-0}" = "1" ] || {
    log_debug "Not publishing PostgreSQL template from an existing worktree database"
    return 0
  }

  local template_ref ref_commit current_commit compatibility_root version_root template_dir
  template_ref="$(postgres_template_ref "$project_root")" || {
    log_debug "No remote default branch is available for PostgreSQL template publishing"
    return 0
  }
  ref_commit="$(git -C "$project_root" rev-parse "${template_ref}^{commit}" 2>/dev/null)" || return 0
  current_commit="$(git -C "$project_root" rev-parse HEAD)"
  [ "$current_commit" = "$ref_commit" ] || {
    log_debug "Not publishing PostgreSQL template: HEAD is not $template_ref"
    return 0
  }
  [ -z "$(git -C "$project_root" status --porcelain --untracked-files=all)" ] || {
    log_debug "Not publishing PostgreSQL template from a dirty worktree"
    return 0
  }

  postgres_load_tools
  version_root="$(postgres_template_version_root "$project_root")"
  compatibility_root="$(postgres_template_compatibility_root "$project_root" "$project_type")" || return 0
  template_dir="${compatibility_root}/${current_commit}"
  [ ! -f "${template_dir}/READY" ] || return 0

  local lock_dir="${compatibility_root}/.publish-${current_commit}.lock"
  (umask 077 && mkdir -p "$compatibility_root")
  if ! mkdir "$lock_dir" 2>/dev/null; then
    log_info "Another process is publishing PostgreSQL template $current_commit"
    return 0
  fi

  local data_directory staging status=0 was_running=false
  data_directory="$(postgres_data_directory "$project_root")"
  staging="${compatibility_root}/.template-${current_commit}.$$"
  if postgres_cluster_running "$data_directory"; then
    was_running=true
  fi

  log_info "Publishing clean PostgreSQL template for $template_ref"
  werksfeer_service_postgres_stop "$project_root" || status=$?
  if [ "$status" -eq 0 ]; then
    (umask 077 && mkdir "$staging") || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    postgres_copy_tree "$data_directory" "${staging}/data" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$(date +%s)" > "${staging}/READY"
    printf 'ref=%s\ncommit=%s\n' "$template_ref" "$current_commit" > "${staging}/manifest"
    mv "$staging" "$template_dir" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    log_info "Cached PostgreSQL template at $template_dir"
    postgres_prune_templates "$version_root" || status=$?
  elif [ -e "$staging" ]; then
    postgres_remove_template_staging "$staging" "$compatibility_root" 2>/dev/null || true
  fi

  rmdir "$lock_dir" 2>/dev/null || true
  if [ "$was_running" = true ]; then
    werksfeer_service_postgres_start "$project_root" || status=$?
  fi
  return "$status"
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
  postgres_run_with_locale "$POSTGRES_INITDB" \
    --pgdata="$data_directory" \
    --username="$(postgres_user)" \
    --encoding="$(postgres_encoding)" \
    --locale="$(postgres_locale)" \
    --auth-local=trust \
    --auth-host=reject \
    --no-instructions
}

postgres_check_cluster_metadata() {
  local project_root="$1"
  local data_directory="$2"
  local metadata actual_encoding actual_collation actual_ctype expected_locale

  metadata="$("$POSTGRES_PSQL" \
    --host="$(postgres_socket_directory "$project_root")" \
    --port="$(postgres_port)" \
    --username="$(postgres_user)" \
    --dbname=postgres \
    --no-align \
    --tuples-only \
    --field-separator='|' \
    --set=ON_ERROR_STOP=1 \
    --command="SELECT pg_encoding_to_char(encoding), datcollate, datctype FROM pg_database WHERE datname = 'template1'")" || {
      log_error "Could not inspect PostgreSQL encoding and locale in $data_directory"
      return 1
    }

  IFS='|' read -r actual_encoding actual_collation actual_ctype <<EOF_METADATA
$metadata
EOF_METADATA
  expected_locale="$(postgres_locale)"

  if [ "$actual_encoding" != "$(postgres_encoding)" ] ||
      [ "$(postgres_normalize_locale "$actual_collation")" != "$(postgres_normalize_locale "$expected_locale")" ] ||
      [ "$(postgres_normalize_locale "$actual_ctype")" != "$(postgres_normalize_locale "$expected_locale")" ]; then
    log_error "$data_directory uses ${actual_encoding:-unknown}/${actual_collation:-unknown}/${actual_ctype:-unknown}"
    log_error "Expected $(postgres_encoding)/${expected_locale}/${expected_locale}"
    log_error "Stop the old server and move or remove this worktree's data directory to rebuild it"
    return 1
  fi
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
      postgres_check_cluster_metadata "$project_root" "$data_directory"
      return $?
    fi

    log_error "pg_ctl reports a running cluster, but it is not ready at $socket_dir"
    return 1
  fi

  log_info "Starting PostgreSQL at $socket_dir"
  postgres_run_with_locale "$POSTGRES_PG_CTL" start \
    --pgdata="$data_directory" \
    --log="${data_directory}/postgres.log" \
    --wait \
    --timeout=30

  "$POSTGRES_PG_ISREADY" --quiet --host="$socket_dir" --port="$(postgres_port)" || {
    log_error "PostgreSQL started but did not become ready at $socket_dir"
    return 1
  }

  if ! postgres_check_cluster_metadata "$project_root" "$data_directory"; then
    "$POSTGRES_PG_CTL" stop \
      --pgdata="$data_directory" \
      --mode=fast \
      --wait \
      --timeout=30 || true
    return 1
  fi
}

werksfeer_service_postgres_prepare() {
  werksfeer_service_postgres_start "$1"
}

werksfeer_service_postgres_template_hydrate() {
  postgres_hydrate_from_template "$1" "$2"
}

werksfeer_service_postgres_template_publish() {
  postgres_publish_template "$1" "$2"
}

werksfeer_service_postgres_template_status() {
  local project_root="$1"
  local project_type template_ref ref_commit template=""
  project_type="$(detect_project_type "$project_root")"

  if postgres_template_cache_enabled; then
    printf 'enabled=true\n'
  else
    local enabled_status=$?
    if [ "$enabled_status" -eq 1 ]; then
      printf 'enabled=false\n'
      return 0
    fi
    return "$enabled_status"
  fi

  postgres_load_tools
  template_ref="$(postgres_template_ref "$project_root")" || template_ref=""
  if [ -n "$template_ref" ]; then
    ref_commit="$(git -C "$project_root" rev-parse "${template_ref}^{commit}" 2>/dev/null || true)"
  else
    ref_commit=""
  fi
  template="$(postgres_find_compatible_template "$project_root" "$project_type")" || template=""

  printf 'template_ref=%s\nref_commit=%s\ncache_root=%s\ncompatible_template=%s\n' \
    "$template_ref" \
    "$ref_commit" \
    "$(postgres_template_version_root "$project_root")" \
    "$template"
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

  if [ "$enabled" = "false" ]; then
    printf 'enabled=false\n'
    return 0
  fi

  postgres_load_tools
  postgres_check_required_extensions

  printf 'enabled=%s\ndata_directory=%s\nsocket_directory=%s\npg_config=%s\npostgres=%s\npostgres_version=%s\nencoding=%s\nlocale=%s\nextensions=ok\n' \
    "$enabled" \
    "$(postgres_data_directory "$project_root")" \
    "$(postgres_socket_directory "$project_root")" \
    "$POSTGRES_PG_CONFIG" \
    "$POSTGRES_SERVER" \
    "$(postgres_major_version)" \
    "$(postgres_encoding)" \
    "$(postgres_locale)"
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
