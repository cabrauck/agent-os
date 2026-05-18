# Dry-Run-First Default

## Rule

Every mutating operation defaults to dry-run. Side effects require explicit opt-in.

## Implementations by layer

**Shell scripts:**
```bash
mode="dry-run"
# ...
--dry-run)  mode="dry-run" ;;
--apply)    mode="apply" ;;
```
Never transfer, delete, or deploy in default mode.

**Python functions:**
```python
def deploy(target, apply: bool = False):
    if not apply:
        print(f"[dry-run] would deploy to {target}")
        return
    # actual mutation here
```

**MCP / agent calls:** Describe the intended mutation in the plan step; only execute after explicit user confirmation in the current turn.

## What counts as a mutation

- File transfers (rsync `--apply`)
- API calls that create, update, or delete resources
- Docker/Compose stack changes
- Dataset or volume creation/deletion
- Anything not easily reversible

## Why

Agents execute autonomously. A dry-run-first default prevents unintended side effects from misread state or wrong parameters. `--delete` on rsync is doubly protected: requires both `--apply` and explicit `--delete` flag.
