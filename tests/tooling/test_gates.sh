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

assert_json() {
  path=$1
  expression=$2
  python3 - "$path" "$expression" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
if not eval(sys.argv[2], {"__builtins__": {}}, {"value": value}):
    raise SystemExit(f"assertion failed for {sys.argv[1]}: {sys.argv[2]}")
PY
}

[ -f "$workspace_root/manifests/bench.json" ] || fail 'reviewed bench manifest is absent'
[ -x "$workspace_root/scripts/validate.sh" ] || fail 'validation entry point is absent'

new_workspace() {
  name=$1
  worktree="$tmp_dir/$name"
  mkdir -p "$worktree/scripts/lib" "$worktree/manifests" "$worktree/bin"
  git -C "$worktree" init -q -b main
  git -C "$worktree" config user.name Test
  git -C "$worktree" config user.email test@example.invalid
  cp "$workspace_root/scripts/validate.sh" "$worktree/scripts/validate.sh"
  cp "$workspace_root/scripts/lib/guards.sh" "$worktree/scripts/lib/guards.sh"
  cp "$workspace_root/manifests/bench.json" "$worktree/manifests/bench.json"
  cp "$workspace_root/manifests/nnue.json" "$worktree/manifests/nnue.json"
  cp "$workspace_root/manifests/upstreams.json" "$worktree/manifests/upstreams.json"
  cp "$workspace_root/manifests/corchess-deltas.json" "$worktree/manifests/corchess-deltas.json"
  chmod +x "$worktree/scripts/validate.sh"
  printf '%s\n' fixture >"$worktree/source.txt"
  expected_fixture_bench=$(python3 - "$worktree/manifests/bench.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["expected_nodes"])
PY
)
  git -C "$worktree" add .
  git -C "$worktree" commit -q -m "fixture baseline

Bench: $expected_fixture_bench"
  baseline_sha=$(git -C "$worktree" rev-parse HEAD)
  git -C "$worktree" commit -q --allow-empty -m 'fixture source'
  fixture_source=$(git -C "$worktree" rev-parse HEAD)
  python3 - "$worktree/manifests/bench.json" "$fixture_source" "$baseline_sha" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["source_commit"], value["baseline_commit"] = sys.argv[2:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(value, stream, indent=2); stream.write("\n")
PY
  git -C "$worktree" add manifests/bench.json
  git -C "$worktree" commit -q -m 'review fixture bench provenance'
  source_sha=$(git -C "$worktree" rev-parse HEAD)
  order_log="$worktree/order.log"
  : >"$order_log"
}

install_gate() {
  gate=$1
  output=$2
  path="$worktree/bin/$gate"
  cat >"$path" <<SH
#!/bin/sh
set -eu
printf '%s\n' '$gate' >>'${order_log}'
[ "\${FAIL_GATE:-}" != '$gate' ] || exit 23
if [ '$gate' = build ]; then
  mkdir -p "\$(dirname -- "\$FAKE_ENGINE")"
  printf '%s\n' engine >"\$FAKE_ENGINE"
  chmod +x "\$FAKE_ENGINE"
fi
if [ "\${MALFORM_GATE:-}" = '$gate' ]; then
  printf '%s\n' malformed
elif [ "\${LARGE_GATE:-}" = '$gate' ]; then
  python3 - <<'PY'
print('x' * 70000)
PY
else
  printf '%b\n' '$output'
fi
SH
  chmod +x "$path"
  eval "SF_COR_$(printf '%s' "$gate" | tr '[:lower:]' '[:upper:]')_COMMAND=\$path"
  export "SF_COR_$(printf '%s' "$gate" | tr '[:lower:]' '[:upper:]')_COMMAND"
}

install_gates() {
  FAKE_ENGINE="$worktree/build/stockfish"
  SF_COR_ENGINE=$FAKE_ENGINE
  export FAKE_ENGINE SF_COR_ENGINE
  install_gate provenance "source $source_sha"
  install_gate nnue 'nn-test.nnue 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  install_gate build 'built Stockfish offline'
  install_gate uci 'id name Stockfish dev-test\nid author the Stockfish developers\nuciok'
  expected_bench=$(python3 - "$worktree/manifests/bench.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["expected_nodes"])
PY
)
  install_gate bench "Nodes searched  : $expected_bench"
  install_gate perft 'Nodes searched: 400'
  install_gate reprosearch 'reprosearch testing OK'
  install_gate smoke 'info depth 1 nodes 1\nbestmove e2e4'
}

run_validate() {
  run_id=$1
  shift
  (cd "$worktree" && env "$@" ./scripts/validate.sh "$run_id")
}

new_workspace pass
install_gates
run_validate run-pass
expected_order='provenance
nnue
build
uci
bench
perft
reprosearch
smoke'
[ "$(cat "$order_log")" = "$expected_order" ] || fail 'gates did not run in required order'
evidence="$worktree/evidence/$source_sha/run-pass"
[ -d "$evidence" ] && [ ! -L "$evidence" ] || fail 'passing evidence directory is absent or unsafe'
assert_json "$evidence/provenance.json" 'value["source_sha"] == "'$source_sha'" and value["manifest_digests"].keys() == {"bench", "corchess_deltas", "nnue", "upstreams"}'
assert_json "$evidence/summary.json" 'value["status"] == "pass" and value["merge_authorized"] is False and value["authority"] == "none" and [item["name"] for item in value["ordered_results"]] == ["provenance", "nnue", "build", "uci", "bench", "perft", "reprosearch", "smoke"]'
python3 - "$evidence" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
previous = None
for order, name in enumerate(("provenance", "nnue", "build", "uci", "bench", "perft", "reprosearch", "smoke"), 1):
    path = root / "results" / f"{order:02d}-{name}.json"
    value = json.load(path.open(encoding="utf-8"))
    assert value == {"command": value["command"], "exit_code": 0, "log": f"logs/{order:02d}-{name}.log", "name": name, "order": order, "predecessor_sha256": previous, "status": "pass"}
    previous = hashlib.sha256(path.read_bytes()).hexdigest()
assert (root / "logs/08-smoke.log").stat().st_size <= 65536
PY

bench_before=$(sha256sum "$worktree/manifests/bench.json" | cut -d ' ' -f 1)
for gate in provenance nnue build uci bench perft reprosearch smoke; do
  : >"$order_log"
  expect_fail run_validate "fail-$gate" "FAIL_GATE=$gate"
  failed="$worktree/evidence/$source_sha/fail-$gate"
  assert_json "$failed/summary.json" 'value["status"] == "fail" and value["merge_authorized"] is False'
  assert_json "$failed/results/$(printf '%02d' $(case $gate in provenance) echo 1;; nnue) echo 2;; build) echo 3;; uci) echo 4;; bench) echo 5;; perft) echo 6;; reprosearch) echo 7;; smoke) echo 8;; esac))-$gate.json" 'value["status"] == "fail" and value["exit_code"] == 23'
done

for gate in provenance nnue build uci bench perft reprosearch smoke; do
  expect_fail run_validate "malformed-$gate" "MALFORM_GATE=$gate"
  assert_json "$worktree/evidence/$source_sha/malformed-$gate/summary.json" 'value["status"] == "fail"'
done
[ "$(sha256sum "$worktree/manifests/bench.json" | cut -d ' ' -f 1)" = "$bench_before" ] || fail 'validation updated its reviewed bench expectation'

expect_fail run_validate oversized-smoke LARGE_GATE=smoke
oversized="$worktree/evidence/$source_sha/oversized-smoke"
assert_json "$oversized/summary.json" 'value["status"] == "fail"'
[ "$(wc -c <"$oversized/logs/08-smoke.log")" -le 65536 ] || fail 'smoke evidence was not bounded'

pass_digest=$(python3 - "$evidence" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*")):
    if path.is_file():
        h.update(str(path.relative_to(sys.argv[1])).encode()); h.update(path.read_bytes())
print(h.hexdigest())
PY
)
expect_fail run_validate run-pass
[ "$pass_digest" = "$(python3 - "$evidence" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*")):
    if path.is_file():
        h.update(str(path.relative_to(sys.argv[1])).encode()); h.update(path.read_bytes())
