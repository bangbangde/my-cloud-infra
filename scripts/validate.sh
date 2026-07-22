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

compose_profile_config() {
  local directory=$1
  local env_file=$2
  local profile=$3
  shift 3

  docker compose \
    --project-directory "$directory" \
    --env-file "$env_file" \
    -f "$directory/compose.yaml" \
    --profile "$profile" \
    config "$@"
}

compose_service_block() {
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
    | grep -E '(^|/)(\.env|runtime\.env|[^/]+\.runtime\.env|acme\.json|config/env\.json)$' \
    || true
)"
[[ -z "$tracked_sensitive_files" ]] \
  || die "Sensitive runtime files must not be tracked by Git: $tracked_sensitive_files"

printf '==> Validate shell syntax\n'
for script in "$ROOT_DIR"/scripts/*.sh; do
  bash -n "$script"
done

require_file "$ROOT_DIR/config/env.example.json"

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

printf '==> Validate shared infrastructure Compose models\n'
infrastructure_count=0
postgres_found=false
garage_found=false
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

  infrastructure_model="$(compose_config "$infrastructure_validation_dir" "$infrastructure_validation_dir/.env.example")"
  infrastructure_services="$(compose_config "$infrastructure_validation_dir" "$infrastructure_validation_dir/.env.example" --services)"

  grep -Fx "$infrastructure_service" <<<"$infrastructure_services" >/dev/null \
    || die "Primary service in infrastructure/$infrastructure_service/compose.yaml must be named $infrastructure_service"
  grep -Fx "name: $infrastructure_service" <<<"$infrastructure_model" >/dev/null \
    || die "Compose project name must resolve to $infrastructure_service"

  if [[ "$infrastructure_service" == "postgres" ]]; then
    postgres_found=true
    require_file "$directory/runtime.env.example"
    require_file "$ROOT_DIR/docs/postgres.md"

    grep -Eq '^    image: postgres:[0-9]+\.[0-9]+-bookworm@sha256:[0-9a-f]{64}$' <<<"$infrastructure_model" \
      || die "PostgreSQL image must use an exact patch version, Debian variant and digest"
    [[ "$(grep -Fc '        target: /var/lib/postgresql' <<<"$infrastructure_model" || true)" -eq 1 ]] \
      || die "PostgreSQL 18 data volume must be mounted at /var/lib/postgresql"
    grep -A4 -Fx '  postgres-net:' <<<"$infrastructure_model" | grep -Fx '    name: postgres-net' >/dev/null \
      || die "PostgreSQL network must use the stable postgres-net name"
    if grep -A4 -Fx '  postgres-net:' <<<"$infrastructure_model" | grep -Fx '    internal: true' >/dev/null; then
      die "PostgreSQL network must allow the host loopback port mapping"
    fi
    grep -F 'max_connections=' <<<"$infrastructure_model" >/dev/null \
      || die "PostgreSQL max_connections must be explicit"

    if grep -Eq '^    container_name:' <<<"$infrastructure_model"; then
      die "PostgreSQL must not set container_name"
    fi
    if [[ "$(grep -Fc '      host_ip: 127.0.0.1' <<<"$infrastructure_model" || true)" -ne 1 ]] \
      || [[ "$(grep -Fc '      target: 5432' <<<"$infrastructure_model" || true)" -ne 1 ]] \
      || [[ "$(grep -Fc '      published: "5432"' <<<"$infrastructure_model" || true)" -ne 1 ]]; then
      die "PostgreSQL must publish port 5432 only on the host loopback address"
    fi
    if grep -F 'traefik-net' <<<"$infrastructure_model" >/dev/null; then
      die "PostgreSQL must not attach to traefik-net"
    fi

    for variable in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_INITDB_ARGS; do
      grep -Eq "^${variable}=" "$directory/runtime.env.example" \
        || die "infrastructure/postgres/runtime.env.example must define $variable"
    done
  elif [[ "$infrastructure_service" == "garage" ]]; then
    garage_found=true
    require_file "$directory/runtime.env.example"
    require_file "$directory/garage.toml"
    require_file "$ROOT_DIR/docs/garage.md"

    grep -Eq '^    image: dxflrs/garage:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$infrastructure_model" \
      || die "Garage image must use an exact version and digest"
    [[ "$(grep -Fc '        target: /var/lib/garage/meta' <<<"$infrastructure_model" || true)" -eq 1 ]] \
      || die "Garage metadata volume must be mounted at /var/lib/garage/meta"
    [[ "$(grep -Fc '        target: /var/lib/garage/data' <<<"$infrastructure_model" || true)" -eq 1 ]] \
      || die "Garage data volume must be mounted at /var/lib/garage/data"
    grep -A4 -Fx '  garage-net:' <<<"$infrastructure_model" | grep -Fx '    internal: true' >/dev/null \
      || die "Garage application network must be internal"
    grep -F 'traefik.http.services.garage-web.loadbalancer.server.port' <<<"$infrastructure_model" \
      | grep -F '3902' >/dev/null \
      || die "Garage public router must use only the read-only web endpoint on port 3902"

    if grep -Eq '^    (container_name|ports):' <<<"$infrastructure_model"; then
      die "Garage must not set container_name or publish host ports"
    fi
    if grep -F 'traefik.http.services.garage-web.loadbalancer.server.port' <<<"$infrastructure_model" \
      | grep -F '3900' >/dev/null; then
      die "Garage S3 API must not be routed publicly"
    fi

    for variable in GARAGE_RPC_SECRET GARAGE_DEFAULT_ACCESS_KEY GARAGE_DEFAULT_SECRET_KEY; do
      grep -Eq "^${variable}=" "$directory/runtime.env.example" \
        || die "infrastructure/garage/runtime.env.example must define $variable"
    done
    for variable in \
      GARAGE_PUBLIC_DOMAIN \
      GARAGE_PUBLIC_BUCKET \
      GARAGE_PUBLIC_BUCKET_MAX_SIZE \
      GARAGE_PUBLIC_BUCKET_MAX_OBJECTS; do
      grep -Eq "^${variable}=" "$directory/.env.example" \
        || die "infrastructure/garage/.env.example must define $variable"
    done

    grep -Fx 'replication_factor = 1' "$directory/garage.toml" >/dev/null \
      || die "Garage single-node deployment must use replication_factor = 1"
    grep -Fx 'db_engine = "sqlite"' "$directory/garage.toml" >/dev/null \
      || die "Garage single-node metadata must use SQLite"
    grep -Fx 'metadata_fsync = true' "$directory/garage.toml" >/dev/null \
      || die "Garage metadata fsync must be enabled"
    grep -Fx 'data_fsync = true' "$directory/garage.toml" >/dev/null \
      || die "Garage data fsync must be enabled"
    grep -Fx 'rpc_bind_addr = "127.0.0.1:3901"' "$directory/garage.toml" >/dev/null \
      || die "Garage RPC must bind only to container loopback in single-node mode"
  fi

  infrastructure_count=$((infrastructure_count + 1))
done

[[ "$postgres_found" == true ]] || die "PostgreSQL infrastructure stack is required."
[[ "$garage_found" == true ]] || die "Garage infrastructure stack is required."

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
  app_migration_model="$(
    compose_profile_config \
      "$app_validation_dir" \
      "$app_validation_dir/.env.example" \
      '*'
  )"
  app_migration_services="$(
    compose_profile_config \
      "$app_validation_dir" \
      "$app_validation_dir/.env.example" \
      '*' \
      --services
  )"
  migration_service="${app}-migrate"

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

  if grep -Fx -- "$migration_service" <<<"$app_migration_services" >/dev/null; then
    app_service_block="$(compose_service_block "$app_migration_model" "$app")"
    migration_service_block="$(compose_service_block "$app_migration_model" "$migration_service")"
    migration_source_block="$(compose_service_block "$(<"$directory/compose.yaml")" "$migration_service")"
    app_image="$(sed -n 's/^    image: //p' <<<"$app_service_block")"
    migration_image="$(sed -n 's/^    image: //p' <<<"$migration_service_block")"

    [[ -n "$migration_service_block" ]] \
      || die "Unable to inspect migration service: $migration_service"
    [[ -n "$app_image" && "$migration_image" == "$app_image" ]] \
      || die "apps/$app migration service must use the same image as $app"
    grep -A2 -Fx '    profiles:' <<<"$migration_service_block" | grep -Fx '      - migration' >/dev/null \
      || die "apps/$app migration service must use the migration profile"
    grep -Fx '    restart: "no"' <<<"$migration_service_block" >/dev/null \
      || die "apps/$app migration service must set restart: no"
    grep -Fx '    command:' <<<"$migration_service_block" >/dev/null \
      || die "apps/$app migration service must define an explicit command"
    grep -A2 -Fx '    security_opt:' <<<"$migration_service_block" \
      | grep -Fx '      - no-new-privileges:true' >/dev/null \
      || die "apps/$app migration service must enable no-new-privileges"
    grep -A3 -Fx '    env_file:' <<<"$migration_source_block" \
      | grep -Fx '      - path: ./migration.runtime.env' >/dev/null \
      || die "apps/$app migration service must read migration.runtime.env"
    grep -A3 -Fx '    env_file:' <<<"$migration_source_block" \
      | grep -Fx '        required: true' >/dev/null \
      || die "apps/$app migration.runtime.env must be required"

    if grep -Eq '^    (container_name|labels|ports):' <<<"$migration_service_block"; then
      die "apps/$app migration service must not set container_name, labels or host ports"
    fi
    if grep -Eq '^      traefik-net:' <<<"$migration_service_block"; then
      die "apps/$app migration service must not attach to traefik-net"
    fi
  fi

  if [[ "$app" == "codebuff-next" ]]; then
    grep -Eq '^      postgres-net:' <<<"$app_model" \
      || die "apps/codebuff-next/compose.yaml must attach the service to postgres-net"
    grep -A4 -Fx '  postgres-net:' <<<"$app_model" | grep -Fx '    external: true' >/dev/null \
      || die "apps/codebuff-next/compose.yaml must declare postgres-net as external"
    if grep -Fx -- "$migration_service" <<<"$app_migration_services" >/dev/null; then
      grep -Eq '^      postgres-net:' <<<"$migration_service_block" \
        || die "apps/codebuff-next migration service must attach to postgres-net"
    fi
  fi

  app_count=$((app_count + 1))
done

[[ "$app_count" -gt 0 ]] || die "No applications found under apps/."

printf 'Validation passed for Traefik, %s shared infrastructure service(s) and %s application(s).\n' \
  "$infrastructure_count" "$app_count"
