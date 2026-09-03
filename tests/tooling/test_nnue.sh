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

assert_digest() {
  expected=$1
  path=$2
  actual=$(sha256sum "$path" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || fail "unexpected digest for $path"
}

new_workspace() {
  name=$1
  worktree="$tmp_dir/$name"
  mkdir -p "$worktree/scripts/lib" "$worktree/manifests" "$worktree/src" "$worktree/bin"
  git -C "$worktree" init -q -b main
  cp "$workspace_root/scripts/nnue-prefetch.sh" "$worktree/scripts/nnue-prefetch.sh"
  cp "$workspace_root/scripts/build.sh" "$worktree/scripts/build.sh"
  cp "$workspace_root/scripts/get_native_properties.sh" "$worktree/scripts/get_native_properties.sh"
  cp "$workspace_root/scripts/net.sh" "$worktree/scripts/net.sh"
  cp "$workspace_root/scripts/lib/guards.sh" "$worktree/scripts/lib/guards.sh"
  cp "$workspace_root/manifests/nnue.json" "$worktree/manifests/nnue.json"
  chmod +x "$worktree/scripts/nnue-prefetch.sh" "$worktree/scripts/build.sh"
  printf '#define EvalFileDefaultName "%s"\n' "$test_filename" >"$worktree/src/evaluate.h"
  printf '%s\n' 'all:' >"$worktree/src/Makefile"
  printf '%s\n' reviewed >"$worktree/src/reviewed.txt"
  printf '%s\n' '*.o' '/stockfish' '/Makefile.deps' '/.cache/' '*.nnue' >"$worktree/src/.gitignore"
  git -C "$worktree" config user.name Test
  git -C "$worktree" config user.email test@example.invalid
  git -C "$worktree" add scripts manifests src
  git -C "$worktree" commit -q -m 'fixture baseline'
}

for required in manifests/nnue.json scripts/nnue-prefetch.sh scripts/build.sh; do
  [ -f "$workspace_root/$required" ] || fail "required NNUE file is absent: $required"
done

filename=$(python3 - "$workspace_root/manifests/nnue.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["filename"])
PY
)
digest=$(python3 - "$workspace_root/manifests/nnue.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["sha256"])
PY
)
declared=$(python3 - "$workspace_root/manifests/nnue.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(value) == {"schema", "filename", "url", "sha256"}
assert value["schema"] == 1
assert value["url"].startswith("https://")
print(value["filename"])
PY
)
source_filename=$(python3 - "$workspace_root/src/evaluate.h" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'^#define EvalFileDefaultName "([^"]+)"$', text, re.M)
assert match
print(match.group(1))
PY
)
[ "$declared" = "$source_filename" ] || fail 'manifest does not match pinned Stockfish network declaration'
[ "$filename" = "nn-$(printf '%s' "$digest" | cut -c 1-12).nnue" ] ||
  fail 'manifest filename does not match the full network digest'

payload="$tmp_dir/network.nnue"
printf '%s\n' 'controlled NNUE payload' >"$payload"
test_digest=$(sha256sum "$payload" | cut -d ' ' -f 1)
test_filename="nn-$(printf '%s' "$test_digest" | cut -c 1-12).nnue"

write_manifest() {
  destination=$1
  network_filename=${2:-$test_filename}
  network_url=${3:-"https://example.invalid/$network_filename"}
  network_digest=${4:-$test_digest}
  printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    "  \"filename\": \"$network_filename\"," \
    "  \"url\": \"$network_url\"," \
    "  \"sha256\": \"$network_digest\"" \
    '}' >"$destination"
}

install_fake_curl() {
  target=$1
  tee "$target" >/dev/null <<'SH'
#!/bin/sh
set -eu
output=
url=
proto=false
tls=false
fail_mode=false
location=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --output) output=$2; shift 2 ;;
    --proto) [ "$2" = '=https' ] || exit 91; proto=true; shift 2 ;;
    --tlsv1.2) tls=true; shift ;;
    --fail) fail_mode=true; shift ;;
    --location) location=true; shift ;;
    --*) exit 92 ;;
    *) url=$1; shift ;;
  esac
done
[ "$proto" = true ] && [ "$tls" = true ] && [ "$fail_mode" = true ] && [ "$location" = true ] || exit 93
[ "$url" = "$EXPECTED_URL" ] || exit 94
case $output in
  "$EXPECTED_CACHE_DIR"/.download.*) ;;
  *) exit 95 ;;
