#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
POSTGRES_DIR="$ROOT_DIR/infrastructure/postgres"
LOCK_FILE="$ROOT_DIR/.ops.lock"

OUTPUT_DIR=""
WORK_DIR=""
PARTIAL_ARCHIVE=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/postgres-backup.sh <existing-output-directory>

Creates one timestamped PostgreSQL backup archive. Copy the completed archive
to protected off-host storage to satisfy the documented recovery objective.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      "$OUTPUT_DIR"/.postgres-backup.*) rm -rf -- "$WORK_DIR" ;;
      *) printf 'WARNING: Refusing to remove unexpected path: %s\n' "$WORK_DIR" >&2 ;;
    esac
  fi

  if [[ -n "$PARTIAL_ARCHIVE" && -f "$PARTIAL_ARCHIVE" ]]; then
    rm -f -- "$PARTIAL_ARCHIVE"
  fi

  trap - EXIT
  exit "$status"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

acquire_lock() {
  if [[ "${OPS_LOCK_HELD:-}" == "1" ]]; then
    return
  fi

  require_command flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another infrastructure operation is already running."
}

compose() {
  docker compose \
    --project-directory "$POSTGRES_DIR" \
    --env-file "$POSTGRES_DIR/.env" \
    -f "$POSTGRES_DIR/compose.yaml" \
    "$@"
}

main() {
  local archive
  local database
  local postgres_version
  local timestamp
  local -a databases=()

  [[ $# -eq 1 ]] || {
    usage >&2
    exit 1
  }

  require_command docker
  require_command sha256sum
  require_command tar
  docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable."

  [[ -f "$POSTGRES_DIR/.env" ]] \
    || die "Missing $POSTGRES_DIR/.env; create it from .env.example."
  [[ -f "$POSTGRES_DIR/.env.runtime" ]] \
    || die "Missing $POSTGRES_DIR/.env.runtime; create it from .env.runtime.example."
  [[ -d "$1" ]] || die "Backup output directory does not exist: $1"

  OUTPUT_DIR="$(cd -- "$1" && pwd)"
  acquire_lock
  compose config --quiet
  compose exec -T postgres pg_isready >/dev/null \
    || die "PostgreSQL is not ready."

  umask 077
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$OUTPUT_DIR/postgres-$timestamp.tar.gz"
  PARTIAL_ARCHIVE="$archive.partial"
  [[ ! -e "$archive" && ! -e "$PARTIAL_ARCHIVE" ]] \
    || die "Backup archive already exists: $archive"

  WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.postgres-backup.XXXXXX")"
  chmod 700 "$WORK_DIR"
  mkdir -- "$WORK_DIR/databases"

  printf '==> Export PostgreSQL global objects\n'
  # Expanded by the shell inside the PostgreSQL container.
  # shellcheck disable=SC2016
  compose exec -T postgres sh -ceu \
    'exec pg_dumpall --username "$POSTGRES_USER" --globals-only' \
    >"$WORK_DIR/globals.sql"

  mapfile -t databases < <(
    # Expanded by the shell inside the PostgreSQL container.
    # shellcheck disable=SC2016
    compose exec -T postgres sh -ceu \
      'exec psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align --command "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> '\''postgres'\'' ORDER BY datname;"' \
      | tr -d '\r'
  )

  for database in "${databases[@]}"; do
    [[ "$database" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
      || die "Database name cannot be represented safely in a backup filename: $database"
    printf '==> Export database: %s\n' "$database"
    # Expanded by the shell inside the PostgreSQL container.
    # shellcheck disable=SC2016
    compose exec -T postgres sh -ceu \
      'exec pg_dump --username "$POSTGRES_USER" --format=custom --create --dbname "$1"' \
      sh "$database" >"$WORK_DIR/databases/$database.dump"
  done

  postgres_version="$(compose exec -T postgres postgres --version | tr -d '\r')"
  {
    printf 'created_at_utc=%s\n' "$timestamp"
    printf 'postgres_version=%s\n' "$postgres_version"
    printf 'database_count=%s\n' "${#databases[@]}"
    for database in "${databases[@]}"; do
      printf 'database=%s\n' "$database"
    done
  } >"$WORK_DIR/manifest.txt"

  (
    cd -- "$WORK_DIR"
    sha256sum globals.sql manifest.txt
    for database in "${databases[@]}"; do
      sha256sum "databases/$database.dump"
    done
  ) >"$WORK_DIR/SHA256SUMS"

  tar -czf "$PARTIAL_ARCHIVE" -C "$WORK_DIR" .
  chmod 600 "$PARTIAL_ARCHIVE"
  mv -- "$PARTIAL_ARCHIVE" "$archive"
  PARTIAL_ARCHIVE=""

  printf 'PostgreSQL backup created: %s\n' "$archive"
  printf 'Copy this archive to protected off-host storage.\n'
}

main "$@"
