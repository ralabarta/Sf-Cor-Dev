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

file_contains() {
  needle=$1
  path=$2
  while IFS= read -r line; do
    case $line in
      *"$needle"*) return 0 ;;
    esac
  done <"$path"
  return 1
}

applying_lines() {
  path=$1
  while IFS= read -r line; do
    case $line in
      'applying '*) printf '%s\n' "$line" ;;
    esac
  done <"$path"
}

for required in scripts/discover.sh scripts/intake.sh scripts/lib/guards.sh; do
  [ -f "$workspace_root/$required" ] || fail "required intake file is absent: $required"
done

configure_git() {
  git -C "$1" config user.name 'Intake Test'
  git -C "$1" config user.email 'intake@example.invalid'
}

patch_sha() {
  git -C "$corchess_repo" diff-tree --root --binary --full-index --no-renames \
    --no-commit-id -p "$1" | sha256sum | cut -d ' ' -f 1
}

official_repo="$tmp_dir/official-source"
corchess_repo="$tmp_dir/corchess-source"
mkdir -p "$official_repo"
git -C "$official_repo" init -q -b master
configure_git "$official_repo"
printf '%s\n' official >"$official_repo/engine.txt"
git -C "$official_repo" add engine.txt
git -C "$official_repo" commit -q -m 'official base'
official_sha=$(git -C "$official_repo" rev-parse HEAD)

git clone -q "$official_repo" "$corchess_repo"
configure_git "$corchess_repo"
git -C "$corchess_repo" switch -q -c corchess
printf '%s\n' one >"$corchess_repo/order.txt"
git -C "$corchess_repo" add order.txt
git -C "$corchess_repo" commit -q -m 'delta one'
delta_one=$(git -C "$corchess_repo" rev-parse HEAD)
printf '%s\n' one two >"$corchess_repo/order.txt"
git -C "$corchess_repo" commit -q -am 'delta two'
delta_two=$(git -C "$corchess_repo" rev-parse HEAD)
mkdir -p "$corchess_repo/src"
printf '%s\n' search >"$corchess_repo/src/search.cpp"
printf '%s\n' header >"$corchess_repo/src/search.h"
git -C "$corchess_repo" add src
git -C "$corchess_repo" commit -q -m 'atomic search delta'

git -C "$corchess_repo" switch -q --detach "$official_sha"
printf '%s\n' legacy >"$corchess_repo/engine.txt"
git -C "$corchess_repo" commit -q -am 'legacy context'
printf '%s\n' corchess >"$corchess_repo/engine.txt"
git -C "$corchess_repo" commit -q -am 'conflicting delta'
conflict_delta=$(git -C "$corchess_repo" rev-parse HEAD)

git -C "$corchess_repo" switch -q corchess
git -C "$corchess_repo" switch -q -c aggregate "$delta_two"
printf '%s\n' side >"$corchess_repo/side.txt"
git -C "$corchess_repo" add side.txt
git -C "$corchess_repo" commit -q -m 'side delta'
git -C "$corchess_repo" switch -q corchess
printf '%s\n' tip >"$corchess_repo/tip.txt"
git -C "$corchess_repo" add tip.txt
git -C "$corchess_repo" commit -q -m 'tip delta'
git -C "$corchess_repo" merge -q --no-ff aggregate -m 'aggregate merge'
merge_delta=$(git -C "$corchess_repo" rev-parse HEAD)
corchess_sha=$(git -C "$corchess_repo" rev-parse corchess)
tree_delta_sha=$corchess_sha
git -C "$corchess_repo" switch -q -c default-head "$official_sha"
[ "$(git -C "$corchess_repo" rev-parse HEAD)" != "$corchess_sha" ] ||
  fail 'CorChess fixture HEAD must differ from refs/heads/corchess'

write_upstreams() {
  destination=$1
  official_url=${2:-"file://$official_repo"}
  corchess_url=${3:-"file://$corchess_repo"}
  official_ref=${4:-$official_sha}
  corchess_ref=${5:-$corchess_sha}
  printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    "  \"official\": {\"url\": \"$official_url\", \"ref\": \"refs/heads/master\", \"commit\": \"$official_ref\"}," \
    "  \"corchess\": {\"url\": \"$corchess_url\", \"ref\": \"refs/heads/corchess\", \"commit\": \"$corchess_ref\"}" \
    '}' >"$destination"
}