esac
printf '%s\n' invoked >>"$CURL_LOG"
cp "$DOWNLOAD_SOURCE" "$output"
[ -f "$output" ] && [ ! -L "$output" ] || exit 96
[ "${CURL_FAIL_AFTER_WRITE:-0}" -eq 0 ] || exit 97
SH
  chmod +x "$target"
}

install_fake_make() {
  target=$1
  tee "$target" >/dev/null <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MAKE_LOG"
[ "$1" = -C ] || exit 81
stage_src=$2
shift 2
[ "$1" = "ARCH=${EXPECTED_ARCH:-x86-64}" ] || exit 82
shift
if [ -n "${EXPECTED_JOBS:-}" ]; then
  [ "$1" = "-j$EXPECTED_JOBS" ] || exit 88
  shift
fi
[ "$1" = "${EXPECTED_TARGET:-all}" ] || exit 83
[ "$#" -eq 1 ] || exit 84
if [ "${EXPECTED_SUPPORT_SCRIPTS:-false}" = true ]; then
  [ -x "$stage_src/../scripts/get_native_properties.sh" ] || exit 89
  [ -x "$stage_src/../scripts/net.sh" ] || exit 90
fi
if [ "${EXPECTED_CLEAN_STAGE:-false}" = true ]; then
  [ "$(tr -d '\n' <"$stage_src/reviewed.txt")" = reviewed ] || exit 97
  for forbidden in stale.o stockfish Makefile.deps .cache/marker unreviewed.cpp nn-stale.nnue; do
    [ ! -e "$stage_src/$forbidden" ] || exit 98
  done
fi
[ ! -L "$stage_src/$EXPECTED_FILENAME" ] || exit 85
actual=$(sha256sum "$stage_src/$EXPECTED_FILENAME" | cut -d ' ' -f 1)
[ "$actual" = "$EXPECTED_DIGEST" ] || exit 86
[ "${MAKE_FAIL:-0}" -eq 0 ] || exit 87
printf '%s\n' 'controlled stockfish binary' >"$stage_src/stockfish"
chmod +x "$stage_src/stockfish"
SH
  chmod +x "$target"
}

install_fake_getconf() {
  target=$1
  tee "$target" >/dev/null <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = _NPROCESSORS_ONLN ] || exit 89
printf '%s\n' 7
SH
  chmod +x "$target"
}

new_workspace valid
write_manifest "$worktree/manifests/nnue.json"
install_fake_curl "$worktree/bin/curl"
install_fake_make "$worktree/bin/make"
install_fake_getconf "$worktree/bin/getconf"
cache_home="$worktree/cache"
cache_dir="$cache_home/sf-cor-dev/nnue"
cache_object="$cache_dir/$test_digest"
curl_log="$worktree/curl.log"
make_log="$worktree/make.log"
export PATH="$worktree/bin:$PATH" XDG_CACHE_HOME="$cache_home"
export DOWNLOAD_SOURCE="$payload" EXPECTED_URL="https://example.invalid/$test_filename"
export EXPECTED_CACHE_DIR="$cache_dir" CURL_LOG="$curl_log"
export EXPECTED_FILENAME="$test_filename" EXPECTED_DIGEST="$test_digest" MAKE_LOG="$make_log"
(
  cd "$worktree"
  ./scripts/nnue-prefetch.sh
)
[ -f "$cache_object" ] && [ ! -L "$cache_object" ] || fail 'prefetch did not publish a regular cache object'
assert_digest "$test_digest" "$cache_object"
[ "$(wc -l <"$curl_log")" -eq 1 ] || fail 'prefetch did not use the controlled TLS downloader exactly once'
[ -z "$(fd -H '^\.download\.' "$cache_dir" -d 1)" ] || fail 'prefetch left a temporary download behind'
(
  cd "$worktree"
  ./scripts/nnue-prefetch.sh
)
[ "$(wc -l <"$curl_log")" -eq 1 ] || fail 'verified cache reuse performed another download'

lock_dir="$cache_object.lock"
mkdir "$lock_dir"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
[ -d "$lock_dir" ] || fail 'failed lock acquisition removed another prefetch lock'
(
  cd "$worktree"
  ./scripts/nnue-prefetch.sh --verify-only
)
[ -d "$lock_dir" ] || fail 'verify-only cleanup removed another prefetch lock'
rm "$cache_object"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh --verify-only"
[ -d "$lock_dir" ] || fail 'failed verify-only cleanup removed another prefetch lock'
rmdir "$lock_dir"
cp "$payload" "$cache_object"

