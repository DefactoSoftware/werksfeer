#!/usr/bin/env bash

# Service-provider orchestration. Providers expose functions named
# werksfeer_service_<name>_<action> and run in the main werksfeer process so
# they can share its parsed project configuration and logging.

service_names() {
  toml_get_array "services" "enabled"
}

service_enabled() {
  local expected="$1"
  local service

  while IFS= read -r service; do
    [ "$service" = "$expected" ] && return 0
  done <<EOF_SERVICES
$(service_names)
EOF_SERVICES

  return 1
}

validate_service_name() {
  case "$1" in
    ""|*[!a-z0-9_-]*)
      log_error "Invalid service name in .worktree.toml: $1"
      return 1
      ;;
  esac
}

run_service_action() {
  local service="$1"
  local action="$2"
  local project_root="$3"
  shift 3
  local normalized handler

  validate_service_name "$service"
  normalized="$(echo "$service" | tr '-' '_')"
  handler="werksfeer_service_${normalized}_${action}"

  if ! type "$handler" >/dev/null 2>&1; then
    log_error "Service '$service' does not support '$action'"
    return 1
  fi

  "$handler" "$project_root" "$@"
}

run_services_action() {
  local action="$1"
  local project_root="$2"
  local services service
  services="$(service_names)"

  [ -z "$services" ] && return 0

  while IFS= read -r service; do
    [ -z "$service" ] && continue
    run_service_action "$service" "$action" "$project_root"
  done <<EOF_SERVICES
$services
EOF_SERVICES
}

services_environment() {
  local project_root="$1"
  run_services_action "env" "$project_root"
}

service_usage() {
  cat >&2 <<'EOF_USAGE'
Usage:
  werksfeer services prepare  Initialize and start configured services
  werksfeer services start    Start configured services
  werksfeer services stop     Stop configured services without deleting data
  werksfeer services status   Show configured service state
  werksfeer services doctor   Validate service prerequisites
  werksfeer services env      Print service connection environment as KEY=VALUE

Provider shortcut:
  werksfeer postgres COMMAND  Run one PostgreSQL provider command

PostgreSQL additionally supports: socket-dir, database-exists NAME
EOF_USAGE
}

services_cli() {
  local action="${1:-}"
  local project_root="$2"

  case "$action" in
    prepare|start|stop|status|doctor|env)
      run_services_action "$action" "$project_root"
      ;;
    help|-h|--help|"")
      service_usage
      ;;
    *)
      log_error "Unknown services command: $action"
      service_usage
      return 1
      ;;
  esac
}

service_provider_cli() {
  local service="$1"
  local action="$2"
  local project_root="$3"
  shift 3

  if ! service_enabled "$service"; then
    log_error "Service '$service' is not enabled in .worktree.toml"
    return 1
  fi

  case "$action" in
    prepare|start|stop|status|doctor|env|socket-dir|database-exists)
      run_service_action "$service" "$(echo "$action" | tr '-' '_')" "$project_root" "$@"
      ;;
    help|-h|--help|"")
      service_usage
      ;;
    *)
      log_error "Unknown $service command: $action"
      service_usage
      return 1
      ;;
  esac
}
