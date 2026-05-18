#!/usr/bin/env bash
# Shared Vaultwarden CLI session helpers for truenas-agent.
# Ported from ai-devops-stack/scripts/lib/bw-session.sh; cache namespace
# renamed to truenas-agent so the two projects don't clobber each other.

bw_session_runtime_dir() {
  if [[ -n "${TRUENAS_AGENT_BW_SESSION_DIR:-}" ]]; then
    printf '%s\n' "${TRUENAS_AGENT_BW_SESSION_DIR}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    printf '%s/truenas-agent\n' "${XDG_RUNTIME_DIR}"
  elif [[ -d "/run/user/$(id -u)" && -w "/run/user/$(id -u)" ]]; then
    printf '/run/user/%s/truenas-agent\n' "$(id -u)"
  else
    printf '/tmp/truenas-agent-%s\n' "$(id -u)"
  fi
}

bw_session_file() {
  if [[ -n "${TRUENAS_AGENT_BW_SESSION_FILE:-}" ]]; then
    printf '%s\n' "${TRUENAS_AGENT_BW_SESSION_FILE}"
  else
    printf '%s/bw-session\n' "$(bw_session_runtime_dir)"
  fi
}

bw_session_load() {
  local session_file
  session_file="$(bw_session_file)"
  if [[ -z "${BW_SESSION:-}" && -r "${session_file}" ]]; then
    BW_SESSION="$(<"${session_file}")"
    export BW_SESSION
  fi
}

bw_session_save() {
  local session="$1"
  local session_dir session_file
  session_dir="$(bw_session_runtime_dir)"
  session_file="$(bw_session_file)"
  umask 077
  mkdir -p "${session_dir}"
  printf '%s' "${session}" >"${session_file}"
  chmod 600 "${session_file}"
}

bw_session_forget() {
  local session_file
  session_file="$(bw_session_file)"
  rm -f "${session_file}"
  unset BW_SESSION
}

# bw_run <bw-args...>
# Wrapper that honours BW_INSECURE_TLS=1 (-> NODE_TLS_REJECT_UNAUTHORIZED=0)
# and transparently appends --session "$BW_SESSION" to all subcommands except
# config/login/logout/lock/unlock.
bw_run() {
  local cmd="${1:-}"
  local -a base_cmd
  if [[ "${BW_INSECURE_TLS:-0}" == "1" ]]; then
    base_cmd=(env NODE_TLS_REJECT_UNAUTHORIZED=0 bw)
  else
    base_cmd=(bw)
  fi

  case "${cmd}" in
    ""|config|login|logout|lock|unlock)
      "${base_cmd[@]}" "$@"
      ;;
    *)
      bw_session_load
      if [[ -n "${BW_SESSION:-}" ]]; then
        "${base_cmd[@]}" "$@" --session "${BW_SESSION}"
      else
        "${base_cmd[@]}" "$@"
      fi
      ;;
  esac
}

bw_session_configure_server() {
  if [[ -n "${VAULTWARDEN_BASE_URL:-}" ]]; then
    bw config server "${VAULTWARDEN_BASE_URL}" >/dev/null 2>&1 || true
  fi
}

bw_session_status() {
  bw_session_load
  bw_run status 2>/dev/null || true
}

bw_session_require_unlocked() {
  local status
  command -v bw >/dev/null 2>&1 || {
    printf '[FAIL] bw is missing\n' >&2
    return 1
  }
  bw_session_configure_server
  status="$(bw_session_status)"
  if ! grep -q '"status":"unlocked"' <<<"${status}"; then
    printf '[FAIL] Vaultwarden CLI is not unlocked. Run: BW_INSECURE_TLS=1 scripts/secrets/bw-session.sh unlock\n' >&2
    return 1
  fi
}

# bw_get_custom_field <item> <field-name>
# Reads a value from the "fields" array of a Vaultwarden item. Useful for
# items that store a hash in the password field and the plaintext in a
# hidden custom field (e.g. claude-os/operator-basic-auth -> plaintext_password).
bw_get_custom_field() {
  local item="$1"
  local field="$2"
  bw_run get item "${item}" \
    | jq -r --arg name "${field}" '.fields[]? | select(.name==$name) | .value'
}
