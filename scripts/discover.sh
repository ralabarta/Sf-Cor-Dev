#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/guards.sh
. "$script_dir/lib/guards.sh"

[ "$#" -le 1 ] || fail 'usage: scripts/discover.sh [manifests/upstreams.json]'
root=$(resolve_repository_root "$script_dir")
manifest=$(require_owned_manifest "$root" "${1:-manifests/upstreams.json}" upstreams.json)
require_command python3
require_command git

parsed=$(mktemp)
probe_repo=$(mktemp -d)
trap 'rm -f "$parsed"; rm -rf "$probe_repo"' EXIT HUP INT TERM
git -C "$probe_repo" init -q --bare
python3 - "$manifest" >"$parsed" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
if set(data) != {"schema", "official", "corchess"} or data["schema"] != 1:
    raise SystemExit("invalid upstream manifest schema")
expected_refs = {
    "official": "refs/heads/master",
    "corchess": "refs/heads/corchess",
}
for name in ("official", "corchess"):
    source = data[name]
    if set(source) != {"url", "ref", "commit"}:
        raise SystemExit(f"invalid {name} source entry")
    if not isinstance(source["url"], str) or not re.match(r"^(https|file)://[^\s]+$", source["url"]):
        raise SystemExit(f"invalid {name} source URL")
    if source["ref"] != expected_refs[name]:
        raise SystemExit(f"invalid {name} tracked ref")
    if not isinstance(source["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise SystemExit(f"invalid {name} commit identity")
    print(name, source["url"], source["ref"], source["commit"], sep="\t")
if data["official"]["url"] == data["corchess"]["url"]:
    raise SystemExit("official and CorChess sources must be distinct")
PY

result=0
tab=$(printf '\t')
while IFS="$tab" read -r name url ref pinned; do
  require_commit_sha "$pinned"
  observed=$(git ls-remote "$url" "$ref" | {
    read -r sha found_ref
    [ "$found_ref" = "$ref" ] || exit 1
    [ -z "${extra:-}" ] || exit 1
    printf '%s' "$sha"
  }) || observed=
  status=invalid
  if [ -n "$observed" ]; then
    require_commit_sha "$observed"
    if git -C "$probe_repo" fetch -q --no-tags "$url" "+$ref:refs/observed/$name" &&
       git -C "$probe_repo" fetch -q --no-tags "$url" "$pinned" &&
       [ "$(git -C "$probe_repo" cat-file -t "$pinned" 2>/dev/null || true)" = commit ]; then
      if [ "$observed" = "$pinned" ]; then
        status=unchanged
      elif git -C "$probe_repo" merge-base --is-ancestor "$pinned" "$observed"; then
        status=advanced
      else
        status=diverged
      fi
    fi
  fi
  python3 - "$name" "$ref" "$pinned" "${observed:-null}" "$status" <<'PY'
import json
import sys

source, ref, pinned, observed, status = sys.argv[1:]
print(json.dumps({
    "observed": None if observed == "null" else observed,
    "pinned": pinned,
    "ref": ref,
    "source": source,
    "status": status,
}, sort_keys=True, separators=(",", ":")))
PY
  [ "$status" != invalid ] || result=1
done <"$parsed"
exit "$result"
