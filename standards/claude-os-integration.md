# Claude-OS Integration Standard

## Geltungsbereich

Gilt für das gesamte WSL2-Dev-Setup unter `~/dev/`. Definiert:

- **Teil A** — was die eine claude-os-Instanz (heute TrueNAS Custom App auf
  `192.168.88.202:30174`) topologisch erfüllen muss, damit das Upstream-
  Service-Dashboard (`/api/services/status`) für alle sechs Standard-Services
  `running` meldet.
- **Teil B** — was jedes Dev-Projekt unter `~/dev/<projekt>/` erfüllen muss,
  damit es als "in claude-os integriert" gilt und gegenüber der Instanz die
  notwendigen Anker liefert (KB, File-Watch-Pfad, agent-os-Layout).

Beide Teile zusammen sind die Bedingung für ein durchgängig grünes Bild
über alle Projekte in der einen Instanz.

## Topologie-Überblick

```
~/dev/                                  ← Dev-Workstation, WSL2
├── agent-os/                           ← globales Framework + Standards (dieses Repo)
│   ├── profiles/default/               ← Quelle für KB `global` in claude-os
│   └── standards/                      ← dieser Standard liegt hier
├── truenas/                            ← Projekt, KB `truenas`
├── dev-stack/                          ← Projekt, KB `dev-stack`
├── ai-teacher-stack/                   ← Projekt, KB `ai-teacher-stack`
└── ai-devops-stack/                    ← Projekt, KB `ai-devops-stack`
                                          enthält das claude-os-Deployment
                                          unter compose/claude-os/

TrueNAS                                 ← Laufzeit
└── pool01/appdata/
    ├── claude-os/                      ← Instanz-State (Redis, SQLite, Uploads)
    └── claude-os-projects/             ← read-only Mirror der Dev-Projekte
        ├── global/                     ← rsync von ~/dev/agent-os/profiles/default/
        ├── truenas/                    ← rsync von ~/dev/truenas/
        ├── dev-stack/                  ← rsync von ~/dev/dev-stack/
        ├── ai-teacher-stack/           ← rsync von ~/dev/ai-teacher-stack/
        └── ai-devops-stack/            ← rsync von ~/dev/ai-devops-stack/

claude-os-Instanz                       ← TrueNAS Custom App, port 30174
└── mountet /mnt/pool01/appdata/claude-os-projects als /projects:ro
```

Die rsync-Mirror-Schicht entkoppelt Dev-Workstation und Instanz. Edits passieren
in `~/dev/`, der Mirror auf TrueNAS ist read-only.

## Teil A — Instanz-Compliance

Der Upstream-Service-Check in `mcp_server/server.py` (`api_get_services_status`)
prüft jeden Service mit OR-Logik aus zwei lokalen Probes:

```python
service.running = pgrep("<process>") or lsof(":<port>")
```

Beide Probes laufen im PID- bzw. Network-Namespace des claude-os-api-Containers.
Wir bringen `running = true` rein über die Compose-Topologie, ohne den Code
anzufassen.

### Namespace-Anker

Genau ein Service ist der **Namespace-Anker**. Die anderen Container teilen
dessen PID- und Network-Namespace per `pid: service:<anker>` und
`network_mode: service:<anker>`.

**Anker ist `claude-os-api`** — semantisch der Hauptdienst, sein Hostname
bleibt der einzige Compose-DNS-Eintrag, den die Außenwelt (Caddy) anspricht.

Konsequenzen:

- `claude-os-redis` und `claude-os-worker` haben keinen eigenen Compose-DNS-Namen.
  Sie sind nur als Prozesse/Ports im Net-NS von `claude-os-api` erreichbar.
- Niemand außerhalb des Stacks spricht direkt mit Redis. API und Worker erreichen
  Redis intern über `localhost:6379`.
- Caddy spricht weiterhin `claude-os-api:8051` — semantisch unverändert.

### A1 — `procps` und `lsof` im API-Image

