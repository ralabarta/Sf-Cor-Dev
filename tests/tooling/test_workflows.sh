#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
workflow="$workspace_root/.github/workflows/compatibility.yml"
readme="$workspace_root/README.md"
gga="$workspace_root/.gga"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -f "$workflow" ] || fail 'compatibility workflow is absent'
[ -f "$readme" ] || fail 'maintainer documentation is absent'
[ -f "$gga" ] || fail 'GGA configuration is absent'

python3 - "$workflow" "$readme" "$gga" <<'PY'
import pathlib
import re
import sys

import yaml

workflow_path, readme_path, gga_path = map(pathlib.Path, sys.argv[1:])
workflow_text = workflow_path.read_text(encoding="utf-8")
readme = readme_path.read_text(encoding="utf-8")
gga = gga_path.read_text(encoding="utf-8")
workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)

assert set(workflow) == {"name", "on", "permissions", "jobs"}
assert set(workflow["on"]) == {"pull_request"}
assert workflow["permissions"] == {}
assert set(workflow["jobs"]) == {"compatibility"}
job = workflow["jobs"]["compatibility"]
assert job["runs-on"] == "ubuntu-24.04"
assert job["permissions"] == {"contents": "read"}
assert job["env"]["SOURCE_SHA"] == "${{ github.event.pull_request.head.sha }}"
assert job["env"]["PR_NUMBER"] == "${{ github.event.number }}"
assert job["env"]["RUN_ID"] == "pr-${{ github.event.number }}-${{ github.run_id }}-${{ github.run_attempt }}"

steps = job["steps"]
checkout = steps[0]
assert checkout["uses"] == "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
assert checkout["with"] == {
    "repository": "${{ github.event.pull_request.head.repo.full_name }}",
    "ref": "${{ github.event.pull_request.head.sha }}",
    "persist-credentials": "false",
}
upload = steps[-1]
assert upload["uses"] == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
assert upload["if"] == "always()"
assert upload["with"]["if-no-files-found"] == "error"
assert upload["with"]["path"] == "evidence/${{ env.SOURCE_SHA }}/${{ env.RUN_ID }}"
assert upload["with"]["retention-days"] == "14"

uses = [step["uses"] for step in steps if "uses" in step]
assert uses == [
    "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
]
assert all(re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action) for action in uses)

runs = [step["run"] for step in steps if "run" in step]
assert len(runs) == 2
assert all("${{" not in script for script in runs)
binding, gates = runs
for required in (
    'test "${#SOURCE_SHA}" -eq 40',
    'test "$(git rev-parse HEAD)" = "$SOURCE_SHA"',
):
    assert required in binding
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

headings = [line.strip() for line in readme.splitlines() if line.startswith("## ")]
assert headings[0] == "## Maintainer path"
ordered = [
    "Review the manifests",
    "Run local tests and gates",
    "Open a pull request for human review",
    "Choose an explicit delivery path",
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
    "Draft development prerelease",
    "human PR review",
    "protected-branch policy",
    "non-authoritative",
    "does not merge, approve, push, publish",
    "Scheduling, automatic merge, signing, and attestations are out of scope",
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
