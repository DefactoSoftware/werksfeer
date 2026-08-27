#!/usr/bin/env bash

# Managed dependency/build cache. This file is sourced by the main werksfeer
# executable after its helper functions have been defined.

werksfeer_sha256() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    log_error "openssl, shasum, or sha256sum is required to identify the build cache"
    return 1
  fi
}

managed_cache_repository_key() {
  local main_path="$1"
  printf '%s' "$main_path" | werksfeer_sha256
}

managed_cache_root() {
  local main_path="$1"
  local repository_key
  repository_key="$(managed_cache_repository_key "$main_path")" || return 1
  printf '%s/werksfeer/build-caches/%s\n' \
    "${XDG_CACHE_HOME:-$HOME/.cache}" \
    "${repository_key:0:16}"
}

managed_cache_checkout() {
  printf '%s/checkout\n' "$(managed_cache_root "$1")"
}

managed_cache_manifest() {
  printf '%s/READY\n' "$(managed_cache_root "$1")"
}

managed_cache_manifest_value() {
  local manifest="$1"
  local key="$2"
  [ -f "$manifest" ] || return 0
  sed -n "s/^${key}=//p" "$manifest" | head -1
}

managed_cache_ref() {
  local main_path="$1"
  local configured remote_head
  configured="$(toml_get "cache" "ref" "")"
  [ -n "$configured" ] && {
    printf '%s\n' "$configured"
    return 0
  }

  remote_head="$(git -C "$main_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$remote_head" ]; then
    printf '%s\n' "$remote_head"
  elif git -C "$main_path" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'origin/main\n'
  elif git -C "$main_path" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'origin/master\n'
  else
    printf 'HEAD\n'
  fi
}

managed_cache_auto_warm_enabled() {
  local value
  value="${WERKSFEER_CACHE_AUTO_WARM:-$(toml_get "cache" "auto_warm" "false")}"
  case "$value" in
    true|1) return 0 ;;
    false|0|'') return 1 ;;
    *)
      log_error "cache.auto_warm must be true, false, 1, or 0: $value"
      return 2
      ;;
  esac
}

managed_cache_configuration_inputs() {
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$WERKSFEER_VERSION" \
    "$(toml_get "cache" "command" "")" \
    "$(toml_get "setup" "node_install" "")" \
    "$(toml_get "hooks" "post_dependencies" "")" \
    "$(toml_get_array "sync" "skip")" | werksfeer_sha256
}

managed_cache_load_target_configuration() {
  local checkout="$1"
  local main_path="$2"
  local project_config="${checkout}/.worktree.toml"
  local main_local_config="${main_path}/.worktree.local.toml"

  if [ ! -f "$project_config" ]; then
    log_error "No .worktree.toml found in managed cache checkout: $checkout"
    return 1
  fi

  toml_reset
  toml_parse "$project_config"
  if [ -f "$main_local_config" ]; then
    toml_parse "$main_local_config"
    log_debug "Loaded local configuration from $main_local_config"
  fi
}

