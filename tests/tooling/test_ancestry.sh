#!/bin/sh
set -eu

pinned_sha=1dc0912d86dafb99e96d679a6ac76cbdf1553459
excluded_sha=edb0d9db6731067ec50ce619ff372b463bc4dd5d
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

git_at_root() {
  git -C "$workspace_root" "$@"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

reject_excluded_ancestry() {
  target=$1
  target_name=$2
  ! git_at_root merge-base --is-ancestor "$excluded_sha" "$target" ||
    fail "excluded Stockfish identity commit is reachable from $target_name"
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

ancestry_target=HEAD
merge_head=
if merge_head=$(git_at_root rev-parse -q --verify MERGE_HEAD 2>/dev/null); then
  [ "$merge_head" = "$pinned_sha" ] ||
    fail 'pending merge does not use the exact pinned official commit'
  ancestry_target=$merge_head
fi

git_at_root merge-base --is-ancestor "$pinned_sha" "$ancestry_target" ||
  fail 'ancestry target does not preserve the pinned official ancestry'
if git_at_root cat-file -e "$excluded_sha^{commit}" 2>/dev/null; then
  reject_excluded_ancestry HEAD HEAD
  [ -z "$merge_head" ] || reject_excluded_ancestry "$merge_head" 'pending MERGE_HEAD'
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
  Copying.txt \
  tests/.gitattributes \
  tests/reprosearch.sh \
  tests/signature.sh \
  tests/testing.py || fail 'canonical official test baseline differs from the pinned commit'

[ "$(sha256sum "$workspace_root/tests/perft.sh" | cut -d ' ' -f 1)" = 67c38ddfb933056d2570ca35861db6689b8dba8da98efd0f8712acc37d505cb0 ] ||
  fail 'perft test differs from the reviewed PATH-portable baseline'

[ "$(git_at_root diff --numstat "$pinned_sha" -- tests/instrumented.py)" = "$(printf '2\t2\ttests/instrumented.py')" ] ||
  fail 'instrumented test changes exceed the Sf-Cor-Dev identity adaptation'
[ "$(rg -c 'starts_with\("Sf-Cor-Dev"\)' "$workspace_root/tests/instrumented.py")" -eq 2 ] ||
  fail 'instrumented tests do not enforce the Sf-Cor-Dev startup identity'

changed_engine_paths=$(git_at_root diff --name-only "$pinned_sha" -- src)
expected_engine_paths='src/misc.cpp
src/search.cpp
src/search.h'
[ "$changed_engine_paths" = "$expected_engine_paths" ] ||
  fail 'downstream engine changes exceed the reviewed search and identity boundary'
rg -q 'ss << "Sf-Cor-Dev "' "$workspace_root/src/misc.cpp" ||
  fail 'engine product identity is not Sf-Cor-Dev'
rg -q 'Stockfish and CorChess developers' "$workspace_root/src/misc.cpp" ||
  fail 'engine attribution does not preserve Stockfish and CorChess credit'
! rg -qi 'stronger|strength|CorChess 5' "$workspace_root/src/misc.cpp" ||
  fail 'engine identity makes an unreviewed strength or CorChess branding claim'

printf '%s\n' 'official ancestry tests passed'
