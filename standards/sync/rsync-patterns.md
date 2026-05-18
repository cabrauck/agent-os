# rsync Transfer Patterns

## Env-Override for SSH targets

All sync scripts use `VAR="${VAR:-default}"` for every connection parameter:

```bash
TRUENAS_SSH_HOST="${TRUENAS_SSH_HOST:-AgentAI@192.168.88.202}"
TRUENAS_SSH_KEY="${TRUENAS_SSH_KEY:-${HOME}/.ssh/id_ed25519_truenas_ai_devops}"
TRUENAS_PROJECTS_ROOT="${TRUENAS_PROJECTS_ROOT:-/mnt/pool01/appdata/claude-os-projects}"
PROJECT_NAME="${PROJECT_NAME:-<project>}"
```

- SSH host, key path, remote root, and project name are always overridable without editing the script
- Sensitive defaults (key paths, hostnames) stay out of committed values — override via `.env` or shell environment

## --delete double protection

`--delete` is a separate flag from `--apply`. Both must be passed explicitly:

```bash
./sync-to-claude-os-projects.sh --apply           # transfers, never deletes
./sync-to-claude-os-projects.sh --apply --delete  # transfers + removes remote orphans
```

- Never run `--delete` without reviewing the dry-run diff first
- Default mode (`--dry-run`) never modifies the remote, even with `--delete` present

## SSH options

```bash
ssh_opts="-i ${TRUENAS_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

`StrictHostKeyChecking=accept-new` accepts new host keys but rejects changed ones.
`BatchMode=yes` fails immediately instead of prompting for a password.
