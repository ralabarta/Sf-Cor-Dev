#!/bin/sh
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 1 ] || fail 'usage: release-evidence.sh <join|plan-publish|plan-rollback> ...'
command=$1
shift

python3 - "$command" "$@" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile

SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_TAG = re.compile(r"^dev-[A-Za-z0-9._-]+$")
ARTIFACTS = {
    "linux-x64": "stockfish-linux-x64-x86-64-universal.tar.gz",
    "windows-x64": "stockfish-windows-x64-x86-64-universal.zip",
}


def die(message):
    raise SystemExit(message)


def load_object(path, label):
    try:
        if path.is_symlink() or not path.is_file():
            die(f"{label} must be a regular file")
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        die(f"invalid {label}: {error}")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value


def load_array(path, label):
    try:
        if path.is_symlink() or not path.is_file():
            die(f"{label} must be a regular file")
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        die(f"invalid {label}: {error}")
    if not isinstance(value, list):
        die(f"{label} must be a JSON array")
    return value


def require_sha(value, label):
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        die(f"invalid {label}")
    return value


def canonical_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def validate_provenance(value):
    if not isinstance(value, dict):
        die("release provenance is absent")
    require_sha(value.get("source_sha"), "provenance source SHA")
    require_sha(value.get("nnue_sha256"), "provenance NNUE digest")
    if not isinstance(value.get("nnue_filename"), str) or not value["nnue_filename"]:
        die("provenance NNUE filename is absent")
    if not isinstance(value.get("gpl_source_url"), str) or not value["gpl_source_url"].startswith("https://"):
        die("provenance GPL source URL is absent")
    checksums = value.get("checksums")
    if not isinstance(checksums, dict) or not checksums:
        die("provenance checksums are absent")
    for name, digest in checksums.items():
        if not isinstance(name, str) or not name or not SHA256.fullmatch(str(digest)):
            die("invalid provenance checksum")
    return value


