#!/usr/bin/env bash

set -Eeuo pipefail

WARN_USED_PERCENT=70
STOP_USED_PERCENT=75
MIN_FREE_GIB=10

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "Docker is required."
command -v df >/dev/null 2>&1 || die "df is required."

docker_root="$(docker info --format '{{.DockerRootDir}}')"
[[ -n "$docker_root" && -d "$docker_root" ]] \
  || die "Docker root directory is unavailable: ${docker_root:-not reported}"

read -r total_kib used_kib available_kib used_percent mountpoint < <(
  LC_ALL=C df -Pk "$docker_root" \
    | awk 'NR == 2 { gsub(/%/, "", $5); print $2, $3, $4, $5, $6 }'
)

[[ "$used_percent" =~ ^[0-9]+$ && "$available_kib" =~ ^[0-9]+$ ]] \
  || die "Unable to read filesystem capacity for $docker_root"

available_gib=$((available_kib / 1024 / 1024))
total_gib=$((total_kib / 1024 / 1024))
used_gib=$((used_kib / 1024 / 1024))

printf 'Garage capacity check: %s GiB used of %s GiB, %s GiB free, %s%% used (%s).\n' \
  "$used_gib" "$total_gib" "$available_gib" "$used_percent" "$mountpoint"

if ((used_percent >= STOP_USED_PERCENT || available_gib < MIN_FREE_GIB)); then
  die "Do not accept new Garage writes until disk usage is below ${STOP_USED_PERCENT}% and at least ${MIN_FREE_GIB} GiB is free."
fi

if ((used_percent >= WARN_USED_PERCENT)); then
  printf 'WARNING: Disk usage has reached the Garage warning threshold of %s%%.\n' \
    "$WARN_USED_PERCENT" >&2
fi
