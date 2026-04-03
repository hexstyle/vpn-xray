# Documentation

Read these in order if you want the shortest path from zero to a working setup:

1. [Setup Runbook](./SETUP-RUNBOOK.md)
2. [Current Supported State](./CURRENT-LAB-STATE.md)
3. [Web UI](./WEB-UI.md)
4. [Shared Rules](./SHARED-RULES.md)
5. [Architecture](./ARCHITECTURE.md)

Optional background:

- [UI Extensibility Notes](./UI-EXTENSIBILITY.md)

## Human-First Index

- `SETUP-RUNBOOK.md`
  - quickest supported install path
- `CURRENT-LAB-STATE.md`
  - what is supported right now
- `WEB-UI.md`
  - what the router UI does and how to use it
- `SHARED-RULES.md`
  - how GitHub-backed selective routing works
- `ARCHITECTURE.md`
  - component map and responsibilities

## Automation Note

Automation should follow the same structure humans do:

- supported router profiles live in [`../routers/`](../routers/README.md)
- supported VPS profiles live in [`../vps/`](../vps/README.md)
- entrypoint scripts live in [`../scripts/`](../scripts/README.md)
