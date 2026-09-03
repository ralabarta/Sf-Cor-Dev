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

configure_git() {
  git -C "$1" config user.name 'Candidate Test'
  git -C "$1" config user.email 'candidate@example.invalid'
}

repository_state() {
  repository=$1
  {
    git -C "$repository" rev-parse HEAD
    git -C "$repository" for-each-ref --format='%(refname) %(objectname)'
    git -C "$repository" status --porcelain=v2 --branch
  } | sha256sum | cut -d ' ' -f 1
}

write_upstreams() {
  destination=$1
  official_commit=$2
  corchess_commit=$3
  printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    "  \"official\": {\"url\": \"file://$official_repo\", \"ref\": \"refs/heads/master\", \"commit\": \"$official_commit\"}," \
    "  \"corchess\": {\"url\": \"file://$corchess_repo\", \"ref\": \"refs/heads/corchess\", \"commit\": \"$corchess_commit\"}" \
    '}' >"$destination"
}

official_repo="$tmp_dir/official"
corchess_repo="$tmp_dir/corchess"
mkdir -p "$official_repo"
git -C "$official_repo" init -q -b master
configure_git "$official_repo"
mkdir -p "$official_repo/src"
printf '%s\n' base >"$official_repo/src/search.cpp"
printf '%s\n' header >"$official_repo/src/search.h"
git -C "$official_repo" add src
git -C "$official_repo" commit -q -m 'official base'
official_sha=$(git -C "$official_repo" rev-parse HEAD)

git clone -q "$official_repo" "$corchess_repo"
configure_git "$corchess_repo"
git -C "$corchess_repo" switch -q -c corchess
printf '%s\n' feature >"$corchess_repo/src/search.cpp"
git -C "$corchess_repo" commit -q -am 'search feature'
printf '\000\001\377binary\000' >"$corchess_repo/src/search.h"
git -C "$corchess_repo" commit -q -am 'binary search table'
# Exercise a sync-merge-heavy history whose only surviving result is the tree delta.
git -C "$corchess_repo" switch -q -c sync-side
printf '%s\n' temporary >"$corchess_repo/src/temporary.cpp"
git -C "$corchess_repo" add src/temporary.cpp
git -C "$corchess_repo" commit -q -m 'temporary side change'
git -C "$corchess_repo" switch -q corchess
git -C "$corchess_repo" merge -q --no-ff sync-side -m 'sync side history'
git -C "$corchess_repo" rm -q src/temporary.cpp
git -C "$corchess_repo" commit -q -m 'remove temporary side change'
corchess_sha=$(git -C "$corchess_repo" rev-parse corchess)
manifest="$tmp_dir/upstreams.json"
write_upstreams "$manifest" "$official_sha" "$corchess_sha"

[ -x "$workspace_root/scripts/prepare-candidate.sh" ] || fail 'candidate preparation script is absent or not executable'
before_official=$(repository_state "$official_repo")
before_corchess=$(repository_state "$corchess_repo")
before_manifest=$(sha256sum "$manifest" | cut -d ' ' -f 1)
(umask 077; "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/candidate-a" "$manifest")
(umask 022; "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/candidate-b" "$manifest")
diff -r "$tmp_dir/candidate-a" "$tmp_dir/candidate-b" >/dev/null ||
  fail 'candidate output is not deterministic'
[ "$(repository_state "$official_repo")" = "$before_official" ] || fail 'official source was mutated'
[ "$(repository_state "$corchess_repo")" = "$before_corchess" ] || fail 'CorChess source was mutated'
[ "$(sha256sum "$manifest" | cut -d ' ' -f 1)" = "$before_manifest" ] || fail 'manifest was mutated'