managed_cache_validate_root() {
  local main_path="$1"
  local cache_root="$2"
  local owner_file="${cache_root}/OWNER"

  if [ -f "$owner_file" ]; then
    if [ "$(cat "$owner_file")" != "$main_path" ]; then
      log_error "Build cache belongs to a different repository: $cache_root"
      return 1
    fi
    return 0
  fi

  if [ -d "$cache_root" ] && [ -n "$(find "$cache_root" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    log_error "Refusing to use an unowned build cache directory: $cache_root"
    return 1
  fi

  mkdir -p "$cache_root"
  printf '%s\n' "$main_path" > "$owner_file"
}

managed_cache_fetch_ref() {
  local main_path="$1"
  local cache_ref="$2"
  local remote_name
  remote_name="${cache_ref%%/*}"

  if [ "$remote_name" != "$cache_ref" ] &&
      git -C "$main_path" remote get-url "$remote_name" >/dev/null 2>&1; then
    log_info "Fetching $remote_name before warming the build cache"
    if ! git -C "$main_path" fetch --quiet --prune "$remote_name"; then
      log_warn "Could not fetch $remote_name; using the newest locally available $cache_ref"
    fi
  fi
}

managed_cache_prepare_checkout() {
  local main_path="$1"
  local cache_ref="$2"
  local cache_root checkout target_commit
  cache_root="$(managed_cache_root "$main_path")" || return 1
  checkout="${cache_root}/checkout"

  managed_cache_validate_root "$main_path" "$cache_root"
  target_commit="$(git -C "$main_path" rev-parse "${cache_ref}^{commit}" 2>/dev/null)" || {
    log_error "Cannot resolve build cache ref: $cache_ref"
    return 1
  }

  if [ ! -d "${checkout}/.git" ]; then
    if [ -e "$checkout" ]; then
      log_error "Refusing to replace unexpected build cache checkout: $checkout"
      return 1
    fi
    log_info "Creating managed build cache checkout at $checkout"
    git clone --local --no-checkout --quiet "$main_path" "$checkout"
  fi

  if [ "$(git -C "$checkout" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
    log_error "Managed build cache checkout is not a Git repository: $checkout"
    return 1
  fi

  if ! git -C "$checkout" cat-file -e "${target_commit}^{commit}" 2>/dev/null; then
    git -C "$checkout" fetch --quiet "$main_path" "$target_commit"
  fi

  # This checkout is owned exclusively by werksfeer. Generated ignored caches
  # remain in place so package managers and compilers can update incrementally.
  git -C "$checkout" -c core.hooksPath=/dev/null checkout --quiet --detach --force "$target_commit"
  printf '%s\n' "$checkout"
}

managed_cache_release_lock() {
  if [ -n "${WERKSFEER_CACHE_LOCK_DIR:-}" ]; then
    rm -f "${WERKSFEER_CACHE_LOCK_DIR}/pid"
    rmdir "$WERKSFEER_CACHE_LOCK_DIR" 2>/dev/null || true
    WERKSFEER_CACHE_LOCK_DIR=""
  fi
}

managed_cache_acquire_lock() {
  local lock_dir="$1"
  local owner_pid=""

  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -f "${lock_dir}/pid" ]; then
      owner_pid="$(cat "${lock_dir}/pid")"
    fi

    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      log_info "Another process is already warming this repository's build cache"
      return 1
    fi

    log_warn "Removing stale managed build cache lock"
    rm -f "${lock_dir}/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    if ! mkdir "$lock_dir" 2>/dev/null; then
      log_info "Another process is already warming this repository's build cache"
      return 1
    fi
  fi

  printf '%s\n' "$$" > "${lock_dir}/pid"
}

managed_cache_node_inputs() {
  local checkout="$1"
  git -C "$checkout" ls-tree -r HEAD -- \
    package.json \
    package-lock.json \
    npm-shrinkwrap.json \
    pnpm-lock.yaml \
    pnpm-workspace.yaml \
    yarn.lock \
    bun.lock \
    bun.lockb \
    .npmrc \
    .yarnrc \
    .yarnrc.yml \
    .tool-versions \
    mise.toml \
    .mise.toml \
    .node-version \
    .nvmrc | werksfeer_sha256
}

managed_cache_warm_node_dependencies() {
  local checkout="$1"
  local previous_node_inputs="$2"
  local current_node_inputs="$3"

  [ -f "${checkout}/package.json" ] || return 0
  if [ -d "${checkout}/node_modules" ] &&
      [ -n "$previous_node_inputs" ] &&
      [ "$previous_node_inputs" = "$current_node_inputs" ]; then
    log_info "Node dependency inputs are unchanged, keeping cached node_modules"
    return 0
  fi

  install_node_dependencies
}

managed_cache_warm_elixir() {
  if [ -d "_build" ] && [ -d "deps" ] &&
      run_in_project_environment mix deps.loadpaths --no-compile >/dev/null 2>&1 &&
      run_in_project_environment env MIX_ENV=test mix deps.loadpaths --no-compile >/dev/null 2>&1; then
    log_info "Cached Elixir dependencies are ready, skipping mix deps.get"
  else
    log_step "Running mix deps.get"
    run_in_project_environment mix deps.get
    log_step "Running mix deps.get for test"
    run_in_project_environment env MIX_ENV=test mix deps.get
  fi

  log_step "Compiling Elixir dependencies"
  run_in_project_environment mix deps.compile
  log_step "Compiling Elixir dependencies for test"
  run_in_project_environment env MIX_ENV=test mix deps.compile
  log_step "Compiling the Elixir application"
  run_in_project_environment mix compile
  log_step "Compiling the Elixir application for test"
  run_in_project_environment env MIX_ENV=test mix compile
}

managed_cache_warm_project() {
  local checkout="$1"
  local project_type="$2"
  local previous_node_inputs="$3"
  local current_node_inputs="$4"
  local custom_command
  custom_command="$(toml_get "cache" "command" "")"

  if [ -n "$custom_command" ]; then
    log_step "Running custom build cache command: $custom_command"
    run_shell_in_project_environment "$custom_command"
    return 0
  fi

  case "$project_type" in
    rails)
      log_step "Running bundle install"
      run_in_project_environment bundle install
      managed_cache_warm_node_dependencies "$checkout" "$previous_node_inputs" "$current_node_inputs"
      ;;
    elixir)
      managed_cache_warm_elixir
      managed_cache_warm_node_dependencies "$checkout" "$previous_node_inputs" "$current_node_inputs"
      ;;
    python)
      run_dependency_setup "$project_type"
      ;;
    node)
      managed_cache_warm_node_dependencies "$checkout" "$previous_node_inputs" "$current_node_inputs"
      ;;
    *)
      log_info "Unknown project type, no default build cache command is available"
      ;;
  esac

  run_post_dependencies_hook
}

