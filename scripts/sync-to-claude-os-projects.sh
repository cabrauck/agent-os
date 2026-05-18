#!/usr/bin/env bash
# Rsync this repo to its Claude-OS project mirror on TrueNAS.
#
# Flow:
#   WSL2 dev tree (this repo)
#     |  rsync over ssh
#     v
#   TrueNAS dataset /mnt/pool01/appdata/claude-os-projects/global/
#     |  bind-mounted ro into claude-os containers
#     v
#   Claude-OS sees /projects/global/<entire repo>
#
# Default mode is --dry-run. --apply transfers.
#
# Pre-req: SSH access to TrueNAS as a user that can write the dataset.
# Defaults to `root@192.168.88.202` over the agentai SSH key, which can be
# overridden with TRUENAS_SSH_HOST and TRUENAS_SSH_KEY env vars.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default user is AgentAI (case-sensitive) — that user owns the per-project
# mirror dataset on TrueNAS and has shell access via the SSH key below.
TRUENAS_SSH_HOST="${TRUENAS_SSH_HOST:-AgentAI@192.168.88.202}"
TRUENAS_SSH_KEY="${TRUENAS_SSH_KEY:-${HOME}/.ssh/id_ed25519_truenas_ai_devops}"
TRUENAS_PROJECTS_ROOT="${TRUENAS_PROJECTS_ROOT:-/mnt/pool01/appdata/claude-os-projects}"
PROJECT_NAME="${PROJECT_NAME:-global}"

REMOTE_DEST="${TRUENAS_SSH_HOST}:${TRUENAS_PROJECTS_ROOT}/${PROJECT_NAME}/"

mode="dry-run"
delete_flag=""
while (($#)); do
  case "$1" in
    --dry-run) mode="dry-run" ;;
    --apply) mode="apply" ;;
    --delete) delete_flag="--delete" ;;
    --help|-h)
      cat <<USAGE
Usage: $(basename "$0") [--dry-run|--apply] [--delete]

Rsync this repo into its Claude-OS project mirror on TrueNAS.

Options:
  --dry-run   (default) Print what rsync would copy; no changes on TrueNAS.
  --apply     Actually transfer.
  --delete    Remove remote files that no longer exist locally (DESTRUCTIVE).

Env overrides:
  TRUENAS_SSH_HOST       default: root@192.168.88.202
  TRUENAS_SSH_KEY        default: ~/.ssh/id_ed25519_truenas_ai_devops
  TRUENAS_PROJECTS_ROOT  default: /mnt/pool01/appdata/claude-os-projects
  PROJECT_NAME           default: global (subfolder under root)
USAGE
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Files / patterns NEVER mirrored: secrets, build artifacts, caches, .git.
# Git is excluded on purpose because the mirror is for read-only indexing,
# not for cloning from. Add new exclusions here when they show up.
EXCLUDES=(
  "--exclude=.git/"
  "--exclude=.venv/"
  "--exclude=.pytest_cache/"
  "--exclude=__pycache__/"
  "--exclude=node_modules/"
  "--exclude=build/"
  "--exclude=dist/"
  "--exclude=*.egg-info/"
  "--exclude=.generated/"
  "--exclude=inventory/snapshots/"
  "--exclude=audit/"
  "--exclude=.env"
  "--exclude=.env.*"
  "--exclude=config/local.config.yaml"
  "--exclude=config/*.local.yaml"
  "--exclude=*.pem"
  "--exclude=*.key"
  "--exclude=*.p12"
  "--exclude=*.pfx"
  "--exclude=*.log"
)

ssh_opts="-i ${TRUENAS_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

if [[ "${mode}" == "dry-run" ]]; then
  rsync_flags=(-avzhn --human-readable --info=stats2)
else
  rsync_flags=(-avzh --human-readable --info=stats1,progress2)
fi

if [[ -n "${delete_flag}" ]]; then
  rsync_flags+=("${delete_flag}")
fi

echo "Mode:              ${mode}"
echo "Source:            ${ROOT_DIR}/"
echo "Destination:       ${REMOTE_DEST}"
echo "SSH key:           ${TRUENAS_SSH_KEY}"
echo "Delete on remote:  ${delete_flag:-no}"
echo

# Ensure the per-project destination dir exists before rsync (rsync can create
# the trailing path component, but ssh-fail-fast gives a cleaner error if the
# parent dataset is missing).
if [[ "${mode}" == "apply" ]]; then
  ssh ${ssh_opts} "${TRUENAS_SSH_HOST}" "mkdir -p '${TRUENAS_PROJECTS_ROOT}/${PROJECT_NAME}'"
fi

rsync "${rsync_flags[@]}" "${EXCLUDES[@]}" \
  -e "ssh ${ssh_opts}" \
  "${ROOT_DIR}/" "${REMOTE_DEST}"

if [[ "${mode}" == "dry-run" ]]; then
  echo
  echo "Dry-run only. Re-run with --apply to transfer."
fi