def join(metadata_name, artifacts_name, output_name):
    metadata_dir = pathlib.Path(metadata_name)
    artifacts_dir = pathlib.Path(artifacts_name)
    output_dir = pathlib.Path(output_name)
    if metadata_dir.is_symlink() or not metadata_dir.is_dir():
        die("metadata directory is absent or unsafe")
    if artifacts_dir.is_symlink() or not artifacts_dir.is_dir():
        die("artifact directory is absent or unsafe")
    metadata_paths = sorted(metadata_dir.glob("*.json"))
    if len(metadata_paths) != 2:
        die("exactly two platform metadata files are required")
    records = [load_object(path, "platform metadata") for path in metadata_paths]
    platforms = [record.get("platform") for record in records]
    if sorted(platforms) != sorted(ARTIFACTS) or len(set(platforms)) != 2:
        die("duplicate or missing platform metadata")
    records.sort(key=lambda item: item["platform"])
    source_values = {record.get("source_sha") for record in records}
    network_names = {record.get("nnue_filename") for record in records}
    network_digests = {record.get("nnue_sha256") for record in records}
    source_urls = {record.get("gpl_source_url") for record in records}
    if len(source_values) != 1:
        die("platform source SHA mismatch")
    if len(network_names) != 1 or len(network_digests) != 1:
        die("platform NNUE identity mismatch")
    if len(source_urls) != 1:
        die("platform GPL source URL mismatch")
    source_sha = require_sha(source_values.pop(), "source SHA")
    nnue_digest = require_sha(network_digests.pop(), "NNUE digest")
    nnue_filename = network_names.pop()
    if not isinstance(nnue_filename, str) or not re.fullmatch(r"nn-[A-Za-z0-9._-]+\.nnue", nnue_filename):
        die("invalid NNUE filename")
    source_url = source_urls.pop()
    if not isinstance(source_url, str) or not source_url.startswith("https://") or not source_url.endswith(source_sha):
        die("missing GPLv3 source URL for reviewed SHA")
    artifacts = []
    checksum_lines = []
    for record in records:
        platform = record["platform"]
        expected_name = ARTIFACTS[platform]
        if record.get("schema") != 1 or record.get("artifact") != expected_name:
            die("artifact identity mismatch")
        declared = require_sha(record.get("artifact_sha256"), "artifact checksum")
        artifact_path = artifacts_dir / expected_name
        if artifact_path.is_symlink() or not artifact_path.is_file():
            die("required artifact is absent or unsafe")
        actual = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
        if actual != declared:
            die("artifact checksum verification failed")
        artifacts.append({"name": expected_name, "platform": platform, "sha256": actual})
        checksum_lines.append(f"{actual}  {expected_name}\n")
    evidence = {
        "artifacts": artifacts,
        "gpl_source_url": source_url,
        "nnue": {"filename": nnue_filename, "sha256": nnue_digest},
        "schema": 1,
        "source_sha": source_sha,
    }
    notes = [
        "# Development prerelease evidence\n\n",
        f"Source SHA: `{source_sha}`\n\n",
        f"Verified NNUE: `{nnue_filename}` (`{nnue_digest}`)\n\n",
        f"GPLv3 source: {source_url}\n\n",
        "## Artifacts\n\n",
    ]
    notes.extend(f"- `{item['name']}`: `{item['sha256']}`\n" for item in artifacts)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink() or (output_dir.exists() and not output_dir.is_dir()):
        die("output directory is unsafe")
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".release-evidence.", dir=output_dir.parent))
    try:
        (stage / "release-evidence.json").write_bytes(canonical_bytes(evidence))
        (stage / "checksums.sha256").write_text("".join(sorted(checksum_lines)), encoding="utf-8")
        (stage / "release-notes.md").write_text("".join(notes), encoding="utf-8")
        output_dir.mkdir(parents=True, exist_ok=True)
        for name in ("checksums.sha256", "release-evidence.json", "release-notes.md"):
            os.replace(stage / name, output_dir / name)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def plan_publish(evidence_name, state_name, new_tag, rollback_tag):
    if not SAFE_TAG.fullmatch(new_tag) or not SAFE_TAG.fullmatch(rollback_tag):
        die("invalid development release tag")
    evidence = load_object(pathlib.Path(evidence_name), "release evidence")
    provenance = validate_provenance({
        "source_sha": evidence.get("source_sha"),
        "nnue_filename": (evidence.get("nnue") or {}).get("filename"),
        "nnue_sha256": (evidence.get("nnue") or {}).get("sha256"),
        "gpl_source_url": evidence.get("gpl_source_url"),
        "checksums": {item.get("name"): item.get("sha256") for item in evidence.get("artifacts", []) if isinstance(item, dict)},
    })
    releases = load_array(pathlib.Path(state_name), "release state")
    if any(item.get("tag") == new_tag for item in releases if isinstance(item, dict)):
        die("new release tag already exists")
    rollback = next((item for item in releases if isinstance(item, dict) and item.get("tag") == rollback_tag), None)
    if not rollback or not rollback.get("valid") or not rollback.get("known_good"):
        die("rollback target is not retained known-good provenance")
    validate_provenance(rollback.get("provenance"))
    valid = [item for item in releases if isinstance(item, dict) and item.get("development") and item.get("prerelease") and not item.get("draft") and item.get("valid")]
    valid.sort(key=lambda item: (str(item.get("created_at", "")), str(item.get("tag", ""))), reverse=True)
    retained = [new_tag] + [item["tag"] for item in valid[:4]]
    if rollback_tag not in retained:
        retained[-1] = rollback_tag
    retained = list(dict.fromkeys(retained))
    prune = sorted(item["tag"] for item in valid if item["tag"] not in retained)
    steps = [
        {"action": "create_draft", "tag": new_tag},
        {"action": "upload_artifacts", "tag": new_tag},
        {"action": "validate_draft_evidence", "tag": new_tag},
        {"action": "publish_prerelease", "tag": new_tag},
    ]
    steps.extend({"action": "delete_release", "tag": tag} for tag in prune)
    print(json.dumps({"provenance": provenance, "prune_tags": prune, "retained_tags": retained, "rollback_target": rollback_tag, "steps": steps}, indent=2, sort_keys=True))


def plan_rollback(state_name, target_tag):
    if not SAFE_TAG.fullmatch(target_tag):
        die("invalid rollback tag")
    releases = load_array(pathlib.Path(state_name), "release state")
    target = next((item for item in releases if isinstance(item, dict) and item.get("tag") == target_tag), None)
    if not target or not target.get("valid") or not target.get("known_good") or target.get("draft") or not target.get("prerelease"):
        die("rollback target is not a retained published known-good prerelease")
    provenance = validate_provenance(target.get("provenance"))
    steps = [{"action": action, "tag": target_tag} for action in ("download_retained", "verify_checksums", "activate_rollback")]
    print(json.dumps({"provenance": provenance, "steps": steps, "target_tag": target_tag}, indent=2, sort_keys=True))


mode, *arguments = sys.argv[1:]
expected = {"join": 3, "plan-publish": 4, "plan-rollback": 2}
if mode not in expected or len(arguments) != expected[mode]:
    die(f"invalid arguments for {mode}")
{"join": join, "plan-publish": plan_publish, "plan-rollback": plan_rollback}[mode](*arguments)
PY