Der Upstream-Check ruft `pgrep`, `lsof`, `netstat`/`ss` per `subprocess.run`.
Sind diese nicht installiert, returnt die Probe Exception → `status: "unknown"`
(gelb).

`Dockerfile.api` muss `procps` (für `pgrep`/`ps`) und `lsof` mit installieren:

```dockerfile
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git \
    procps lsof \
  && rm -rf /var/lib/apt/lists/*
```

OS-Paket-Komposition, kein Patch am claude-os-Code.

### A2 — Geteilter PID/Net-NS zwischen API, Redis und Worker

```yaml
services:
  claude-os-api:
    # Anker, eigener Net+PID-NS, eigener Compose-DNS-Eintrag.
    # KEIN network_mode, KEIN pid.

  claude-os-redis:
    image: redis:7-alpine
    network_mode: "service:claude-os-api"
    pid:          "service:claude-os-api"
    depends_on:
      - claude-os-api

  claude-os-worker:
    network_mode: "service:claude-os-api"
    pid:          "service:claude-os-api"
    depends_on:
      - claude-os-api
    entrypoint: [/usr/local/bin/claude-os-worker-entrypoint]
```

Effekt im API-Container:

| Probe | Sieht |
|---|---|
| `pgrep -f redis-server` | Redis-Prozess (gleicher PID-NS) |
| `pgrep -f "rq worker"` | Worker-Prozess (gleicher PID-NS) |
| `lsof -i :6379` | Redis-Socket (gleicher Net-NS) |

### A3 — Redis-Connect-Strings auf `localhost`

Da Redis im selben Net-NS lauscht, ist der korrekte Connect-Host
`localhost`, nicht `claude-os-redis`. Compose-Semantik, kein Workaround.

```yaml
environment:
  REDIS_HOST: localhost
  REDIS_PORT: "6379"
```

Gilt für `claude-os-api` und `claude-os-worker`.

### A4 — Frontend als `vite preview`-Prozess

Der Upstream-Check sucht `pgrep -f vite` plus `lsof :5173`. Caddy mit
statischem Build erfüllt das nicht.

Ein separater Container `claude-os-frontend` läuft `vite preview` auf 5173.
`vite preview` ist der von Vite mitgelieferte Production-Static-Server
(kein Dev-Mode, kein HMR). Er hängt ebenfalls am API-Anker:

```yaml
claude-os-frontend:
  image: ${CLAUDE_OS_FRONTEND_IMAGE:-...}
  network_mode: "service:claude-os-api"
  pid:          "service:claude-os-api"
  depends_on:
    - claude-os-api
  command: ["sh", "-c", "cd /opt/claude-os/frontend && exec npx vite preview --host 0.0.0.0 --port 5173"]
```

Voraussetzung: das `claude-os-frontend`-Image enthält das gebaute
`frontend/`-Verzeichnis inklusive `node_modules/`. Heute liefert
`Dockerfile.web` nur den Caddy-Stage mit `dist/`. Implementierungs-Skizze:

- Zweiter Build-Tag aus dem gleichen Multi-Stage-Dockerfile, der den
  Node-Build-Stage als finales Image exportiert.
- Oder: eigenes `Dockerfile.frontend`, das vom Node-Build-Stage abzweigt.

Caddy bleibt der einzige extern erreichbare HTTP-Frontdoor. `vite preview`
ist ausschließlich intern für den Health-Check.

### A5 — File Watcher mit mindestens einem aktiven Projekt

Der Upstream-Check meldet "stopped", wenn `get_global_watcher().get_status()
.projects_watched == 0`.

Beim Bootstrap der Instanz muss mindestens ein File-Watcher auf einen realen
Pfad registriert werden. In unserem Setup pro Dev-Projekt einer, jeweils
auf `/projects/<projekt>/`. Konkret siehe Teil B (B3).

### A6 — Akzeptanztest Instanz

`GET /api/services/status` liefert:

```json
{
  "summary": {
    "total": 6,
    "running": 6,
    "stopped": 0,
    "health": "healthy"
  }
}
```

