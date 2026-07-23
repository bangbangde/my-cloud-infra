#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INFRASTRUCTURE_DIR="$ROOT_DIR/infrastructure"
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

compose_stack() {
  local directory=$1
  local env_file=$2
  shift 2

  docker compose \
    --project-directory "$directory" \
    --env-file "$env_file" \
    -f "$directory/compose.yaml" \
    "$@"
}

compose_model_block() {
  local model=$1
  local service=$2

  awk -v header="  ${service}:" '
    $0 == header { inside = 1 }
    inside && $0 != header && ($0 ~ /^[^ ]/ || $0 ~ /^  [^ ]/) { exit }
    inside { print }
  ' <<<"$model"
}

require_file() {
  [[ -f "$1" ]] || die "Missing ${1#"$ROOT_DIR"/}"
}

require_digest_image() {
  local service_block=$1
  local repository=$2
  local description=$3

  grep -Eq "^    image: ${repository}:[^[:space:]@]+@sha256:[0-9a-f]{64}$" \
    <<<"$service_block" \
    || die "$description image must use a tag and digest"
}

require_loopback_port() {
  local service_block=$1
  local port=$2
  local description=$3

  if [[ "$(grep -Fc '      host_ip: 127.0.0.1' <<<"$service_block" || true)" -ne 1 ]] \
    || [[ "$(grep -Fc "      target: $port" <<<"$service_block" || true)" -ne 1 ]] \
    || [[ "$(grep -Fc "      published: \"$port\"" <<<"$service_block" || true)" -ne 1 ]] \
    || [[ "$(grep -Fc '      published:' <<<"$service_block" || true)" -ne 1 ]]; then
    die "$description must publish only port $port on the host loopback address"
  fi
}

validate_runtime_env_templates() {
  local directory=$1
  local runtime_file

  while IFS= read -r runtime_file; do
    [[ -f "$directory/$runtime_file.example" ]] \
      || die "Missing ${directory#"$ROOT_DIR"/}/$runtime_file.example"
  done < <(
    sed -nE \
      's|^[[:space:]]*-[[:space:]]*path:[[:space:]]+\./(\.env\.[^[:space:]#]+)[[:space:]]*$|\1|p' \
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

  for example in "$source_directory"/.env.*.example; do
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
    | grep -E '(^|/)(\.env($|\.)|acme\.json$|config/env\.json$)' \
    | grep -Ev '\.example$' \
    || true
)"
[[ -z "$tracked_sensitive_files" ]] \
  || die "Sensitive runtime files must not be tracked by Git: $tracked_sensitive_files"

printf '==> Validate shell syntax\n'
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done

printf '==> Validate Traefik Compose model\n'
for file in compose.yaml .env.example .env.runtime.example static.yaml dynamic/tls.yaml; do
  require_file "$TRAEFIK_DIR/$file"
done
validate_runtime_env_templates "$TRAEFIK_DIR"
prepare_validation_stack "$TRAEFIK_DIR"
traefik_validation_dir=$VALIDATION_DIR

traefik_model="$(compose_stack "$traefik_validation_dir" "$traefik_validation_dir/.env.example" config)"
traefik_services="$(
  compose_stack "$traefik_validation_dir" "$traefik_validation_dir/.env.example" config --services
)"
grep -Fx traefik <<<"$traefik_services" >/dev/null || die "Traefik service is required"
grep -Fx socket-proxy <<<"$traefik_services" >/dev/null || die "socket-proxy service is required"

traefik_service_block="$(compose_model_block "$traefik_model" traefik)"
socket_proxy_service_block="$(compose_model_block "$traefik_model" socket-proxy)"
docker_api_network_block="$(compose_model_block "$traefik_model" docker-api)"

grep -Eq '^    image: traefik:v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$traefik_service_block" \
  || die "Traefik image must use an exact patch version"
require_digest_image \
  "$socket_proxy_service_block" \
  'ghcr\.io/tecnativa/docker-socket-proxy' \
  "Socket proxy"
[[ "$(grep -Fc '        target: /var/run/docker.sock' <<<"$socket_proxy_service_block" || true)" -eq 1 ]] \
  || die "Docker socket must be mounted exactly once on socket-proxy"
if grep -F '/var/run/docker.sock' <<<"$traefik_service_block" >/dev/null; then
  die "Traefik must not mount the Docker socket directly"
fi
grep -F '      POST: "0"' <<<"$socket_proxy_service_block" >/dev/null \
  || die "Socket proxy must reject Docker API write requests"
grep -Fx '    internal: true' <<<"$docker_api_network_block" >/dev/null \
  || die "Docker API network must be internal"
grep -Eq '^      docker-api:' <<<"$traefik_service_block" \
  || die "Traefik must attach to docker-api"
grep -Eq '^      docker-api:' <<<"$socket_proxy_service_block" \
  || die "Socket proxy must attach to docker-api"

printf '==> Validate shared infrastructure Compose models\n'
infrastructure_count=0
for directory in "$INFRASTRUCTURE_DIR"/*; do
  [[ -d "$directory" ]] || continue
  infrastructure_service="$(basename -- "$directory")"
  [[ "$infrastructure_service" != "traefik" ]] || continue
  [[ "$infrastructure_service" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "Invalid infrastructure directory name: $infrastructure_service"
  [[ ! -d "$APPS_DIR/$infrastructure_service" ]] \
    || die "Target name is ambiguous across infrastructure/ and apps/: $infrastructure_service"

  require_file "$directory/compose.yaml"
  require_file "$directory/.env.example"
  validate_runtime_env_templates "$directory"
  prepare_validation_stack "$directory"
  infrastructure_validation_dir=$VALIDATION_DIR

  infrastructure_model="$(
    compose_stack \
      "$infrastructure_validation_dir" \
      "$infrastructure_validation_dir/.env.example" \
      config
  )"
  infrastructure_services="$(
    compose_stack \
      "$infrastructure_validation_dir" \
      "$infrastructure_validation_dir/.env.example" \
      config \
      --services
  )"

  grep -Fx "$infrastructure_service" <<<"$infrastructure_services" >/dev/null \
    || die "Primary service in infrastructure/$infrastructure_service/compose.yaml must be named $infrastructure_service"

  infrastructure_service_block="$(
    compose_model_block "$infrastructure_model" "$infrastructure_service"
  )"

  if [[ "$infrastructure_service" == "postgres" ]]; then
    postgres_network_block="$(compose_model_block "$infrastructure_model" postgres-net)"

    require_digest_image "$infrastructure_service_block" postgres "PostgreSQL"
    [[ "$(grep -Fc '        target: /var/lib/postgresql' <<<"$infrastructure_service_block" || true)" -eq 1 ]] \
      || die "PostgreSQL 18 data volume must be mounted at /var/lib/postgresql"
    grep -Fx '    name: postgres-net' <<<"$postgres_network_block" >/dev/null \
      || die "PostgreSQL network must use the stable postgres-net name"
    if grep -Fx '    internal: true' <<<"$postgres_network_block" >/dev/null; then
      die "PostgreSQL network must allow the host loopback port mapping"
    fi
    require_loopback_port "$infrastructure_service_block" 5432 "PostgreSQL"
    if grep -Eq '^      traefik-net:' <<<"$infrastructure_service_block"; then
      die "PostgreSQL must not attach to traefik-net"
    fi
  elif [[ "$infrastructure_service" == "garage" ]]; then
    require_file "$directory/garage.toml"
    garage_network_block="$(compose_model_block "$infrastructure_model" garage-net)"

    require_digest_image "$infrastructure_service_block" dxflrs/garage "Garage"
    [[ "$(grep -Fc '        target: /var/lib/garage/meta' <<<"$infrastructure_service_block" || true)" -eq 1 ]] \
      || die "Garage metadata volume must be mounted at /var/lib/garage/meta"
    [[ "$(grep -Fc '        target: /var/lib/garage/data' <<<"$infrastructure_service_block" || true)" -eq 1 ]] \
      || die "Garage data volume must be mounted at /var/lib/garage/data"
    grep -Fx '    internal: true' <<<"$garage_network_block" >/dev/null \
      || die "Garage application network must be internal"
    grep -Eq '^      garage-net:' <<<"$infrastructure_service_block" \
      || die "Garage must attach to garage-net"
    grep -Eq '^      traefik-net:' <<<"$infrastructure_service_block" \
      || die "Garage must attach to traefik-net for its read-only website"
    require_loopback_port "$infrastructure_service_block" 3900 "Garage"

    garage_traefik_port_labels="$(
      grep -F '.loadbalancer.server.port' <<<"$infrastructure_service_block" \
        | grep -F 'traefik.http.services.' \
        || true
    )"
    [[ -n "$garage_traefik_port_labels" ]] \
      || die "Garage must declare a Traefik service for the read-only website"
    if grep -Fv '3902' <<<"$garage_traefik_port_labels" >/dev/null; then
      die "Garage Traefik service ports must target only the read-only web endpoint 3902"
    fi
    if grep -F 'traefik.' <<<"$infrastructure_service_block" | grep -F '3900' >/dev/null; then
      die "Garage Traefik labels must not reference the S3 API port 3900"
    fi
    grep -Fx 'rpc_bind_addr = "127.0.0.1:3901"' "$directory/garage.toml" >/dev/null \
      || die "Garage RPC must bind only to container loopback in single-node mode"
  fi

  infrastructure_count=$((infrastructure_count + 1))
done

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

  app_model="$(
    compose_stack \
      "$app_validation_dir" \
      "$app_validation_dir/.env.example" \
      --profile '*' \
      config
  )"
  app_services="$(
    compose_stack "$app_validation_dir" "$app_validation_dir/.env.example" config --services
  )"
  app_variables="$(
    compose_stack "$app_validation_dir" "$app_validation_dir/.env.example" config --variables
  )"

  grep -Fx "$app" <<<"$app_services" >/dev/null \
    || die "Primary service in apps/$app/compose.yaml must be named $app"
  app_service_block="$(compose_model_block "$app_model" "$app")"

  for variable in IMAGE_REPOSITORY APP_DOMAIN IMAGE_TAG; do
    awk -v variable="$variable" \
      '$1 == variable && $2 == "true" { found = 1 } END { exit !found }' \
      <<<"$app_variables" \
      || die "apps/$app/compose.yaml must require $variable"
  done

  if grep -Eq '^    (container_name|ports):' <<<"$app_model"; then
    die "apps/$app/compose.yaml must not set container_name or publish host ports"
  fi
  grep -Eq '^      traefik-net:' <<<"$app_service_block" \
    || die "apps/$app/compose.yaml must attach a service to traefik-net"

  app_count=$((app_count + 1))
done

printf 'Validation passed for Traefik, %s shared infrastructure service(s) and %s application(s).\n' \
  "$infrastructure_count" "$app_count"
