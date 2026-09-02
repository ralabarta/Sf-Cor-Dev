#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
suites_file="$script_dir/suites.list"
result=0

while IFS= read -r suite || [ -n "$suite" ]; do
  case $suite in
    ''|'#'*) continue ;;
  esac

  suite_path="$workspace_root/$suite"
  if [ ! -f "$suite_path" ] || [ ! -x "$suite_path" ]; then
    printf 'declared suite is not executable: %s\n' "$suite" >&2
    result=1
    continue
  fi

  if ! "$suite_path"; then
    result=1
  fi
done < "$suites_file"

exit "$result"