managed_cache_write_manifest() {
  local main_path="$1"
  local checkout="$2"
  local cache_ref="$3"
  local project_type="$4"
  local node_inputs="$5"
  local configuration_inputs="$6"
  local manifest temporary commit
  manifest="$(managed_cache_manifest "$main_path")"
  temporary="${manifest}.tmp.$$"
  commit="$(git -C "$checkout" rev-parse HEAD)"

  {
    printf 'format=1\n'
    printf 'repository=%s\n' "$main_path"
    printf 'ref=%s\n' "$cache_ref"
    printf 'commit=%s\n' "$commit"
    printf 'project_type=%s\n' "$project_type"
    printf 'node_inputs=%s\n' "$node_inputs"
    printf 'configuration_inputs=%s\n' "$configuration_inputs"
    printf 'warmed_at=%s\n' "$(date +%s)"
  } > "$temporary"
  mv "$temporary" "$manifest"
}

managed_cache_warm_locked() {
  local main_path="$1"
  local cache_ref="$2"
  local checkout manifest
  local target_commit ready_commit project_type previous_node_inputs current_node_inputs
  local configuration_inputs ready_configuration_inputs

  managed_cache_fetch_ref "$main_path" "$cache_ref"
  target_commit="$(git -C "$main_path" rev-parse "${cache_ref}^{commit}" 2>/dev/null)" || {
    log_error "Cannot resolve build cache ref: $cache_ref"
    return 1
  }
  manifest="$(managed_cache_manifest "$main_path")"
  ready_commit="$(managed_cache_manifest_value "$manifest" "commit")"
  checkout="$(managed_cache_checkout "$main_path")"

  previous_node_inputs="$(managed_cache_manifest_value "$manifest" "node_inputs")"
  checkout="$(managed_cache_prepare_checkout "$main_path" "$cache_ref")" || return 1
  managed_cache_load_target_configuration "$checkout" "$main_path" || return 1
  configuration_inputs="$(managed_cache_configuration_inputs)" || return 1
  ready_configuration_inputs="$(managed_cache_manifest_value "$manifest" "configuration_inputs")"

  if [ "$ready_commit" = "$target_commit" ] &&
      [ "$ready_configuration_inputs" = "$configuration_inputs" ] &&
      git_checkout_is_clean "$checkout"; then
    log_info "Managed build cache is already warm for $cache_ref at ${target_commit:0:12}"
    return 0
  fi

  project_type="$(detect_project_type "$checkout")"
  current_node_inputs="$(managed_cache_node_inputs "$checkout")" || return 1

  log_step "Warming $project_type build cache for $cache_ref at ${target_commit:0:12}"
  (
    cd "$checkout" || exit 1
    export WERKSFEER_POSTGRES=false
    managed_cache_warm_project \
      "$checkout" \
      "$project_type" \
      "$previous_node_inputs" \
      "$current_node_inputs"
  )

  if ! git_checkout_is_clean "$checkout"; then
    log_error "Build cache commands modified tracked files in $checkout"
    log_info "Use reproducible install/build commands or configure cache.command"
    return 1
  fi

  managed_cache_write_manifest \
    "$main_path" \
    "$checkout" \
    "$cache_ref" \
    "$project_type" \
    "$current_node_inputs" \
    "$configuration_inputs"
  log_step "Managed build cache is ready"
}

managed_cache_warm() (
  local project_root="$1"
  local main_path cache_ref cache_root lock_dir warm_status=0
  main_path="$(cd "$project_root" && get_main_worktree_path)"
  toml_reset
  load_project_configuration "$main_path"
  cache_ref="$(managed_cache_ref "$main_path")"
  cache_root="$(managed_cache_root "$main_path")" || return 1

  managed_cache_validate_root "$main_path" "$cache_root"
  lock_dir="${cache_root}/.warm.lock"
  if ! managed_cache_acquire_lock "$lock_dir"; then
    return 0
  fi

  # Keep cleanup limited to the exact lock directory created above, including
  # when a compiler is interrupted or automatic warming falls back to setup.
  WERKSFEER_CACHE_LOCK_DIR="$lock_dir"
  trap 'managed_cache_release_lock' EXIT
  trap 'managed_cache_release_lock; exit 129' HUP
  trap 'managed_cache_release_lock; exit 130' INT
  trap 'managed_cache_release_lock; exit 143' TERM

  managed_cache_warm_locked "$main_path" "$cache_ref" || warm_status=$?
  managed_cache_release_lock
  trap - EXIT HUP INT TERM
  return "$warm_status"
)

