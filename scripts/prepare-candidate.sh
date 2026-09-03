#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/guards.sh
. "$script_dir/lib/guards.sh"

[ "$#" -ge 1 ] && [ "$#" -le 2 ] ||
  fail 'usage: scripts/prepare-candidate.sh <output-directory> [upstreams.json]'
root=$(resolve_repository_root "$script_dir")
output=$1
upstreams=${2:-"$root/manifests/upstreams.json"}
require_command git
require_command python3
require_command sha256sum

case $output in
  /*) ;;
  *) output="$PWD/$output" ;;
esac
[ ! -e "$output" ] || fail "candidate output already exists: $output"
output_parent=$(dirname -- "$output")
[ -d "$output_parent" ] || fail "candidate output parent does not exist: $output_parent"
[ -f "$upstreams" ] && [ ! -L "$upstreams" ] || fail 'upstream manifest must be a regular file'

provenance_repo=$(mktemp -d)
stage=$(mktemp -d "$output_parent/.candidate.XXXXXX")
parsed=$(mktemp)
paths_file=$(mktemp)
records_file=$(mktemp)
cleanup() {
  rm -f "$parsed" "$paths_file" "$records_file"
  rm -rf "$provenance_repo"
  [ ! -d "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$stage/patches"
git -C "$provenance_repo" init -q --bare

python3 - "$upstreams" >"$parsed" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    upstreams = json.load(stream)
if set(upstreams) != {"schema", "official", "corchess"} or upstreams["schema"] != 1:
    raise SystemExit("invalid upstream manifest schema")
expected_refs = {"official": "refs/heads/master", "corchess": "refs/heads/corchess"}
for name in ("official", "corchess"):
    source = upstreams[name]
    if set(source) != {"url", "ref", "commit"}:
        raise SystemExit(f"invalid {name} source entry")
    if not isinstance(source["url"], str) or not re.fullmatch(r"(?:https|file)://[^\s]+", source["url"]):
        raise SystemExit(f"invalid {name} source URL")
    if source["ref"] != expected_refs[name]:
        raise SystemExit(f"invalid {name} tracked ref")
    if not isinstance(source["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise SystemExit(f"invalid {name} commit identity")
    print(name, source["url"], source["ref"], source["commit"], sep="\t")
if upstreams["official"]["url"] == upstreams["corchess"]["url"]:
    raise SystemExit("official and CorChess sources must be distinct")
PY

tab=$(printf '\t')
official_url=
official_ref=
official_declared=
corchess_url=
corchess_ref=
corchess_declared=
while IFS="$tab" read -r name url ref commit; do
  case $name in
    official) official_url=$url; official_ref=$ref; official_declared=$commit ;;
    corchess) corchess_url=$url; corchess_ref=$ref; corchess_declared=$commit ;;
    *) fail "unknown upstream identity: $name" ;;
  esac
done <"$parsed"

fetch_ref() {
  _candidate_name=$1
  _candidate_url=$2
  _candidate_ref=$3
  _candidate_declared=$4
  git -C "$provenance_repo" fetch -q --no-tags "$_candidate_url" \
    "+$_candidate_ref:refs/upstreams/$_candidate_name" ||
    fail "declared source does not provide tracked ref: $_candidate_ref"
  git -C "$provenance_repo" cat-file -e "$_candidate_declared^{commit}" 2>/dev/null ||
    fail "declared source does not provide commit: $_candidate_declared"
  git -C "$provenance_repo" merge-base --is-ancestor \
    "$_candidate_declared" "refs/upstreams/$_candidate_name" ||
    fail "declared commit is outside tracked ref: $_candidate_declared"
}
fetch_ref official "$official_url" "$official_ref" "$official_declared"
fetch_ref corchess "$corchess_url" "$corchess_ref" "$corchess_declared"
official_sha=$(git -C "$provenance_repo" rev-parse refs/upstreams/official)
corchess_sha=$(git -C "$provenance_repo" rev-parse refs/upstreams/corchess)
merge_base=$(git -C "$provenance_repo" merge-base "$official_sha" "$corchess_sha")
[ "$merge_base" = "$official_sha" ] ||
  fail 'CorChess tracked ref is not based on the exact observed official ref'

git -C "$provenance_repo" diff --name-only -z "$official_sha" "$corchess_sha" >"$paths_file"
python3 - "$paths_file" <<'PY'
import pathlib
import re
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
paths = raw.split(b"\0")
if paths[-1:] == [b""]:
    paths.pop()
decoded = []
for value in paths:
    try:
        path = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit("changed path is not UTF-8") from error
    parts = path.split("/")
    if (
        not path
        or path.startswith("/")
        or "\\" in path
        or any(part in ("", ".", "..") for part in parts)
        or any(ord(char) < 32 or ord(char) == 127 for char in path)
        or not re.fullmatch(r"[A-Za-z0-9._+@/-]+", path)
    ):
        raise SystemExit(f"unsafe changed path: {path!r}")
    decoded.append(path)
if decoded != sorted(decoded) or len(decoded) != len(set(decoded)):
    raise SystemExit("changed paths are not sorted and unique")
pathlib.Path(sys.argv[1]).write_text("\n".join(decoded) + ("\n" if decoded else ""), encoding="utf-8")
PY

path_index=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  path_index=$((path_index + 1))
  patch_relative=$(printf 'patches/%04d.patch' "$path_index")
  patch_path="$stage/$patch_relative"
  git -C "$provenance_repo" diff --binary --full-index --no-renames \
    "$official_sha" "$corchess_sha" -- "$path" >"$patch_path"
  [ -s "$patch_path" ] || fail "empty canonical path patch: $path"
  base_mode=$(git -C "$provenance_repo" ls-tree "$official_sha" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
  corchess_mode=$(git -C "$provenance_repo" ls-tree "$corchess_sha" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
  case ${base_mode:-missing} in 100644|100755|missing) ;; *) fail "unsupported base tree entry: $path" ;; esac
  case ${corchess_mode:-missing} in 100644|100755|missing) ;; *) fail "unsupported CorChess tree entry: $path" ;; esac
  if git -C "$provenance_repo" cat-file -e "$official_sha:$path" 2>/dev/null; then
    base_blob=$(git -C "$provenance_repo" rev-parse "$official_sha:$path")
  else
    base_blob=0000000000000000000000000000000000000000
  fi
  if git -C "$provenance_repo" cat-file -e "$corchess_sha:$path" 2>/dev/null; then
    corchess_blob=$(git -C "$provenance_repo" rev-parse "$corchess_sha:$path")
  else
    corchess_blob=0000000000000000000000000000000000000000
  fi
  patch_digest=$(sha256sum "$patch_path" | cut -d ' ' -f 1)
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$path" "$base_blob" "$corchess_blob" "$patch_relative" "$patch_digest" >>"$records_file"
done <"$paths_file"

python3 - "$stage" "$official_url" "$official_ref" "$official_sha" \
  "$corchess_url" "$corchess_ref" "$corchess_sha" "$merge_base" "$records_file" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    output,
    official_url,
    official_ref,
    official_sha,
    corchess_url,
    corchess_ref,
    corchess_sha,
    merge_base,
    records_path,
) = sys.argv[1:]
root = pathlib.Path(output)
records = []
record_lines = []
with open(records_path, encoding="utf-8") as stream:
    for line in stream:
        path, base_blob, corchess_blob, patch, patch_sha256 = line.rstrip("\n").split("\t")
        records.append({
            "path": path,
            "base_blob": base_blob,
            "corchess_blob": corchess_blob,
            "patch": patch,
            "patch_sha256": patch_sha256,
        })
        record_lines.append(f"{path}\t{base_blob}\t{corchess_blob}\t{patch_sha256}\n")
group_digest = hashlib.sha256("".join(record_lines).encode("utf-8")).hexdigest()
groups = [] if not records else [{
    "id": "candidate-tree-delta",
    "patch_sha256": group_digest,
    "paths": records,
}]
upstreams = {
    "schema": 2,
    "official": {"url": official_url, "ref": official_ref, "commit": official_sha},
    "corchess": {"url": corchess_url, "ref": corchess_ref, "commit": corchess_sha},
    "merge_base": merge_base,
}
manifest = {
    "schema": 2,
    "reviewed": False,
    "official_base": official_sha,
    "corchess_ref": corchess_sha,
    "merge_base": merge_base,
    "groups": groups,
}
summary = {
    "schema": 1,
    "reviewed": False,
    "official_commit": official_sha,
    "corchess_commit": corchess_sha,
    "merge_base": merge_base,
    "changed_paths": [entry["path"] for entry in records],
    "paths": records,
    "compatibility_warnings": [],
}
for name, value in (
    ("candidate-upstreams.json", upstreams),
    ("candidate-manifest.json", manifest),
    ("summary.json", summary),
):
    (root / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY

chmod 0755 "$stage" "$stage/patches"
python3 - "$stage" <<'PY' || fail 'cannot normalize candidate file modes'
import pathlib
import sys

for path in pathlib.Path(sys.argv[1]).rglob("*"):
    if path.is_file():
        path.chmod(0o644)
PY
mv "$stage" "$output"
stage=
printf 'prepared unreviewed candidate %s from official %s and CorChess %s\n' \
  "$output" "$official_sha" "$corchess_sha"
