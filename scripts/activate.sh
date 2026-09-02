#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/guards.sh
. "$script_dir/lib/guards.sh"

root=$(resolve_repository_root "$script_dir")
mode=activate
if [ "${1:-}" = --rollback ]; then
  mode=rollback
  shift
fi

require_command chmod
require_command cp
require_command cut
require_command dirname
require_command flock
require_command git
require_command ln
require_command mktemp
require_command mv
require_command python3
require_command readlink
require_command rm
require_command rmdir
require_command sha256sum
require_command stat
require_command tr

require_identifier() {
  value=$1
  label=$2
  case $value in
    *[!0-9a-f]*|'') fail "invalid $label identity" ;;
  esac
}

safe_executable() {
  boundary=$1
  candidate=$2
  python3 - "$boundary" "$candidate" <<'PY'
import os
import stat
import sys

boundary, candidate = map(os.path.normpath, sys.argv[1:])
if not os.path.isabs(boundary) or not os.path.isabs(candidate):
    raise SystemExit(1)
if os.path.commonpath((boundary, candidate)) != boundary or candidate == boundary:
    raise SystemExit(1)
current = os.sep
for component in candidate.split(os.sep)[1:]:
    current = os.path.join(current, component)
    info = os.lstat(current)
    if stat.S_ISLNK(info.st_mode):
        raise SystemExit(1)
if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
    raise SystemExit(1)
print(candidate)
PY
}

version_target() {
  link=$1
  name=$2
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    printf '\n'
    return
  fi
  [ -L "$link" ] || fail "$name is not a stable symlink"
  target=$(readlink "$link") || fail "cannot read $name"
  case $target in
    versions/[0-9a-f]*-[0-9a-f]*/stockfish) ;;
    *) fail "$name has an unsafe version target" ;;
  esac
  remainder=${target#versions/}
  identity=${remainder%/stockfish}
  source_part=${identity%%-*}
  manifest_part=${identity#*-}
  require_commit_sha "$source_part"
  require_sha256 "$manifest_part"
  [ "$identity" = "$source_part-$manifest_part" ] || fail "$name has an unsafe version target"
  validate_version "$identity"
  printf '%s\n' "$target"
}

validate_version() {
  identity=$1
  directory="$versions_dir/$identity"
  binary="$directory/stockfish"
  checksum="$directory/stockfish.sha256"
  [ -d "$directory" ] && [ ! -L "$directory" ] || fail 'retained version directory is unsafe'
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || fail 'retained version binary is unsafe'
  [ -f "$checksum" ] && [ ! -L "$checksum" ] || fail 'retained version checksum is unsafe'
  [ "$(stat -c %a "$directory")" = 555 ] || fail 'retained version directory is mutable'
  [ "$(stat -c %a "$binary")" = 555 ] || fail 'retained version binary is mutable'
  [ "$(stat -c %a "$checksum")" = 444 ] || fail 'retained version checksum is mutable'
  expected=$(tr -d '\n' <"$checksum")
  require_sha256 "$expected"
  actual=$(sha256sum "$binary" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || fail 'retained version failed checksum verification'
}

make_link() {
  name=$1
  target=$2
  temporary=$(mktemp "$data_root/.$name.XXXXXX") || fail "cannot reserve temporary $name link"
  rm -f -- "$temporary"
  ln -s "$target" "$temporary" || fail "cannot create temporary $name link"
  case $name in
    current) current_tmp=$temporary ;;
    previous) previous_tmp=$temporary ;;
    restore) restore_tmp=$temporary ;;
  esac
}

switch_links() {
  new_current=$1
  displaced=$2
  old_previous=$3
  make_link current "$new_current"
  if [ -n "$displaced" ]; then
    make_link previous "$displaced"
    if ! mv -Tf "$previous_tmp" "$data_root/previous"; then
      fail 'cannot atomically retain previous version'
    fi
    previous_tmp=
  fi
  if mv -Tf "$current_tmp" "$data_root/current"; then
    current_tmp=
    return
  fi
  if [ -n "$displaced" ]; then
    if [ -n "$old_previous" ]; then
      make_link restore "$old_previous"
      mv -Tf "$restore_tmp" "$data_root/previous" || fail 'current switch failed and previous restoration failed'
      restore_tmp=
    else
      rm -f -- "$data_root/previous"
    fi
  fi
  fail 'cannot atomically switch current version'
}

