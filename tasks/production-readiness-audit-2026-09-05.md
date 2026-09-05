# Production Readiness Audit — 2026-09-05

> **Scope:** repository state at commit `7d1eeb24cb00b0faa2821d7c52cf16fd7e8b2096`
> **Overall assessment:** **READY WITH CONDITIONS**
> **Confidence:** Medium-high

## 1. Executive Summary

Sf-Cor-Dev is reasonably prepared to operate as a local UCI engine under human control. Its public release pipeline should not yet be considered fully autonomous, recoverable, or cross-platform verified.

Isolated validation confirmed:

- 10 operational suites: **PASS**
- `scripts/validate.sh`: **PASS**
- GCC `analyze` build: **PASS**
- UBSan and UCI smoke: **PASS**
- shell syntax and JSON/YAML parsing: **PASS**

After adversarial review, no Critical or High findings remained:

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 7 |
| Low | 9 |
| Info | 1 |

### Key strengths

- Isolated build from `git archive HEAD`.
- NNUE integrity through HTTPS and a full SHA-256 hash.
- GitHub Actions pinned by SHA.
- Minimal CI permissions.
- Versioned, locked local activation with rollback.
- Fail-closed and explicitly non-authoritative evidence.
- Good negative coverage of operational scripts.

### Key risks

1. Gates that may incorrectly report success.
2. Windows releases without execution testing.
3. Critical suites excluded from required CI.
4. Git operations and releases vulnerable to concurrency or partial failures.
5. Mutable SDD artifacts consumed by a phase with write authority.

## 2. System Map

### Product

**VERIFIED:** local C++ executable compatible with UCI, derived from Stockfish and integrated with CorChess deltas.

Main entry point and execution flow:

- `src/main.cpp:39-50`
- `main → UCIEngine::loop → Engine::go → ThreadPool::start_thinking → Search::Worker::start_searching`

Composition root:

- `src/engine.h:33-44`
- `src/engine.h:121-136`

### Operational plane

```text
Git upstreams
    │
    ▼
discover.sh
    │
prepare-candidate.sh
    │
intake.sh ──► reviewed manifests
    │
    ▼
nnue-prefetch.sh
    │
build.sh
    │
validate.sh
    │
update-local.sh
    │
activate.sh / rollback.sh
    │
    ▼
Local UCI executable
```

### CI/CD

- `compatibility.yml`: build and primary gates.
- `upstream-intake.yml`: detection and preparation of upstream changes.
- `prerelease.yml`: Linux/Windows builds, join, publication, and pruning.

### Persistence

There is no database or remote application storage.

Relevant persistence consists of:

- versioned manifests;
- NNUE cache;
- local version directories;
- `current` and `previous` symlinks;
- validation evidence;
- GitHub releases;
- Engram memory and SDD artifacts.

### Trust boundaries

1. Git/NNUE upstreams → local scripts.
2. PR/fork → read-only GitHub Actions.
3. Protected `main` → publication job with `contents: write`.
4. Worktree → destructive Git scripts.
5. Build/evidence → local activation.
6. Web, MCP, repository, and memory → agent context.
7. Probabilistic model → `Edit`, `Write`, `Bash`, and other tools.

### Non-applicable infrastructure

There is no evidence of:

- HTTP service;
- database;
- Kubernetes;
- cloud runtime;
- queues;
- multi-tenancy;
- distributed high availability.

Requiring autoscaling, database backups, distributed tracing, or multi-region deployment would not be appropriate.

## 3. Architecture Assessment

The actual architecture has two clearly differentiated subsystems:

1. C++ UCI engine.
2. Shell/Git/GitHub Actions control plane.

The separation is pragmatic and appropriate. There is no evidence justifying microservices, DDD, CQRS, or a rewrite.

### Strengths

- CorChess deltas are limited and bound to declared blobs.
- The build does not consume untracked files from the worktree.
- Common guards centralize validation of hashes, paths, and repository state.
- Activation and rollback are separated from build and validation.
- Workflows reduce authority by job.

### Primary debt

**INFERRED:** the architecture protects static identities well, but temporal transitions less effectively.

This explains several findings:

- cleanliness checked too early;
- gates reading live files;
- unserialized multi-step operations;
- memory artifacts without immutable binding.

