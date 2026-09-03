#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
runner_source=${RUNNER_UNDER_TEST:-"$script_dir/run.sh"}
failing_source="$script_dir/fixtures/failing-suite.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
sandbox="$tmp_dir/workspace with spaces"
tooling="$sandbox/tests/tooling"
fixtures="$tooling/fixtures"
log="$tmp_dir/suite order.log"
mkdir -p "$fixtures"

if [ ! -f "$runner_source" ]; then
  printf 'runner under test is absent: %s\n' "$runner_source" >&2
  exit 1
fi

cp "$runner_source" "$tooling/run.sh"
cp "$failing_source" "$fixtures/failing suite.sh"
chmod +x "$tooling/run.sh" "$fixtures/failing suite.sh"

write_passing_suite() {
  suite_path=$1
  suite_name=$2
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    "printf '%s\\n' '$suite_name' >> \"\$TEST_RUNNER_LOG\"" \
    > "$suite_path"
  chmod +x "$suite_path"
}

read_log() {
  value=
  while IFS= read -r line; do
    if [ -n "$value" ]; then
      value="$value
$line"
    else
      value=$line
    fi
  done < "$log"
  printf '%s' "$value"
}

write_passing_suite "$fixtures/first suite.sh" 'first suite'
write_passing_suite "$fixtures/second suite.sh" 'second suite'

printf '%s\n' \
  'tests/tooling/fixtures/first suite.sh' \
  'tests/tooling/fixtures/second suite.sh' \
  > "$tooling/suites.list"

(
  cd "$tmp_dir"
  TEST_RUNNER_LOG="$log" "$tooling/run.sh"
)
expected=$(printf '%s\n' 'first suite' 'second suite')
actual=$(read_log)
if [ "$actual" != "$expected" ]; then
  printf 'stable order mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

: > "$log"
printf '%s\n' \
  'tests/tooling/fixtures/first suite.sh' \
  'tests/tooling/fixtures/failing suite.sh' \
  'tests/tooling/fixtures/second suite.sh' \
  > "$tooling/suites.list"

set +e
(
  cd "$workspace_root"
  TEST_RUNNER_LOG="$log" "$tooling/run.sh"
)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'declared suite failure was not propagated\n' >&2
  exit 1
fi
expected=$(printf '%s\n' 'first suite' 'failing suite' 'second suite')
actual=$(read_log)
if [ "$actual" != "$expected" ]; then
  printf 'failure run order mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

printf '%s\n' 'runner tests passed'
