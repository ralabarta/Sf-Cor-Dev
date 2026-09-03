#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/guards.sh
. "$script_dir/lib/guards.sh"

[ "$#" -le 2 ] || fail 'usage: scripts/intake.sh [upstreams.json] [corchess-deltas.json]'
root=$(resolve_repository_root "$script_dir")
upstreams=$(require_owned_manifest "$root" "${1:-manifests/upstreams.json}" upstreams.json)
deltas=$(require_owned_manifest "$root" "${2:-manifests/corchess-deltas.json}" corchess-deltas.json)
require_command git
require_command python3
require_command sha256sum
require_command sort
require_clean_repository "$root"
acquire_intake_lock "$root"

parsed=$(mktemp)
patch_file=$(mktemp)
provenance_repo=$(mktemp -d)
candidate_repo=$(mktemp -d)
# shellcheck disable=SC2154 # acquire_intake_lock defines intake_lock.
trap 'rm -f "$parsed" "$patch_file"; rm -rf "$provenance_repo" "$candidate_repo"; rmdir "$intake_lock"' EXIT HUP INT TERM
git -C "$provenance_repo" init -q --bare
python3 - "$upstreams" "$deltas" >"$parsed" <<'PY'
import hashlib
import json
import re
import sys


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def valid_path(path):
    if not isinstance(path, str) or not path.startswith("src/") or "\\" in path:
        return False
    parts = path.split("/")
    return (
        all(part not in ("", ".", "..") for part in parts)
        and all(31 < ord(char) < 127 for char in path)
        and re.fullmatch(r"[A-Za-z0-9._+@/-]+", path) is not None
    )


upstreams = load(sys.argv[1])
queue = load(sys.argv[2])
if set(upstreams) != {"schema", "official", "corchess"} or upstreams["schema"] != 1:
    raise SystemExit("invalid upstream manifest schema")
