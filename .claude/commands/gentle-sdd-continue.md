---
description: Continue the next SDD phase in the dependency chain
---

Read the SDD workflow FIRST: `.claude/skills/_shared/sdd-orchestrator-workflow.md` under the workspace when a workspace-scope install wrote it there, otherwise `~/.claude/skills/_shared/sdd-orchestrator-workflow.md`. Then treat it as the authoritative SDD workflow instructions for this command.
The Claude Code session model is controlled by Claude Code; Gentle AI only configures models for Agent tool calls to phase sub-agents.

WORKFLOW:

1. If the gentle-ai binary is available, run gentle-ai sdd-continue [change] --cwd <repo> and treat its dispatcher/status output as authoritative for every artifact store. Do not determine or branch on the artifact store yourself; consume artifactStore and the locators returned in artifactPaths. If unavailable, read .claude/skills/_shared/sdd-status-contract.md from the project root and produce structured status before acting.
2. Resolve the active change. If `$ARGUMENTS` is missing and more than one active change exists, ask the user to choose and STOP. Do not guess.
3. Check which artifacts already exist for the active change (proposal, specs, design, tasks)
4. Determine the next phase needed based on the dependency graph:
   proposal → [specs ∥ design] → tasks → apply → verify → archive
5. Launch the appropriate sub-agent(s) for the next phase only if authoritative status says the dependency is ready. Route only by `nextRecommended` and dependency states; never infer from free text. If `blockedReasons` is non-empty, do not proceed to apply, archive, or terminal work. If `nextRecommended` is `verify`, verification/remediation may run only to refresh evidence; if `nextRecommended` is `resolve-blockers`, report `blockedReasons` and stop; if `nextRecommended` is a planning token (`propose`, `spec`, `design`, or `tasks`), launch the corresponding planning phase. Carry `actionContext` and allowed edit roots into any sub-agent launch.
6. Present the result and ask the user to proceed

CONTEXT:

- Working directory: Detect agent-side before proceeding by running `git rev-parse --show-toplevel` with the Bash tool; if that fails, run `pwd` with the Bash tool.
- Current project: Derive agent-side from the detected working directory basename. Do not use slash-command shell interpolation for this value.
- Change name: $ARGUMENTS
- Execution mode: ask/cache per orchestrator
- Artifact store mode: ask/cache per orchestrator
- Delivery strategy: ask/cache per orchestrator

ENGRAM NOTE:
To check which artifacts exist, search: mem_search(query: "sdd/$ARGUMENTS/", project: "{project}") to list all artifacts for this change.
Sub-agents handle persistence automatically with topic_key "sdd/$ARGUMENTS/{type}".

Use the lazy workflow instructions to coordinate this workflow. Do NOT execute phase work inline when a native sub-agent is available.

STATUS CONTRACT:

Prefer gentle-ai sdd-continue [change] --cwd <repo> when available for every artifact store; do not branch on the store or reconstruct status from Engram when native output is available. Otherwise read .claude/skills/_shared/sdd-status-contract.md from the project root and follow it. If status reports workspace-planning with no allowed edit roots, do not launch apply/verify/archive work that would infer repo-local ownership.
