# Agent Instruction Split: AGENTS.md / CLAUDE.md

## Rule

`AGENTS.md` = cross-agent project policy. `CLAUDE.md` = imports AGENTS.md + Claude-specific overlays only.

## AGENTS.md — what belongs here

- Mission and placement/workspace rules
- Operating rules, hard safety rules
- Links to `agent-os/standards/`
- Tool-neutral commands and workflows

## CLAUDE.md — what belongs here

- Import/reference line pointing to AGENTS.md
- MCP server list
- Claude Code hooks, permissions, settings references
- Claude-specific workflow hints (slash commands, memory, thinking mode)

## Why

Codex, Cursor, Aider read AGENTS.md. Claude-specific syntax in the main file breaks portability across agents.
