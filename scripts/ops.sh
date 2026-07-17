#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_DIR="$ROOT_DIR/infrastructure/traefik"
APPS_DIR="$ROOT_DIR/apps"
LOCK_FILE="$ROOT_DIR/.ops.lock"

TEMP_ENV=""
REGISTRY_LOGGED_IN=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/ops.sh init-env <config-json>
  bash scripts/ops.sh deploy traefik
  bash scripts/ops.sh deploy <app> <image-tag>
  bash scripts/ops.sh status [target]
  bash scripts/ops.sh logs <target>
  bash scripts/ops.sh restart <target>
  bash scripts/ops.sh validate

Targets are "traefik" or a directory name under apps/.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?

  if [[ -n "$TEMP_ENV" && -f "$TEMP_ENV" ]]; then
    rm -f -- "$TEMP_ENV"
  fi

  if [[ "$REGISTRY_LOGGED_IN" == true ]]; then
    docker logout ghcr.io >/dev/null 2>&1 || true
  fi

  trap - EXIT
  exit "$status"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_docker_compose() {
  require_command docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable."
}

acquire_lock() {
  if [[ "${OPS_LOCK_HELD:-}" == "1" ]]; then
    return
  fi

  require_command flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another infrastructure operation is already running."
}

validate_target_name() {
  local target=$1
  [[ "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid target name: $target"
}

validate_image_tag() {
  local image_tag=$1
  [[ "$image_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "Invalid image tag: $image_tag"
}

app_dir() {
  local app=$1
  validate_target_name "$app"

  local directory="$APPS_DIR/$app"
  [[ -f "$directory/compose.yaml" ]] || die "Application not found: apps/$app/compose.yaml"
  printf '%s\n' "$directory"
}

compose_with_env() {
  local directory=$1
  local env_file=$2
  shift 2

  docker compose \
    --project-directory "$directory" \
    --env-file "$env_file" \
    -f "$directory/compose.yaml" \
    "$@"
}

require_stack_env() {
  local directory=$1
  [[ -f "$directory/.env" ]] || die "Missing $directory/.env; create and configure it from .env.example."
}

require_runtime_envs() {
  local directory=$1
  local example
  local actual

  for example in "$directory"/runtime.env.example "$directory"/*.runtime.env.example; do
    [[ -f "$example" ]] || continue
    actual="${example%.example}"
    [[ -f "$actual" ]] || die "Missing $actual; create it from $(basename -- "$example")."
  done
}

registry_login() {
  if [[ -z "${GHCR_TOKEN:-}" ]]; then
    return
  fi

  [[ -n "${GHCR_USERNAME:-}" ]] || die "GHCR_USERNAME is required when GHCR_TOKEN is set."
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
  REGISTRY_LOGGED_IN=true
}

report_health_contract() {
  local directory=$1
  local env_file=$2
  local service=$3
  local container_id
  local health

  container_id="$(compose_with_env "$directory" "$env_file" ps -q "$service" 2>/dev/null || true)"
  [[ -n "$container_id" ]] || return

  health="$(docker inspect "$container_id" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)"
  if [[ "$health" == "none" ]]; then
    printf 'WARNING: %s is running without a Docker HEALTHCHECK.\n' "$service"
  else
    printf 'Health status: %s\n' "$health"
  fi
}

deploy_traefik() {
  [[ -f "$TRAEFIK_DIR/compose.yaml" ]] || die "Traefik compose file not found."
  require_stack_env "$TRAEFIK_DIR"
  require_runtime_envs "$TRAEFIK_DIR"

  acquire_lock

  printf '==> Validate Traefik configuration\n'
  compose_with_env "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env" config --quiet

  printf '==> Pull Traefik stack images\n'
  compose_with_env "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env" pull socket-proxy traefik

  printf '==> Start Traefik\n'
  compose_with_env "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env" up -d --wait --wait-timeout 120 traefik
  report_health_contract "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env" traefik
  printf 'Traefik deployment finished.\n'
}

deploy_app() {
  local app=$1
  local image_tag=$2
  local directory
  local current_env
  local previous_tag=""

  validate_image_tag "$image_tag"
  directory="$(app_dir "$app")"
  require_stack_env "$directory"
  require_runtime_envs "$directory"
  current_env="$directory/.env"

  acquire_lock
  registry_login

  [[ "$(grep -Ec '^IMAGE_TAG=' "$current_env" || true)" -eq 1 ]] \
    || die "$current_env must contain exactly one IMAGE_TAG entry."
  previous_tag="$(sed -n 's/^IMAGE_TAG=//p' "$current_env")"

  umask 077
  TEMP_ENV="$(mktemp "$directory/.env.next.XXXXXX")"
  cp -- "$current_env" "$TEMP_ENV"
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$image_tag/" "$TEMP_ENV"

  printf '==> Deploying %s\n' "$app"
  printf 'Previous tag: %s\n' "${previous_tag:-not recorded}"
  printf 'Target tag:   %s\n' "$image_tag"

  compose_with_env "$directory" "$TEMP_ENV" config --quiet
  compose_with_env "$directory" "$TEMP_ENV" config --services | grep -Fx -- "$app" >/dev/null \
    || die "Primary Compose service must be named $app."

  printf '==> Pull application image\n'
  compose_with_env "$directory" "$TEMP_ENV" pull "$app"

  printf '==> Start application\n'
  if compose_with_env "$directory" "$TEMP_ENV" up -d --wait --wait-timeout 120 "$app"; then
    report_health_contract "$directory" "$TEMP_ENV" "$app"
    mv -f -- "$TEMP_ENV" "$current_env"
    TEMP_ENV=""
    printf 'Application deployment finished: %s:%s\n' "$app" "$image_tag"
    return
  fi

  printf 'Deployment failed; showing recent logs.\n' >&2
  compose_with_env "$directory" "$TEMP_ENV" logs --tail 100 "$app" >&2 || true

  printf '==> Attempt to restore the previously recorded tag: %s\n' "${previous_tag:-unknown}" >&2
  if compose_with_env "$directory" "$current_env" config --quiet \
    && compose_with_env "$directory" "$current_env" up -d --wait --wait-timeout 120 "$app"; then
    printf 'Previous application version restored.\n' >&2
  else
    printf 'Failed to restore the previous application version.\n' >&2
  fi

  return 1
}

target_details() {
  local target=$1
  local directory
  local env_file

  validate_target_name "$target"
  if [[ "$target" == "traefik" ]]; then
    directory="$TRAEFIK_DIR"
  else
    directory="$(app_dir "$target")"
  fi

  env_file="$directory/.env"
  require_stack_env "$directory"
  printf '%s\n%s\n' "$directory" "$env_file"
}

status_target() {
  local target=$1
  local details
  local directory
  local env_file

  details="$(target_details "$target")"
  directory="$(printf '%s\n' "$details" | sed -n '1p')"
  env_file="$(printf '%s\n' "$details" | sed -n '2p')"
  compose_with_env "$directory" "$env_file" ps
}

logs_target() {
  local target=$1
  local details
  local directory
  local env_file

  details="$(target_details "$target")"
  directory="$(printf '%s\n' "$details" | sed -n '1p')"
  env_file="$(printf '%s\n' "$details" | sed -n '2p')"
  compose_with_env "$directory" "$env_file" logs --tail 200 -f "$target"
}

restart_target() {
  local target=$1
  local details
  local directory
  local env_file

  details="$(target_details "$target")"
  directory="$(printf '%s\n' "$details" | sed -n '1p')"
  env_file="$(printf '%s\n' "$details" | sed -n '2p')"

  acquire_lock
  compose_with_env "$directory" "$env_file" restart "$target"
  compose_with_env "$directory" "$env_file" ps "$target"
}

main() {
  local command=${1:-help}
  case "$command" in
    init-env)
      [[ $# -eq 2 ]] || die "init-env requires exactly one JSON configuration file."
      bash "$ROOT_DIR/scripts/init-env.sh" "$2"
      ;;
    deploy)
      require_docker_compose
      local target=${2:-}
      [[ -n "$target" ]] || die "A deployment target is required."
      if [[ "$target" == "traefik" ]]; then
        [[ $# -eq 2 ]] || die "Traefik deployment does not accept an image tag."
        deploy_traefik
      else
        [[ $# -eq 3 ]] || die "Application deployment requires an image tag."
        deploy_app "$target" "$3"
      fi
      ;;
    status)
      require_docker_compose
      if [[ $# -eq 1 ]]; then
        docker compose ls
      else
        [[ $# -eq 2 ]] || die "status accepts at most one target."
        status_target "$2"
      fi
      ;;
    logs)
      require_docker_compose
      [[ $# -eq 2 ]] || die "logs requires exactly one target."
      logs_target "$2"
      ;;
    restart)
      require_docker_compose
      [[ $# -eq 2 ]] || die "restart requires exactly one target."
      restart_target "$2"
      ;;
    validate)
      [[ $# -eq 1 ]] || die "validate does not accept additional arguments."
      bash "$ROOT_DIR/scripts/validate.sh"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
