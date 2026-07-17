#!/usr/bin/env bash

# jq expressions intentionally reference variables supplied through jq --arg.
# shellcheck disable=SC2016

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INFRASTRUCTURE_DIR="$ROOT_DIR/infrastructure"
APPS_DIR="$ROOT_DIR/apps"

CONFIG_FILE=""
STAGING_DIR=""
TARGET_FILES=()
EXAMPLE_FILES=()
STAGED_FILES=()

usage() {
  cat <<'EOF'
Usage:
  bash scripts/init-env.sh <config-json>

Creates missing environment files declared in the JSON configuration.
Existing files are left unchanged.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  local temp_root=${TMPDIR:-/tmp}

  if [[ -n "$STAGING_DIR" ]]; then
    case "$STAGING_DIR" in
      "$temp_root"/my-cloud-env-init.*) rm -rf -- "$STAGING_DIR" ;;
      *) printf 'WARNING: Refusing to remove unexpected path: %s\n' "$STAGING_DIR" >&2 ;;
    esac
  fi

  trap - EXIT
  exit "$status"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

contains_target() {
  local candidate=$1
  local target

  for target in "${TARGET_FILES[@]}"; do
    [[ "$target" == "$candidate" ]] && return 0
  done

  return 1
}

join_by_comma() {
  local IFS=', '
  printf '%s' "$*"
}

read_expected_keys() {
  local example=$1
  sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$example"
}

jq_for_file() {
  local expression=$1
  local relative_file=$2
  jq -r --arg file "$relative_file" "$expression" "$CONFIG_FILE" | tr -d '\r'
}

jq_for_value() {
  local expression=$1
  local relative_file=$2
  local key=$3
  jq -r --arg file "$relative_file" --arg key "$key" "$expression" "$CONFIG_FILE" | tr -d '\r'
}