UI-seitig: sechs grüne Service-Karten, "System Health" = `Healthy`.

## Teil B — Projekt-Compliance

Ein Dev-Projekt unter `~/dev/<projekt>/` gilt als "in claude-os integriert",
wenn alle folgenden Punkte erfüllt sind.

### B1 — Projekt-`agent-os/`-Layout vorhanden

Im Projekt-Root existiert ein `agent-os/`-Verzeichnis mit mindestens:

```
agent-os/
├── product/          # mission.md, roadmap.md, tech-stack.md (Pflicht für claude-os ingest)
├── standards/        # projektspezifische Standards, gruppiert nach Bereich
│   └── index.yml     # Pflicht — von /index-standards erzeugt
└── specs/            # optional, Specs für laufende Arbeit
```

Initialisierung erfolgt über die offiziellen Slash-Commands des Frameworks:
`/plan-product`, `/discover-standards`, `/index-standards`, jeweils im Projekt-
Claude-Code-Kontext, plus `bash scripts/project-install.sh` aus `~/dev/agent-os/`.

Bei Projekten mit bestehendem Inhalt: `project-install.sh --commands-only`,
um existierende Standards nicht zu überschreiben.

### B2 — Knowledge Base in claude-os existiert

Pro Projekt genau eine KB:

| Quelle (WSL) | KB-Name in claude-os | KB-Typ |
|---|---|---|
| `~/dev/agent-os/profiles/default/` | `global` | `agent-os` |
| `~/dev/truenas/` | `truenas` | `agent-os` |
| `~/dev/dev-stack/` | `dev-stack` | `agent-os` |
| `~/dev/ai-teacher-stack/` | `ai-teacher-stack` | `agent-os` |
| `~/dev/ai-devops-stack/` | `ai-devops-stack` | `agent-os` |

Erzeugung via MCP:
```
mcp__claude-os__create_knowledge_base \
  name=<projekt> \
  kb_type=agent-os \
  description="..."
```

### B3 — Ingest aus `/projects/<projekt>/agent-os`

Pro KB:

```
mcp__claude-os__ingest_agent_os_profile \
  kb_name=<projekt> \
  profile_path=/projects/<projekt>/agent-os
```

Nach jedem Ingest sofort `get_agent_os_stats <projekt>` verifizieren:
`total_documents > 0`, `documents_by_type` enthält `product`, `standard`,
ggf. `spec`. Bei `total_documents == 0` trotz vorhandener Dateien ist das
Quellverzeichnis nicht das `agent-os/`-Sub-Verzeichnis, sondern das
Projekt-Root übergeben worden — Pfad korrigieren und reingesten.

### B4 — File-Watcher auf `/projects/<projekt>/` registriert

Pro Projekt-KB ein File-Watcher auf den Mirror-Pfad. Dies erfüllt
gleichzeitig Regel A5 (mindestens ein aktives Watch-Projekt) und sorgt dafür,
dass Edits auf der Dev-Workstation nach rsync automatisch in claude-os
auflaufen.

### B4a — Per-KB Folder-Mapping (Auto-Sync-Pipeline)

Der File-Watcher aus B4 ist die Aggregatfunktion auf Projekt-Ebene. Zusätzlich
muss pro KB-Typ ein konkreter Folder gemappt werden, damit die jeweilige KB
auch befüllt wird. Das passiert über `POST /api/projects/{project_id}/folders`
mit `{mcp_type, folder_path, auto_sync}` (= UI-Tab "Folders + Auto-Sync").

Default-Mapping pro Projekt `<name>` mit Mirror unter `/projects/<name>/`:

| MCP-Typ | Folder | auto_sync | Was landet drin |
|---|---|---|---|
| `knowledge_docs` | `/projects/<name>/docs` | true | Markdown-Doku |
| `project_profile` | `/projects/<name>/agent-os/product` | true | mission, roadmap, tech-stack |
| `project_index` | `/projects/<name>/agent-os/standards` | true | Standards inkl. `index.yml` |
| `project_memories` | `/projects/<name>/agent-os/specs` | true | Specs/Tasks |
| `code_structure` | `/projects/<name>` | false | Source-Tree; Tree-Sitter-Indexer wird separat angestoßen, kein File-Watch |

