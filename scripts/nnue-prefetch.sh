#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/guards.sh
. "$script_dir/lib/guards.sh"

root=$(resolve_repository_root "$script_dir")
mode=prefetch
if [ "${1:-}" = --verify-only ]; then
  mode=verify
  shift
fi
manifest=$(require_owned_manifest "$root" "${1:-manifests/nnue.json}" nnue.json)
[ "$#" -le 1 ] || fail 'usage: nnue-prefetch.sh [--verify-only] [manifest]'
require_command sha256sum
require_command mktemp

manifest_values=$(
  python3 - "$manifest" <<'PY'
import json
import re
import sys
from urllib.parse import urlsplit

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, dict) or set(value) != {"schema", "filename", "url", "sha256"}:
    raise SystemExit(1)
if value["schema"] != 1:
    raise SystemExit(1)
filename = value["filename"]
url = value["url"]
digest = value["sha256"]
if not isinstance(filename, str) or not re.fullmatch(r"nn-[0-9a-f]{12}\.nnue", filename):
    raise SystemExit(1)
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit(1)
if filename != f"nn-{digest[:12]}.nnue":
    raise SystemExit(1)
if not isinstance(url, str) or any(character.isspace() for character in url):
    raise SystemExit(1)
parsed = urlsplit(url)
if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
    raise SystemExit(1)
if parsed.query or parsed.fragment or parsed.path.rsplit("/", 1)[-1] != filename:
    raise SystemExit(1)
print(filename, url, digest)
PY
) || fail 'invalid NNUE manifest'
set -f
set -- $manifest_values
set +f
[ "$#" -eq 3 ] || fail 'invalid NNUE manifest'
filename=$1
url=$2
digest=$3
require_sha256 "$digest"

cache_home=${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}
cache_home_existed=false
product_dir_existed=false
cache_dir_existed=false
[ -d "$cache_home" ] && [ ! -L "$cache_home" ] && cache_home_existed=true
[ -d "$cache_home/sf-cor-dev" ] && [ ! -L "$cache_home/sf-cor-dev" ] && product_dir_existed=true
[ -d "$cache_home/sf-cor-dev/nnue" ] && [ ! -L "$cache_home/sf-cor-dev/nnue" ] && cache_dir_existed=true
if [ "$mode" = verify ]; then
  cache_dir=$(require_safe_directory "$cache_home/sf-cor-dev/nnue" existing)
else
  cache_dir=$(require_safe_directory "$cache_home/sf-cor-dev/nnue" create)
fi
cache_object="$cache_dir/$digest"
lock_dir="$cache_object.lock"
lock_owned=false
temporary=
cache_success=false
cleanup() {
  [ -z "$temporary" ] || rm -f -- "$temporary"
  if [ "$lock_owned" = true ]; then
    lock_owned=false
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  if [ "$mode" = prefetch ] && [ "$cache_success" = false ]; then
    [ "$cache_dir_existed" = true ] || rmdir "$cache_dir" 2>/dev/null || true
    [ "$product_dir_existed" = true ] || rmdir "$cache_home/sf-cor-dev" 2>/dev/null || true
    [ "$cache_home_existed" = true ] || rmdir "$cache_home" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

if [ "$mode" = prefetch ]; then
  mkdir "$lock_dir" 2>/dev/null || fail 'another NNUE prefetch holds the cache lock'
  lock_owned=true
fi
if [ -e "$cache_object" ] || [ -L "$cache_object" ]; then
  [ ! -L "$cache_object" ] || fail 'cached NNUE object must not be a symlink'
  [ -f "$cache_object" ] || fail 'cached NNUE object is not a regular file'
  actual=$(sha256sum "$cache_object" | cut -d ' ' -f 1)
  [ "$actual" = "$digest" ] || fail 'cached NNUE object failed checksum verification'
  cache_success=true
  if [ "$mode" = verify ]; then
    printf '%s %s\n' "$filename" "$digest"
  else
    printf 'verified cached NNUE: %s\n' "$cache_object"
  fi
  exit 0
fi
[ "$mode" = prefetch ] || fail 'declared NNUE cache object is absent'
require_command curl

temporary=$(mktemp "$cache_dir/.download.XXXXXX")
[ -f "$temporary" ] && [ ! -L "$temporary" ] || fail 'temporary NNUE download is not a regular file'
curl --fail --location --proto '=https' --tlsv1.2 --output "$temporary" "$url" ||
  fail 'NNUE download failed'
actual=$(sha256sum "$temporary" | cut -d ' ' -f 1)
[ "$actual" = "$digest" ] || fail 'downloaded NNUE object failed checksum verification'
chmod 0444 "$temporary"
mv "$temporary" "$cache_object"
temporary=
cache_success=true
printf 'cached verified NNUE: %s\n' "$cache_object"
