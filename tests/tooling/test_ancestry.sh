#!/bin/sh
set -eu

pinned_sha=3f6f417b87c0e80ee30914b6b539b4ab7d3b2a5b
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

git_at_root() {
  git -C "$workspace_root" "$@"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(git_at_root cat-file -t "$pinned_sha")" = commit ] ||
  fail 'pinned official object is not a commit'
[ "$(git_at_root rev-parse "$pinned_sha^{commit}")" = "$pinned_sha" ] ||
  fail 'pinned official object identity changed'
[ "$(git_at_root rev-parse --is-shallow-repository)" = false ] ||
  fail 'shallow history cannot prove preserved official ancestry'
[ -z "$(git_at_root for-each-ref --format='%(refname)' refs/replace)" ] ||
  fail 'replace refs are forbidden for ancestry proof'

git_dir=$(git_at_root rev-parse --git-dir)
case $git_dir in
  /*) ;;
  *) git_dir="$workspace_root/$git_dir" ;;
esac
[ ! -s "$git_dir/info/grafts" ] || fail 'grafts are forbidden for ancestry proof'

if merge_head=$(git_at_root rev-parse -q --verify MERGE_HEAD 2>/dev/null); then
  [ "$merge_head" = "$pinned_sha" ] ||
    fail 'pending merge does not use the exact pinned official commit'
  git_at_root merge-base --is-ancestor "$pinned_sha" "$merge_head" ||
    fail 'pending merge does not preserve official ancestry'
else
  git_at_root merge-base --is-ancestor "$pinned_sha" HEAD ||
    fail 'HEAD does not preserve the pinned official ancestry'
fi

for path in src tests Copying.txt; do
  [ -e "$workspace_root/$path" ] || fail "required upstream path is absent: $path"
done

for entrypoint in \
  src/Makefile \
  tests/instrumented.py \
  tests/perft.sh \
  tests/reprosearch.sh \
  tests/signature.sh \
  tests/testing.py
do
  [ -f "$workspace_root/$entrypoint" ] ||
    fail "required upstream test entry point is absent: $entrypoint"
done

for executable in tests/perft.sh tests/reprosearch.sh tests/signature.sh; do
  [ -x "$workspace_root/$executable" ] ||
    fail "upstream test entry point is not executable: $executable"
done

git_at_root diff --quiet "$pinned_sha" -- \
  src \
  Copying.txt \
  tests/.gitattributes \
  tests/instrumented.py \
  tests/perft.sh \
  tests/reprosearch.sh \
  tests/signature.sh \
  tests/testing.py || fail 'canonical official engine or test baseline differs from the pinned commit'

printf '%s\n' 'official ancestry tests passed'
