# Documentation Index

This folder is the main entry point for both people and automation.

If you are opening this repository for the first time, read in this order:

1. [Setup Runbook](./SETUP-RUNBOOK.md)
2. [Current Implementation State](./CURRENT-LAB-STATE.md)
3. [Web UI](./WEB-UI.md)
4. [Shared Rules](./SHARED-RULES.md)
5. [Architecture](./ARCHITECTURE.md)

Optional background:

- [UI Extensibility Notes](./UI-EXTENSIBILITY.md)

## What Each File Is For

- `SETUP-RUNBOOK.md`
  - quickest end-to-end installation path
- `CURRENT-LAB-STATE.md`
  - current implemented feature set and expected runtime behavior
- `WEB-UI.md`
  - what the standalone router UI does
- `SHARED-RULES.md`
  - how the shared GitHub-backed destination list works
- `ARCHITECTURE.md`
  - system map and component responsibilities
- `UI-EXTENSIBILITY.md`
  - notes for deeper UI customization work

## For Automation

If you are scripting or automating work in this repo, start here too. The docs are written for humans first, but the structure is also intended to be machine-readable enough to locate:

- where configuration comes from
- which scripts are entrypoints
- which files are templates
- which router-side files are deployed