The correct improvement is not to add layers. Existing boundaries should use snapshots, compare-and-swap, and immutable identities.

## 4. AI Agent & Harness Assessment

### Authority

**VERIFIED:** `sdd-apply` has edit, write, and shell capabilities. The research and explore phases can consume external content and persist results.

### Positive controls

- Explicit instructions for consent and separation between exploration, proposal, and application.
- `allowedEditRoots` limits the scope of some phases.
- RDD is opt-in.
- Contracts attempt to preserve lineage, state, and authority.
- Instructions acknowledge that prompts and guardrails are not security boundaries.

### Memory

Engram allows observations to be updated under stable locators. A later phase can retrieve changed content without requiring a previously admitted digest.

### Prompt injection

There is a conceptual path:

```text
web/MCP/repository
    → research/explore
    → persisted artifact
    → apply with Write/Edit/Bash
```

**NOT VERIFIED:** it was not demonstrated that an injection can survive current controls and cause a privileged operation. This should be treated as an evaluation gap, not as a confirmed vulnerability.

### Harness supply chain

- `.mcp.json` uses `npx -y`.
- Some executables are resolved through `PATH`.
- Hooks can hide failures through `|| true`.

The risk is Low because it requires compromise of the environment, registry, cache, or PATH. Execution is not, however, fully reproducible.

### Evals

There is no executable local corpus that tests:

- memory poisoning;
- artifact substitution;
- writing outside locators;
- indirect prompt injection;
- malformed outputs;
- consent preservation.

## 5. Security Assessment

### Threat model

Assets:

- `main` branch;
- reviewed manifests;
- published artifacts;
- publication GitHub token;
- activated binary;
- user's local files;
- environment secrets;
- persistent memory and human decisions.

Attack surfaces:

- Git and shell;
- upstream downloads;
- GitHub Actions;
- MCP and hooks;
- paths configurable through UCI;
- persistent agent memory.

### Result

The following were not found:

- authentication bypass;
- remote privilege escalation;
- demonstrated RCE;
- confirmed committed secret;
- demonstrated exfiltration;
- direct CI compromise.

Current Actions are pinned by SHA and use reduced permissions. The greatest confirmed security risk concerns internal integrity and confused-deputy behavior, not a remotely exploitable High vulnerability.

## 6. Infrastructure & Operations Assessment

### Status

**READY WITH CONDITIONS** for assisted local operation.

### Strengths

- Strict `main` check, required approval, stale-review dismissal, and enforcement for administrators.
- Force-push and branch deletion disabled.
- Only the publication job receives `contents: write`.
- The draft release is validated before publication.
- Local rollback with checksum verification.
- Builds separated by platform.

### Limitations

- Windows produces an artifact without executing it.
- Publication and pruning form a non-atomic transaction.
- There is no `concurrency` group for releases.
- Specific timeouts are missing.
- Checksums prove integrity, not authenticity.
- Toolchains and runners are not hermetic.
- There is no byte-for-byte reproducibility test.

### Backups and disaster recovery

There is no persistent application data to back up. The operational equivalent is retaining a usable release and a previous local version.

**VERIFIED:** the restore flow downloads and verifies the assets when run.

**NOT VERIFIED:** a recent actual restoration from a published release.

## 7. Code Quality & Maintainability Assessment

Overall code quality is good. No new god objects, relevant circular dependencies, or speculative abstractions that block maintenance were identified.

The most fragile points are:

- `scripts/intake.sh`
- `scripts/validate.sh`
- `scripts/activate.sh`
- `.github/workflows/prerelease.yml`

These files implement operational transactions through shell and Git. Their complexity is partly driven by the domain, but intermediate states are not always formalized.

The C++ code passed compilation with analysis and a UBSan smoke test. No defect was demonstrated in the current CorChess delta.

## 8. Testing Assessment

The operational suite has good value: it tests failures, symlinks, locks, hashes, paths with spaces, activation, and rollback. Required CI does not run all of that evidence.

| Area | Current coverage | Confidence |
|---|---|---|
| Operational scripts | Broad locally | High |
| Ubuntu x64 build | Executed | High |
| UCI smoke | Executed | High |
| UBSan | Smoke executed | Medium-high |
| Windows runtime | Absent | Low |
| Multithreading | Limited | Medium-low |
| Release concurrency | Absent | Low |
| Agent evals | Absent | Low |
| Binary reproducibility | Absent | Low |