chmod 0644 "$cache_object"
printf '%s\n' tampered >"$cache_object"
before_tamper=$(sha256sum "$cache_object" | cut -d ' ' -f 1)
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
after_tamper=$(sha256sum "$cache_object" | cut -d ' ' -f 1)
[ "$after_tamper" = "$before_tamper" ] || fail 'prefetch replaced a tampered cache object'
[ "$(wc -l <"$curl_log")" -eq 1 ] || fail 'tampered cache triggered a download'
cp "$payload" "$cache_object"

build_output_path="$worktree/build/Sf-Cor-Dev"
mkdir -p "$worktree/build" "$worktree/src/.cache"
printf '%s\n' stale >"$worktree/src/stale.o"
printf '%s\n' stale >"$worktree/src/stockfish"
printf '%s\n' stale >"$worktree/src/Makefile.deps"
printf '%s\n' stale >"$worktree/src/.cache/marker"
printf '%s\n' stale >"$worktree/src/nn-stale.nnue"
printf '%s\n' unreviewed >"$worktree/src/unreviewed.cpp"
printf '%s\n' dirty >"$worktree/src/reviewed.txt"
printf '%s\n' preserved >"$build_output_path"
output_before=$(sha256sum "$build_output_path" | cut -d ' ' -f 1)
export SF_COR_BUILD_OUTPUT="$build_output_path" SF_COR_BUILD_ARCH=x86-64 EXPECTED_CLEAN_STAGE=true
(
  cd "$worktree"
  ./scripts/build.sh
)
build_output=$(tr -d '\n' <"$build_output_path")
[ "$build_output" = 'controlled stockfish binary' ] || fail 'offline build did not publish the staged binary'
[ "$(wc -l <"$make_log")" -eq 1 ] || fail 'offline build did not invoke the upstream make path exactly once'
assert_digest "$test_digest" "$cache_object"
unset SF_COR_BUILD_OUTPUT

EXPECTED_ARCH=native EXPECTED_TARGET=profile-build EXPECTED_JOBS=7 EXPECTED_SUPPORT_SCRIPTS=true \
  export EXPECTED_ARCH EXPECTED_TARGET EXPECTED_JOBS EXPECTED_SUPPORT_SCRIPTS
(
  cd "$worktree"
  ./scripts/build.sh --profile local
)
[ ! -e "$worktree/build/stockfish" ] || fail 'local profile published the internal Make target as a public build name'
[ -x "$worktree/build/Sf-Cor-Dev" ] || fail 'local profile did not publish the Sf-Cor-Dev binary'
[ "$(wc -l <"$make_log")" -eq 2 ] || fail 'local profile did not invoke make exactly once'
rg -q 'ARCH=native -j7 profile-build$' "$make_log" ||
  fail 'local profile did not use native profile-build with detected parallelism'
unset EXPECTED_ARCH EXPECTED_TARGET EXPECTED_JOBS EXPECTED_SUPPORT_SCRIPTS

printf '%s\n' preserved >"$build_output_path"
MAKE_FAIL=1 export MAKE_FAIL
expect_fail sh -c "cd '$worktree' && ./scripts/build.sh"
unset MAKE_FAIL
assert_digest "$output_before" "$build_output_path"
[ -z "$(fd -H '^\.build\.' "$worktree" -d 1)" ] || fail 'failed build left staging state behind'

