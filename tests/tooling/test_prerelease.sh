#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expect_fail() {
  if "$@" >"$tmp_dir/command.out" 2>"$tmp_dir/command.err"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

script="$workspace_root/scripts/release-evidence.sh"
workflow="$workspace_root/.github/workflows/prerelease.yml"
[ -x "$script" ] || fail 'release evidence entry point is absent'
[ -f "$workflow" ] || fail 'prerelease workflow is absent'
mkdir -p "$tmp_dir/bin"
printf '%s\n' '#!/bin/sh' 'printf invoked >"$GH_INVOCATION_LOG"' 'exit 99' >"$tmp_dir/bin/gh"
chmod +x "$tmp_dir/bin/gh"
GH_INVOCATION_LOG="$tmp_dir/gh-invoked"
PATH="$tmp_dir/bin:$PATH"
export GH_INVOCATION_LOG PATH

make_fixture() {
  root=$1
  mkdir -p "$root/metadata" "$root/artifacts" "$root/output"
  printf '%s\n' linux-binary >"$root/artifacts/stockfish-linux-x86-64.tar.gz"
  printf '%s\n' windows-binary >"$root/artifacts/stockfish-windows-x86-64.zip"
  python3 - "$root" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
source = "0123456789abcdef0123456789abcdef01234567"
network = "nn-1a298aa575a0.nnue"
network_digest = "1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2"
for platform, artifact in (
    ("linux-x64", "stockfish-linux-x86-64.tar.gz"),
    ("windows-x64", "stockfish-windows-x86-64.zip"),
):
    path = root / "artifacts" / artifact
    value = {
        "schema": 1,
        "platform": platform,
        "artifact": artifact,
        "artifact_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "source_sha": source,
        "nnue_filename": network,
        "nnue_sha256": network_digest,
        "gpl_source_url": f"https://github.com/example/sf-cor-dev/tree/{source}",
    }
    (root / "metadata" / f"{platform}.json").write_text(
        json.dumps(value, indent=2) + "\n", encoding="utf-8"
    )
PY
}

mutate_json() {
  path=$1
  expression=$2
  python3 - "$path" "$expression" <<'PY'
import json, sys
path, expression = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
exec(expression, {"__builtins__": {}}, {"value": value})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(value, stream, indent=2)
    stream.write("\n")
PY
}

run_join() {
  root=$1
  "$script" join "$root/metadata" "$root/artifacts" "$root/output"
}

make_fixture "$tmp_dir/pass"
run_join "$tmp_dir/pass"
python3 - "$tmp_dir/pass/output" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
evidence = json.load((root / "release-evidence.json").open(encoding="utf-8"))
assert evidence["source_sha"] == "0123456789abcdef0123456789abcdef01234567"
assert evidence["nnue"] == {
    "filename": "nn-1a298aa575a0.nnue",
    "sha256": "1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2",
}
assert [item["platform"] for item in evidence["artifacts"]] == ["linux-x64", "windows-x64"]
assert evidence["gpl_source_url"].endswith(evidence["source_sha"])
checksums = (root / "checksums.sha256").read_text(encoding="utf-8").splitlines()
assert checksums == sorted(checksums)
assert len(checksums) == 2 and all("  stockfish-" in line for line in checksums)
notes = (root / "release-notes.md").read_text(encoding="utf-8")
for required in (evidence["source_sha"], evidence["nnue"]["filename"], evidence["nnue"]["sha256"], evidence["gpl_source_url"]):
    assert required in notes
for item in evidence["artifacts"]:
    assert item["name"] in notes and item["sha256"] in notes
PY
first_digest=$(sha256sum "$tmp_dir/pass/output/"* | sha256sum | cut -d ' ' -f 1)
run_join "$tmp_dir/pass"
second_digest=$(sha256sum "$tmp_dir/pass/output/"* | sha256sum | cut -d ' ' -f 1)
[ "$first_digest" = "$second_digest" ] || fail 'release evidence is not deterministic'

for case_name in source artifact nnue-name nnue-digest missing-checksum missing-gpl; do
  root="$tmp_dir/fail-$case_name"
  make_fixture "$root"
  case $case_name in
    source) mutate_json "$root/metadata/windows-x64.json" 'value["source_sha"] = "f" * 40' ;;
    artifact) mutate_json "$root/metadata/windows-x64.json" 'value["artifact"] = "wrong.zip"' ;;
    nnue-name) mutate_json "$root/metadata/windows-x64.json" 'value["nnue_filename"] = "nn-wrong.nnue"' ;;
    nnue-digest) mutate_json "$root/metadata/windows-x64.json" 'value["nnue_sha256"] = "f" * 64' ;;
    missing-checksum) mutate_json "$root/metadata/windows-x64.json" 'value.pop("artifact_sha256")' ;;
    missing-gpl) mutate_json "$root/metadata/windows-x64.json" 'value.pop("gpl_source_url")' ;;
  esac
  expect_fail run_join "$root"
done

make_fixture "$tmp_dir/missing-artifact"
rm "$tmp_dir/missing-artifact/artifacts/stockfish-windows-x86-64.zip"
expect_fail run_join "$tmp_dir/missing-artifact"

make_fixture "$tmp_dir/tamper"
printf '%s\n' tampered >>"$tmp_dir/tamper/artifacts/stockfish-linux-x86-64.tar.gz"
expect_fail run_join "$tmp_dir/tamper"

make_fixture "$tmp_dir/malformed"
printf '%s\n' '{bad json' >"$tmp_dir/malformed/metadata/linux-x64.json"
expect_fail run_join "$tmp_dir/malformed"

make_fixture "$tmp_dir/duplicate"
mutate_json "$tmp_dir/duplicate/metadata/windows-x64.json" 'value["platform"] = "linux-x64"'
expect_fail run_join "$tmp_dir/duplicate"

