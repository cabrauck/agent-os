# WSL2 Canonical Workspace

## Rule

The canonical Git checkout for all repos under `~/dev/` lives in Ubuntu WSL2.
Windows paths (`D:\...`, `/mnt/c/...`) are mirrors or convenience copies — never the source of truth.

## Canonical path

```
/home/cabra/dev/<project>/   ← edits, commits, agent work happen here
```

## Allowed Windows-side use

- One-time bootstrap or migration tasks
- Reading/viewing files via `\\wsl.localhost\...`
- Ollama / GPU-bound workloads on the Windows host

## Never do from a Windows mirror

- Git commits or pushes
- Agent-coding sessions (Codex, Cursor, Claude Code)
- Running `make`, tests, or deployment scripts

## Why

Windows mirror and WSL2 checkout diverge silently. Commits from the wrong side create conflicting histories that require manual reconciliation.

## Verification

`ai-devops-stack` provides `scripts/check-canonical-workspace.sh` — run before productive coding sessions.
