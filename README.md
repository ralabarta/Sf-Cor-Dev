# Sf-Cor-Dev Baseline

This repository provides a reproducible project baseline for collaboration and automated checks. It intentionally does not select an application stack.

## Tooling baseline

| Tool | Version | Purpose |
| --- | --- | --- |
| Gentle AI | 2.5.0 | Workspace agent, skills, SDD commands, Context7, permissions, and Engram integration |
| Gentleman Guardian Angel (GGA) | 2.10.1 | Strict Claude-backed review of matching staged files through a pre-commit hook |
| Engram | 1.20.0 | Local project memory with a repository-safe project identity |
| Codegraph | 1.6.0 | Local source index and MCP-backed code navigation |

These are the versions verified on this machine. The commands below do not pin or install the global binaries.

## Setup

Install the managed Gentle AI workspace configuration:

```sh
gentle-ai install --scope workspace --agent claude-code --component engram,sdd,skills,context7,persona,permissions
```

Inspect the current GGA configuration and reinstall its pre-commit hook:

```sh
env gga config
env gga install
```

Use `env gga` to bypass shell aliases without relying on an absolute binary path.

Engram memory remains local under `.engram/`. Only `.engram/config.json`, which sets `project_name` to `sf-cor-dev`, belongs in repository configuration. Do not run memory synchronization as part of baseline setup.

### Codegraph

Codegraph v1.6.0 provides a local source index used through its CLI and the configured MCP integration. Initialize and verify the project index from the repository root:

```sh
codegraph init --yes .
codegraph status .
```

Only `.codegraph/.gitignore` belongs in version control. The database, WAL/SHM files, logs, caches, sockets, PID files, and trails remain local and ignored; do not ignore the entire `.codegraph/` directory at the repository root.

Codegraph is the code-navigation index for symbols and relationships. Graphify is the separate project knowledge graph and is not replaced by Codegraph.

## Diagnostics

Run fresh checks before delivery:

```sh
gentle-ai doctor
engram doctor --json
env gga config
```

Known global `gentle-ai doctor` notices about duplicate PATH entries or unavailable optional tools are non-blocking for this workspace baseline.

Receipt-driven development mode is user-controlled and must not be changed without explicit authorization.