### Bugs that could exist even if all tests pass

1. `reprosearch` obtains no samples and still returns success.
2. The published `.exe` does not start on Windows.
3. A concurrent edit is deleted by `intake.sh`.
4. Validation and activation use different contents from a manifest.
5. Two concurrent publications break retention.
6. Search works with one thread but diverges or degrades with several.
7. A workflow preserves the expected strings but has an invalid DAG.
8. An Engram artifact changes between status and apply.
9. An indirect injection conditions a privileged phase.
10. A binary is not reproducible even though the source SHA and package metadata match.

## 9. Documentation Assessment

The README is generally clear about integration, validation, security, activation, rollback, releases, and limitations.

Confirmed contradiction:

- `README.md:249`
- `README.md:288`
- `README.md:337`

These sections state that the first prerelease cannot be published, while `scripts/release-evidence.sh:253-260` supports an initial publication without a previous rollback release.

**Classification:** mostly correct, with one localized operational contradiction.

## 10. Findings

### AUD-001 — Intake can destroy concurrent edits

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** Correctness / Git safety

**Evidence:** `scripts/intake.sh:16-17`, `scripts/intake.sh:390-402`, `scripts/lib/guards.sh:83-105`.

**Problem:** cleanliness is checked before lengthy operations; `read-tree --reset -u` and `reset --hard` are subsequently executed.

**Impact:** loss of local tracked changes.

**Failure scenario:** another editor modifies the worktree after preflight and before publication or rollback.

**Root cause:** the state check and the destructive mutation are separated in time.

**Recommendation:** revalidate `HEAD`, index, and worktree immediately before mutation, and avoid destructive rollback on divergent state.

**Proposed validation:** inject a concurrent edit immediately before publication and rollback.

**Estimated effort:** M.

### AUD-002 — Validation and activation can use different snapshots

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** Correctness / Provenance

**Evidence:** `scripts/validate.sh:26-38`, `scripts/validate.sh:157-165`, `scripts/validate.sh:262-266`, `scripts/update-local.sh:23-41`.

**Problem:** gates read live files and `update-local.sh` only rechecks `HEAD`.

**Impact:** evidence and activation can become bound to different content.

**Failure scenario:** a manifest changes during bench or reprosearch without changing `HEAD`.

**Root cause:** absence of an immutable snapshot or complete final revalidation.

**Recommendation:** validate from a snapshot and compare final digests before activation.

**Proposed validation:** mutate a manifest between gates and require an abort without activation.

**Estimated effort:** M.

### AUD-003 — Windows is published without execution testing

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** Release / Cross-platform

**Evidence:** `.github/workflows/prerelease.yml:123-152`.

**Problem:** the Windows job builds, copies, and packages the executable, but never runs `Sf-Cor-Dev.exe`.

**Impact:** a binary that does not start or respond to UCI can be published.

**Failure scenario:** an incorrect runtime dependency, CPU baseline, or NNUE load does not affect the linker.

**Root cause:** build/package success is equated with runtime readiness.

**Recommendation:** run `uci`, `isready`, and a smoke test from the extracted artifact.

**Proposed validation:** a fixture with an invalid executable must block publication.

**Estimated effort:** S.

### AUD-004 — Required CI omits critical suites

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** CI / Testing

**Evidence:** `.github/workflows/compatibility.yml:32-57`, `tests/tooling/run.sh:9-24`, `tests/tooling/suites.list:1-10`.

**Problem:** `compatibility` does not run `tests/tooling/run.sh` or `tests/instrumented.py`.

**Impact:** regressions in intake, activation, rollback, release, or UCI can enter while the required check is green.

**Failure scenario:** a PR breaks an operational suite not included in CI.

**Root cause:** tests with preventive value remain a manual checklist.

**Recommendation:** add separate required jobs instead of hiding them inside a monolithic gate.

**Proposed validation:** mutants that fail exclusively in each omitted suite must block the PR.

**Estimated effort:** M.

### AUD-005 — `reprosearch` can produce a false PASS

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** Testing / False positive

