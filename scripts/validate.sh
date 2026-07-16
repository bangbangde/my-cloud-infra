#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_DIR="$ROOT_DIR/infrastructure/traefik"
APPS_DIR="$ROOT_DIR/apps"
VALIDATION_DIRS=()
VALIDATION_DIR=""

cleanup() {
  local directory
  local temp_root=${TMPDIR:-/tmp}

  for directory in "${VALIDATION_DIRS[@]}"; do
    case "$directory" in
      "$temp_root"/my-cloud-validate.*) rm -rf -- "$directory" ;;
      *) printf 'WARNING: Refusing to remove unexpected path: %s\n' "$directory" >&2 ;;
    esac
  done
}

trap cleanup EXIT

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

compose_config() {
  local directory=$1
  local env_file=$2
  shift 2

  docker compose \
    --project-directory "$directory" \
    --env-file "$env_file" \
    -f "$directory/compose.yaml" \
    config "$@"
}

require_file() {
  [[ -f "$1" ]] || die "Missing ${1#"$ROOT_DIR"/}"
}

validate_runtime_env_templates() {
  local directory=$1
  local runtime_file

  while IFS= read -r runtime_file; do
    [[ -f "$directory/$runtime_file.example" ]] \
      || die "Missing ${directory#"$ROOT_DIR"/}/$runtime_file.example"
  done < <(
    sed -nE \
      's|^[[:space:]]*-[[:space:]]*path:[[:space:]]+\./([^[:space:]#]*runtime\.env)[[:space:]]*$|\1|p' \
      "$directory/compose.yaml"
  )
}

prepare_validation_stack() {
  local source_directory=$1
  local example
  local name

  VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/my-cloud-validate.XXXXXX")"
  VALIDATION_DIRS+=("$VALIDATION_DIR")
  cp -- "$source_directory/compose.yaml" "$source_directory/.env.example" "$VALIDATION_DIR/"

  for example in "$source_directory"/runtime.env.example "$source_directory"/*.runtime.env.example; do
    [[ -f "$example" ]] || continue
    name="$(basename -- "$example")"
    cp -- "$example" "$VALIDATION_DIR/$name"
    cp -- "$example" "$VALIDATION_DIR/${name%.example}"
  done
}

command -v docker >/dev/null 2>&1 || die "Docker is required."
command -v git >/dev/null 2>&1 || die "Git is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose is required."

tracked_sensitive_files="$(
  git -C "$ROOT_DIR" ls-files \
    | grep -E '(^|/)(\.env|runtime\.env|[^/]+\.runtime\.env|acme\.json)$' \
    || true
)"
[[ -z "$tracked_sensitive_files" ]] \
  || die "Sensitive runtime files must not be tracked by Git: $tracked_sensitive_files"

printf '==> Validate shell syntax\n'
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done

printf '==> Validate Traefik Compose model\n'
for file in compose.yaml .env.example runtime.env.example static.yaml dynamic/tls.yaml; do
  require_file "$TRAEFIK_DIR/$file"
done
validate_runtime_env_templates "$TRAEFIK_DIR"
prepare_validation_stack "$TRAEFIK_DIR"
traefik_validation_dir=$VALIDATION_DIR

traefik_model="$(compose_config "$traefik_validation_dir" "$traefik_validation_dir/.env.example")"
traefik_services="$(compose_config "$traefik_validation_dir" "$traefik_validation_dir/.env.example" --services)"
grep -Fx traefik <<<"$traefik_services" >/dev/null || die "Traefik service is required"
grep -Fx socket-proxy <<<"$traefik_services" >/dev/null || die "socket-proxy service is required"
grep -Eq '^    image: traefik:v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$traefik_model" \
  || die "Traefik image must use an exact patch version"
grep -Eq '^    image: ghcr\.io/tecnativa/docker-socket-proxy:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$traefik_model" \
  || die "Socket proxy image must use a version and digest"
[[ "$(grep -Fc '        target: /var/run/docker.sock' <<<"$traefik_model" || true)" -eq 1 ]] \
  || die "Docker socket must be mounted exactly once"
grep -F '      POST: "0"' <<<"$traefik_model" >/dev/null \
  || die "Socket proxy must reject Docker API write requests"
grep -A3 -Fx '  docker-api:' <<<"$traefik_model" | grep -Fx '    internal: true' >/dev/null \
  || die "Docker API network must be internal"

printf '==> Validate application Compose models\n'
app_count=0
for directory in "$APPS_DIR"/*; do
  [[ -d "$directory" ]] || continue
  app="$(basename -- "$directory")"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid application directory name: $app"
  require_file "$directory/compose.yaml"
  require_file "$directory/.env.example"
  validate_runtime_env_templates "$directory"
  prepare_validation_stack "$directory"
  app_validation_dir=$VALIDATION_DIR

  app_model="$(compose_config "$app_validation_dir" "$app_validation_dir/.env.example")"
  app_services="$(compose_config "$app_validation_dir" "$app_validation_dir/.env.example" --services)"
  app_variables="$(compose_config "$app_validation_dir" "$app_validation_dir/.env.example" --variables)"

  grep -Fx "$app" <<<"$app_services" >/dev/null \
    || die "Primary service in apps/$app/compose.yaml must be named $app"
  grep -Fx "name: $app" <<<"$app_model" >/dev/null \
    || die "Compose project name must resolve to $app"

  for variable in IMAGE_REPOSITORY APP_DOMAIN IMAGE_TAG; do
    awk -v variable="$variable" \
      '$1 == variable && $2 == "true" { found = 1 } END { exit !found }' \
      <<<"$app_variables" \
      || die "apps/$app/compose.yaml must require $variable"
  done

  if grep -Eq '^    (container_name|ports):' <<<"$app_model"; then
    die "apps/$app/compose.yaml must not set container_name or publish host ports"
  fi
  grep -Eq '^      traefik-net:' <<<"$app_model" \
    || die "apps/$app/compose.yaml must attach a service to traefik-net"

  app_count=$((app_count + 1))
done

[[ "$app_count" -gt 0 ]] || die "No applications found under apps/."

printf 'Validation passed for Traefik and %s application(s).\n' "$app_count"
