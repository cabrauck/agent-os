#!/usr/bin/env bash
# Sync cabrauck/agent-os fork with buildermethods/agent-os upstream.
#
# Flow:
#   1. Fetch upstream
#   2. Check for new commits
#   3. Rebase local commits on top of upstream/main
#   4. Push to origin (cabrauck/agent-os)
#   5. Log result to ~/dev/agent-os/scripts/.sync-upstream.log
#
# Run daily via cron — see: crontab -l
# Manual run: bash scripts/sync-from-upstream.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${REPO_DIR}/scripts/.sync-upstream.log"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
  echo "[${TIMESTAMP}] $*" | tee -a "${LOG_FILE}"
}

cd "${REPO_DIR}"

log "Fetching upstream (buildermethods/agent-os)..."
git fetch upstream

BEHIND=$(git rev-list HEAD..upstream/main --count)

if [[ "${BEHIND}" -eq 0 ]]; then
  log "Already up to date with upstream/main. Nothing to do."
  exit 0
fi

log "Upstream has ${BEHIND} new commit(s). Rebasing..."

if ! git rebase upstream/main; then
  log "ERROR: Rebase conflict. Manual intervention required."
  log "  Run: cd ${REPO_DIR} && git rebase --abort (to cancel)"
  log "  Or:  git rebase --continue (after resolving conflicts)"
  exit 1
fi

log "Rebase successful. Pushing to origin (cabrauck/agent-os)..."
git push --force-with-lease origin main

log "Done. Fork is now ${BEHIND} upstream commit(s) ahead of previous state."
