#!/usr/bin/env bash
# Repair existing Claude-OS projects that were created before code_structure was
# seeded into project_mcps.
#
# Default mode is --dry-run. --apply creates the missing KB via Claude-OS API,
# backs up the SQLite DB, inserts exactly one project_mcps row if absent, and
# configures the code_structure folder/index.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_OS_BASE_URL="${CLAUDE_OS_BASE_URL:-http://192.168.88.202:30174}"
CLAUDE_OS_PROJECT_NAME="${CLAUDE_OS_PROJECT_NAME:-global}"
CLAUDE_OS_PROJECT_PATH="${CLAUDE_OS_PROJECT_PATH:-/projects/${CLAUDE_OS_PROJECT_NAME}}"
CLAUDE_OS_CODE_STRUCTURE_FOLDER="${CLAUDE_OS_CODE_STRUCTURE_FOLDER:-${CLAUDE_OS_PROJECT_PATH}}"
TRUENAS_SSH_HOST="${TRUENAS_SSH_HOST:-AgentAI@192.168.88.202}"
TRUENAS_SSH_KEY="${TRUENAS_SSH_KEY:-${HOME}/.ssh/id_ed25519_truenas_ai_devops}"
CLAUDE_OS_DB_PATH="${CLAUDE_OS_DB_PATH:-/mnt/pool01/appdata/claude-os/data/claude-os.db}"

mode="dry-run"
while (($#)); do
  case "$1" in
    --dry-run) mode="dry-run" ;;
    --apply) mode="apply" ;;
    --help|-h)
      cat <<USAGE
Usage: $(basename "$0") [--dry-run|--apply]

Repairs the missing code_structure MCP mapping for an existing Claude-OS project.
USAGE
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

export PATH="${HOME}/.nvm/versions/node/v22.22.2/bin:${PATH}"
export BW_INSECURE_TLS="${BW_INSECURE_TLS:-1}"

# shellcheck source=/dev/null
. "${ROOT_DIR}/scripts/lib/bw-session.sh"

if [[ "${mode}" == "apply" ]]; then
  bw_session_require_unlocked >/dev/null
fi

auth_args=()
if [[ "${mode}" == "apply" ]]; then
  CO_USER="$(bw_run get username claude-os/operator-basic-auth)"
  CO_PASS="$(bw_get_custom_field claude-os/operator-basic-auth plaintext_password)"
  auth_args=(-u "${CO_USER}:${CO_PASS}")
fi

api_json() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  if [[ "${mode}" == "dry-run" ]]; then
    printf '[DRY-RUN] %s %s %s\n' "${method}" "${path}" "${payload}"
    return 0
  fi

  if [[ -n "${payload}" ]]; then
    curl -k -sS --fail-with-body --max-time 120 \
      -X "${method}" "${auth_args[@]}" \
      -H 'Content-Type: application/json' \
      --data "${payload}" \
      "${CLAUDE_OS_BASE_URL%/}${path}"
  else
    curl -k -sS --fail-with-body --max-time 30 \
      -X "${method}" "${auth_args[@]}" \
      "${CLAUDE_OS_BASE_URL%/}${path}"
  fi
}

api_get() {
  local path="$1"
  curl -k -sS --fail-with-body --max-time 30 "${auth_args[@]}" "${CLAUDE_OS_BASE_URL%/}${path}"
}

resolve_project_id() {
  jq -r --arg name "${CLAUDE_OS_PROJECT_NAME}" '
    def rows:
      if type == "array" then .
      elif has("projects") then .projects
      elif has("items") then .items
      elif has("data") and (.data | type == "array") then .data
      else [] end;
    rows[] | select(.name == $name) | .id
  ' | head -1
}

resolve_kb_id() {
  jq -r --arg name "${CLAUDE_OS_PROJECT_NAME}-code_structure" '
    def rows:
      if type == "array" then .
      elif has("knowledge_bases") then .knowledge_bases
      elif has("items") then .items
      elif has("data") and (.data | type == "array") then .data
      else [] end;
    rows[] | select(.name == $name) | .id
  ' | head -1
}