make_count=$(wc -l <"$make_log")
cache_before=$(sha256sum "$cache_object" | cut -d ' ' -f 1)
printf '%s\n' 'external sentinel' >"$tmp_dir/external-output"
external_before=$(sha256sum "$tmp_dir/external-output" | cut -d ' ' -f 1)
printf '%s\n' 'repository sentinel' >"$worktree/escaped-output"
repository_before=$(sha256sum "$worktree/escaped-output" | cut -d ' ' -f 1)
expect_fail env SF_COR_BUILD_OUTPUT="$worktree/escaped-output" sh -c "cd '$worktree' && ./scripts/build.sh"
assert_digest "$repository_before" "$worktree/escaped-output"
expect_fail env SF_COR_BUILD_OUTPUT="$worktree/build/../escaped-output" sh -c "cd '$worktree' && ./scripts/build.sh"
assert_digest "$repository_before" "$worktree/escaped-output"
expect_fail env SF_COR_BUILD_OUTPUT='../external-output' sh -c "cd '$worktree' && ./scripts/build.sh"
expect_fail env SF_COR_BUILD_OUTPUT="$tmp_dir/external-output" sh -c "cd '$worktree' && ./scripts/build.sh"
assert_digest "$external_before" "$tmp_dir/external-output"
mkdir "$tmp_dir/external-build"
ln -s "$tmp_dir/external-build" "$worktree/build/linked"
expect_fail env SF_COR_BUILD_OUTPUT="$worktree/build/linked/Sf-Cor-Dev" sh -c "cd '$worktree' && ./scripts/build.sh"
[ ! -e "$tmp_dir/external-build/Sf-Cor-Dev" ] || fail 'symlinked build output escaped the staging root'
printf '%s\n' unsafe >"$worktree/build/not-a-directory"
expect_fail env SF_COR_BUILD_OUTPUT="$worktree/build/not-a-directory/Sf-Cor-Dev" sh -c "cd '$worktree' && ./scripts/build.sh"
[ "$(wc -l <"$make_log")" -eq "$make_count" ] || fail 'rejected output path invoked make'
assert_digest "$cache_before" "$cache_object"
assert_digest "$output_before" "$build_output_path"
[ -z "$(fd -H '^\.build\.' "$worktree" -d 1)" ] || fail 'rejected output path left staging state behind'

chmod 0644 "$cache_object"
printf '%s\n' tampered >"$cache_object"
make_count=$(wc -l <"$make_log")
expect_fail sh -c "cd '$worktree' && ./scripts/build.sh"
[ "$(wc -l <"$make_log")" -eq "$make_count" ] || fail 'build invoked make with a tampered cache object'
assert_digest "$output_before" "$build_output_path"
rm "$cache_object"
ln -s "$payload" "$cache_object"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
[ -L "$cache_object" ] || fail 'prefetch replaced a symlink cache object'

new_workspace mismatch
zero_digest=0000000000000000000000000000000000000000000000000000000000000000
mismatch_filename=nn-000000000000.nnue
write_manifest "$worktree/manifests/nnue.json" "$mismatch_filename" "https://example.invalid/$mismatch_filename" "$zero_digest"
install_fake_curl "$worktree/bin/curl"
cache_home="$worktree/cache"
cache_dir="$cache_home/sf-cor-dev/nnue"
export PATH="$worktree/bin:$PATH" XDG_CACHE_HOME="$cache_home" EXPECTED_CACHE_DIR="$cache_dir"
export EXPECTED_URL="https://example.invalid/$mismatch_filename" CURL_LOG="$worktree/curl.log"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
[ ! -e "$cache_dir/$zero_digest" ] || fail 'checksum mismatch published a cache object'
[ ! -e "$cache_home" ] || fail 'checksum mismatch changed empty cache state'
[ -z "$(fd -H '^\.download\.' "$cache_dir" -d 1 2>/dev/null || true)" ] || fail 'checksum mismatch left temporary state'

new_workspace hostile
install_fake_curl "$worktree/bin/curl"
export PATH="$worktree/bin:$PATH" XDG_CACHE_HOME="$worktree/cache"
write_manifest "$worktree/manifests/nnue.json"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh ../nnue.json"
write_manifest "$worktree/manifests/nnue.json" '../network.nnue'
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
write_manifest "$worktree/manifests/nnue.json" "$test_filename" "http://example.invalid/$test_filename"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
write_manifest "$worktree/manifests/nnue.json" "$test_filename" "https://example.invalid/$test_filename" "$(printf '%s' "$test_digest" | tr a-f A-F)"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
printf '%s\n' '{invalid' >"$worktree/manifests/nnue.json"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
rm "$worktree/manifests/nnue.json"
ln -s "$workspace_root/manifests/nnue.json" "$worktree/manifests/nnue.json"
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"
rm "$worktree/manifests/nnue.json"
write_manifest "$worktree/manifests/nnue.json"
mkdir "$worktree/real-cache"
ln -s "$worktree/real-cache" "$worktree/cache-link"
XDG_CACHE_HOME="$worktree/cache-link" export XDG_CACHE_HOME
expect_fail sh -c "cd '$worktree' && ./scripts/nnue-prefetch.sh"

printf '%s\n' 'NNUE tests passed'
