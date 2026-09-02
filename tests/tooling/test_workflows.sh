#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
compatibility_workflow="$workspace_root/.github/workflows/compatibility.yml"
upstream_workflow="$workspace_root/.github/workflows/upstream-intake.yml"
readme="$workspace_root/README.md"
gga="$workspace_root/.gga"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -f "$compatibility_workflow" ] || fail 'compatibility workflow is absent'
[ -f "$upstream_workflow" ] || fail 'upstream intake workflow is absent'
[ -f "$readme" ] || fail 'maintainer documentation is absent'
[ -f "$gga" ] || fail 'GGA configuration is absent'

python3 - "$compatibility_workflow" "$upstream_workflow" "$readme" "$gga" <<'PY'
import pathlib
import re
import sys

import yaml

compatibility_path, upstream_path, readme_path, gga_path = map(pathlib.Path, sys.argv[1:])
workflow_text = compatibility_path.read_text(encoding="utf-8")
upstream_text = upstream_path.read_text(encoding="utf-8")
readme = readme_path.read_text(encoding="utf-8")
gga = gga_path.read_text(encoding="utf-8")
workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)
upstream = yaml.load(upstream_text, Loader=yaml.BaseLoader)

assert set(workflow) == {"name", "on", "permissions", "jobs"}
assert set(workflow["on"]) == {"pull_request", "push"}
assert workflow["on"]["push"] == {"branches": ["main"]}
assert workflow["permissions"] == {}
assert set(workflow["jobs"]) == {"compatibility"}
job = workflow["jobs"]["compatibility"]
assert job["runs-on"] == "ubuntu-24.04"
assert job["permissions"] == {"contents": "read", "models": "read"}
assert job["env"]["SOURCE_SHA"] == "${{ github.event.pull_request.head.sha || github.sha }}"
assert job["env"]["RUN_ID"] == "${{ github.event_name }}-${{ github.run_id }}-${{ github.run_attempt }}"

steps = job["steps"]
checkout = steps[0]
assert checkout["uses"] == "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
assert checkout["with"] == {
    "repository": "${{ github.event.pull_request.head.repo.full_name || github.repository }}",
    "ref": "${{ github.event.pull_request.head.sha || github.sha }}",
    "fetch-depth": "0",
    "persist-credentials": "false",
}
upload = steps[-1]
assert upload["uses"] == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
assert upload["if"] == "always()"
assert upload["with"]["if-no-files-found"] == "warn"
assert upload["with"]["name"] == "compatibility-evidence-${{ env.SOURCE_SHA }}-${{ github.run_id }}-${{ github.run_attempt }}"
assert upload["with"]["path"] == "evidence/${{ env.SOURCE_SHA }}/${{ env.RUN_ID }}"
assert upload["with"]["retention-days"] == "14"

uses = [step["uses"] for step in steps if "uses" in step]
assert uses == [
    "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
]
assert all(re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action) for action in uses)

runs = [step["run"] for step in steps if "run" in step]
assert len(runs) == 5
assert all("${{" not in script for script in runs)
binding, gga_install, gga_review, dependencies, gates = runs
for required in (
    'test "${#SOURCE_SHA}" -eq 40',
    'test "$(git rev-parse HEAD)" = "$SOURCE_SHA"',
):
    assert required in binding
for required in (
    "gentleman-guardian-angel/archive/refs/tags/v2.10.1.tar.gz",
    'sha256sum --check --strict',
    'IFS= read -r version',
    'test "$version" = "gga v$GGA_VERSION"',
):
    assert required in gga_install
assert "c1dbcee120b83238e1c7ecce4a60f88a66810796ad95a239debc09e8509d0fba" in workflow_text
assert "env gga run --ci" in gga_review
assert "GGA_PROVIDER" in workflow_text and "github:gpt-4.1" in workflow_text
for required in (
    "sudo apt-get update",
    "sudo apt-get install --no-install-recommends --yes expect ripgrep",
):
    assert required in dependencies