if [ "$mode" = activate ]; then
  [ "$#" -eq 3 ] || fail 'usage: activate.sh <candidate> <source-sha> <manifest-sha256>'
  candidate=$1
  source_sha=$2
  manifest_sha=$3
  require_commit_sha "$source_sha"
  require_identifier "$manifest_sha" manifest
  require_sha256 "$manifest_sha"
  git -C "$root" cat-file -e "$source_sha^{commit}" 2>/dev/null || fail 'source identity is not a committed object'
  candidate=$(safe_executable "$root/build" "$candidate") || fail 'candidate is outside the safe build root or is not an executable regular file'
  validator=${SF_COR_ACTIVATION_VALIDATOR:-}
  if [ -n "$validator" ]; then
    case $validator in /*) ;; *) fail 'activation validator must be an absolute path' ;; esac
    validator=$(safe_executable "$(dirname -- "$validator")" "$validator") || fail 'activation validator is unsafe'
  else
    require_command rg
  fi
else
  [ "$#" -eq 0 ] || fail 'usage: rollback.sh'
fi

data_home=${XDG_DATA_HOME:-${HOME:?HOME is required}/.local/share}
data_root="$data_home/sf-cor-dev"
if [ "$mode" = rollback ]; then
  data_root=$(require_safe_directory "$data_root" existing)
else
  data_root=$(require_safe_directory "$data_root" create)
fi
versions_dir="$data_root/versions"
lock_path="$data_root/activation.lock"
[ ! -L "$lock_path" ] || fail 'activation lock must not be a symlink'
if [ -e "$lock_path" ]; then
  [ -f "$lock_path" ] || fail 'activation lock is not a regular file'
fi
exec 9>"$lock_path"
chmod 0600 "$lock_path"
flock -n 9 || fail 'another activation or rollback holds the lock'

if [ "$mode" = rollback ]; then
  versions_dir=$(require_safe_directory "$versions_dir" existing)
  current_target=$(version_target "$data_root/current" current)
  previous_target=$(version_target "$data_root/previous" previous)
  [ -n "$current_target" ] || fail 'rollback requires an active current version'
  [ -n "$previous_target" ] || fail 'rollback requires a retained previous version'
  current_tmp=
  previous_tmp=
  restore_tmp=
  cleanup() {
    [ -z "$current_tmp" ] || rm -f -- "$current_tmp"
    [ -z "$previous_tmp" ] || rm -f -- "$previous_tmp"
    [ -z "$restore_tmp" ] || rm -f -- "$restore_tmp"
  }
  trap cleanup EXIT HUP INT TERM
  switch_links "$previous_target" "$current_target" "$previous_target"
  printf 'rolled back active Stockfish: %s\n' "$data_root/current"
  exit 0
fi

candidate_before=$(sha256sum "$candidate" | cut -d ' ' -f 1)
if [ -n "$validator" ]; then
  "$validator" "$candidate" || fail 'candidate validation failed'
else
  validation_output=$(mktemp "$data_root/.validation.XXXXXX")
  if ! printf 'uci\nquit\n' | "$candidate" >"$validation_output" 2>&1 || ! rg -q '^uciok$' "$validation_output"; then
    rm -f -- "$validation_output"
    fail 'candidate validation failed'
  fi
  rm -f -- "$validation_output"
fi
candidate_after=$(sha256sum "$candidate" | cut -d ' ' -f 1)
[ "$candidate_after" = "$candidate_before" ] || fail 'candidate changed during validation'

versions_dir_existed=false
[ -d "$versions_dir" ] && [ ! -L "$versions_dir" ] && versions_dir_existed=true
versions_dir=$(require_safe_directory "$versions_dir" create)
identity="$source_sha-$manifest_sha"
version_dir="$versions_dir/$identity"
stage=
created_version=false
current_tmp=
previous_tmp=
restore_tmp=
activation_success=false
cleanup() {
  [ -z "$current_tmp" ] || rm -f -- "$current_tmp"
  [ -z "$previous_tmp" ] || rm -f -- "$previous_tmp"
  [ -z "$restore_tmp" ] || rm -f -- "$restore_tmp"
  [ -z "$stage" ] || rm -rf -- "$stage"
  if [ "$activation_success" = false ] && [ "$created_version" = true ]; then
    chmod u+w "$version_dir" 2>/dev/null || true
    rm -rf -- "$version_dir"
  fi
  if [ "$activation_success" = false ] && [ "$versions_dir_existed" = false ]; then
    rmdir "$versions_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM
current_target=$(version_target "$data_root/current" current)
previous_target=$(version_target "$data_root/previous" previous)
[ -n "$current_target" ] || [ -z "$previous_target" ] || fail 'previous exists without an active current version'

if [ -e "$version_dir" ] || [ -L "$version_dir" ]; then
  [ ! -L "$version_dir" ] || fail 'version identity collides with a symlink'
  validate_version "$identity"
  existing=$(tr -d '\n' <"$version_dir/stockfish.sha256")
  [ "$existing" = "$candidate_before" ] || fail 'version identity collides with different content'
else
  stage=$(mktemp -d "$versions_dir/.version.XXXXXX")
  cp "$candidate" "$stage/stockfish"
  staged=$(sha256sum "$stage/stockfish" | cut -d ' ' -f 1)
  [ "$staged" = "$candidate_before" ] || fail 'staged candidate failed checksum verification'
  printf '%s\n' "$staged" >"$stage/stockfish.sha256"
  chmod 0555 "$stage/stockfish"
  chmod 0444 "$stage/stockfish.sha256"
  chmod 0555 "$stage"
  mv "$stage" "$version_dir" || fail 'cannot publish immutable version'
  stage=
  created_version=true
fi

new_target="versions/$identity/stockfish"
if [ "$current_target" = "$new_target" ]; then
  activation_success=true
  printf 'active Stockfish already selected: %s\n' "$data_root/current"
  exit 0
fi
switch_links "$new_target" "$current_target" "$previous_target"
activation_success=true
printf 'activated Stockfish: %s\n' "$data_root/current"
