#!/usr/bin/env bash
# Sync this repo's agent-os profile + repo docs into Claude-OS.
#
# - Adapted from ai-devops-stack/scripts/sync-claude-os-knowledge.sh.
# - Dry-run by default. --apply requires HTTP Basic Auth credentials.
# - Creates (or upserts) a single Claude-OS knowledge base named "global"
#   of kb_type=agent-os, plus a Claude-OS project of the same name.
# - Uploads only safe content from the Agent-OS framework:
#   profiles/default/global/*.md (standards templates),
#   commands/agent-os/*.md (workflow commands), README.md, config.yml.
#
# Auth (in priority order):
#   CLAUDE_OS_BASIC_AUTH_HEADER="Basic <base64(user:pass)>"
#   or  CLAUDE_OS_BASIC_AUTH_USER + CLAUDE_OS_BASIC_AUTH_PASSWORD
#   (no auth needed for --dry-run)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLAUDE_OS_BASE_URL="${CLAUDE_OS_BASE_URL:-http://192.168.88.202:30174}"
CLAUDE_OS_PROJECT_NAME="${CLAUDE_OS_PROJECT_NAME:-global}"
CLAUDE_OS_PROJECT_PATH="${CLAUDE_OS_PROJECT_PATH:-/projects/global}"
CLAUDE_OS_CODE_STRUCTURE_FOLDER="${CLAUDE_OS_CODE_STRUCTURE_FOLDER:-${CLAUDE_OS_PROJECT_PATH}}"
CLAUDE_OS_KB_NAME="${CLAUDE_OS_KB_NAME:-global}"
CLAUDE_OS_KB_TYPE="${CLAUDE_OS_KB_TYPE:-agent-os}"
CLAUDE_OS_BASIC_AUTH_HEADER="${CLAUDE_OS_BASIC_AUTH_HEADER:-}"
CLAUDE_OS_BASIC_AUTH_USER="${CLAUDE_OS_BASIC_AUTH_USER:-}"
CLAUDE_OS_BASIC_AUTH_PASSWORD="${CLAUDE_OS_BASIC_AUTH_PASSWORD:-}"

mode="dry-run"

