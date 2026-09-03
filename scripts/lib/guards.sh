#!/bin/sh

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

resolve_repository_root() {
  scripts_dir=$1
  expected=$(CDPATH= cd -- "$scripts_dir/.." && pwd -P)
  root=$(git -C "$expected" rev-parse --show-toplevel 2>/dev/null) ||
    fail 'scripts are not inside a Git repository'
  root=$(CDPATH= cd -- "$root" && pwd -P)
  [ "$root" = "$expected" ] || fail 'script location does not match repository root'
  [ "$(pwd -P)" = "$root" ] || fail 'current directory does not match repository root'
  printf '%s\n' "$root"
}

require_owned_manifest() {
  root=$1
  candidate=$2
  name=$3
  case $candidate in
    "manifests/$name") path="$root/$candidate" ;;
    "$root/manifests/$name") path=$candidate ;;
    *) fail "manifest path is outside its reviewed boundary: $candidate" ;;
  esac
  [ ! -L "$path" ] || fail "manifest must not be a symlink: $path"
  [ -f "$path" ] || fail "manifest is not a regular file: $path"
  [ ! -x "$path" ] || fail "manifest must not be executable: $path"
  printf '%s\n' "$path"
}

require_sha256() {
  case $1 in
    *[!0-9a-f]*|'') fail "invalid full SHA-256: $1" ;;
  esac
  [ "${#1}" -eq 64 ] || fail "invalid full SHA-256: $1"
}

require_safe_directory() {
  candidate=$1
  mode=$2
  require_command python3
  python3 - "$candidate" "$mode" <<'PY' || fail "unsafe directory path: $candidate"
import os
import stat
import sys

path, mode = sys.argv[1:]
if mode not in {"create", "existing"} or not os.path.isabs(path):
    raise SystemExit(1)
path = os.path.normpath(path)
if path == os.sep:
    raise SystemExit(1)
current = os.sep
for component in path.split(os.sep)[1:]:
    current = os.path.join(current, component)
    try:
        info = os.lstat(current)
    except FileNotFoundError:
        if mode != "create":
            raise SystemExit(1)
        os.mkdir(current, 0o700)
        info = os.lstat(current)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise SystemExit(1)
print(path)
PY
}

require_commit_sha() {
  case $1 in
    *[!0-9a-f]*|'') fail "invalid full commit identity: $1" ;;
  esac
  [ "${#1}" -eq 40 ] || fail "invalid full commit identity: $1"
}

require_clean_repository() {
  root=$1
  git -C "$root" diff --quiet || fail 'tracked worktree is dirty'
  git -C "$root" diff --cached --quiet || fail 'integration index is not empty'
  git_dir=$(git -C "$root" rev-parse --git-dir)
  case $git_dir in
    /*) ;;
    *) git_dir="$root/$git_dir" ;;
  esac
  for state in CHERRY_PICK_HEAD MERGE_HEAD REVERT_HEAD; do
    [ ! -e "$git_dir/$state" ] || fail "repository operation is already active: $state"
  done
}

acquire_intake_lock() {
  root=$1
  common=$(git -C "$root" rev-parse --git-common-dir)
  case $common in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  intake_lock="$common/sf-cor-dev-intake.lock"
  mkdir "$intake_lock" 2>/dev/null || fail 'another intake operation holds the lock'
  trap 'rmdir "$intake_lock"' EXIT HUP INT TERM
}
