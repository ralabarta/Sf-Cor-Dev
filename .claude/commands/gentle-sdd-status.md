---
description: Show structured SDD status for an active change
---

Show structured SDD status for an active change. This command is read-only: do not launch SDD executors and do not edit files.

HARD GATE:

SDD Session Preflight must already be complete for this session. It must include execution mode, artifact store, chained PR strategy, and review budget. If missing, ask the exact orchestrator preflight prompt and STOP. Do not inspect status in the same turn.

CONTEXT:

- Working directory: Detect agent-side before proceeding by running `git rev-parse --show-toplevel` with the Bash tool; if that fails, run `pwd` with the Bash tool.
- Current project: Derive agent-side from the detected working directory basename. Do not use slash-command shell interpolation for this value.
- Change name: $ARGUMENTS

TASK:

1. If the `gentle-ai` binary is available, run `gentle-ai sdd-status [change] --cwd <repo> --json --instructions`. Treat the returned JSON as authoritative for every artifact store, including `engram`, `openspec`, and `hybrid`. Do not branch on the store or reconstruct status from Engram when native JSON is available.
2. If the binary is unavailable, read `.claude/skills/_shared/sdd-status-contract.md` from the project root and reconstruct only the read-only status shape it defines.
3. Resolve the active change from authoritative status:
   - If `$ARGUMENTS` is provided, report the result for that exact change.
   - If omitted and status selects exactly one active change, report how it was selected.
   - If omitted or ambiguous with multiple active changes, report `nextRecommended: select-change`, explain the ambiguity, and STOP. Do not guess.
4. Return structured status with:
   - Active change selection and schemaName.
   - planningHome, changeRoot, artifactPaths, and contextFiles.
   - Artifact statuses for proposal, specs, design, tasks, apply-progress, and verify-report.
   - Task progress: total, completed, pending, and allComplete.
   - Dependency states for proposal, specs, design, tasks, apply, verify, and archive.
   - `nextRecommended` as a reported value only.
   - `blockedReasons` whenever non-empty.
   - actionContext mode, workspace root, and allowed edit roots.

READ-ONLY RULES:

- Do not create, update, or delete artifacts.
- Do not mark tasks complete.
- Do not launch any SDD executor, continuation, or phase.
- Never launch `propose`, `spec`, `design`, `tasks`, `apply`, `verify`, `remediate`, or `archive`, regardless of `nextRecommended`.
- Do not infer routing from free text. Report `nextRecommended`, dependency states, and `blockedReasons` without acting on them.
- If status cannot be resolved safely, return `status: blocked` with the missing information.
