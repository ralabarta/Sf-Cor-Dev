#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp_dir=$(mktemp -d)
cleanup() {
  chmod -R u+w "$tmp_dir" 2>/dev/null || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expect_fail() {
  if "$@" >"$tmp_dir/command.out" 2>"$tmp_dir/command.err"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

state_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = sys.argv[1]
digest = hashlib.sha256()
if not os.path.lexists(root):
    print("absent")
    raise SystemExit
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    directories.sort()
    files.sort()
    for name in directories + files:
        path = os.path.join(current, name)
        relative = os.path.relpath(path, root)
        info = os.lstat(path)
        digest.update(f"{relative}\0{stat.S_IFMT(info.st_mode):o}\0{stat.S_IMODE(info.st_mode):o}\0".encode())
        if stat.S_ISLNK(info.st_mode):
            digest.update(os.readlink(path).encode())
        elif stat.S_ISREG(info.st_mode):
            with open(path, "rb") as source:
                digest.update(source.read())
print(digest.hexdigest())
PY
}

assert_unchanged_after_failure() {
  before=$(state_digest "$data_root")
  expect_fail "$@"
  after=$(state_digest "$data_root")
  [ "$after" = "$before" ] || fail "failed command changed activation state: $*"
}

write_candidate() {
  path=$1
  label=$2
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$label" >"$path"
  chmod 0755 "$path"
}

for required in scripts/activate.sh scripts/rollback.sh; do
  [ -f "$workspace_root/$required" ] || fail "required activation file is absent: $required"
done

worktree="$tmp_dir/worktree"
mkdir -p "$worktree/scripts/lib" "$worktree/build" "$worktree/bin"
git -C "$worktree" init -q -b main
git -C "$worktree" config user.email test@example.invalid
git -C "$worktree" config user.name 'Activation Test'
printf '%s\n' seed >"$worktree/README.md"
git -C "$worktree" add README.md
git -C "$worktree" commit -qm seed
source_sha=$(git -C "$worktree" rev-parse HEAD)
cp "$workspace_root/scripts/activate.sh" "$worktree/scripts/activate.sh"
cp "$workspace_root/scripts/rollback.sh" "$worktree/scripts/rollback.sh"
cp "$workspace_root/scripts/lib/guards.sh" "$worktree/scripts/lib/guards.sh"
chmod +x "$worktree/scripts/activate.sh" "$worktree/scripts/rollback.sh"

validator="$worktree/bin/validator"
cat >"$validator" <<'SH'
#!/bin/sh
set -eu
candidate=$1
[ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ] || exit 70
[ "${VALIDATOR_FAIL:-0}" -eq 0 ] || exit 71
if [ "${VALIDATOR_TAMPER:-0}" -eq 1 ]; then
  chmod u+w "$candidate"
  printf '%s\n' tampered >>"$candidate"
fi
if [ -n "${VALIDATOR_READY_FIFO:-}" ]; then
  printf '%s\n' ready >"$VALIDATOR_READY_FIFO"
  IFS= read -r release <"$VALIDATOR_RELEASE_FIFO"
  [ "$release" = release ] || exit 72
fi
"$candidate" >/dev/null
SH
chmod +x "$validator"

data_home="$worktree/data"
data_root="$data_home/sf-cor-dev"
export XDG_DATA_HOME="$data_home" SF_COR_ACTIVATION_VALIDATOR="$validator"
activate() {
  (cd "$worktree" && ./scripts/activate.sh "$@")
}
rollback() {
  (cd "$worktree" && ./scripts/rollback.sh "$@")
}

manifest_one=1111111111111111111111111111111111111111111111111111111111111111
manifest_two=2222222222222222222222222222222222222222222222222222222222222222
manifest_three=3333333333333333333333333333333333333333333333333333333333333333
version_one="$source_sha-$manifest_one"
version_two="$source_sha-$manifest_two"
version_three="$source_sha-$manifest_three"
candidate_one="$worktree/build/stockfish-one"
candidate_two="$worktree/build/stockfish-two"
candidate_three="$worktree/build/stockfish-three"
write_candidate "$candidate_one" version-one
write_candidate "$candidate_two" version-two
write_candidate "$candidate_three" version-three

activate "$candidate_one" "$source_sha" "$manifest_one"
[ "$(readlink "$data_root/current")" = "versions/$version_one/stockfish" ] || fail 'first activation did not select the versioned binary'
[ ! -e "$data_root/previous" ] && [ ! -L "$data_root/previous" ] || fail 'first activation created a previous link'
[ "$($data_root/current)" = version-one ] || fail 'stable current link is not executable'
[ "$(stat -c %a "$data_root/versions/$version_one/stockfish")" = 555 ] || fail 'versioned binary is not immutable by mode'

activate "$candidate_two" "$source_sha" "$manifest_two"
[ "$(readlink "$data_root/current")" = "versions/$version_two/stockfish" ] || fail 'replacement did not switch current'
[ "$(readlink "$data_root/previous")" = "versions/$version_one/stockfish" ] || fail 'replacement did not retain previous'
rollback
[ "$(readlink "$data_root/current")" = "versions/$version_one/stockfish" ] || fail 'rollback did not restore previous'
[ "$(readlink "$data_root/previous")" = "versions/$version_two/stockfish" ] || fail 'rollback did not retain displaced current'

assert_unchanged_after_failure activate "$worktree/build/missing" "$source_sha" "$manifest_three"
mkdir "$worktree/build/directory"
assert_unchanged_after_failure activate "$worktree/build/directory" "$source_sha" "$manifest_three"
cp "$candidate_three" "$worktree/build/non-executable"
chmod 0644 "$worktree/build/non-executable"
assert_unchanged_after_failure activate "$worktree/build/non-executable" "$source_sha" "$manifest_three"
ln -s "$candidate_three" "$worktree/build/symlinked"
assert_unchanged_after_failure activate "$worktree/build/symlinked" "$source_sha" "$manifest_three"
VALIDATOR_FAIL=1 export VALIDATOR_FAIL
assert_unchanged_after_failure activate "$candidate_three" "$source_sha" "$manifest_three"
unset VALIDATOR_FAIL
candidate_tamper="$worktree/build/tamper"
write_candidate "$candidate_tamper" tamper
VALIDATOR_TAMPER=1 export VALIDATOR_TAMPER
assert_unchanged_after_failure activate "$candidate_tamper" "$source_sha" "$manifest_three"
unset VALIDATOR_TAMPER
assert_unchanged_after_failure activate "$candidate_three" '../escape' "$manifest_three"
assert_unchanged_after_failure activate "$candidate_three" "$source_sha" '../escape'

collision="$worktree/build/collision"
write_candidate "$collision" collision
assert_unchanged_after_failure activate "$collision" "$source_sha" "$manifest_one"

foreign="$tmp_dir/foreign"
mkdir "$foreign"
ln -s "$foreign" "$worktree/linked-data"
foreign_before=$(state_digest "$foreign")
expect_fail env XDG_DATA_HOME="$worktree/linked-data" SF_COR_ACTIVATION_VALIDATOR="$validator" sh -c "cd '$worktree' && ./scripts/activate.sh '$candidate_three' '$source_sha' '$manifest_three'"
[ "$(state_digest "$foreign")" = "$foreign_before" ] || fail 'symlinked data root escaped into a foreign root'

original_previous=$(readlink "$data_root/previous")
rm "$data_root/previous"
ln -s "$tmp_dir/foreign-binary" "$data_root/previous"
assert_unchanged_after_failure rollback
rm "$data_root/previous"
ln -s "$original_previous" "$data_root/previous"

version_two_binary="$data_root/versions/$version_two/stockfish"
chmod u+w "$version_two_binary"
printf '%s\n' tampered >>"$version_two_binary"
chmod 0555 "$version_two_binary"
assert_unchanged_after_failure rollback
chmod u+w "$version_two_binary"
cp "$candidate_two" "$version_two_binary"
chmod 0555 "$version_two_binary"
activate "$candidate_two" "$source_sha" "$manifest_two"
rollback

real_mv=$(command -v mv)
cat >"$worktree/bin/mv" <<'SH'
#!/bin/sh
set -eu
count=0
[ ! -f "$MV_COUNT" ] || count=$(cat "$MV_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$MV_COUNT"
[ "$count" -ne "$MV_FAIL_AT" ] || exit 73
exec "$REAL_MV" "$@"
SH
chmod +x "$worktree/bin/mv"
export PATH="$worktree/bin:$PATH" REAL_MV="$real_mv" MV_COUNT="$worktree/mv.count" MV_FAIL_AT=3
assert_unchanged_after_failure activate "$candidate_three" "$source_sha" "$manifest_three"
[ ! -e "$data_root/versions/$version_three" ] || fail 'failed atomic switch retained a new version'
rm "$worktree/bin/mv" "$MV_COUNT"
unset REAL_MV MV_COUNT MV_FAIL_AT

ready_fifo="$worktree/ready.fifo"
release_fifo="$worktree/release.fifo"
mkfifo "$ready_fifo" "$release_fifo"
VALIDATOR_READY_FIFO="$ready_fifo" VALIDATOR_RELEASE_FIFO="$release_fifo" export VALIDATOR_READY_FIFO VALIDATOR_RELEASE_FIFO
activate "$candidate_three" "$source_sha" "$manifest_three" >"$worktree/background.out" 2>"$worktree/background.err" &
activation_pid=$!
IFS= read -r ready <"$ready_fifo"
[ "$ready" = ready ] || fail 'blocking validator did not acquire the activation lock'
assert_unchanged_after_failure activate "$candidate_three" "$source_sha" "$manifest_three"
printf '%s\n' release >"$release_fifo"
wait "$activation_pid" || fail 'serialized activation failed after lock release'
unset VALIDATOR_READY_FIFO VALIDATOR_RELEASE_FIFO
[ "$(readlink "$data_root/current")" = "versions/$version_three/stockfish" ] || fail 'serialized activation did not complete'
[ "$(readlink "$data_root/previous")" = "versions/$version_one/stockfish" ] || fail 'serialized activation lost the displaced current'

fresh_home="$worktree/fresh-data"
fresh_root="$fresh_home/sf-cor-dev"
before=$(state_digest "$fresh_root")
expect_fail env XDG_DATA_HOME="$fresh_home" SF_COR_ACTIVATION_VALIDATOR="$validator" sh -c "cd '$worktree' && ./scripts/rollback.sh"
[ "$(state_digest "$fresh_root")" = "$before" ] || fail 'rollback without previous changed fresh state'

[ -z "$(fd -H '^\.(current|previous)\.' "$data_root" -d 1)" ] || fail 'activation left temporary stable links'
printf '%s\n' 'activation tests passed'