printf 'Mode: %s\n' "${mode}"
printf 'Project: %s\n' "${CLAUDE_OS_PROJECT_NAME}"
printf 'Project path: %s\n' "${CLAUDE_OS_PROJECT_PATH}"
printf 'Code structure folder: %s\n' "${CLAUDE_OS_CODE_STRUCTURE_FOLDER}"
printf 'Claude-OS DB: %s:%s\n' "${TRUENAS_SSH_HOST}" "${CLAUDE_OS_DB_PATH}"

if [[ "${mode}" == "dry-run" ]]; then
  printf '[DRY-RUN] Would create KB %s-code_structure if missing.\n' "${CLAUDE_OS_PROJECT_NAME}"
  printf '[DRY-RUN] Would backup SQLite DB before inserting missing project_mcps row.\n'
  printf '[DRY-RUN] Would configure code_structure folder and run structural indexing.\n'
  exit 0
fi

project_id="$(api_get /api/projects | resolve_project_id)"
if [[ -z "${project_id}" || "${project_id}" == "null" ]]; then
  printf '[FAIL] Project not found: %s\n' "${CLAUDE_OS_PROJECT_NAME}" >&2
  exit 1
fi

kb_payload="$(jq -n \
  --arg name "${CLAUDE_OS_PROJECT_NAME}-code_structure" \
  --arg kb_type "generic" \
  --arg description "Code Structure for ${CLAUDE_OS_PROJECT_NAME}" \
  '{name:$name,kb_type:$kb_type,description:$description}')"
api_json POST /api/kb "${kb_payload}" >/tmp/claude-os-code-structure-kb.json 2>/dev/null || true

kb_id="$(api_get /api/kb | resolve_kb_id)"
if [[ -z "${kb_id}" || "${kb_id}" == "null" ]]; then
  printf '[FAIL] Could not resolve KB id for %s-code_structure\n' "${CLAUDE_OS_PROJECT_NAME}" >&2
  exit 1
fi

ssh_opts=(-i "${TRUENAS_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
backup_path="${CLAUDE_OS_DB_PATH}.bak-code_structure-$(date -u +%Y%m%dT%H%M%SZ)"

read -r -d '' sql <<SQL || true
.backup '${backup_path}'
UPDATE projects
SET path = '${CLAUDE_OS_PROJECT_PATH}'
WHERE id = ${project_id}
  AND path != '${CLAUDE_OS_PROJECT_PATH}';
INSERT INTO project_mcps (project_id, kb_id, mcp_type)
SELECT ${project_id}, ${kb_id}, 'code_structure'
WHERE NOT EXISTS (
  SELECT 1 FROM project_mcps
  WHERE project_id = ${project_id}
    AND mcp_type = 'code_structure'
);
SELECT project_id, kb_id, mcp_type
FROM project_mcps
WHERE project_id = ${project_id}
  AND mcp_type = 'code_structure';
SQL

printf '%s\n' "${sql}" | ssh "${ssh_opts[@]}" "${TRUENAS_SSH_HOST}" \
  "sqlite3 '${CLAUDE_OS_DB_PATH}'"

folder_payload="$(jq -n \
  --arg mcp_type "code_structure" \
  --arg folder_path "${CLAUDE_OS_CODE_STRUCTURE_FOLDER}" \
  '{mcp_type:$mcp_type,folder_path:$folder_path,auto_sync:false}')"
api_json POST "/api/projects/${project_id}/folders" "${folder_payload}" | jq .

index_payload="$(jq -n \
  --arg project_path "${CLAUDE_OS_CODE_STRUCTURE_FOLDER}" \
  --arg cache_path "/data/tree-sitter-cache/${CLAUDE_OS_PROJECT_NAME}.db" \
  '{project_path:$project_path,cache_path:$cache_path,token_budget:2048}')"
api_json POST "/api/kb/${CLAUDE_OS_PROJECT_NAME}-code_structure/index-structural" "${index_payload}" | jq .

printf '\n[OK] code_structure repaired for project %s (project_id=%s, kb_id=%s).\n' \
  "${CLAUDE_OS_PROJECT_NAME}" "${project_id}" "${kb_id}"
printf '[OK] SQLite backup: %s\n' "${backup_path}"
