#!/usr/bin/env bash
# Vaultwarden CLI session helper for truenas-agent.
#
# Stores a short-lived Bitwarden/Vaultwarden CLI session outside the repository
# so dry-run-first scripts can read Vaultwarden without copy/pasting BW_SESSION
# and without exporting NODE_TLS_REJECT_UNAUTHORIZED=0 globally.
#
# Ported verbatim (with path adjustments) from ai-devops-stack/scripts/secrets/bw-session.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a
fi

if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck disable=SC1091
  . "${NVM_DIR}/nvm.sh"
fi

VAULTWARDEN_BASE_URL="${VAULTWARDEN_BASE_URL:-https://192.168.88.202:30032}"
BW_INSECURE_TLS="${BW_INSECURE_TLS:-0}"

# shellcheck disable=SC1091
. "${ROOT_DIR}/scripts/lib/bw-session.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/secrets/bw-session.sh <unlock|status|path|lock|forget>

Commands:
  unlock   Run bw unlock --raw and cache the session token with chmod 600.
  status   Show bw status after loading the cached session.
  path     Print the runtime session file path.
  lock     Run bw lock and remove the cached session.
  forget   Remove the cached session without contacting Vaultwarden.

The cached session is written under $XDG_RUNTIME_DIR/truenas-agent/bw-session
(or /tmp/truenas-agent-<uid>/bw-session as fallback). chmod 600.

Set BW_INSECURE_TLS=1 while the Vaultwarden cert is self-signed:
    BW_INSECURE_TLS=1 scripts/secrets/bw-session.sh unlock
USAGE
}

cmd="${1:-status}"
case "${cmd}" in
  unlock)
    command -v bw >/dev/null 2>&1 || { printf '[FAIL] bw is missing\n' >&2; exit 1; }
    bw_session_configure_server
    session="$(bw_run unlock --raw)"
    if [[ -z "${session}" ]]; then
      printf '[FAIL] bw unlock returned an empty session\n' >&2
      exit 1
    fi
    bw_session_save "${session}"
    BW_SESSION="${session}"
    export BW_SESSION
    status="$(bw_session_status)"
    if ! grep -q '"status":"unlocked"' <<<"${status}"; then
      printf '[FAIL] cached session did not unlock bw\n' >&2
      exit 1
    fi
    printf '[OK] Vaultwarden session cached: %s\n' "$(bw_session_file)"
    ;;
  status)
    status="$(bw_session_status)"
    if [[ -z "${status}" ]]; then
      printf '[FAIL] bw status unavailable\n' >&2
      exit 1
    fi
    printf '%s\n' "${status}"
    ;;
  path)
    printf '%s\n' "$(bw_session_file)"
    ;;
  lock)
    bw_session_load
    bw_run lock >/dev/null 2>&1 || true
    bw_session_forget
    printf '[OK] Vaultwarden session locked and cache removed\n'
    ;;
  forget)
    bw_session_forget
    printf '[OK] Vaultwarden session cache removed\n'
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    printf 'Unknown command: %s\n' "${cmd}" >&2
    usage
    exit 2
    ;;
esac