write_deltas() {
  destination=$1
  shift
  {
    printf '%s\n' '{' '  "schema": 1,' '  "reviewed": true,' \
      "  \"official_base\": \"$official_sha\"," \
      "  \"corchess_ref\": \"$corchess_sha\"," '  "deltas": ['
    first=true
    for commit in "$@"; do
      digest=$(patch_sha "$commit")
      if [ "$first" = false ]; then
        printf ',\n'
      fi
      printf '    {"commit": "%s", "patch_sha256": "%s"}' "$commit" "$digest"
      first=false
    done
    printf '\n%s\n' '  ]' '}'
  } >"$destination"
}

path_patch() {
  _path_patch_path=$1
  _path_patch_destination=$2
  git -C "$corchess_repo" diff --binary --full-index --no-renames \
    "$official_sha" "$corchess_sha" -- "$_path_patch_path" >"$_path_patch_destination"
}

write_tree_deltas() {
  _tree_destination=$1
  shift
  entries="$tmp_dir/schema2-entries"
  : >"$entries"
  for path in "$@"; do
    patch="$tmp_dir/schema2-$(printf '%s' "$path" | tr '/.' '__').patch"
    path_patch "$path" "$patch"
    if git -C "$corchess_repo" cat-file -e "$official_sha:$path" 2>/dev/null; then
      base_blob=$(git -C "$corchess_repo" rev-parse "$official_sha:$path")
    else
      base_blob=0000000000000000000000000000000000000000
    fi
    if git -C "$corchess_repo" cat-file -e "$corchess_sha:$path" 2>/dev/null; then
      corchess_blob=$(git -C "$corchess_repo" rev-parse "$corchess_sha:$path")
    else
      corchess_blob=0000000000000000000000000000000000000000
    fi
    patch_digest=$(sha256sum "$patch" | cut -d ' ' -f 1)
    printf '%s\t%s\t%s\t%s\n' "$path" "$base_blob" "$corchess_blob" "$patch_digest" >>"$entries"
  done
  group_digest=$(sha256sum "$entries" | cut -d ' ' -f 1)
  python3 - "$_tree_destination" "$official_sha" "$corchess_sha" "$group_digest" "$entries" <<'PY'
import json
import sys

output, official, corchess, group_digest, entries_path = sys.argv[1:]
paths = []
with open(entries_path, encoding="utf-8") as stream:
    for line in stream:
        path, base_blob, corchess_blob, patch_sha256 = line.rstrip("\n").split("\t")
        paths.append({
            "path": path,
            "base_blob": base_blob,
            "corchess_blob": corchess_blob,
            "patch_sha256": patch_sha256,
        })
data = {
    "schema": 2,
    "reviewed": True,
    "official_base": official,
    "corchess_ref": corchess,
    "merge_base": official,
    "groups": [{"id": "search", "patch_sha256": group_digest, "paths": paths}],
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY
}

new_worktree() {
  name=$1
  worktree="$tmp_dir/$name"
  git clone -q "$official_repo" "$worktree"
  configure_git "$worktree"
  mkdir -p "$worktree/scripts/lib" "$worktree/manifests"
  cp "$workspace_root/scripts/discover.sh" "$worktree/scripts/discover.sh"
  cp "$workspace_root/scripts/intake.sh" "$worktree/scripts/intake.sh"
  cp "$workspace_root/scripts/lib/guards.sh" "$worktree/scripts/lib/guards.sh"
  chmod +x "$worktree/scripts/discover.sh" "$worktree/scripts/intake.sh"
  write_upstreams "$worktree/manifests/upstreams.json"
  write_deltas "$worktree/manifests/corchess-deltas.json" "$delta_one" "$delta_two"
  git -C "$worktree" add scripts manifests
  git -C "$worktree" commit -q -m 'install intake tooling'
}

new_worktree 'reviewed queue'
manifest_digest=$(sha256sum "$worktree/manifests/corchess-deltas.json" | cut -d ' ' -f 1)
(
  cd "$worktree"
  ./scripts/discover.sh >"$tmp_dir/discovery.out"
  ./scripts/intake.sh >"$tmp_dir/intake.out"
)
[ "$(git -C "$worktree" branch --show-current)" = "integrate/$manifest_digest" ] ||
  fail 'intake did not select the manifest-digest branch'
[ "$(git -C "$worktree" rev-parse HEAD)" = "$official_sha" ] ||
  fail 'intake created an automatic commit instead of leaving reviewed index changes'
[ "$(git -C "$worktree" show :order.txt)" = "$(printf '%s\n' one two)" ] ||
  fail 'reviewed deltas were not applied in manifest order'
expected=$(printf 'applying %s\napplying %s' "$delta_one" "$delta_two")
actual=$(applying_lines "$tmp_dir/intake.out")
[ "$actual" = "$expected" ] || fail 'intake output did not preserve queue order'
file_contains '"source":"official"' "$tmp_dir/discovery.out" ||
  fail 'discovery did not identify the official source'
file_contains '"ref":"refs/heads/master"' "$tmp_dir/discovery.out" ||
  fail 'discovery did not query the exact official ref'
file_contains '"source":"corchess"' "$tmp_dir/discovery.out" ||
  fail 'discovery did not identify the CorChess source'
file_contains '"ref":"refs/heads/corchess"' "$tmp_dir/discovery.out" ||
  fail 'discovery did not query the exact CorChess ref'
[ "$(rg -o '"status":"unchanged"' "$tmp_dir/discovery.out" | wc -l)" -eq 2 ] ||
  fail 'discovery did not report stable unchanged statuses'

git -C "$worktree" commit -q -m 'accept reviewed integration'
git -C "$worktree" switch -q master
mkdir -p "$worktree/evidence" "$worktree/activation" "$worktree/release"
printf '%s\n' preserved >"$worktree/evidence/state"
printf '%s\n' preserved >"$worktree/activation/state"
printf '%s\n' preserved >"$worktree/release/state"
git -C "$worktree" add evidence activation release
git -C "$worktree" commit -q -m 'record protected state'
unchanged_state() {
  {
    git -C "$worktree" rev-parse HEAD
    git -C "$worktree" for-each-ref --format='%(refname) %(objectname)'
    git -C "$worktree" status --porcelain=v2 --branch
    git -C "$worktree" ls-files -s
    sha256sum "$worktree/manifests/upstreams.json" \
      "$worktree/manifests/corchess-deltas.json" \
      "$worktree/evidence/state" "$worktree/activation/state" "$worktree/release/state"
  } | sha256sum | cut -d ' ' -f 1
}
before_unchanged=$(unchanged_state)
(
  cd "$worktree"
  ./scripts/intake.sh >"$tmp_dir/unchanged.out"
)
printf '%s\n' 'no changes' >"$tmp_dir/expected-unchanged.out"
cmp -s "$tmp_dir/expected-unchanged.out" "$tmp_dir/unchanged.out" ||
  fail 'unchanged intake did not report exactly no changes'
after_unchanged=$(unchanged_state)
[ "$after_unchanged" = "$before_unchanged" ] ||
  fail 'unchanged intake mutated source, refs, provenance, activation, release, or integration state'

valid_integration_commit=$(git -C "$worktree" rev-parse "refs/heads/integrate/$manifest_digest")
integration_tree=$(git -C "$worktree" rev-parse "$valid_integration_commit^{tree}")
unrelated_commit=$(printf '%s\n' 'same tree without official ancestry' |
  git -C "$worktree" commit-tree "$integration_tree")
git -C "$worktree" update-ref "refs/heads/integrate/$manifest_digest" "$unrelated_commit"
before_unrelated=$(unchanged_state)
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
file_contains 'integration branch does not preserve official ancestry' "$tmp_dir/command.err" ||
  fail 'same-tree integration branch without official ancestry was not rejected'
[ ! -s "$tmp_dir/command.out" ] ||
  fail 'same-tree integration branch without official ancestry reported no changes'
after_unrelated=$(unchanged_state)
[ "$after_unrelated" = "$before_unrelated" ] ||
  fail 'unrelated-history integration check mutated protected state'
git -C "$worktree" update-ref "refs/heads/integrate/$manifest_digest" "$valid_integration_commit"

git -C "$worktree" switch -q "integrate/$manifest_digest"
printf '%s\n' tampered >"$worktree/order.txt"
git -C "$worktree" commit -q -am 'tamper with integration result'
git -C "$worktree" switch -q master
before_mismatch=$(unchanged_state)
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
file_contains 'integration branch already exists with different content' "$tmp_dir/command.err" ||
  fail 'mismatched integration branch did not fail closed'
after_mismatch=$(unchanged_state)
[ "$after_mismatch" = "$before_mismatch" ] ||
  fail 'mismatched integration check mutated protected state'

new_worktree 'declared source provenance'
git -C "$worktree" fetch -q "file://$corchess_repo" "$corchess_sha"
foreign_source="$tmp_dir/foreign-source"
git clone -q "$official_repo" "$foreign_source"
write_upstreams "$worktree/manifests/upstreams.json" "file://$official_repo" \
  "file://$foreign_source" "$official_sha" "$corchess_sha"
git -C "$worktree" add manifests/upstreams.json
git -C "$worktree" commit -q -m 'declare foreign CorChess source'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] ||
  fail 'unproven local object changed branch'

