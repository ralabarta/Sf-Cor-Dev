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

for required in scripts/update-local.sh scripts/lib/guards.sh; do
  [ -f "$workspace_root/$required" ] || fail "required local updater file is absent: $required"
done

worktree="$tmp_dir/worktree"
mkdir -p "$worktree/scripts/lib" "$worktree/manifests" "$worktree/build" "$worktree/data/sf-cor-dev"
git -C "$worktree" init -q -b main
cp "$workspace_root/scripts/update-local.sh" "$worktree/scripts/update-local.sh"
cp "$workspace_root/scripts/lib/guards.sh" "$worktree/scripts/lib/guards.sh"
printf '%s\n' '{"schema":1,"deltas":[]}' >"$worktree/manifests/corchess-deltas.json"
printf '%s\n' source >"$worktree/source.txt"
git -C "$worktree" add scripts manifests source.txt
git -C "$worktree" -c user.name=Test -c user.email=test@example.invalid commit -q -m fixture
source_sha=$(git -C "$worktree" rev-parse HEAD)
manifest_sha=$(sha256sum "$worktree/manifests/corchess-deltas.json" | cut -d ' ' -f 1)
printf '%s\n' known-good >"$worktree/data/sf-cor-dev/current-sentinel"

for helper in nnue-prefetch.sh validate.sh activate.sh rollback.sh; do
  printf '%s\n' '#!/bin/sh' 'exit 98' >"$worktree/scripts/$helper"
  chmod +x "$worktree/scripts/$helper"
done
tee "$worktree/scripts/nnue-prefetch.sh" >/dev/null <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = manifests/nnue.json ] || exit 81
printf '%s\n' prefetch >>"$UPDATE_LOG"
SH
tee "$worktree/scripts/validate.sh" >/dev/null <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = local-test ] || exit 82
[ "${SF_COR_BUILD_PROFILE:-}" = local ] || exit 83
[ "${SF_COR_ENGINE:-}" = "$EXPECTED_CANDIDATE" ] || exit 89
[ "${SF_COR_BUILD_OUTPUT:-}" = "$EXPECTED_CANDIDATE" ] || exit 90
for variable in \
  SF_COR_PROVENANCE_COMMAND SF_COR_NNUE_COMMAND SF_COR_BUILD_COMMAND SF_COR_UCI_COMMAND \
  SF_COR_BENCH_COMMAND SF_COR_PERFT_COMMAND SF_COR_REPROSEARCH_COMMAND SF_COR_SMOKE_COMMAND \
  SF_COR_ACTIVATION_VALIDATOR; do
  eval "value=\${$variable:-}"
  [ -z "$value" ] || exit 91
done
printf '%s\n' validate >>"$UPDATE_LOG"
[ "${VALIDATE_FAIL:-0}" -eq 0 ] || exit 84
printf '%s\n' '#!/bin/sh' 'printf "id name Sf-Cor-Dev Test\nuciok\n"' >"$SF_COR_BUILD_OUTPUT"
chmod +x "$SF_COR_BUILD_OUTPUT"
SH
tee "$worktree/scripts/activate.sh" >/dev/null <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 3 ] || exit 85
[ "$1" = "$EXPECTED_CANDIDATE" ] || exit 86
[ "$2" = "$EXPECTED_SOURCE_SHA" ] || exit 87
[ "$3" = "$EXPECTED_MANIFEST_SHA" ] || exit 88
[ -z "${SF_COR_ACTIVATION_VALIDATOR:-}" ] || exit 89
printf '%s\n' activate >>"$UPDATE_LOG"
printf '%s\n' "$2-$3" >"$XDG_DATA_HOME/sf-cor-dev/current-sentinel"
SH
chmod +x "$worktree/scripts/"*.sh

update_log="$worktree/update.log"
mkdir -p "$worktree/hostile"
printf '%s\n' '#!/bin/sh' 'exit 97' >"$worktree/hostile/override"
chmod +x "$worktree/hostile/override"
export UPDATE_LOG="$update_log" XDG_DATA_HOME="$worktree/data"
export EXPECTED_CANDIDATE="$worktree/build/Sf-Cor-Dev" EXPECTED_SOURCE_SHA="$source_sha"
export EXPECTED_MANIFEST_SHA="$manifest_sha"
export SF_COR_ENGINE="$worktree/hostile/engine" SF_COR_BUILD_OUTPUT="$worktree/hostile/output"
export SF_COR_PROVENANCE_COMMAND="$worktree/hostile/override"
export SF_COR_NNUE_COMMAND="$worktree/hostile/override"
export SF_COR_BUILD_COMMAND="$worktree/hostile/override"
export SF_COR_UCI_COMMAND="$worktree/hostile/override"
export SF_COR_BENCH_COMMAND="$worktree/hostile/override"
export SF_COR_PERFT_COMMAND="$worktree/hostile/override"
export SF_COR_REPROSEARCH_COMMAND="$worktree/hostile/override"
export SF_COR_SMOKE_COMMAND="$worktree/hostile/override"
export SF_COR_ACTIVATION_VALIDATOR="$worktree/hostile/override"
(
  cd "$worktree"
  ./scripts/update-local.sh local-test
)
[ "$(tr '\n' ' ' <"$update_log")" = 'prefetch validate activate ' ] ||
  fail 'local updater did not preserve prefetch, validation/build, activation order'
[ "$(tr -d '\n' <"$worktree/data/sf-cor-dev/current-sentinel")" = "$source_sha-$manifest_sha" ] ||
  fail 'local updater did not activate the verified candidate identity'

: >"$update_log"
printf '%s\n' known-good >"$worktree/data/sf-cor-dev/current-sentinel"
if VALIDATE_FAIL=1 sh -c "cd '$worktree' && ./scripts/update-local.sh local-test"; then
  fail 'local updater accepted failed validation'
fi
[ "$(tr -d '\n' <"$worktree/data/sf-cor-dev/current-sentinel")" = known-good ] ||
  fail 'failed local update replaced the active known-good engine'
[ "$(tr '\n' ' ' <"$update_log")" = 'prefetch validate ' ] ||
  fail 'failed validation did not stop before activation'

printf '%s\n' 'local updater tests passed'
