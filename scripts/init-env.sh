#!/usr/bin/env bash

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
  bash scripts/init-env.sh <config-yml>

Creates missing environment files declared in the YAML configuration.
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

yq_for_file() {
  local expression=$1
  local relative_file=$2
  FILE_PATH="$relative_file" yq eval -r "$expression" "$CONFIG_FILE"
}

yq_for_value() {
  local expression=$1
  local relative_file=$2
  local key=$3
  FILE_PATH="$relative_file" ENV_KEY="$key" yq eval -r "$expression" "$CONFIG_FILE"
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

  yq eval -e '.version == 1' "$CONFIG_FILE" >/dev/null \
    || die "Configuration version must be 1."
  yq eval -e '(.files | tag) == "!!map"' "$CONFIG_FILE" >/dev/null \
    || die "Configuration must contain a files mapping."

  mapfile -t configured_files < <(yq eval -r '.files | keys | .[]' "$CONFIG_FILE")
  [[ "${#configured_files[@]}" -gt 0 ]] || die "Configuration files mapping must not be empty."

  for configured_file in "${configured_files[@]}"; do
    contains_target "$configured_file" \
      || die "Configuration target has no matching tracked template: $configured_file"
  done

  for index in "${!TARGET_FILES[@]}"; do
    relative=${TARGET_FILES[$index]}
    example=${EXAMPLE_FILES[$index]}

    node_type="$(yq_for_file '.files[strenv(FILE_PATH)] | tag' "$relative")"
    [[ "$node_type" == '!!map' ]] \
      || die "Configuration must define a key-value mapping for $relative"

    mapfile -t expected_keys < <(read_expected_keys "$example")
    mapfile -t configured_keys < <(yq_for_file '.files[strenv(FILE_PATH)] | keys | .[]' "$relative")
    [[ "${#expected_keys[@]}" -gt 0 ]] || die "Template has no environment keys: ${example#"$ROOT_DIR"/}"

    expected_signature="$(printf '%s\n' "${expected_keys[@]}" | LC_ALL=C sort)"
    configured_signature="$(printf '%s\n' "${configured_keys[@]}" | LC_ALL=C sort)"
    if [[ "$expected_signature" != "$configured_signature" ]]; then
      die "$relative keys must match its template. Expected: $(join_by_comma "${expected_keys[@]}"); configured: $(join_by_comma "${configured_keys[@]}")"
    fi

    for key in "${expected_keys[@]}"; do
      node_type="$(yq_for_value '.files[strenv(FILE_PATH)][strenv(ENV_KEY)] | tag' "$relative" "$key")"
      [[ "$node_type" == '!!str' ]] \
        || die "$relative:$key must be a YAML string; quote boolean-like or numeric values."

      linebreak="$(yq_for_value '.files[strenv(FILE_PATH)][strenv(ENV_KEY)] | (contains("\n") or contains("\r"))' "$relative" "$key")"
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
      encoded="$(yq_for_value '.files[strenv(FILE_PATH)][strenv(ENV_KEY)] | @base64' "$relative" "$key")"
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
  require_command yq

  local yq_version
  yq_version="$(yq --version 2>&1 || true)"
  [[ "$yq_version" =~ version[[:space:]]+v?4\. ]] \
    || die "mikefarah/yq v4 is required; found: ${yq_version:-unknown version}"

  umask 077
  validate_config_location
  discover_targets
  validate_config_shape
  stage_files
  install_missing_files
}

main "$@"