new_worktree 'hostile paths'
for hostile in '../upstreams.json' README.sh requirements.txt CMakeLists.txt executable.md executable.mdx; do
  printf '%s\n' '{}' >"$worktree/$hostile" 2>/dev/null || true
  chmod +x "$worktree/$hostile" 2>/dev/null || true
  expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh '$hostile' manifests/corchess-deltas.json"
  file_contains 'manifest path is outside its reviewed boundary' "$tmp_dir/command.err" ||
    fail "hostile path did not reach manifest boundary guard: $hostile"
done
outside="$tmp_dir/foreign.json"
printf '%s\n' '{}' >"$outside"
expect_fail sh -c "cd '$worktree' && ./scripts/discover.sh '$outside'"
file_contains 'manifest path is outside its reviewed boundary' "$tmp_dir/command.err" ||
  fail 'foreign absolute path did not reach manifest boundary guard'
rm "$worktree/manifests/upstreams.json"
ln -s "$outside" "$worktree/manifests/upstreams.json"
expect_fail sh -c "cd '$worktree' && ./scripts/discover.sh"

new_worktree 'cwd mismatch'
expect_fail "$worktree/scripts/discover.sh"

new_worktree 'dirty state'
printf '%s\n' dirty >>"$worktree/engine.txt"
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] || fail 'dirty intake changed branch'