print(h.hexdigest())
PY
)" ] || fail 'a collision changed immutable evidence'

commands_before=$(wc -l <"$order_log")
for unsafe in ../escape nested/run '..' .hidden 'run id'; do
  expect_fail run_validate "$unsafe"
done
expect_fail run_validate foreign-root "SF_COR_EVIDENCE_ROOT=$tmp_dir/foreign"
[ ! -e "$tmp_dir/foreign" ] || fail 'foreign evidence root was changed'
[ "$(wc -l <"$order_log")" -eq "$commands_before" ] || fail 'unsafe evidence request ran a gate command'

new_workspace symlink-root
install_gates
mkdir "$worktree/foreign-evidence"
ln -s "$worktree/foreign-evidence" "$worktree/evidence"
expect_fail run_validate unsafe-root
[ -z "$(fd . "$worktree/foreign-evidence" -d 1)" ] || fail 'symlink evidence root escaped containment'
rm "$worktree/evidence"
mkdir "$worktree/evidence"
ln -s "$worktree/foreign-evidence" "$worktree/evidence/$source_sha"
expect_fail run_validate unsafe-source-parent
[ -z "$(fd . "$worktree/foreign-evidence" -d 1)" ] || fail 'symlink source parent escaped containment'
rm "$worktree/evidence/$source_sha"
printf '%s\n' unsafe >"$worktree/evidence/$source_sha"
expect_fail run_validate unsafe-source-node

new_workspace missing-bench
install_gates
rm "$worktree/manifests/bench.json"
expect_fail run_validate missing-bench
[ ! -e "$worktree/evidence" ] || fail 'missing reviewed bench created evidence state'

new_workspace missing-rg
minimal_path="$tmp_dir/missing-rg-path"
mkdir "$minimal_path"
for required in dirname git python3 sha256sum mktemp; do
  ln -s "$(command -v "$required")" "$minimal_path/$required"
