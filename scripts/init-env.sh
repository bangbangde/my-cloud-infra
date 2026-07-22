#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INFRASTRUCTURE_DIR="$ROOT_DIR/infrastructure"
APPS_DIR="$ROOT_DIR/apps"
TRAEFIK_RUNTIME_TARGET="infrastructure/traefik/.env.runtime"

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

json_query() {
  local query_type=$1
  local config_file=$2
  shift 2
  python3 - "$config_file" "$query_type" "$@" <<'PYTHON' | tr -d '\r'
import json
import sys
import base64

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

query_type = sys.argv[2]

if query_type == 'get_version':
    print(data.get('version', ''))
elif query_type == 'get_files_type':
    print(type(data.get('files')).__name__)
elif query_type == 'get_files_keys':
    files = data.get('files', {})
    for k in files.keys():
        print(k)
elif query_type == 'get_file_type':
    file_path = sys.argv[3]
    obj = data.get('files', {}).get(file_path)
    print(type(obj).__name__ if obj is not None else 'null')
elif query_type == 'get_file_keys':
    file_path = sys.argv[3]
    obj = data.get('files', {}).get(file_path, {})
    for k in obj.keys():
        print(k)
elif query_type == 'get_value_type':
    file_path = sys.argv[3]
    key = sys.argv[4]
    obj = data.get('files', {}).get(file_path, {}).get(key)
    print(type(obj).__name__ if obj is not None else 'null')
elif query_type == 'has_linebreak':
    file_path = sys.argv[3]
    key = sys.argv[4]
    value = data.get('files', {}).get(file_path, {}).get(key, '')
    has_newline = '\n' in str(value) or '\r' in str(value)
    print('true' if has_newline else 'false')
elif query_type == 'get_traefik_type':
    traefik = data.get('traefik')
    print(type(traefik).__name__ if traefik is not None else 'null')
elif query_type == 'get_domains_type':
    domains = data.get('traefik', {}).get('domains')
    print(type(domains).__name__ if domains is not None else 'null')
elif query_type == 'get_domains_length':
    domains = data.get('traefik', {}).get('domains', [])
    print(len(domains))
elif query_type == 'all_domains_are_strings':
    domains = data.get('traefik', {}).get('domains', [])
    all_strings = all(isinstance(d, str) for d in domains)
    print('true' if all_strings else 'false')
elif query_type == 'get_domains':
    domains = data.get('traefik', {}).get('domains', [])
    for d in domains:
        print(d)
elif query_type == 'get_value':
    file_path = sys.argv[3]
    key = sys.argv[4]
    value = data.get('files', {}).get(file_path, {}).get(key, '')
    print(value)
elif query_type == 'get_value_base64':
    file_path = sys.argv[3]
    key = sys.argv[4]
    value = data.get('files', {}).get(file_path, {}).get(key, '')
    encoded = base64.b64encode(str(value).encode('utf-8')).decode('utf-8')
    print(encoded)
else:
    sys.exit(1)
PYTHON
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
      \( -name '.env.example' -o -name '.env.*.example' \) \
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

  [[ "$(json_query get_version "$CONFIG_FILE")" == "2" ]] \
    || die "Configuration version must be 2."
  [[ "$(json_query get_files_type "$CONFIG_FILE")" == "dict" ]] \
    || die "Configuration must contain a files mapping."

  mapfile -t configured_files < <(json_query get_files_keys "$CONFIG_FILE")
  [[ "${#configured_files[@]}" -gt 0 ]] || die "Configuration files mapping must not be empty."

  for configured_file in "${configured_files[@]}"; do
    contains_target "$configured_file" \
      || die "Configuration target has no matching tracked template: $configured_file"
  done

  for index in "${!TARGET_FILES[@]}"; do
    relative=${TARGET_FILES[$index]}
    example=${EXAMPLE_FILES[$index]}

    node_type="$(json_query get_file_type "$CONFIG_FILE" "$relative")"
    [[ "$node_type" == dict ]] \
      || die "Configuration must define a key-value mapping for $relative"

    mapfile -t expected_keys < <(read_expected_keys "$example")
    mapfile -t configured_keys < <(json_query get_file_keys "$CONFIG_FILE" "$relative")
    [[ "${#expected_keys[@]}" -gt 0 ]] || die "Template has no environment keys: ${example#"$ROOT_DIR"/}"

    expected_signature="$(printf '%s\n' "${expected_keys[@]}" | LC_ALL=C sort)"
    configured_signature="$(printf '%s\n' "${configured_keys[@]}" | LC_ALL=C sort)"
    if [[ "$expected_signature" != "$configured_signature" ]]; then
      die "$relative keys must match its template. Expected: $(join_by_comma "${expected_keys[@]}"); configured: $(join_by_comma "${configured_keys[@]}")"
    fi

    for key in "${expected_keys[@]}"; do
      node_type="$(json_query get_value_type "$CONFIG_FILE" "$relative" "$key")"
      [[ "$node_type" == str ]] \
        || die "$relative:$key must be a JSON string."

      linebreak="$(json_query has_linebreak "$CONFIG_FILE" "$relative" "$key")"
      [[ "$linebreak" == false ]] \
        || die "$relative:$key must be a single-line value."
    done
  done
}