new_worktree 'staged state'
printf '%s\n' staged >"$worktree/staged.txt"
git -C "$worktree" add staged.txt
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] || fail 'staged intake changed branch'

new_worktree 'invalid evidence'
write_deltas "$worktree/manifests/corchess-deltas.json" "$delta_one"
python3 - "$worktree/manifests/corchess-deltas.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["deltas"][0]["patch_sha256"] = "0" * 64
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
git -C "$worktree" add manifests/corchess-deltas.json
git -C "$worktree" commit -q -m 'use invalid patch evidence'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] || fail 'invalid evidence changed branch'

new_worktree 'aggregate merge'
write_deltas "$worktree/manifests/corchess-deltas.json" "$merge_delta"
git -C "$worktree" add manifests/corchess-deltas.json
git -C "$worktree" commit -q -m 'select aggregate merge'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] || fail 'aggregate merge changed branch'

new_worktree 'conflict'
write_upstreams "$worktree/manifests/upstreams.json" "file://$official_repo" \
  "file://$corchess_repo" "$official_sha" "$conflict_delta"
corchess_sha=$conflict_delta
write_deltas "$worktree/manifests/corchess-deltas.json" "$conflict_delta"
git -C "$worktree" add manifests
git -C "$worktree" commit -q -m 'select conflicting delta'
mkdir -p "$worktree/evidence" "$worktree/activation" "$worktree/release"
printf '%s\n' preserved >"$worktree/evidence/state"
printf '%s\n' preserved >"$worktree/activation/state"
printf '%s\n' preserved >"$worktree/release/state"
git -C "$worktree" add evidence activation release
git -C "$worktree" commit -q -m 'record conflict test protected state'
before_conflict=$(unchanged_state)
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
after_conflict=$(unchanged_state)
[ "$after_conflict" = "$before_conflict" ] ||
  fail 'conflicting intake mutated caller branch, refs, index, worktree, or cherry-pick state'
[ -z "$(git -C "$worktree" diff --name-only --diff-filter=U)" ] ||
  fail 'conflicting intake leaked unresolved paths into the caller'
[ ! -e "$worktree/.git/CHERRY_PICK_HEAD" ] ||
  fail 'conflicting intake leaked cherry-pick state into the caller'

# Schema 2 applies one complete reviewed tree-delta group on top of the caller's
# downstream HEAD, preserving all downstream tooling and history.
corchess_sha=$tree_delta_sha
new_worktree 'schema 2 downstream'
write_upstreams "$worktree/manifests/upstreams.json"
write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp src/search.h
git -C "$worktree" add manifests
git -C "$worktree" commit -q -m 'review atomic tree delta'
schema2_head=$(git -C "$worktree" rev-parse HEAD)
schema2_tooling=$(sha256sum "$worktree/scripts/intake.sh" | cut -d ' ' -f 1)
schema2_manifest_digest=$(sha256sum "$worktree/manifests/corchess-deltas.json" | cut -d ' ' -f 1)
(
  cd "$worktree"
  ./scripts/intake.sh >"$tmp_dir/schema2.out"
)
[ "$(git -C "$worktree" branch --show-current)" = "integrate/$schema2_manifest_digest" ] ||
  fail 'schema-2 intake did not select the manifest-digest branch'
[ "$(git -C "$worktree" rev-parse HEAD)" = "$schema2_head" ] ||
  fail 'schema-2 intake discarded downstream history or created an automatic commit'
