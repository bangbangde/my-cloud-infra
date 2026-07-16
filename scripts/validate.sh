#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_DIR="$ROOT_DIR/infrastructure/traefik"
APPS_DIR="$ROOT_DIR/apps"
GENERATED_RUNTIME_ENVS=()

cleanup() {
  local file

  for file in "${GENERATED_RUNTIME_ENVS[@]}"; do
    rm -f -- "$file" || true
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

prepare_runtime_envs() {
  local directory=$1
  local example
  local actual

  for example in "$directory"/runtime.env.example "$directory"/*.runtime.env.example; do
    [[ -f "$example" ]] || continue
    actual="${example%.example}"
    if [[ ! -e "$actual" ]]; then
      cp -- "$example" "$actual"
      GENERATED_RUNTIME_ENVS+=("$actual")
    fi
  done
}

command -v docker >/dev/null 2>&1 || die "Docker is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose is required."

if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_sensitive_files="$(
    git -C "$ROOT_DIR" ls-files \
      | grep -E '(^|/)(\.env|runtime\.env|[^/]+\.runtime\.env|acme\.json)$' \
      || true
  )"
  [[ -z "$tracked_sensitive_files" ]] \
    || die "Sensitive runtime files must not be tracked by Git: $tracked_sensitive_files"
fi

printf '==> Validate shell syntax\n'
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done

printf '==> Validate Traefik Compose model\n'
[[ -f "$TRAEFIK_DIR/compose.yaml" ]] || die "Missing infrastructure/traefik/compose.yaml"
[[ -f "$TRAEFIK_DIR/.env.example" ]] || die "Missing infrastructure/traefik/.env.example"
[[ -f "$TRAEFIK_DIR/runtime.env.example" ]] || die "Missing infrastructure/traefik/runtime.env.example"
prepare_runtime_envs "$TRAEFIK_DIR"
compose_config "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env.example" --quiet
compose_config "$TRAEFIK_DIR" "$TRAEFIK_DIR/.env.example" --services | grep -Fx -- socket-proxy >/dev/null \
  || die "Traefik stack must include socket-proxy"

grep -Eq '^[[:space:]]+image: traefik:v[0-9]+\.[0-9]+\.[0-9]+$' "$TRAEFIK_DIR/compose.yaml" \
  || die "Traefik image must use an exact patch version"
grep -Eq 'image: ghcr\.io/tecnativa/docker-socket-proxy:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' "$TRAEFIK_DIR/compose.yaml" \
  || die "Socket proxy image must use a version and digest"
[[ "$(grep -Fc '/var/run/docker.sock:/var/run/docker.sock' "$TRAEFIK_DIR/compose.yaml" || true)" -eq 1 ]] \
  || die "Docker socket must be mounted exactly once, by socket-proxy"
[[ "$(grep -Fc 'no-new-privileges:true' "$TRAEFIK_DIR/compose.yaml" || true)" -eq 2 ]] \
  || die "Traefik and socket-proxy must enable no-new-privileges"
[[ "$(grep -Ec '^[[:space:]]+driver:[[:space:]]+local$' "$TRAEFIK_DIR/compose.yaml" || true)" -eq 2 ]] \
  || die "Traefik and socket-proxy must use Docker local log rotation"
grep -F 'POST: "0"' "$TRAEFIK_DIR/compose.yaml" >/dev/null \
  || die "Socket proxy must reject Docker API write requests"
grep -A1 '^  docker-api:$' "$TRAEFIK_DIR/compose.yaml" | grep -F 'internal: true' >/dev/null \
  || die "Docker API network must be internal"
grep -F 'endpoint: "tcp://socket-proxy:2375"' "$TRAEFIK_DIR/static.yaml" >/dev/null \
  || die "Traefik Docker provider must use socket-proxy"
grep -F 'level: INFO' "$TRAEFIK_DIR/static.yaml" >/dev/null \
  || die "Traefik production log level must be INFO"
[[ -f "$TRAEFIK_DIR/dynamic/tls.yaml" ]] || die "Missing Traefik default TLS policy"
grep -F 'minVersion: VersionTLS12' "$TRAEFIK_DIR/dynamic/tls.yaml" >/dev/null \
  || die "Traefik must require TLS 1.2 or newer"
grep -F 'sniStrict: true' "$TRAEFIK_DIR/dynamic/tls.yaml" >/dev/null \
  || die "Traefik must reject unknown SNI names"

printf '==> Validate application Compose models\n'
app_count=0
for directory in "$APPS_DIR"/*; do
  [[ -d "$directory" ]] || continue
  app="$(basename -- "$directory")"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid application directory name: $app"
  [[ -f "$directory/compose.yaml" ]] || die "Missing apps/$app/compose.yaml"
  [[ -f "$directory/.env.example" ]] || die "Missing apps/$app/.env.example"

  [[ "$(grep -Ec '^IMAGE_REPOSITORY=' "$directory/.env.example" || true)" -eq 1 ]] \
    || die "apps/$app/.env.example must contain exactly one IMAGE_REPOSITORY entry"
  [[ "$(grep -Ec '^APP_DOMAIN=' "$directory/.env.example" || true)" -eq 1 ]] \
    || die "apps/$app/.env.example must contain exactly one APP_DOMAIN entry"
  [[ "$(grep -Ec '^IMAGE_TAG=' "$directory/.env.example" || true)" -eq 1 ]] \
    || die "apps/$app/.env.example must contain exactly one IMAGE_TAG entry"
  grep -Fx "IMAGE_REPOSITORY=ghcr.io/example/$app" "$directory/.env.example" >/dev/null \
    || die "apps/$app/.env.example must use the public placeholder ghcr.io/example/$app"
  grep -Fx "APP_DOMAIN=$app.example.com" "$directory/.env.example" >/dev/null \
    || die "apps/$app/.env.example must use the reserved example domain $app.example.com"
  grep -F "\${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}" "$directory/compose.yaml" >/dev/null \
    || die "apps/$app/compose.yaml must interpolate IMAGE_REPOSITORY"
  grep -F "\${APP_DOMAIN:?APP_DOMAIN is required}" "$directory/compose.yaml" >/dev/null \
    || die "apps/$app/compose.yaml must interpolate APP_DOMAIN"

  prepare_runtime_envs "$directory"
  compose_config "$directory" "$directory/.env.example" --quiet
  compose_config "$directory" "$directory/.env.example" --services | grep -Fx -- "$app" >/dev/null \
    || die "Primary service in apps/$app/compose.yaml must be named $app"

  if grep -Eq '^[[:space:]]*container_name:' "$directory/compose.yaml"; then
    die "container_name is not allowed in apps/$app/compose.yaml"
  fi

  grep -F 'no-new-privileges:true' "$directory/compose.yaml" >/dev/null \
    || die "apps/$app/compose.yaml must enable no-new-privileges"
  grep -Eq '^[[:space:]]+driver:[[:space:]]+local$' "$directory/compose.yaml" \
    || die "apps/$app/compose.yaml must use Docker local log rotation"

  compose_config "$directory" "$directory/.env.example" | grep -F 'name: traefik-net' >/dev/null \
    || die "apps/$app/compose.yaml must reference traefik-net"

  app_count=$((app_count + 1))
done

[[ "$app_count" -gt 0 ]] || die "No applications found under apps/."

if grep -REn --include='*.yaml' --include='*.yml' '(_FULL_IMAGE|[A-Z0-9_]+_VERSION)' "$APPS_DIR"; then
  die "Legacy application-specific image variables are not allowed."
fi

printf 'Validation passed for Traefik and %s application(s).\n' "$app_count"
