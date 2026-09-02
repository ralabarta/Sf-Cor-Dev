# Sf-Cor-Dev

This source-bearing downstream Stockfish fork accepts only reviewed, immutable inputs and keeps automatic compatibility evidence separate from merge authority.

## Maintainer path

1. **Review the manifests.** Confirm the full official and CorChess SHAs, ordered CorChess deltas, NNUE URL and SHA-256, and the human-owned bench expectation in `manifests/`.
2. **Run local tests and gates.** From a clean committed source tree, prefetch the declared NNUE, build offline, and create a unique evidence run.
3. **Open a pull request for human review.** Require the compatibility check, review its evidence, and apply ordinary protected-branch policy. Passing automation is non-authoritative and never replaces human PR review.
4. **Choose an explicit delivery path.** After review, either run the **Draft development prerelease** workflow for the reviewed full SHA or activate the validated local binary. Neither path is automatic.

```sh
tests/tooling/run.sh
scripts/nnue-prefetch.sh manifests/nnue.json
scripts/build.sh manifests/nnue.json
scripts/validate.sh local-review-1
env gga
```

Use a new `local-review-*` run ID for each validation. Evidence is written under `evidence/<source-sha>/<run-id>/`; missing or failed evidence is a closed gate.

### Review checklist

- [ ] All manifest URLs, full SHAs, and SHA-256 values match the reviewed sources.
- [ ] `tests/tooling/run.sh`, the local compatibility gates, and `env gga` pass.
- [ ] The PR source SHA exactly matches the SHA recorded in compatibility evidence.
- [ ] A human reviewer approves the source and any bench expectation change.
- [ ] Protected-branch requirements pass before merge or delivery.

The compatibility workflow does not merge, approve, push, publish, alter bench expectations, update manifests, write PR state, or grant authority. Scheduling, automatic merge, signing, and attestations are out of scope.

## Local activation and rollback

Activation is optional, user-local, versioned, and unprivileged. Use only a binary whose source and manifest identities match reviewed evidence.

```sh
source_sha=$(git rev-parse HEAD)
manifest_sha=$(sha256sum manifests/corchess-deltas.json | cut -d ' ' -f 1)
scripts/activate.sh "$PWD/build/stockfish" "$source_sha" "$manifest_sha"
scripts/rollback.sh
```

Activation retains the prior version as `previous`. If validation or switching fails, keep the current version and inspect the gate evidence before retrying. To undo repository automation and guidance, revert the compatibility workflow/docs work-unit commit; local activation state can be rolled back independently with `scripts/rollback.sh`.

## Draft prerelease

Run `.github/workflows/prerelease.yml` only with the reviewed full commit SHA, a development tag, and a retained known-good rollback tag. Leave publication disabled while validating the draft evidence; publication remains a separate explicit maintainer action.

The workflow builds Linux and Windows `x86-64-universal` artifacts from the same reviewed SHA, verifies NNUE identity, joins checksums and GPL source provenance, and preserves the configured rollback target. It does not authorize its own merge.

## Tooling baseline

| Tool | Purpose |
| --- | --- |
| Gentle AI | Workspace skills, SDD commands, Context7, permissions, and Engram integration |
| Gentleman Guardian Angel (GGA) | Strict staged-file review through the pre-commit hook |
| Engram | Local project memory with repository-safe identity |
| Codegraph | Local source index and MCP-backed code navigation |
| Graphify | Separate project knowledge graph |

Install the managed workspace configuration, then inspect and reinstall the GGA hook when needed:

```sh
gentle-ai install --scope workspace --agent claude-code --component engram,sdd,skills,context7,persona,permissions
env gga config
env gga install
```

Use `env gga` to bypass shell aliases. Engram data remains local under `.engram/`; only `.engram/config.json` belongs in repository configuration. Receipt-driven development mode is user-controlled and must not be changed without explicit authorization.

Initialize or verify Codegraph from the repository root:

```sh
codegraph init --yes .
codegraph status .
```

Only `.codegraph/.gitignore` belongs in version control. Run `graphify update .` after source changes; generated graph output remains local.

## Diagnostics

```sh
gentle-ai doctor
engram doctor --json
env gga config
```

Global notices about optional tools do not weaken repository tests, compatibility gates, GGA, human review, or protected-branch requirements.