[ "$(sha256sum "$worktree/scripts/intake.sh" | cut -d ' ' -f 1)" = "$schema2_tooling" ] ||
  fail 'schema-2 intake changed downstream tooling'
[ "$(git -C "$worktree" show :src/search.cpp)" = "$(printf '%s\n' search)" ] ||
  fail 'schema-2 intake did not apply the reviewed path tree'
[ "$(git -C "$worktree" show :src/search.h)" = "$(printf '%s\n' header)" ] ||
  fail 'schema-2 intake did not apply the complete atomic group'
file_contains 'applying group search' "$tmp_dir/schema2.out" ||
  fail 'schema-2 intake did not report the atomic group'

# A caller engine path that differs from the official base fails before any
# branch, index, worktree, or protected downstream state changes.
new_worktree 'schema 2 caller mismatch'
write_upstreams "$worktree/manifests/upstreams.json"
write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp src/search.h
mkdir -p "$worktree/src"
printf '%s\n' downstream >"$worktree/src/search.cpp"
git -C "$worktree" add manifests src/search.cpp
git -C "$worktree" commit -q -m 'downstream engine conflict'
mkdir -p "$worktree/evidence" "$worktree/activation" "$worktree/release"
printf '%s\n' preserved >"$worktree/evidence/state"
printf '%s\n' preserved >"$worktree/activation/state"
printf '%s\n' preserved >"$worktree/release/state"
git -C "$worktree" add evidence activation release
git -C "$worktree" commit -q -m 'record schema-2 protected state'
before_schema2_conflict=$(unchanged_state)
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
after_schema2_conflict=$(unchanged_state)
[ "$after_schema2_conflict" = "$before_schema2_conflict" ] ||
  fail 'schema-2 base mismatch mutated caller state'

# Atomic group metadata binds the complete ordered path set. Removing one path,
# duplicating/unsorting paths, or using an unsafe spelling must fail closed.
new_worktree 'schema 2 partial group'
write_upstreams "$worktree/manifests/upstreams.json"
write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp src/search.h
python3 - "$worktree/manifests/corchess-deltas.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["groups"][0]["paths"].pop()
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
git -C "$worktree" add manifests
git -C "$worktree" commit -q -m 'truncate atomic group'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
[ "$(git -C "$worktree" branch --show-current)" = master ] ||
  fail 'partial schema-2 group changed branch'

new_worktree 'schema 2 unsorted paths'
write_upstreams "$worktree/manifests/upstreams.json"
write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp src/search.h
python3 - "$worktree/manifests/corchess-deltas.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["groups"][0]["paths"].reverse()
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
git -C "$worktree" add manifests
git -C "$worktree" commit -q -m 'unsort atomic group'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"

new_worktree 'schema 2 unsafe path'
write_upstreams "$worktree/manifests/upstreams.json"
write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp
python3 - "$worktree/manifests/corchess-deltas.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["groups"][0]["paths"][0]["path"] = "../search.cpp"
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
git -C "$worktree" add manifests
git -C "$worktree" commit -q -m 'use unsafe tree path'
expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"

for mutation in merge_base corchess_blob patch_sha256 overlap; do
  new_worktree "schema 2 tamper $mutation"
  write_upstreams "$worktree/manifests/upstreams.json"
  write_tree_deltas "$worktree/manifests/corchess-deltas.json" src/search.cpp src/search.h
  python3 - "$worktree/manifests/corchess-deltas.json" "$mutation" <<'PY'
import copy
import hashlib
import json
import sys

path, mutation = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
group = data["groups"][0]
if mutation == "merge_base":
    data["merge_base"] = "0" * 40
elif mutation == "overlap":
    duplicate = copy.deepcopy(group)
    duplicate["id"] = "search-copy"
    data["groups"].append(duplicate)
else:
    group["paths"][0][mutation] = "0" * (40 if mutation == "corchess_blob" else 64)
    records = "".join(
        f'{entry["path"]}\t{entry["base_blob"]}\t{entry["corchess_blob"]}\t{entry["patch_sha256"]}\n'
        for entry in group["paths"]
    )
    group["patch_sha256"] = hashlib.sha256(records.encode("utf-8")).hexdigest()
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
  git -C "$worktree" add manifests
  git -C "$worktree" commit -q -m "tamper with $mutation evidence"
  expect_fail sh -c "cd '$worktree' && ./scripts/intake.sh"
  [ "$(git -C "$worktree" branch --show-current)" = master ] ||
    fail "schema-2 $mutation tampering changed branch"
done

printf '%s\n' 'intake tests passed'