for required in (
    "scripts/nnue-prefetch.sh manifests/nnue.json",
    "scripts/build.sh manifests/nnue.json",
    'scripts/validate.sh "$RUN_ID"',
    'summary["authority"] == "none"',
    'summary["merge_authorized"] is False',
    'provenance["source_sha"] == os.environ["SOURCE_SHA"]',
):
    assert required in gates

for forbidden in (
    "continue-on-error",
    "pull_request_target",
    "workflow_dispatch",
    "schedule:",
    "contents: write",
    "pull-requests: write",
    "checks: write",
    "statuses: write",
    "git push",
    "gh pr",
    "gh release",
    "auto-merge",
    "--amend",
    "manifests/bench.json >",
    "manifests/bench.json\n",
    "|| true",
):
    assert forbidden not in workflow_text
assert "human review remains mandatory" in workflow_text.lower()
assert "non-authoritative" in workflow_text.lower()

assert set(upstream) == {"name", "on", "permissions", "jobs"}
assert upstream["on"] == {"schedule": [{"cron": "*/15 * * * *"}], "workflow_dispatch": ""}
assert upstream["permissions"] == {}
assert set(upstream["jobs"]) == {"observe"}
observe = upstream["jobs"]["observe"]
assert observe["runs-on"] == "ubuntu-24.04"
assert observe["permissions"] == {"contents": "read"}
observe_steps = observe["steps"]
assert observe_steps[0]["uses"] == "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
assert observe_steps[0]["with"] == {"persist-credentials": "false"}
observe_runs = [step["run"] for step in observe_steps if "run" in step]
assert len(observe_runs) == 1
observer = observe_runs[0]
for required in (
    "scripts/discover.sh manifests/upstreams.json",
    '"refs/heads/master"',
    '"refs/heads/corchess"',
    'status == "unchanged"',
    "$GITHUB_STEP_SUMMARY",
    "raise SystemExit(1)",
):
    assert required in upstream_text or required in observer
for forbidden in (
    "scripts/intake.sh",
    ">manifests/corchess-deltas.json",
    ">manifests/upstreams.json",
    "git push",
    "gh pr",
    "contents: write",
    "pull-requests: write",
):
    assert forbidden not in upstream_text

headings = [line.strip() for line in readme.splitlines() if line.startswith("## ")]
assert headings[0] == "## How it works"
ordered = [
    "## Upstream sources",
    "## Build and validation",
    "## Native local updates",
    "## Linux and Windows x64 prereleases",
    "## GitHub delivery workflow",
]
positions = [readme.index(item) for item in ordered]
assert positions == sorted(positions)
for required in (
    "tests/tooling/run.sh",
    "scripts/nnue-prefetch.sh manifests/nnue.json",
    "scripts/build.sh manifests/nnue.json",
    "scripts/validate.sh",
    "env gga",
    "scripts/activate.sh",
    "scripts/rollback.sh",
    "scripts/update-local.sh",
    "refs/heads/corchess",
    "issue #1",
    "Human review remains mandatory",
    "does not grant merge or release authority",
    "Automatic merge, signing, attestations, and autonomous release selection are out of scope",
):
    assert required in readme

patterns = re.search(r'^FILE_PATTERNS="([^"]+)"$', gga, re.MULTILINE).group(1).split(",")
for required in ("*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "Makefile", "*.sh", "*.yml", ".gga"):
    assert required in patterns
exclusions = re.search(r'^EXCLUDE_PATTERNS="([^"]+)"$', gga, re.MULTILINE).group(1).split(",")
for required in ("build/*", "evidence/*", "graphify-out/*", "src/incbin/*", ".github/ci/*"):
    assert required in exclusions
assert 'STRICT_MODE="true"' in gga
assert 'RULES_FILE="AGENTS.md"' in gga
PY

printf '%s\n' 'workflow tests passed'
