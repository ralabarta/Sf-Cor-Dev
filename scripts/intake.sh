#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/guards.sh
. "$script_dir/lib/guards.sh"

[ "$#" -le 2 ] || fail 'usage: scripts/intake.sh [upstreams.json] [corchess-deltas.json]'
root=$(resolve_repository_root "$script_dir")
upstreams=$(require_owned_manifest "$root" "${1:-manifests/upstreams.json}" upstreams.json)
deltas=$(require_owned_manifest "$root" "${2:-manifests/corchess-deltas.json}" corchess-deltas.json)
require_command git
require_command python3
require_command sha256sum
require_clean_repository "$root"
acquire_intake_lock "$root"

parsed=$(mktemp)
patch_file=$(mktemp)
provenance_repo=$(mktemp -d)
trap 'rm -f "$parsed" "$patch_file"; rm -rf "$provenance_repo"; rmdir "$intake_lock"' EXIT HUP INT TERM
git -C "$provenance_repo" init -q --bare
python3 - "$upstreams" "$deltas" >"$parsed" <<'PY'
import json
import re
import sys


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


upstreams = load(sys.argv[1])
queue = load(sys.argv[2])
if set(upstreams) != {"schema", "official", "corchess"} or upstreams["schema"] != 1:
    raise SystemExit("invalid upstream manifest schema")
for name in ("official", "corchess"):
    source = upstreams[name]
    if set(source) != {"url", "commit"}:
        raise SystemExit(f"invalid {name} source entry")
    if not isinstance(source["url"], str) or not re.match(r"^(https|file)://[^\s]+$", source["url"]):
        raise SystemExit(f"invalid {name} source URL")
    if not isinstance(source["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise SystemExit(f"invalid {name} commit identity")
if upstreams["official"]["url"] == upstreams["corchess"]["url"]:
    raise SystemExit("official and CorChess sources must be distinct")
expected = {"schema", "reviewed", "official_base", "corchess_ref", "deltas"}
if set(queue) != expected or queue["schema"] != 1 or queue["reviewed"] is not True:
    raise SystemExit("delta manifest is not an explicitly reviewed queue")
if queue["official_base"] != upstreams["official"]["commit"]:
    raise SystemExit("delta queue official base does not match upstream identity")
if queue["corchess_ref"] != upstreams["corchess"]["commit"]:
    raise SystemExit("delta queue CorChess ref does not match upstream identity")
if not isinstance(queue["deltas"], list):
    raise SystemExit("delta queue must be ordered JSON array")
print("U", "official", upstreams["official"]["url"], upstreams["official"]["commit"], sep="\t")
print("U", "corchess", upstreams["corchess"]["url"], upstreams["corchess"]["commit"], sep="\t")
for entry in queue["deltas"]:
    if not isinstance(entry, dict) or set(entry) != {"commit", "patch_sha256"}:
        raise SystemExit("invalid reviewed delta entry")
    if not isinstance(entry["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", entry["commit"]):
        raise SystemExit("invalid delta commit identity")
    if not isinstance(entry["patch_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["patch_sha256"]):
        raise SystemExit("invalid delta patch SHA-256")
    print("D", entry["commit"], entry["patch_sha256"], sep="\t")
PY

official_url=
official_sha=
corchess_url=
corchess_sha=
tab=$(printf '\t')
while IFS="$tab" read -r record first second third; do
  [ "$record" = U ] || continue
  case $first in
    official) official_url=$second; official_sha=$third ;;
    corchess) corchess_url=$second; corchess_sha=$third ;;
    *) fail "unknown upstream identity: $first" ;;
  esac
done <"$parsed"
require_commit_sha "$official_sha"
require_commit_sha "$corchess_sha"
[ "$official_sha" != "$corchess_sha" ] || fail 'official and CorChess commits must be distinct'

ensure_commit() {
  url=$1
  commit=$2
  git -C "$provenance_repo" fetch --no-tags "$url" "$commit" ||
    fail "declared source does not provide commit: $commit"
  [ "$(git -C "$provenance_repo" cat-file -t "$commit")" = commit ] ||
    fail "declared source object is not a commit: $commit"
  if ! git -C "$root" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$root" fetch --no-tags "$provenance_repo" "$commit"
  fi
  [ "$(git -C "$root" cat-file -t "$commit")" = commit ] ||
    fail "declared source object is not a commit: $commit"
}

ensure_commit "$official_url" "$official_sha"
ensure_commit "$corchess_url" "$corchess_sha"

while IFS="$tab" read -r record commit expected extra; do
  [ "$record" = D ] || continue
  require_commit_sha "$commit"
  require_sha256 "$expected"
  ensure_commit "$corchess_url" "$commit"
  git -C "$root" merge-base --is-ancestor "$commit" "$corchess_sha" ||
    fail "reviewed delta is outside the pinned CorChess identity: $commit"
  parent_line=$(git -C "$root" rev-list --parents -n 1 "$commit")
  set -- $parent_line
  [ "$#" -eq 2 ] || fail "aggregate or root commit is not an admissible delta: $commit"
  git -C "$root" diff-tree --root --binary --full-index --no-renames \
    --no-commit-id -p "$commit" >"$patch_file"
  actual=$(sha256sum "$patch_file" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || fail "patch evidence mismatch: $commit"
done <"$parsed"

manifest_digest=$(sha256sum "$deltas" | cut -d ' ' -f 1)
branch="integrate/$manifest_digest"
if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "integration branch already exists: $branch"
fi

git -C "$root" switch -q -c "$branch" "$official_sha"
git -C "$root" diff --cached --quiet || fail 'integration index was not empty after branch creation'
while IFS="$tab" read -r record commit expected extra; do
  [ "$record" = D ] || continue
  printf 'applying %s\n' "$commit"
  if ! git -C "$root" cherry-pick --no-commit "$commit"; then
    fail "reviewed delta conflicts and requires human resolution: $commit"
  fi
done <"$parsed"

printf 'prepared %s from official %s and CorChess %s\n' \
  "$branch" "$official_sha" "$corchess_sha"