done
expect_fail run_validate missing-rg "PATH=$minimal_path"
rg -qx 'required command is unavailable: rg' "$tmp_dir/command.err" || fail 'missing rg did not fail through deterministic preflight'
[ ! -e "$worktree/evidence" ] || fail 'missing rg created evidence state'
[ ! -s "$order_log" ] || fail 'missing rg ran a gate command'

for dirty_state in tracked staged relevant-untracked; do
  new_workspace "dirty-$dirty_state"
  install_gates
  case $dirty_state in
    tracked) printf '%s\n' dirty >>"$worktree/source.txt" ;;
    staged)
      printf '%s\n' dirty >>"$worktree/source.txt"
      git -C "$worktree" add source.txt
      ;;
    relevant-untracked)
      printf '%s\n' '# unreviewed input' >"$worktree/scripts/unreviewed.sh"
      ;;
  esac
  expect_fail run_validate "dirty-$dirty_state"
  [ ! -e "$worktree/evidence" ] || fail "$dirty_state source state created misleading evidence"
  [ ! -s "$order_log" ] || fail "$dirty_state source state ran a gate command"
done

new_workspace generated-outputs
install_gates
mkdir -p "$worktree/build" "$worktree/evidence"
printf '%s\n' generated >"$worktree/build/untracked-output"
printf '%s\n' generated >"$worktree/evidence/untracked-output"
run_validate generated-outputs

new_workspace builtin-reprosearch-failure
mkdir -p "$worktree/tests"
cat >"$worktree/tests/reprosearch.sh" <<'SH'
#!/bin/sh
printf '%s\n' 'reprosearch testing OK'
exit 47
SH
chmod +x "$worktree/tests/reprosearch.sh"
git -C "$worktree" add tests/reprosearch.sh
git -C "$worktree" commit -q -m 'add reprosearch failure fixture'
source_sha=$(git -C "$worktree" rev-parse HEAD)
install_gates
unset SF_COR_REPROSEARCH_COMMAND
expect_fail run_validate builtin-reprosearch-failure
assert_json "$worktree/evidence/$source_sha/builtin-reprosearch-failure/results/07-reprosearch.json" 'value["status"] == "fail" and value["exit_code"] == 47'
[ "$(wc -l <"$order_log")" -eq 6 ] || fail 'reprosearch failure did not stop before smoke'

new_workspace builtin-reprosearch-cleanup-failure
mkdir -p "$worktree/tests"
cat >"$worktree/tests/reprosearch.sh" <<'SH'
#!/bin/sh
printf '%s\n' 'reprosearch testing OK'
SH
chmod +x "$worktree/tests/reprosearch.sh"
git -C "$worktree" add tests/reprosearch.sh
git -C "$worktree" commit -q -m 'add reprosearch cleanup fixture'
source_sha=$(git -C "$worktree" rev-parse HEAD)
install_gates
unset SF_COR_REPROSEARCH_COMMAND
repro_tmp="$worktree/repro-tmp"
mkdir "$repro_tmp"
real_rm=$(command -v rm)
cat >"$worktree/bin/rm" <<SH
#!/bin/sh
case "\${1:-}:\${2:-}" in
  '-rf:$repro_tmp/'*) exit 52 ;;
esac
exec "$real_rm" "\$@"
SH
chmod +x "$worktree/bin/rm"
expect_fail run_validate builtin-reprosearch-cleanup-failure "TMPDIR=$repro_tmp" "PATH=$worktree/bin:$PATH"
assert_json "$worktree/evidence/$source_sha/builtin-reprosearch-cleanup-failure/results/07-reprosearch.json" 'value["status"] == "fail" and value["exit_code"] == 52'
[ "$(wc -l <"$order_log")" -eq 6 ] || fail 'reprosearch cleanup failure did not stop before smoke'

new_workspace publication-failure
install_gates
real_mv=$(command -v mv)
cat >"$worktree/bin/mv" <<SH
#!/bin/sh
if [ "\${2:-}" = "$worktree/evidence/$source_sha/publication-fail" ]; then
  exit 91
fi
exec "$real_mv" "\$@"
SH
chmod +x "$worktree/bin/mv"
expect_fail run_validate publication-fail "PATH=$worktree/bin:$PATH"
publication_parent="$worktree/evidence/$source_sha"
[ ! -e "$publication_parent/publication-fail" ] || fail 'failed publication created a run directory'
[ ! -e "$publication_parent/.publication-fail.reserve" ] || fail 'failed publication leaked its reservation'
! rg -q '^compatibility evidence passed:' "$tmp_dir/command.out" || fail 'failed publication printed terminal PASS'
publication_summary=$(fd '^summary\.json$' "$publication_parent" --hidden --type f)
[ -n "$publication_summary" ] || fail 'failed publication did not retain non-authoritative evidence'
assert_json "$publication_summary" 'value["status"] == "pass" and value["merge_authorized"] is False and value["authority"] == "none"'

printf '%s\n' 'gate tests passed'
