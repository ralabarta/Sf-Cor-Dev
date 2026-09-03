#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=scripts/lib/guards.sh
. "$script_dir/lib/guards.sh"

[ "$#" -le 1 ] || fail 'usage: update-local.sh [run-id]'
root=$(resolve_repository_root "$script_dir")
require_command date
require_command git
require_command sha256sum

if [ "$#" -eq 1 ]; then
  run_id=$1
else
  run_id="local-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
case $run_id in
  *[!A-Za-z0-9._-]*|.*|*..*|'') fail 'invalid evidence run ID' ;;
esac

manifest=$(require_owned_manifest "$root" manifests/corchess-deltas.json corchess-deltas.json)
source_sha=$(git -C "$root" rev-parse HEAD)
require_commit_sha "$source_sha"
manifest_sha=$(sha256sum "$manifest" | cut -d ' ' -f 1)
require_sha256 "$manifest_sha"
candidate="$root/build/Sf-Cor-Dev"

unset SF_COR_PROVENANCE_COMMAND SF_COR_NNUE_COMMAND SF_COR_BUILD_COMMAND SF_COR_UCI_COMMAND
unset SF_COR_BENCH_COMMAND SF_COR_PERFT_COMMAND SF_COR_REPROSEARCH_COMMAND SF_COR_SMOKE_COMMAND
unset SF_COR_ACTIVATION_VALIDATOR
SF_COR_BUILD_PROFILE=local
SF_COR_ENGINE=$candidate
SF_COR_BUILD_OUTPUT=$candidate
export SF_COR_BUILD_PROFILE SF_COR_ENGINE SF_COR_BUILD_OUTPUT

"$script_dir/nnue-prefetch.sh" manifests/nnue.json
"$script_dir/validate.sh" "$run_id"
[ "$(git -C "$root" rev-parse HEAD)" = "$source_sha" ] || fail 'source identity changed during local update'
"$script_dir/activate.sh" "$candidate" "$source_sha" "$manifest_sha"
printf 'local Sf-Cor-Dev update passed: %s\n' "$run_id"