managed_cache_source() {
  local main_path="$1"
  local worktree_path="$2"
  local checkout manifest ready_commit checkout_commit
  checkout="$(managed_cache_checkout "$main_path")" || return 1
  manifest="$(managed_cache_manifest "$main_path")" || return 1

  [ -f "$manifest" ] && [ -d "${checkout}/.git" ] || return 1
  [ "$(managed_cache_manifest_value "$manifest" "repository")" = "$main_path" ] || return 1
  [ "$(managed_cache_manifest_value "$manifest" "configuration_inputs")" = \
    "$(managed_cache_configuration_inputs)" ] || return 1
  ready_commit="$(managed_cache_manifest_value "$manifest" "commit")"
  checkout_commit="$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$ready_commit" ] && [ "$ready_commit" = "$checkout_commit" ] || return 1
  reusable_build_cache "$checkout" "$worktree_path" || return 1
  printf '%s\n' "$checkout"
}

sync_managed_shared_dirs() {
  local cache_source="$1"
  local worktree_path="$2"
  local project_type="$3"
  local shared_dirs skip_dirs
  shared_dirs="$(toml_get_array "sync" "symlink")"
  [ -z "$shared_dirs" ] && shared_dirs="$(default_symlink_dirs "$project_type")"
  [ -z "$shared_dirs" ] && return 0

  if ! reusable_worktree_cache "$cache_source" "$worktree_path"; then
    log_info "Skip managed shared cache (target is not the exact clean cached revision)"
    return 0
  fi

  skip_dirs="$(toml_get_array "sync" "skip")"
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    if [ -n "$skip_dirs" ] && echo "$skip_dirs" | grep -qxF "$dir"; then
      log_info "Skip shared cache $dir (in skip list)"
      continue
    fi
    if [ -L "${worktree_path}/${dir}" ] || [ -d "${worktree_path}/${dir}" ]; then
      log_info "Skip shared cache $dir (already exists)"
      continue
    fi
    [ -d "${cache_source}/${dir}" ] || continue

    copy_tree "${cache_source}/${dir}" "${worktree_path}/${dir}"
    log_info "Copied $dir from managed cache"
    if [ "$dir" = "node_modules" ]; then
      export WERKSFEER_REUSED_NODE_DEPENDENCIES=1
    fi
  done <<EOF_SHARED_DIRS
$shared_dirs
EOF_SHARED_DIRS
}

managed_cache_status() (
  local project_root="$1"
  local main_path cache_ref cache_root checkout manifest ready_commit checkout_commit current_ref_commit
  local ready_configuration_inputs current_configuration_inputs
  main_path="$(cd "$project_root" && get_main_worktree_path)"
  toml_reset
  load_project_configuration "$main_path"
  cache_ref="$(managed_cache_ref "$main_path")"
  cache_root="$(managed_cache_root "$main_path")" || return 1
  checkout="${cache_root}/checkout"
  manifest="${cache_root}/READY"
  ready_commit="$(managed_cache_manifest_value "$manifest" "commit")"
  ready_configuration_inputs="$(managed_cache_manifest_value "$manifest" "configuration_inputs")"
  if [ -d "${checkout}/.git" ]; then
    managed_cache_load_target_configuration "$checkout" "$main_path" || return 1
  fi
  current_configuration_inputs="$(managed_cache_configuration_inputs)" || return 1
  checkout_commit="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
  current_ref_commit="$(git -C "$main_path" rev-parse "${cache_ref}^{commit}" 2>/dev/null || true)"

  printf 'cache_root=%s\n' "$cache_root"
  printf 'ref=%s\n' "$cache_ref"
  printf 'ref_commit=%s\n' "$current_ref_commit"
  printf 'cache_commit=%s\n' "$ready_commit"
  if [ -n "$ready_commit" ] &&
      [ "$ready_commit" = "$checkout_commit" ] &&
      [ "$ready_configuration_inputs" = "$current_configuration_inputs" ]; then
    printf 'ready=true\n'
  else
    printf 'ready=false\n'
  fi
  printf 'current=%s\n' "$([ -n "$ready_commit" ] && [ "$ready_commit" = "$current_ref_commit" ] && printf true || printf false)"
)