**Evidence:** `tests/reprosearch.sh:9`, `tests/reprosearch.sh:16-17`, `tests/reprosearch.sh:48-61`.

**Problem:** without `pipefail`, an `expect` failure can become empty input for a successful `awk` process.

**Impact:** incorrect reproducibility evidence.

**Failure scenario:** the engine terminates prematurely or `expect` fails; no samples are obtained and the script prints `OK`.

**Root cause:** the parity of found samples is validated, but neither their existence nor the producer's exit code is validated.

**Recommendation:** capture the status and output of `expect` separately and require the expected number of samples.

**Proposed validation:** fixtures for timeout, empty output, engine failure, and odd count.

**Estimated effort:** XS-S.

### AUD-006 — Publication and pruning are neither idempotent nor serialized

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** CI/CD / Recovery

**Evidence:** `.github/workflows/prerelease.yml:212-260`, `.github/workflows/prerelease.yml:271-310`.

**Problem:** there is no mutual exclusion or reconciliation of a partial publication.

**Impact:** a failed workflow can leave a public release, divergent retention, and a retry blocked by an existing tag.

**Failure scenario:** publication completes successfully and pruning fails, or two manual dispatches overlap.

**Root cause:** a multi-operation transaction without a checkpoint or convergence.

**Recommendation:** add `concurrency`, reconcile tag/assets, and decouple pruning from publication.

**Proposed validation:** overlap two publications and repeat after each mutation boundary.

**Estimated effort:** M.

### AUD-007 — Engram artifacts are not bound to an immutable revision

**Severity:** Medium
**Confidence:** High
**Status:** VERIFIED
**Category:** Agent / Memory integrity

**Evidence:** `.claude/skills/_shared/sdd-phase-common.md:19-37`, `.claude/skills/_shared/engram-convention.md:138-140`, `.claude/skills/sdd-apply/SKILL.md:45-63`.

**Problem:** a locator can retrieve updated content without requiring a previously admitted digest or revision.

**Impact:** `apply`, with write and shell authority, can execute tasks different from those reviewed.

**Failure scenario:** tasks change between status and retrieval while retaining the same locator.

**Root cause:** stable logical identity without cryptographic binding to the content.

**Recommendation:** bind the observation ID, revision, and digest admitted by status.

**Proposed validation:** replace tasks after status and require rejection before any write.

**Estimated effort:** M-L.

### AUD-008 — A signal during activation can leave `current` dangling

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Recovery

**Evidence:** `scripts/activate.sh:119-145`, `scripts/activate.sh:230-243`, `scripts/activate.sh:273-274`.

**Problem:** cleanup can delete the new version after renaming `current` but before recording success.

**Impact:** the active engine remains unusable until manual recovery.

**Failure scenario:** `TERM` arrives during that window.

**Root cause:** the logical commit and cleanup state are not atomic.

**Recommendation:** retain the target before the final rename or restore links during cleanup.

**Proposed validation:** inject signals at each rename boundary.

**Estimated effort:** S-M.

### AUD-009 — Operational timeouts are incomplete

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Resilience

**Evidence:** `scripts/nnue-prefetch.sh:112-116`, `scripts/release-evidence.sh:302-305`; workflows without `timeout-minutes`.

**Problem:** several commands rely solely on global environment timeouts.

**Impact:** jobs or gates can remain blocked for extended periods.

**Failure scenario:** the engine, a download, or `gh` does not respond.

**Root cause:** absence of local deadlines.

**Recommendation:** add timeouts per job and command; retry only idempotent operations.

**Proposed validation:** fixtures that never respond.

**Estimated effort:** S.

### AUD-010 — Semantic validation of manifests is uneven

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Contracts

**Evidence:** `scripts/validate.sh:41-78`.

**Problem:** `bench.json` receives strong validation while other manifests receive parsing or partial validation.

**Impact:** compatibility can produce evidence for valid JSON with inconsistent semantics.

**Failure scenario:** inconsistent upstream or delta fields do not affect the current build.

**Root cause:** duplicated and distributed validators.

**Recommendation:** reuse a single canonical offline validator.

**Proposed validation:** negative cases with invalid SHA, paths, refs, and review states.

**Estimated effort:** S-M.

### AUD-011 — MCP and hook execution uses dynamic resolution

