#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/guards.sh
. "$script_dir/lib/guards.sh"

root=$(resolve_repository_root "$script_dir")
manifest=$(require_owned_manifest "$root" "${1:-manifests/nnue.json}" nnue.json)
[ "$#" -le 1 ] || fail 'usage: build.sh [manifest]'
require_command sha256sum
require_command mktemp
require_command make

manifest_values=$("$script_dir/nnue-prefetch.sh" --verify-only "$manifest") ||
  fail 'declared NNUE cache object is unavailable'
set -f
set -- $manifest_values
set +f
[ "$#" -eq 2 ] || fail 'invalid verified NNUE result'
filename=$1
digest=$2
require_sha256 "$digest"
cache_home=${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}
cache_dir=$(require_safe_directory "$cache_home/sf-cor-dev/nnue" existing)
cache_object="$cache_dir/$digest"

source_filename=$(
  python3 - "$root/src/evaluate.h" <<'PY'
import re
import sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except (OSError, UnicodeError):
    raise SystemExit(1)
match = re.search(r'^#define EvalFileDefaultName "([^"]+)"$', text, re.M)
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
) || fail 'pinned Stockfish network declaration is invalid'
[ "$source_filename" = "$filename" ] || fail 'manifest network does not match pinned Stockfish source'

[ ! -L "$cache_object" ] || fail 'cached NNUE object must not be a symlink'
[ -f "$cache_object" ] || fail 'declared NNUE cache object is absent'
actual=$(sha256sum "$cache_object" | cut -d ' ' -f 1)
[ "$actual" = "$digest" ] || fail 'cached NNUE object failed checksum verification'

arch=${SF_COR_BUILD_ARCH:-x86-64}
case $arch in
  *[!A-Za-z0-9._-]*|'') fail 'invalid build architecture' ;;
esac
staging_root="$root/build"
output=${SF_COR_BUILD_OUTPUT:-"$staging_root/stockfish"}
output=$(
  python3 - "$staging_root" "$output" <<'PY'
import os
import stat
import sys

staging_root, output = sys.argv[1:]
if not os.path.isabs(staging_root) or not os.path.isabs(output):
    raise SystemExit(1)
staging_root = os.path.normpath(staging_root)
output = os.path.normpath(output)
if output == staging_root or os.path.commonpath((staging_root, output)) != staging_root:
    raise SystemExit(1)
current = os.sep
for component in os.path.dirname(output).split(os.sep)[1:]:
    current = os.path.join(current, component)
    try:
        info = os.lstat(current)
    except FileNotFoundError:
        break
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SystemExit(1)
try:
    info = os.lstat(output)
except FileNotFoundError:
    pass
else:
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
print(output)
PY
) || fail 'build output is outside the safe staging root'
output_parent=$(dirname -- "$output")
output_parent_existed=false
[ -d "$output_parent" ] && [ ! -L "$output_parent" ] && output_parent_existed=true
output_parent=$(require_safe_directory "$output_parent" create)

stage=$(mktemp -d "$root/.build.XXXXXX")
output_tmp=
build_success=false
cleanup() {
  [ -z "$output_tmp" ] || rm -f -- "$output_tmp"
  rm -rf -- "$stage"
  if [ "$build_success" = false ] && [ "$output_parent_existed" = false ]; then
    rmdir "$output_parent" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM
cp -R "$root/src" "$stage/src"
cp "$cache_object" "$stage/src/$filename"
actual=$(sha256sum "$stage/src/$filename" | cut -d ' ' -f 1)
[ "$actual" = "$digest" ] || fail 'staged NNUE object failed checksum verification'

make -C "$stage/src" "ARCH=$arch" all
binary="$stage/src/stockfish"
[ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] ||
  fail 'upstream build did not produce an executable regular file'
output_tmp=$(mktemp "$output_parent/.stockfish.XXXXXX")
cp "$binary" "$output_tmp"
chmod 0755 "$output_tmp"
mv "$output_tmp" "$output"
output_tmp=
build_success=true
printf 'built Stockfish offline: %s\n' "$output"