validate_traefik_domains() {
  local dashboard_domain
  local domain
  local domain_count
  local unique_domain_count
  local -a domains=()

  contains_target "$TRAEFIK_RUNTIME_TARGET" \
    || die "Missing tracked template for $TRAEFIK_RUNTIME_TARGET"
  [[ "$(json_query get_traefik_type "$CONFIG_FILE")" == "dict" && "$(json_query get_domains_type "$CONFIG_FILE")" == "list" ]] \
    || die "Configuration must contain a traefik.domains array."

  domain_count="$(json_query get_domains_length "$CONFIG_FILE")"
  [[ "$domain_count" -gt 0 ]] || die "traefik.domains must not be empty."
  [[ "$(json_query all_domains_are_strings "$CONFIG_FILE")" == "true" ]] \
    || die "Every traefik.domains entry must be a JSON string."

  mapfile -t domains < <(json_query get_domains "$CONFIG_FILE")
  unique_domain_count="$(printf '%s\n' "${domains[@]}" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')"
  [[ "$unique_domain_count" -eq "$domain_count" ]] \
    || die "traefik.domains must not contain duplicates."

  for domain in "${domains[@]}"; do
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
      || die "Invalid domain in traefik.domains: $domain"
  done

  dashboard_domain="$(json_query get_value "$CONFIG_FILE" 'infrastructure/traefik/.env' 'DOMAIN_NAME')"
  printf '%s\n' "${domains[@]}" | grep -Fx -- "$dashboard_domain" >/dev/null \
    || die "infrastructure/traefik/.env:DOMAIN_NAME must also appear in traefik.domains."
}

append_traefik_domains() {
  local domain
  local index=0

  while IFS= read -r domain; do
    printf "TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_DOMAINS_%s_MAIN='%s'\n" "$index" "$domain"
    printf "TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_DOMAINS_%s_SANS='*.%s'\n" "$index" "$domain"
    index=$((index + 1))
  done < <(json_query get_domains "$CONFIG_FILE")
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
      encoded="$(json_query get_value_base64 "$CONFIG_FILE" "$relative" "$key")"
      value="$(printf '%s' "$encoded" | base64 --decode)"
      escaped=${value//\'/\\\'}
      printf "%s='%s'\n" "$key" "$escaped" >>"$staged"
    done

    if [[ "$relative" == "$TRAEFIK_RUNTIME_TARGET" ]]; then
      append_traefik_domains >>"$staged"
    fi

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
  require_command python3

  umask 077
  validate_config_location
  discover_targets
  validate_config_shape
  validate_traefik_domains
  stage_files
  install_missing_files
}

main "$@"