**Severity:** Low
**Confidence:** Medium
**Status:** VERIFIED
**Category:** Supply chain / Agent

**Evidence:** `.mcp.json:3-18`, `.claude/settings.json:3-9`.

**Problem:** `npx -y` and lookup through PATH do not bind execution to a reproducible binary identity.

**Impact:** a compromised registry, cache, or PATH could execute code with the user's permissions.

**Failure scenario:** local shadowing or an altered transitive dependency.

**Root cause:** logical versions without installation provenance.

**Recommendation:** use verified wrappers, lock/integrity, and version/hash checks.

**Proposed validation:** reject a decoy binary in PATH and verify reproducible offline startup.

**Estimated effort:** S-M.

### AUD-012 — Release provenance does not authenticate the builder

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Supply chain

**Evidence:** `.github/workflows/prerelease.yml:66-97`, `.github/workflows/prerelease.yml:108-152`.

**Problem:** toolchains and runners are not fully pinned; checksums are generated in the same environment that builds.

**Impact:** a compromised builder can produce a consistent binary and checksum.

**Failure scenario:** a mutable compiler package is compromised.

**Root cause:** self-contained integrity without external attestation.

**Recommendation:** record the exact toolchain and issue verifiable attestations.

**Proposed validation:** verify the attestation from a clean machine.

**Estimated effort:** M.

### AUD-013 — Relevant pthread errors are ignored

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** C++ / Error handling

**Evidence:** `src/thread_native.h:90-112`, `src/thread_native.h:140-145`.

**Problem:** return values from `pthread_attr_*` and join are not always checked.

**Impact:** opaque thread failure or a smaller stack than expected.

**Failure scenario:** a platform or resource limit rejects the requested attribute.

**Root cause:** only part of the thread lifecycle propagates errors.

**Recommendation:** check and propagate all relevant return values.

**Proposed validation:** wrappers that inject pthread error codes.

**Estimated effort:** S.

### AUD-014 — Generated artifacts are not ignored

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Repository hygiene

**Evidence:** `.gitignore:1-52`; `git status` showed `build/`, `evidence/`, and `graphify-out/`.

**Problem:** operational outputs can be added accidentally.

**Impact:** binaries, logs, or generated noise can enter commits.

**Failure scenario:** use of `git add .`.

**Root cause:** the documented boundary is not enforced by Git.

**Recommendation:** ignore generated directories that should not be versioned.

**Proposed validation:** generate them and require a clean status.

**Estimated effort:** XS.

### AUD-015 — Prerelease bootstrap documentation is outdated

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Documentation

**Evidence:** `README.md:249`, `README.md:288`, `README.md:337`, versus `scripts/release-evidence.sh:253-260`.

**Problem:** the README contradicts current behavior.

**Impact:** an operator can become blocked or follow an unnecessary procedure.

**Failure scenario:** a legitimate initial publication.

**Root cause:** the documentation predates bootstrap support.

**Recommendation:** update the affected sections.

**Proposed validation:** contractual review against the current planner.

**Estimated effort:** XS.

### AUD-016 — The legacy downloader disables strict TLS

**Severity:** Low
**Confidence:** High
**Status:** VERIFIED
**Category:** Download integrity

**Evidence:** `scripts/net.sh:3-25`, `scripts/net.sh:51-60`.

**Problem:** the curl fallback uses `-k` and a short hash prefix; without a hashing tool it can accept any file.

**Impact:** a direct or legacy build can consume an untrusted NNUE file.

**Failure scenario:** a hostile network during a build that omits `nnue-prefetch.sh`.

**Root cause:** a legacy upstream helper provides weaker guarantees than the maintained flow.

**Recommendation:** remove `-k` and require a manifest with a full SHA-256 hash.

**Proposed validation:** reject an invalid certificate and a payload with a valid name but an incorrect hash.

**Estimated effort:** S.

### AUD-017 — No local agent evals exist

**Severity:** Info
**Confidence:** High
**Status:** VERIFIED
**Category:** Agent testing

**Evidence:** agents exist under `.claude/agents/`, but there is no local corpus of behavioral journeys or associated CI.

**Problem:** contract and authority regressions have no automated detection.

**Impact:** incorrect agent behavior can remain invisible.

