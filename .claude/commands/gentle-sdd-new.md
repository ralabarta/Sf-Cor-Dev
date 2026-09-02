---
description: Start a new SDD change — runs exploration then creates a proposal
---

Read the SDD workflow FIRST: `.claude/skills/_shared/sdd-orchestrator-workflow.md` under the workspace when a workspace-scope install wrote it there, otherwise `~/.claude/skills/_shared/sdd-orchestrator-workflow.md`. Then treat it as the authoritative SDD workflow instructions for this command.
The Claude Code session model is controlled by Claude Code; Gentle AI only configures models for Agent tool calls to phase sub-agents.

WORKFLOW:

1. Launch `sdd-explore` to investigate the codebase for this change.
2. Present the exploration summary and immediately offer `sdd-research`.
3. Create or update `gentle-ai.sdd-preproposal/v1`. If research is selected, require it to reach lifecycle `done`, persist through the selected artifact store, read it back, and validate its evidence references. Resolve all product decisions. If any decision remains unresolved, persist the pending state before presenting the complete blocking prompt, then STOP without launching `sdd-propose`.
4. Persist and read back the confirmed pre-proposal state. In `hybrid` mode, both store copies MUST have the same revision and exact bytes.
5. Only when the pre-proposal gate is ready, launch `sdd-propose` with the confirmed handoff: state revision, confirmed decisions, and optional exploration/research evidence references.
6. Present the proposal summary and ask the user if they want to continue with specs and design.

CONTEXT:

- Working directory: Detect agent-side before proceeding by running `git rev-parse --show-toplevel` with the Bash tool; if that fails, run `pwd` with the Bash tool.
- Current project: Derive agent-side from the detected working directory basename. Do not use slash-command shell interpolation for this value.
- Change name: $ARGUMENTS
- Execution mode: ask/cache per orchestrator
- Artifact store mode: ask/cache per orchestrator
- Delivery strategy: ask/cache per orchestrator

ENGRAM NOTE:
Sub-agents handle persistence automatically. Each phase saves its artifact to engram with topic_key "sdd/$ARGUMENTS/{type}".

Use the lazy workflow instructions to coordinate this workflow. Do NOT execute phase work inline when a native sub-agent is available.