usage() {
  cat <<'USAGE'
Usage: sync-claude-os-knowledge.sh [--dry-run|--apply]

Registers the global Agent-OS framework profile + commands as a Claude-OS
knowledge base named "global". Uploads profiles/default/global/*.md
(standards templates), commands/agent-os/*.md (workflow commands),
README.md, and config.yml.

Defaults to dry-run. --apply requires Basic Auth credentials in the
environment (see header of this script).

Env overrides:
  CLAUDE_OS_CODE_STRUCTURE_FOLDER  default: CLAUDE_OS_PROJECT_PATH
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run) mode="dry-run" ;;
    --apply) mode="apply" ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

# If --apply and no explicit auth env vars, try to fetch from Vaultwarden via
# the bw-session helper. The Vaultwarden item claude-os/operator-basic-auth
# stores the bcrypt hash in `password` (consumed by Caddy at deploy time) and
# the plaintext as a hidden custom field `plaintext_password` — see
# agent-os/standards/secrets/vaultwarden.md.
if [[ "${mode}" == "apply" && -z "${CLAUDE_OS_BASIC_AUTH_HEADER}" \
      && ( -z "${CLAUDE_OS_BASIC_AUTH_USER}" || -z "${CLAUDE_OS_BASIC_AUTH_PASSWORD}" ) ]]; then
  if [[ -r "${ROOT_DIR}/scripts/lib/bw-session.sh" ]]; then
    # shellcheck source=/dev/null
    . "${ROOT_DIR}/scripts/lib/bw-session.sh"
    if bw_session_require_unlocked 2>/dev/null; then
      CLAUDE_OS_BASIC_AUTH_USER="${CLAUDE_OS_BASIC_AUTH_USER:-$(bw_run get username claude-os/operator-basic-auth 2>/dev/null || true)}"
      CLAUDE_OS_BASIC_AUTH_PASSWORD="${CLAUDE_OS_BASIC_AUTH_PASSWORD:-$(bw_get_custom_field claude-os/operator-basic-auth plaintext_password 2>/dev/null || true)}"
      export CLAUDE_OS_BASIC_AUTH_USER CLAUDE_OS_BASIC_AUTH_PASSWORD
    fi
  fi
fi

auth_args=()
if [[ -n "${CLAUDE_OS_BASIC_AUTH_HEADER}" ]]; then
  auth_args=(-H "Authorization: ${CLAUDE_OS_BASIC_AUTH_HEADER}")
elif [[ -n "${CLAUDE_OS_BASIC_AUTH_USER}" && -n "${CLAUDE_OS_BASIC_AUTH_PASSWORD}" ]]; then
  auth_args=(-u "${CLAUDE_OS_BASIC_AUTH_USER}:${CLAUDE_OS_BASIC_AUTH_PASSWORD}")
fi

if [[ "${mode}" == "apply" && ${#auth_args[@]} -eq 0 ]]; then
  printf '[FAIL] No Claude-OS credentials available for --apply.\n' >&2
  printf '       Either set CLAUDE_OS_BASIC_AUTH_HEADER, or CLAUDE_OS_BASIC_AUTH_USER+CLAUDE_OS_BASIC_AUTH_PASSWORD,\n' >&2
  printf '       or unlock Vaultwarden first:\n' >&2
  printf '         BW_INSECURE_TLS=1 scripts/secrets/bw-session.sh unlock\n' >&2
  exit 1
fi

# Curated, safe file selection. No source code, no secrets, no snapshots.
collect_files() {
  (
    cd "${ROOT_DIR}"
    find \
      README.md config.yml \
      profiles/default/global \
      commands/agent-os \
      -type f \
      ! -path '*/.git/*' \
      ! -path '*/.github/*' \
      ! -name '.env*' \
      ! -name 'CHANGELOG.md' \
      ! -name 'LICENSE' \
      ! -name '*.pem' ! -name '*.key' ! -name '*.p12' ! -name '*.pfx' \
      ! -name '*.log' \
      \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) \
      2>/dev/null | sort
  )
}

mapfile -t files < <(collect_files)

printf 'Mode: %s\n' "${mode}"
printf 'Claude-OS: %s\n' "${CLAUDE_OS_BASE_URL}"
printf 'Project: %s\n' "${CLAUDE_OS_PROJECT_NAME}"
printf 'Code structure folder: %s\n' "${CLAUDE_OS_CODE_STRUCTURE_FOLDER}"
printf 'KB: %s (type %s)\n' "${CLAUDE_OS_KB_NAME}" "${CLAUDE_OS_KB_TYPE}"
printf 'Files selected: %d\n' "${#files[@]}"

for file in "${files[@]}"; do
  printf '  %s\n' "${file}"
done

if [[ "${mode}" == "dry-run" ]]; then
  printf '\nDry-run only. Re-run with --apply to create project/KB and upload documents.\n'
  exit 0
fi

api_json() {
  local method="$1"
  local path="$2"
  local payload="$3"
  local expected_regex="${4:-^2}"
  local code
  code="$(curl -k -sS -o "/tmp/claude-os-sync-response.$$" -w '%{http_code}' \
    -X "${method}" \
    "${auth_args[@]}" \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${CLAUDE_OS_BASE_URL%/}${path}" || true)"
  if [[ "${code}" =~ ${expected_regex} ]]; then
    printf '[OK] %s %s -> HTTP %s\n' "${method}" "${path}" "${code}"
  else
    printf '[FAIL] %s %s -> HTTP %s\n' "${method}" "${path}" "${code:-curl-failed}" >&2
    cat "/tmp/claude-os-sync-response.$$" >&2 || true
    rm -f "/tmp/claude-os-sync-response.$$"
    return 1
  fi
  rm -f "/tmp/claude-os-sync-response.$$"
}

command -v jq >/dev/null 2>&1 || {
  printf '[FAIL] jq is required for --apply\n' >&2
  exit 1
}

# 1. Project
project_payload="$(jq -n \
  --arg name "${CLAUDE_OS_PROJECT_NAME}" \
  --arg path "${CLAUDE_OS_PROJECT_PATH}" \
  --arg description "Global Agent-OS framework (Builder Methods): default profile standards templates and workflow slash-commands" \
  '{name:$name,path:$path,description:$description}')"
api_json POST /api/projects "${project_payload}" '^2|^409$'

project_id="$(curl -k -sS \
  "${auth_args[@]}" \
  "${CLAUDE_OS_BASE_URL%/}/api/projects" \
  | jq -r --arg name "${CLAUDE_OS_PROJECT_NAME}" '
      def rows:
        if type == "array" then .
        elif has("projects") then .projects
        elif has("items") then .items
        elif has("data") and (.data | type == "array") then .data
        else [] end;
      rows[] | select(.name == $name) | .id
    ' \
  | head -1)"

if [[ -z "${project_id}" || "${project_id}" == "null" ]]; then
  printf '[FAIL] Could not resolve Claude-OS project id for %s.\n' "${CLAUDE_OS_PROJECT_NAME}" >&2
  exit 1
fi

# 1b. Ensure the code_structure KB exists, then configure its project MCP. Some
# Claude-OS builds validate code_structure but do not seed the project mapping;
# scripts/repair-claude-os-code-structure.sh fixes existing projects.
code_structure_kb_payload="$(jq -n \
  --arg name "${CLAUDE_OS_PROJECT_NAME}-code_structure" \
  --arg kb_type "generic" \
  --arg description "Code Structure for ${CLAUDE_OS_PROJECT_NAME}" \
  '{name:$name,kb_type:$kb_type,description:$description}')"
api_json POST /api/kb "${code_structure_kb_payload}" '^2|^400$|^409$'

code_structure_payload="$(jq -n \
  --arg mcp_type "code_structure" \
  --arg folder_path "${CLAUDE_OS_CODE_STRUCTURE_FOLDER}" \
  '{mcp_type:$mcp_type,folder_path:$folder_path,auto_sync:true}')"
api_json POST "/api/projects/${project_id}/folders" "${code_structure_payload}" '^2'

# 2. Single agent-os KB
kb_payload="$(jq -n \
  --arg name "${CLAUDE_OS_KB_NAME}" \
  --arg kb_type "${CLAUDE_OS_KB_TYPE}" \
  --arg description "Global Agent-OS profile: default standards templates and framework workflow commands. Source of cross-project standards and slash-command definitions." \
  '{name:$name,kb_type:$kb_type,description:$description}')"
api_json POST /api/kb "${kb_payload}" '^2|^400$|^409$'

# 3. Upload each file
for file in "${files[@]}"; do
  payload="$(jq -n \
    --rawfile content "${ROOT_DIR}/${file}" \
    --arg filename "${file}" \
    '{content:$content,filename:$filename,metadata:{source:$filename,managed_by:"global",repo:"agent-os"}}')"
  api_json POST "/api/kb/${CLAUDE_OS_KB_NAME}/documents/content" "${payload}" '^2'
done

printf '\n[OK] Claude-OS knowledge sync completed for %s.\n' "${CLAUDE_OS_PROJECT_NAME}"