expected_refs = {"official": "refs/heads/master", "corchess": "refs/heads/corchess"}
for name in ("official", "corchess"):
    source = upstreams[name]
    if set(source) != {"url", "ref", "commit"}:
        raise SystemExit(f"invalid {name} source entry")
    if not isinstance(source["url"], str) or not re.match(r"^(https|file)://[^\s]+$", source["url"]):
        raise SystemExit(f"invalid {name} source URL")
    if source["ref"] != expected_refs[name]:
        raise SystemExit(f"invalid {name} tracked ref")
    if not isinstance(source["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise SystemExit(f"invalid {name} commit identity")
if upstreams["official"]["url"] == upstreams["corchess"]["url"]:
    raise SystemExit("official and CorChess sources must be distinct")
for name in ("official", "corchess"):
    source = upstreams[name]
    print("U", name, source["url"], source["ref"], source["commit"], sep="\t")

schema = queue.get("schema") if isinstance(queue, dict) else None
if schema == 1:
    expected = {"schema", "reviewed", "official_base", "corchess_ref", "deltas"}
    if set(queue) != expected or queue["reviewed"] is not True:
        raise SystemExit("delta manifest is not an explicitly reviewed queue")
    if queue["official_base"] != upstreams["official"]["commit"]:
        raise SystemExit("delta queue official base does not match upstream identity")
    if queue["corchess_ref"] != upstreams["corchess"]["commit"]:
        raise SystemExit("delta queue CorChess ref does not match upstream identity")
    if not isinstance(queue["deltas"], list):
        raise SystemExit("delta queue must be ordered JSON array")
    print("S", "1", sep="\t")
    for entry in queue["deltas"]:
        if not isinstance(entry, dict) or set(entry) != {"commit", "patch_sha256"}:
            raise SystemExit("invalid reviewed delta entry")
        if not isinstance(entry["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", entry["commit"]):
            raise SystemExit("invalid delta commit identity")
        if not isinstance(entry["patch_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["patch_sha256"]):
            raise SystemExit("invalid delta patch SHA-256")
        print("D", entry["commit"], entry["patch_sha256"], sep="\t")
elif schema == 2:
    expected = {"schema", "reviewed", "official_base", "corchess_ref", "merge_base", "groups"}
    if set(queue) != expected or queue["reviewed"] is not True:
        raise SystemExit("delta manifest is not an explicitly reviewed schema-2 queue")
    if queue["official_base"] != upstreams["official"]["commit"]:
        raise SystemExit("delta queue official base does not match upstream identity")
    if queue["corchess_ref"] != upstreams["corchess"]["commit"]:
        raise SystemExit("delta queue CorChess ref does not match upstream identity")
    if queue["merge_base"] != queue["official_base"]:
        raise SystemExit("schema-2 merge-base must equal the exact official base")
    groups = queue["groups"]
    if not isinstance(groups, list):
        raise SystemExit("schema-2 groups must be an ordered JSON array")
    group_ids = []
    all_paths = []
    print("S", "2", queue["merge_base"], sep="\t")
    for group in groups:
        if not isinstance(group, dict) or set(group) != {"id", "patch_sha256", "paths"}:
            raise SystemExit("invalid schema-2 atomic group")
        group_id = group["id"]
        group_digest = group["patch_sha256"]
        paths = group["paths"]
        if not isinstance(group_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", group_id):
            raise SystemExit("invalid schema-2 group identity")
        if not isinstance(group_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", group_digest):
            raise SystemExit("invalid schema-2 group SHA-256")
        if not isinstance(paths, list) or not paths:
            raise SystemExit("schema-2 atomic groups must contain at least one path")
        path_names = []
        records = []
        for entry in paths:
            if not isinstance(entry, dict) or set(entry) != {"path", "base_blob", "corchess_blob", "patch_sha256"}:
                raise SystemExit("invalid schema-2 path entry")
            path = entry["path"]
            if not valid_path(path):
                raise SystemExit("unsafe schema-2 engine path")
            for key in ("base_blob", "corchess_blob"):
                if not isinstance(entry[key], str) or not re.fullmatch(r"[0-9a-f]{40}", entry[key]):
                    raise SystemExit(f"invalid schema-2 {key}")
            if not isinstance(entry["patch_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["patch_sha256"]):
                raise SystemExit("invalid schema-2 path patch SHA-256")
            path_names.append(path)
            records.append(
                f'{path}\t{entry["base_blob"]}\t{entry["corchess_blob"]}\t{entry["patch_sha256"]}\n'
            )
        if path_names != sorted(path_names) or len(path_names) != len(set(path_names)):
            raise SystemExit("schema-2 group paths must be sorted and unique")
        actual_group_digest = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
        if actual_group_digest != group_digest:
            raise SystemExit("schema-2 atomic group evidence is incomplete or tampered")
        group_ids.append(group_id)
        all_paths.extend(path_names)
        print("G", group_id, group_digest, sep="\t")
        for entry in paths:
            print(
                "P",
                group_id,
                entry["path"],
                entry["base_blob"],
                entry["corchess_blob"],
                entry["patch_sha256"],
                sep="\t",
            )
    if group_ids != sorted(group_ids) or len(group_ids) != len(set(group_ids)):
        raise SystemExit("schema-2 groups must be sorted and unique")
    if len(all_paths) != len(set(all_paths)):
        raise SystemExit("schema-2 paths overlap across atomic groups")
else:
    raise SystemExit("unsupported delta manifest schema")
PY

official_url=
official_ref=
official_sha=
corchess_url=
corchess_ref=
corchess_sha=
manifest_schema=
declared_merge_base=
tab=$(printf '\t')
while IFS="$tab" read -r record first second third fourth _; do
  case $record in
    U)
      case $first in
        official) official_url=$second; official_ref=$third; official_sha=$fourth ;;
        corchess) corchess_url=$second; corchess_ref=$third; corchess_sha=$fourth ;;
        *) fail "unknown upstream identity: $first" ;;
      esac
      ;;
    S) manifest_schema=$first; declared_merge_base=$second ;;
  esac
done <"$parsed"
require_commit_sha "$official_sha"
require_commit_sha "$corchess_sha"
[ "$official_sha" != "$corchess_sha" ] || fail 'official and CorChess commits must be distinct'

fetch_source() {
  name=$1
  url=$2
  ref=$3
  commit=$4
  git -C "$provenance_repo" fetch -q --no-tags "$url" "+$ref:refs/upstreams/$name" ||
    fail "declared source does not provide tracked ref: $ref"
  observed=$(git -C "$provenance_repo" rev-parse "refs/upstreams/$name")
  git -C "$provenance_repo" cat-file -e "$commit^{commit}" 2>/dev/null ||
    fail "declared source does not provide commit: $commit"
  git -C "$provenance_repo" merge-base --is-ancestor "$commit" "$observed" ||
    fail "declared commit is outside tracked ref: $commit"
}

fetch_source official "$official_url" "$official_ref" "$official_sha"
fetch_source corchess "$corchess_url" "$corchess_ref" "$corchess_sha"
if [ "$manifest_schema" = 2 ]; then
  actual_merge_base=$(git -C "$provenance_repo" merge-base "$official_sha" "$corchess_sha")
  [ "$actual_merge_base" = "$declared_merge_base" ] ||
    fail 'schema-2 merge-base evidence mismatch'
fi

while IFS="$tab" read -r record commit expected; do
  [ "$record" = D ] || continue
  require_commit_sha "$commit"
  require_sha256 "$expected"
  git -C "$provenance_repo" cat-file -e "$commit^{commit}" 2>/dev/null ||
    fail "declared source does not provide commit: $commit"
  git -C "$provenance_repo" merge-base --is-ancestor "$commit" "$corchess_sha" ||
    fail "reviewed delta is outside the pinned CorChess identity: $commit"
  parent_line=$(git -C "$provenance_repo" rev-list --parents -n 1 "$commit")
  # shellcheck disable=SC2086 # Intentional splitting of a validated rev-list record.
  set -- $parent_line
  [ "$#" -eq 2 ] || fail "aggregate or root commit is not an admissible delta: $commit"
  git -C "$provenance_repo" diff-tree --root --binary --full-index --no-renames \
    --no-commit-id -p "$commit" >"$patch_file"
  actual=$(sha256sum "$patch_file" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || fail "patch evidence mismatch: $commit"
done <"$parsed"

# Construct and validate the complete candidate away from the caller's repository.
original_head=$(git -C "$root" rev-parse HEAD)
original_branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) ||
  fail 'intake requires an attached caller branch'
reviewed_bootstrap_transition=1d33062cc6c68efaf4380f89ef9a6cba1fe09d4f
manifest_digest=$(sha256sum "$deltas" | cut -d ' ' -f 1)
branch="integrate/$manifest_digest"
git -C "$candidate_repo" init -q
git -C "$candidate_repo" fetch -q --no-tags "$provenance_repo" "$official_sha" "$corchess_sha"
if [ "$manifest_schema" = 1 ]; then
  candidate_parent=$official_sha
  git -C "$candidate_repo" switch -q --detach "$official_sha"
  while IFS="$tab" read -r record commit expected; do
    [ "$record" = D ] || continue
    git -C "$candidate_repo" cherry-pick --no-commit "$commit" ||
      fail "reviewed delta conflicts and requires human resolution: $commit"
  done <"$parsed"
else
  candidate_parent=$original_head
  integrated_head=false
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    branch_tip=$(git -C "$root" rev-parse "refs/heads/$branch")
    if [ "$original_head" = "$branch_tip" ]; then
      parent_line=$(git -C "$root" rev-list --parents -n 1 "$branch_tip")
      # shellcheck disable=SC2086 # Intentional splitting of a validated rev-list record.
      set -- $parent_line
      [ "$#" -eq 2 ] || fail "integration branch does not preserve downstream ancestry: $branch"
      candidate_parent=$2
    fi
  else
    expected_transition_paths=$(
      while IFS="$tab" read -r record group path _; do
        [ "$record" = P ] && printf '%s\n' "$path"
      done <"$parsed" | LC_ALL=C sort
    )
    # shellcheck disable=SC2046 # rev-list emits only validated commit identities.
    for possible_commit in $(git -C "$root" rev-list --first-parent "$original_head"); do
      parent_line=$(git -C "$root" rev-list --parents -n 1 "$possible_commit")
      # shellcheck disable=SC2086 # Intentional splitting of a validated rev-list record.
      set -- $parent_line
      [ "$#" -eq 2 ] || continue
      possible_parent=$2
      transition_matches=true
      while IFS="$tab" read -r record group path base_blob corchess_blob expected; do
        [ "$record" = P ] || continue
        if git -C "$root" cat-file -e "$possible_parent:$path" 2>/dev/null; then
          parent_blob=$(git -C "$root" rev-parse "$possible_parent:$path")
        else
          parent_blob=0000000000000000000000000000000000000000
        fi
        if git -C "$root" cat-file -e "$possible_commit:$path" 2>/dev/null; then
          commit_blob=$(git -C "$root" rev-parse "$possible_commit:$path")
        else
          commit_blob=0000000000000000000000000000000000000000
        fi
        if [ "$parent_blob" != "$base_blob" ] || [ "$commit_blob" != "$corchess_blob" ]; then
          transition_matches=false
          break
        fi
      done <"$parsed"
      if [ "$transition_matches" = true ]; then
        actual_transition_paths=$(
          git -C "$root" diff-tree --no-commit-id --name-only --no-renames -r "$possible_commit" |
            LC_ALL=C sort
        )
        # Preserve the immutable, previously reviewed bootstrap delivery; every
        # later delivered transition must contain only the declared path set.
        if [ "$actual_transition_paths" != "$expected_transition_paths" ] &&
           [ "$possible_commit" != "$reviewed_bootstrap_transition" ]; then
          fail 'delivered schema-2 transition contains changes outside the reviewed atomic group'
        fi
      fi
      if [ "$transition_matches" = true ] &&
         git -C "$root" merge-base --is-ancestor "$official_sha" "$possible_parent"; then
        candidate_parent=$possible_parent
        integrated_head=true
        break
      fi
    done
  fi
  git -C "$root" merge-base --is-ancestor "$official_sha" "$candidate_parent" ||
    fail "integration branch does not preserve downstream ancestry: $branch"
  git -C "$candidate_repo" fetch -q --no-tags "$root" "$candidate_parent"
  git -C "$candidate_repo" switch -q --detach "$candidate_parent"
  while IFS="$tab" read -r record group path base_blob corchess_blob expected; do
    [ "$record" = P ] || continue
    base_mode=$(git -C "$provenance_repo" ls-tree "$official_sha" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
    corchess_mode=$(git -C "$provenance_repo" ls-tree "$corchess_sha" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
    caller_mode=$(git -C "$candidate_repo" ls-tree HEAD -- "$path" | cut -f 1 | cut -d ' ' -f 1)
    case ${base_mode:-missing} in 100644|100755|missing) ;; *) fail "unsupported official tree entry: $path" ;; esac
    case ${corchess_mode:-missing} in 100644|100755|missing) ;; *) fail "unsupported CorChess tree entry: $path" ;; esac
    [ "${caller_mode:-missing}" = "${base_mode:-missing}" ] ||
      fail "downstream engine path mode differs from official base: $path"
    if git -C "$provenance_repo" cat-file -e "$official_sha:$path" 2>/dev/null; then
      actual_base_blob=$(git -C "$provenance_repo" rev-parse "$official_sha:$path")
    else
      actual_base_blob=0000000000000000000000000000000000000000
    fi
    if git -C "$provenance_repo" cat-file -e "$corchess_sha:$path" 2>/dev/null; then
      actual_corchess_blob=$(git -C "$provenance_repo" rev-parse "$corchess_sha:$path")
    else
      actual_corchess_blob=0000000000000000000000000000000000000000
    fi
    if git -C "$candidate_repo" cat-file -e "HEAD:$path" 2>/dev/null; then
      caller_blob=$(git -C "$candidate_repo" rev-parse "HEAD:$path")
    else
      caller_blob=0000000000000000000000000000000000000000
    fi
    [ "$actual_base_blob" = "$base_blob" ] || fail "official base blob evidence mismatch: $path"
    [ "$actual_corchess_blob" = "$corchess_blob" ] || fail "CorChess blob evidence mismatch: $path"
    [ "$caller_blob" = "$base_blob" ] || fail "downstream engine path differs from official base: $path"
    git -C "$provenance_repo" diff --binary --full-index --no-renames \
      "$official_sha" "$corchess_sha" -- "$path" >"$patch_file"
    actual=$(sha256sum "$patch_file" | cut -d ' ' -f 1)
    [ "$actual" = "$expected" ] || fail "path patch evidence mismatch: $path"
    git -C "$candidate_repo" apply --index --binary --whitespace=nowarn "$patch_file" ||
      fail "reviewed tree delta conflicts and requires human resolution: $path"
  done <"$parsed"
fi
expected_tree=$(git -C "$candidate_repo" write-tree)

if [ "$manifest_schema" = 2 ] && [ "$integrated_head" = true ]; then
  while IFS="$tab" read -r record group path base_blob corchess_blob expected; do
    [ "$record" = P ] || continue
    current_mode=$(git -C "$root" ls-tree "$original_head" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
    expected_mode=$(git -C "$provenance_repo" ls-tree "$corchess_sha" -- "$path" | cut -f 1 | cut -d ' ' -f 1)
    [ "${current_mode:-missing}" = "${expected_mode:-missing}" ] ||
      fail "downstream engine path mode differs from reviewed integration: $path"
    if git -C "$root" cat-file -e "$original_head:$path" 2>/dev/null; then
      current_blob=$(git -C "$root" rev-parse "$original_head:$path")
    else
      current_blob=0000000000000000000000000000000000000000
    fi
    [ "$current_blob" = "$corchess_blob" ] ||
      fail "downstream engine path differs from reviewed integration: $path"
  done <"$parsed"
  printf '%s\n' 'no changes'
  exit 0
fi

if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  branch_tree=$(git -C "$root" rev-parse "refs/heads/$branch^{tree}")
  [ "$branch_tree" = "$expected_tree" ] || fail "integration branch already exists with different content: $branch"
  if [ "$manifest_schema" = 1 ]; then
    git -C "$root" merge-base --is-ancestor "$candidate_parent" "refs/heads/$branch" ||
      fail "integration branch does not preserve official ancestry: $branch"
  else
    parent_line=$(git -C "$root" rev-list --parents -n 1 "refs/heads/$branch")
    # shellcheck disable=SC2086 # Intentional splitting of a validated rev-list record.
    set -- $parent_line
    [ "$#" -eq 2 ] && [ "$2" = "$candidate_parent" ] ||
      fail "integration branch does not preserve downstream ancestry: $branch"
  fi
  printf '%s\n' 'no changes'
  exit 0
fi

# Import candidate objects without updating FETCH_HEAD or any caller ref.
candidate_commit=$(printf '%s\n' 'reviewed integration candidate' |
  GIT_AUTHOR_NAME='Sf-Cor-Dev Intake' GIT_AUTHOR_EMAIL='intake@example.invalid' \
  GIT_COMMITTER_NAME='Sf-Cor-Dev Intake' GIT_COMMITTER_EMAIL='intake@example.invalid' \
  git -C "$candidate_repo" commit-tree "$expected_tree" -p "$candidate_parent")
git -C "$root" fetch -q --no-tags --no-write-fetch-head "$candidate_repo" "$candidate_commit"

publish_complete=false
rollback_publish() {
  [ "$publish_complete" = false ] || return 0
  git -C "$root" reset -q --hard "$original_head" >/dev/null 2>&1 || true
  git -C "$root" switch -q "$original_branch" >/dev/null 2>&1 || true
  git -C "$root" update-ref -d "refs/heads/$branch" >/dev/null 2>&1 || true
}
# shellcheck disable=SC2154 # acquire_intake_lock defines intake_lock.
trap 'rollback_publish; rm -f "$parsed" "$patch_file"; rm -rf "$provenance_repo" "$candidate_repo"; rmdir "$intake_lock"' EXIT HUP INT TERM

git -C "$root" update-ref "refs/heads/$branch" "$candidate_parent" "0000000000000000000000000000000000000000"
git -C "$root" switch -q "$branch"
git -C "$root" read-tree --reset -u "$expected_tree"
publish_complete=true
if [ "$manifest_schema" = 1 ]; then
  while IFS="$tab" read -r record commit expected; do
    [ "$record" = D ] || continue
    printf 'applying %s\n' "$commit"
  done <"$parsed"
else
  while IFS="$tab" read -r record group expected; do
    [ "$record" = G ] || continue
    printf 'applying group %s\n' "$group"
  done <"$parsed"
fi
printf 'prepared %s from official %s and CorChess %s\n' \
  "$branch" "$official_sha" "$corchess_sha"