**Failure scenario:** altered locator, malformed output, or omitted consent.

**Root cause:** static rules without behavioral evaluation.

**Recommendation:** add a small risk-driven corpus.

**Proposed validation:** journeys for the happy path, blocking, rejection, poisoning, and recovery.

**Estimated effort:** M.

## 11. Systemic Root Causes

1. Operational transactions are represented as shell sequences without a single logical commit.
2. File identity is strong, but temporal binding between stages is incomplete.
3. Valuable local evidence exists but is not required by CI.
4. The release pipeline prioritizes package integrity over execution of the final artifact.
5. Agent memory is mutable without an admitted content identity.
6. Recovery and concurrency are less thoroughly tested than happy paths and deterministic failures.

## 12. Prioritized Remediation Plan

### P0 — Immediately

There are no demonstrated Critical risks.

### P1 — Next

1. Fix the false PASS in `reprosearch`.
   - Benefit: restores confidence in a central gate.
   - Effort: XS-S.
   - Dependencies: none.
2. Add tooling tests to required CI.
   - Benefit: turns existing evidence into prevention.
   - Effort: M.
   - Dependency: CI budget.
3. Run a real smoke test of the Windows artifact.
   - Benefit: avoids publishing unusable binaries.
   - Effort: S.
4. Revalidate the worktree immediately before Git mutations.
   - Benefit: prevents loss of work.
   - Effort: M.
5. Use a single snapshot between validate and activate.
   - Benefit: guarantees consistent provenance.
   - Effort: M.
6. Serialize publication and make it resumable.
   - Benefit: deterministic recovery.
   - Effort: M.
7. Bind Engram artifacts to ID, revision, and digest.
   - Benefit: protects apply authority.
   - Effort: M-L.

### P2 — Planned

- Local timeouts.
- Canonical manifest validators.
- Complete pthread error handling.
- Release attestations.
- Fault injection for signals and concurrency.
- Removal or hardening of `net.sh`.

### P3 — Opportunistic

- Ignore generated outputs.
- Correct the bootstrap documentation.
- Add agent evals.
- Evaluate byte-for-byte reproducibility only if it becomes a public guarantee.

## 13. Quick Wins

1. Fix `tests/reprosearch.sh`.
2. Add a `uci`/`isready` smoke test on Windows.
3. Add `concurrency` to the prerelease workflow.
4. Add `timeout-minutes`.
5. Ignore `build/`, `evidence/`, and `graphify-out/`.
6. Update the bootstrap documentation.
7. Remove `curl -k`.

## 14. Do NOT Do

- Do not rewrite the engine.
- Do not migrate the scripts to another language without a demonstrated need.
- Do not introduce microservices.
- Do not adopt Kubernetes.
- Do not add a database to manage releases.
- Do not replace the entire CI/CD chain.
- Do not turn every script into a generic abstraction.
- Do not block delivery due to lack of byte-for-byte reproducibility while it is not a declared guarantee.
- Do not consider prompts a replacement for technical isolation.
- Do not optimize for coverage percentage instead of failure scenarios.

## 15. Verification Matrix

| Area | Status | Evidence | Confidence |
|---|---|---|---|
| Architecture | VERIFIED | Graphify and current source | High |
| C++ code | Partially VERIFIED | GCC analyze, UBSan smoke | Medium-high |
| Agent | Partially VERIFIED | `.claude/agents`, skills | Medium |
| Harness | Partially VERIFIED | MCP, hooks, contracts | Medium |
| Security | Partially VERIFIED | Threat model and source | Medium-high |
| Infrastructure | NOT VERIFIED / not applicable | No IaC or cloud runtime | High |
| CI/CD | VERIFIED | Workflows and branch state | High |
| Tests | Partially VERIFIED | Tooling and validate executed | High |
| Observability | Partially VERIFIED | Logs and Actions evidence | Medium |
| Backups | Not applicable | No persistent application data | High |
| Restore | Not fully VERIFIED | Logic inspected; no actual restore | Medium |
| Documentation | VERIFIED | README compared with implementation | High |
| Windows runtime | NOT VERIFIED | Build/package only | High |
| Reproducibility | NOT VERIFIED | No double build | High |
| Agent injection | NOT VERIFIED | Plausible path without eval | Low-medium |