python3 - "$tmp_dir/candidate-a" "$official_sha" "$corchess_sha" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
official, corchess = sys.argv[2:]
upstreams = json.loads((root / "candidate-upstreams.json").read_text(encoding="utf-8"))
manifest = json.loads((root / "candidate-manifest.json").read_text(encoding="utf-8"))
summary = json.loads((root / "summary.json").read_text(encoding="utf-8"))
assert upstreams == {
    "schema": 2,
    "official": {"url": upstreams["official"]["url"], "ref": "refs/heads/master", "commit": official},
    "corchess": {"url": upstreams["corchess"]["url"], "ref": "refs/heads/corchess", "commit": corchess},
    "merge_base": official,
}
assert manifest["schema"] == 2 and manifest["reviewed"] is False
assert manifest["official_base"] == official
assert manifest["corchess_ref"] == corchess
assert manifest["merge_base"] == official
assert len(manifest["groups"]) == 1
paths = manifest["groups"][0]["paths"]
assert [entry["path"] for entry in paths] == ["src/search.cpp", "src/search.h"]
assert summary["changed_paths"] == ["src/search.cpp", "src/search.h"]
assert summary["compatibility_warnings"] == []
for entry in paths:
    assert set(entry) == {"path", "base_blob", "corchess_blob", "patch", "patch_sha256"}
    assert len(entry["base_blob"]) == len(entry["corchess_blob"]) == 40
    patch = root / entry["patch"]
    assert patch.is_file()
    assert hashlib.sha256(patch.read_bytes()).hexdigest() == entry["patch_sha256"]
assert b"GIT binary patch" in (root / paths[1]["patch"]).read_bytes()
for path in root.rglob("*"):
    assert "timestamp" not in path.name.lower()
    assert (path.stat().st_mode & 0o777) == (0o755 if path.is_dir() else 0o644)
PY

# A no-delta branch produces an empty, deterministic candidate rather than a fake group.
git -C "$corchess_repo" switch -q --detach "$corchess_sha"
git -C "$corchess_repo" branch -f corchess "$official_sha"
write_upstreams "$manifest" "$official_sha" "$official_sha"
"$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/no-delta" "$manifest"
python3 - "$tmp_dir/no-delta/candidate-manifest.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["groups"] == []
PY

# Divergence is rejected even when both commits are available from their declared refs.
git -C "$official_repo" switch -q --detach "$official_sha"
printf '%s\n' divergent >"$official_repo/src/search.cpp"
git -C "$official_repo" commit -q -am 'divergent official'
divergent_sha=$(git -C "$official_repo" rev-parse HEAD)
git -C "$official_repo" branch -f master "$divergent_sha"
git -C "$corchess_repo" branch -f corchess "$corchess_sha"
write_upstreams "$manifest" "$divergent_sha" "$corchess_sha"
expect_fail "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/divergent" "$manifest"

# Unsafe Git path spellings and symlink tree entries fail closed.
git -C "$official_repo" branch -f master "$official_sha"
git -C "$corchess_repo" switch -q corchess
printf '%s\n' unsafe >"$corchess_repo/src\\unsafe.cpp"
git -C "$corchess_repo" add 'src\unsafe.cpp'
git -C "$corchess_repo" commit -q -m 'unsafe path spelling'
unsafe_sha=$(git -C "$corchess_repo" rev-parse HEAD)
write_upstreams "$manifest" "$official_sha" "$unsafe_sha"
expect_fail "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/unsafe" "$manifest"

git -C "$corchess_repo" reset -q --hard "$corchess_sha"
ln -s search.cpp "$corchess_repo/src/search-link"
git -C "$corchess_repo" add src/search-link
git -C "$corchess_repo" commit -q -m 'symlink path'
symlink_sha=$(git -C "$corchess_repo" rev-parse HEAD)
write_upstreams "$manifest" "$official_sha" "$symlink_sha"
expect_fail "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/symlink" "$manifest"

# Existing output is never overwritten, including after candidate tampering.
printf '%s\n' tampered >>"$tmp_dir/candidate-a/summary.json"
write_upstreams "$manifest" "$official_sha" "$corchess_sha"
expect_fail "$workspace_root/scripts/prepare-candidate.sh" "$tmp_dir/candidate-a" "$manifest"

printf '%s\n' 'candidate preparation tests passed'
