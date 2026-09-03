#!/bin/sh
set -eu

if [ -n "${TEST_RUNNER_LOG:-}" ]; then
  printf '%s\n' 'failing suite' >> "$TEST_RUNNER_LOG"
fi

exit 23