Toleranz: existiert ein erwarteter Sub-Pfad in einem Projekt nicht (z.B.
`agent-os/specs/` bei einem Projekt das noch keine Specs hat), wird der
entsprechende Mapping-Eintrag **übersprungen**, nicht erzwungen. Sobald
das Verzeichnis später angelegt wird, kann der Mapping-Schritt re-run werden.

Beim erstmaligen Setzen eines Mappings ingestiert claude-os den Folder
direkt einmal (`ingest_directory(folder_path, kb_name)`). Folge-Edits laufen
dann via `auto_sync=true` über den File-Watcher.

Bootstrap-Script: `ai-devops-stack/scripts/bootstrap-claude-os-folders.sh`
(idempotent, dry-run-default).

### B5 — rsync-Mirror aktuell

Quelle: `~/dev/<projekt>/` auf der Dev-Workstation. Ziel: `pool01/appdata/
claude-os-projects/<projekt>/` auf TrueNAS, gemountet als `/projects/<projekt>:ro`
in API und Worker.

Sync läuft über `bash ~/dev/agent-os/scripts/sync-to-claude-os-projects.sh`
(oder projekt-eigenes Pendant) und ist non-destructive (kein `--delete` ohne
explizite Erlaubnis).

### B6 — Akzeptanztest Projekt

Pro Projekt:

1. `get_agent_os_stats <projekt>` — `total_documents > 0`, `documents_by_type`
   enthält erwartete Typen.
2. `get_product_context <projekt>` — liefert Mission, Tech-Stack, Roadmap
   (außer für `global`).
3. `get_standards <projekt>` — liefert projektspezifische Standards.
4. `GET /api/projects/{id}/folders` listet jede existierende Mapping aus B4a
   mit `auto_sync` wie im Default vorgesehen.
5. Pro gemappter KB: `total_documents > 0` nach erstem Sync.
6. UI: Projekt erscheint in der Projects-Sidebar, File-Watcher-Status zeigt
   für mindestens einen Mount aktive Beobachtung.

Über alle Projekte:
- `list_knowledge_bases_by_type agent-os` enthält genau die fünf KBs aus B2.
- Service-Dashboard meldet `health: "healthy"` (siehe Teil A).

## Out-of-Scope

- **Kein Patch am Service-Dashboard-Endpoint**.
- **Kein Health-Sidecar.** Compose-Namespace-Sharing ist die nähere Variante am Upstream.
- **Kein Fork** des claude-os-Repos.
- **`compose/claude-os/patches/0001-rag_engine-use-config-env.patch`** ist ein
  unabhängiger Upstream-Bug-Fix (hartkodiertes `localhost:11434`, ignoriert
  `Config.OLLAMA_HOST`) und PR-Material an `brobertsaz/claude-os`. Steht
  nicht im Konflikt mit diesem Standard.
- **Code-Snapshot-KBs pro Projekt** (`<projekt>-code_structure` o.ä.) sind
  hier explizit nicht Teil der Integration. Falls später gewünscht, separat
  spezifizieren.
- **Cleanup verwaister KBs** in claude-os: das MCP exponiert kein delete-Tool;
  Cleanup erfordert externen Eingriff (DB-/Filesystem-Ebene des Instanz-Backends).

## Implementierungs-Verantwortung

| Bereich | Repo / Pfad |
|---|---|
| Teil A — Compose, Dockerfile, Caddyfile | `~/dev/ai-devops-stack/compose/claude-os/` |
| Teil B — Sync-Scripts, Bootstrap | `~/dev/agent-os/scripts/` und projekt-eigene `scripts/` |
| `agent-os/`-Layout pro Projekt | jeweils `~/dev/<projekt>/agent-os/` |
| Dieser Standard | `~/dev/agent-os/standards/claude-os-integration.md` |
