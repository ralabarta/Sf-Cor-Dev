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
trap 'rm -f "$parsed"' EXIT HUP INT TERM
python3 - "$manifest" >"$parsed" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
if set(data) != {"schema", "official", "corchess"} or data["schema"] != 1:
    raise SystemExit("invalid upstream manifest schema")
for name in ("official", "corchess"):
    source = data[name]
    if set(source) != {"url", "commit"}:
        raise SystemExit(f"invalid {name} source entry")
    if not isinstance(source["url"], str) or not re.match(r"^(https|file)://[^\s]+$", source["url"]):
        raise SystemExit(f"invalid {name} source URL")
    if not isinstance(source["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise SystemExit(f"invalid {name} commit identity")
    print(name, source["url"], source["commit"], sep="\t")
if data["official"] == data["corchess"] or data["official"]["url"] == data["corchess"]["url"]:
    raise SystemExit("official and CorChess sources must be distinct")
PY

while IFS="$(printf '\t')" read -r name url commit; do
  require_commit_sha "$commit"
  observed=$(git ls-remote "$url" HEAD | {
    read -r sha ref
    [ "$ref" = HEAD ] || exit 1
    printf '%s' "$sha"
  })
  require_commit_sha "$observed"
  printf '%s %s observed %s\n' "$name" "$commit" "$observed"
done <"$parsed"