state="$tmp_dir/releases.json"
python3 - "$state" <<'PY'
import json, sys
releases = []
for number in range(1, 7):
    releases.append({
        "tag": f"dev-2026090{number}",
        "created_at": f"2026-09-0{number}T00:00:00Z",
        "development": True,
        "draft": False,
        "prerelease": True,
        "valid": True,
        "known_good": number == 1,
        "provenance": {
            "source_sha": f"{number}" * 40,
            "nnue_filename": "nn-test.nnue",
            "nnue_sha256": "a" * 64,
            "gpl_source_url": f"https://example.invalid/source/{number}",
            "checksums": {f"artifact-{number}": "b" * 64},
        },
    })
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(releases, stream, indent=2); stream.write("\n")
PY
state_before=$(sha256sum "$state" | cut -d ' ' -f 1)
"$script" plan-publish "$tmp_dir/pass/output/release-evidence.json" "$state" dev-20260907 dev-20260901 >"$tmp_dir/publish-plan.json"
[ "$(sha256sum "$state" | cut -d ' ' -f 1)" = "$state_before" ] || fail 'publish planning mutated release state'
python3 - "$tmp_dir/publish-plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
actions = [step["action"] for step in plan["steps"]]
assert actions[:4] == ["create_draft", "upload_artifacts", "validate_draft_evidence", "publish_prerelease"]
assert all(index > 3 for index, action in enumerate(actions) if action == "delete_release")
assert plan["rollback_target"] == "dev-20260901"
assert "dev-20260901" in plan["retained_tags"]
assert len(plan["retained_tags"]) == 5
assert plan["prune_tags"] == ["dev-20260902", "dev-20260903"]
PY

invalid_state="$tmp_dir/invalid-releases.json"
printf '%s\n' '[{"tag":"dev-bad","valid":false}]' >"$invalid_state"
invalid_before=$(sha256sum "$invalid_state" | cut -d ' ' -f 1)
expect_fail "$script" plan-publish "$tmp_dir/pass/output/release-evidence.json" "$invalid_state" dev-20260907 dev-missing
[ "$(sha256sum "$invalid_state" | cut -d ' ' -f 1)" = "$invalid_before" ] || fail 'failed publish planning mutated release state'

"$script" plan-rollback "$state" dev-20260901 >"$tmp_dir/rollback-plan.json"
python3 - "$tmp_dir/rollback-plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["target_tag"] == "dev-20260901"
assert plan["provenance"]["source_sha"] == "1" * 40
assert [step["action"] for step in plan["steps"]] == ["download_retained", "verify_checksums", "activate_rollback"]
PY
expect_fail "$script" plan-rollback "$state" dev-20260902
expect_fail "$script" plan-rollback "$state" dev-missing
[ "$(sha256sum "$state" | cut -d ' ' -f 1)" = "$state_before" ] || fail 'failed rollback planning mutated release state'

python3 - "$workflow" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for runner in ("ubuntu-24.04", "windows-2022"):
    assert f"runs-on: {runner}" in text
for pin in (
    "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
    "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
    "msys2/setup-msys2@66cd2cce69caa17b53920067426061ca1de3a884",
):
    assert pin in text
assert "ARCH=x86-64" in text or "SF_COR_BUILD_ARCH: x86-64" in text
assert "x86-64-universal" not in text
assert "stockfish-linux-x86-64.tar.gz" in text
assert "stockfish-windows-x86-64.zip" in text
assert "--sort=name" in text and "gzip -n" in text
assert "ZipInfo" in text and "1980, 1, 1, 0, 0, 0" in text
assert "src/stockfish.exe" in text
assert 'archive.writestr(info, pathlib.Path("build/stockfish.exe").read_bytes())' in text
assert "permissions: {}" in text
assert "contents: write" in text and "contents: read" in text
assert "--draft" in text and "--prerelease" in text
assert text.index("--draft") < text.index("--draft=false")
assert "execute_publication" in text
assert "scripts/release-evidence.sh join" in text
assert "scripts/release-evidence.sh plan-publish" in text
assert "env gga run --ci" in text
assert "models: read" in text
assert "gentleman-guardian-angel/archive/refs/tags/v2.10.1.tar.gz" in text
assert "models.github.ai/inference/chat/completions" in text
assert "text.count(old) != 1" in text
assert "env gga --version" in text
assert 'IFS= read -r version' in text
assert 'test "$version" = "gga v$GGA_VERSION"' in text
assert "c1dbcee120b83238e1c7ecce4a60f88a66810796ad95a239debc09e8509d0fba" in text
review = text.index("env gga run --ci")
create = text.index('gh release create "$RELEASE_TAG"')
download = text.index('gh release download "$RELEASE_TAG"')
promote = text.index('gh release edit "$RELEASE_TAG" --draft=false --prerelease')
prune = text.index('"gh", "release", "delete"')
assert review < create < download < promote < prune
assert "hashlib.sha256" in text
assert 'evidence["source_sha"] == os.environ["REVIEWED_SHA"]' in text
assert 'evidence["nnue"]["filename"] == os.environ["EXPECTED_NNUE_FILENAME"]' in text
assert 'evidence["nnue"]["sha256"] == os.environ["EXPECTED_NNUE_SHA256"]' in text
assert 'set(path.name for path in root.iterdir()) == expected_assets' in text
assert '(root / name).read_bytes() == (pathlib.Path("release-output") / name).read_bytes()' in text
for block in re.findall(r"run: \|\n((?:\s{8,}.*\n)+)", text):
    assert "${{" not in block
PY

[ ! -e "$GH_INVOCATION_LOG" ] || fail 'tests invoked GitHub publication commands'
printf '%s\n' 'prerelease tests passed'