## 16. Commands & Evidence

The following checks were run in an isolated temporary copy:

| Exact invocation | Result |
|---|---|
| `git ls-files '*.sh' \| xargs -n1 sh -n` | PASS, exit 0, 33 scripts |
| `python3 -c 'import json, pathlib, subprocess; [json.loads(pathlib.Path(p).read_text()) for p in subprocess.check_output(["git", "ls-files", "*.json"], text=True).splitlines()]'` | PASS, exit 0, 10 files |
| `python3 -c 'import pathlib, subprocess, yaml; [yaml.safe_load(pathlib.Path(p).read_text()) for p in subprocess.check_output(["git", "ls-files", "*.yml", "*.yaml"], text=True).splitlines()]'` | PASS, exit 0, 7 files |
| `tests/tooling/run.sh` | PASS, exit 0, 10 suites |
| `scripts/validate.sh` | PASS, exit 0 |
| `make -C src -j2 build ARCH=x86-64 analyze=yes` | PASS, exit 0 |
| `make -C src -j2 build ARCH=x86-64 sanitize=undefined` followed by UCI, `isready`, perft, and search smoke commands | PASS, exit 0; no UBSan runtime error |
| `git ls-files '*.sh' \| xargs shellcheck` | Exit 1, 57 warning/info/style diagnostics |
| `git diff --check` | PASS, exit 0 |
| MCP `codegraph_explore` over intake, validation, activation, CI, release, and SDD artifact bindings | Completed; current source verified |
| `graphify query "Reconstruct the actual system: purpose, entrypoints, critical modules, agents or harness, privileged scripts, CI/CD, dependencies, trust boundaries, build-release flow, and security-critical paths" --budget 3000` | Completed over 3,392 nodes; used only as an index |
| `env gga run --no-cache` | PASS, exit 0, final staged-document review |

The UBSan smoke test verified:

- UCI;
- `isready`;
- perft;
- search with `bestmove`;
- absence of `runtime error` output.

The state of the original repository remained unchanged during the audit:

```text
 M tasks/lessons.md
?? build/
?? evidence/
?? graphify-out/
?? openspec/changes/
```

## 17. Audit Gaps

The audit could not validate:

- actual execution of the Windows artifact;
- `tests/instrumented.py`, because it downloads Syzygy data;
- ASan and TSan;
- Valgrind;
- actionlint;
- CodeQL, Semgrep, Trivy, Grype, OSV, Syft, and gitleaks;
- fault injection during activation signals;
- concurrent edits during intake or validation;
- two actual concurrent publications;
- a recent restoration from GitHub Releases;
- byte-for-byte reproducibility;
- chess strength and statistical performance;
- broad multi-thread/NUMA behavior;
- prompt injection and memory poisoning through evals;
- deployed configuration outside the repository.

The Graphify graph was two merges behind `HEAD` and included unversioned material. It was therefore used only as an index; conclusions were verified against the current source.

## 18. Final Verdict

1. **Is it production-ready?**
   **READY WITH CONDITIONS** for assisted local operation. It is not ready for unattended releases until P1 is resolved.
2. **What is the greatest technical risk?**
   Gates or pipelines that report success without demonstrating the behavior of the final artifact.
3. **What is the greatest security risk?**
   Integrity of local operations and the harness supply chain; no remote High vulnerability was demonstrated.
4. **What is the greatest agent-specific risk?**
   Mutable Engram artifacts consumed by a phase with `Edit`, `Write`, and `Bash` authority.
5. **What is the greatest operational risk?**
   Non-idempotent publication and potential loss of concurrent edits during intake.
6. **What is the most important architectural debt?**
   Lack of snapshots and logical commits at multi-stage boundaries.
7. **What should be fixed first with one day available?**
   Reprosearch, Windows smoke, concurrency, timeouts, `.gitignore`, and README.
8. **What should be fixed first with one week available?**
   Complete required CI, validate/activate snapshot, intake safety, resumable publication, and immutable Engram binding.
9. **What should not be changed yet?**
   Engine, language, general architecture, manifest model, and local executable strategy.
10. **What additional evidence would increase confidence the most?**
    Windows runtime, instrumented tests in CI, concurrent fault injection, actual restore, TSan, and adversarial agent evals.