validate_config_location() {
  local relative_config

  case "$CONFIG_FILE" in
    "$ROOT_DIR"/*)
      relative_config=${CONFIG_FILE#"$ROOT_DIR"/}
      if git -C "$ROOT_DIR" ls-files --error-unmatch -- "$relative_config" >/dev/null 2>&1; then
        die "Bootstrap configuration must not be tracked by Git: $relative_config"
      fi
      git -C "$ROOT_DIR" check-ignore -q -- "$relative_config" \
        || die "Bootstrap configuration inside the repository must be Git-ignored: $relative_config"
      ;;
  esac
}

discover_targets() {
  local actual
  local example
  local relative

  while IFS= read -r -d '' example; do
    actual=${example%.example}
    relative=${actual#"$ROOT_DIR"/}
    TARGET_FILES+=("$relative")
    EXAMPLE_FILES+=("$example")
  done < <(
    find "$INFRASTRUCTURE_DIR" "$APPS_DIR" -type f \
      \( -name '.env.example' -o -name 'runtime.env.example' -o -name '*.runtime.env.example' \) \
      -print0
  )

  [[ "${#TARGET_FILES[@]}" -gt 0 ]] || die "No environment templates found."
}

validate_config_shape() {
  local configured_file
  local configured_signature
  local expected_signature
  local index
  local key
  local linebreak
  local node_type
  local relative
  local example
  local -a configured_files=()
  local -a configured_keys=()
  local -a expected_keys=()

  jq -e '.version == 1' "$CONFIG_FILE" >/dev/null \
    || die "Configuration version must be 1."
  jq -e '(.files | type) == "object"' "$CONFIG_FILE" >/dev/null \
    || die "Configuration must contain a files mapping."

  mapfile -t configured_files < <(jq -r '.files | keys[]' "$CONFIG_FILE" | tr -d '\r')
  [[ "${#configured_files[@]}" -gt 0 ]] || die "Configuration files mapping must not be empty."

  for configured_file in "${configured_files[@]}"; do
    contains_target "$configured_file" \
      || die "Configuration target has no matching tracked template: $configured_file"
  done

  for index in "${!TARGET_FILES[@]}"; do
    relative=${TARGET_FILES[$index]}
    example=${EXAMPLE_FILES[$index]}

    node_type="$(jq_for_file '.files[$file] | type' "$relative")"
    [[ "$node_type" == object ]] \
      || die "Configuration must define a key-value mapping for $relative"

    mapfile -t expected_keys < <(read_expected_keys "$example")
    mapfile -t configured_keys < <(jq_for_file '.files[$file] | keys[]' "$relative")
    [[ "${#expected_keys[@]}" -gt 0 ]] || die "Template has no environment keys: ${example#"$ROOT_DIR"/}"

    expected_signature="$(printf '%s\n' "${expected_keys[@]}" | LC_ALL=C sort)"
    configured_signature="$(printf '%s\n' "${configured_keys[@]}" | LC_ALL=C sort)"
    if [[ "$expected_signature" != "$configured_signature" ]]; then
      die "$relative keys must match its template. Expected: $(join_by_comma "${expected_keys[@]}"); configured: $(join_by_comma "${configured_keys[@]}")"
    fi

    for key in "${expected_keys[@]}"; do
      node_type="$(jq_for_value '.files[$file][$key] | type' "$relative" "$key")"
      [[ "$node_type" == string ]] \
        || die "$relative:$key must be a JSON string."

      linebreak="$(jq_for_value '.files[$file][$key] | (contains("\n") or contains("\r"))' "$relative" "$key")"
      [[ "$linebreak" == false ]] \
        || die "$relative:$key must be a single-line value."
    done
  done
}

stage_files() {
  local encoded
  local escaped
  local example
  local index
  local key
  local relative
  local staged
  local value
  local -a expected_keys=()

  STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/my-cloud-env-init.XXXXXX")"
  chmod 700 "$STAGING_DIR"

  for index in "${!TARGET_FILES[@]}"; do
    relative=${TARGET_FILES[$index]}
    example=${EXAMPLE_FILES[$index]}
    staged="$STAGING_DIR/$relative"
    mkdir -p -- "$(dirname -- "$staged")"
    : >"$staged"

    mapfile -t expected_keys < <(read_expected_keys "$example")
    for key in "${expected_keys[@]}"; do
      encoded="$(jq_for_value '.files[$file][$key] | @base64' "$relative" "$key")"
      value="$(printf '%s' "$encoded" | base64 --decode)"
      escaped=${value//\'/\\\'}
      printf "%s='%s'\n" "$key" "$escaped" >>"$staged"
    done

    chmod 600 "$staged"
    STAGED_FILES+=("$staged")
  done
}

install_missing_files() {
  local actual
  local created=0
  local index
  local relative
  local skipped=0
  local staged

  for index in "${!TARGET_FILES[@]}"; do
    relative=${TARGET_FILES[$index]}
    actual="$ROOT_DIR/$relative"
    staged=${STAGED_FILES[$index]}

    if [[ -e "$actual" || -L "$actual" ]]; then
      printf 'SKIP: %s already exists.\n' "$relative"
      skipped=$((skipped + 1))
      continue
    fi

    install -m 600 -- "$staged" "$actual"
    printf 'CREATED: %s\n' "$relative"
    created=$((created + 1))
  done

  printf 'Environment initialization finished: %s created, %s unchanged.\n' "$created" "$skipped"
}

main() {
  [[ $# -eq 1 ]] || {
    usage >&2
    exit 1
  }

  [[ -f "$1" ]] || die "Configuration file not found: $1"
  CONFIG_FILE="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"

  require_command base64
  require_command find
  require_command git
  require_command install
  require_command jq

  local jq_version
  local jq_major
  local jq_minor
  local jq_patch
  jq_version="$(jq --version 2>&1 || true)"
  [[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+)(\.([0-9]+))? ]] \
    || die "jq 1.7.1 or newer is required; found: ${jq_version:-unknown version}"
  jq_major=${BASH_REMATCH[1]}
  jq_minor=${BASH_REMATCH[2]}
  jq_patch=${BASH_REMATCH[4]:-0}
  ((jq_major > 1 || (jq_major == 1 && (jq_minor > 7 || (jq_minor == 7 && jq_patch >= 1))))) \
    || die "jq 1.7.1 or newer is required; found: $jq_version"

  umask 077
  validate_config_location
  discover_targets
  validate_config_shape
  stage_files
  install_missing_files
}

main "$@"
