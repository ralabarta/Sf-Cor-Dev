#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/guards.sh
. "$script_dir/lib/guards.sh"

root=$(resolve_repository_root "$script_dir")
[ "$#" -eq 1 ] || fail 'usage: validate.sh <run-id>'
run_id=$1
case $run_id in
  *[!A-Za-z0-9._-]*|.*|*..*|'') fail 'invalid evidence run ID' ;;
esac
require_command git
require_command python3
require_command sha256sum
require_command mktemp
require_command rg

git -C "$root" diff --quiet -- . ':(exclude)build/**' ':(exclude)evidence/**' ||
  fail 'repository source provenance is not clean'
git -C "$root" diff --cached --quiet -- . ':(exclude)build/**' ':(exclude)evidence/**' ||
  fail 'repository source provenance is not clean'
untracked_inputs=$(git -C "$root" ls-files --others -- manifests scripts src tests Copying.txt) ||
  fail 'cannot inspect repository provenance'
[ -z "$untracked_inputs" ] || fail 'repository source provenance is not clean'

bench_manifest=$(require_owned_manifest "$root" manifests/bench.json bench.json)
nnue_manifest=$(require_owned_manifest "$root" manifests/nnue.json nnue.json)
upstreams_manifest=$(require_owned_manifest "$root" manifests/upstreams.json upstreams.json)
deltas_manifest=$(require_owned_manifest "$root" manifests/corchess-deltas.json corchess-deltas.json)
source_sha=$(git -C "$root" rev-parse HEAD)
require_commit_sha "$source_sha"

bench_values=$(python3 - "$bench_manifest" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if set(value) != {"schema", "expected_nodes", "command", "source_commit", "baseline_commit"}:
    raise SystemExit(1)
if value["schema"] != 1 or value["command"] != "bench":
    raise SystemExit(1)
if not isinstance(value["expected_nodes"], int) or value["expected_nodes"] <= 0:
    raise SystemExit(1)
for key in ("source_commit", "baseline_commit"):
    text = value[key]
    if not isinstance(text, str) or len(text) != 40 or any(c not in "0123456789abcdef" for c in text):
        raise SystemExit(1)
print(value["expected_nodes"], value["source_commit"], value["baseline_commit"])
PY
) || fail 'reviewed bench manifest is invalid'
set -f
# shellcheck disable=SC2086 # Intentional splitting of three validated manifest fields.
set -- $bench_values
set +f
[ "$#" -eq 3 ] || fail 'reviewed bench manifest is invalid'
expected_bench=$1
bench_source=$2
bench_baseline=$3
git -C "$root" cat-file -e "$bench_source^{commit}" 2>/dev/null || fail 'reviewed bench source commit is unavailable'
git -C "$root" merge-base --is-ancestor "$bench_source" "$source_sha" || fail 'reviewed bench source is not an ancestor'
message=$(git -C "$root" show -s --format=%B "$bench_baseline") || fail 'reviewed bench baseline commit is unavailable'
printf '%s\n' "$message" | rg -q "^Bench: $expected_bench$" || fail 'reviewed bench value lacks pinned upstream provenance'

for manifest in "$nnue_manifest" "$upstreams_manifest" "$deltas_manifest"; do
  python3 - "$manifest" <<'PY' || fail "input manifest is malformed: $manifest"
import json, sys
json.load(open(sys.argv[1], encoding="utf-8"))
PY
done

expected_root="$root/evidence"
evidence_root=${SF_COR_EVIDENCE_ROOT:-$expected_root}
[ "$evidence_root" = "$expected_root" ] || fail 'evidence root is outside the repository boundary'
[ ! -L "$evidence_root" ] || fail 'evidence root must not be a symlink'
if [ -e "$evidence_root" ]; then
  [ -d "$evidence_root" ] || fail 'evidence root is not a directory'
else
  mkdir -m 700 "$evidence_root" || fail 'cannot create evidence root'
fi
source_dir="$evidence_root/$source_sha"
[ ! -L "$source_dir" ] || fail 'evidence source directory must not be a symlink'
if [ -e "$source_dir" ]; then
  [ -d "$source_dir" ] || fail 'evidence source path is not a directory'
else
  mkdir -m 700 "$source_dir" || fail 'cannot create evidence source directory'
fi
run_path="$source_dir/$run_id"
reservation="$source_dir/.$run_id.reserve"
[ ! -e "$run_path" ] && [ ! -L "$run_path" ] || fail 'evidence run already exists'
mkdir "$reservation" 2>/dev/null || fail 'evidence run is already reserved'
work=$(mktemp -d "$source_dir/.run.XXXXXX")
mkdir "$work/logs" "$work/results"
terminal_status=fail
published=false

write_json() {
  destination=$1
  shift
  python3 - "$destination" "$@" <<'PY'
import json, os, sys, tempfile
path, args = sys.argv[1], sys.argv[2:]
value = json.loads(args[0])
fd, temporary = tempfile.mkstemp(prefix=".json.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary): os.unlink(temporary)
PY
}

finalize() {
  finalize_status=0
  if [ "$published" = false ]; then
    if python3 - "$work" "$terminal_status" <<'PY'
import json, os, pathlib, sys, tempfile
root, status = pathlib.Path(sys.argv[1]), sys.argv[2]
results = []
for path in sorted((root / "results").glob("*.json")):
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    results.append({"name": value["name"], "status": value["status"]})
summary = {"authority": "none", "merge_authorized": False, "ordered_results": results, "status": status}
fd, temporary = tempfile.mkstemp(prefix=".summary.", dir=root)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump(summary, stream, sort_keys=True, separators=(",", ":")); stream.write("\n")
    stream.flush(); os.fsync(stream.fileno())
os.replace(temporary, root / "summary.json")
PY
    then
      if mv "$work" "$run_path"; then
        published=true
      else
        finalize_status=$?
      fi
    else
      finalize_status=$?
    fi
  fi
  rmdir "$reservation" 2>/dev/null || true
  return "$finalize_status"
}
trap finalize EXIT HUP INT TERM

manifest_digests=$(python3 - "$bench_manifest" "$deltas_manifest" "$nnue_manifest" "$upstreams_manifest" <<'PY'
import hashlib, json, sys
names = ("bench", "corchess_deltas", "nnue", "upstreams")
print(json.dumps(dict(zip(names, (hashlib.sha256(open(path, "rb").read()).hexdigest() for path in sys.argv[1:]))), sort_keys=True))
PY
)
write_json "$work/provenance.json" "$(python3 - "$source_sha" "$manifest_digests" "$bench_source" "$bench_baseline" <<'PY'
import json, sys
print(json.dumps({"authority":"none", "bench_baseline_commit":sys.argv[4], "bench_source_commit":sys.argv[3], "manifest_digests":json.loads(sys.argv[2]), "merge_authorized":False, "source_sha":sys.argv[1]}))
PY
)"

engine=${SF_COR_ENGINE:-$root/build/stockfish}
max_log_bytes=65536
bench_max_log_bytes=131072
previous=null
order=0

command_for() {
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  eval "override=\${SF_COR_${upper}_COMMAND:-}"
  if [ -n "$override" ]; then
    case $override in /*) ;; *) fail "gate command must be absolute: $1" ;; esac
    [ -f "$override" ] && [ ! -L "$override" ] && [ -x "$override" ] || fail "gate command is unsafe: $1"
    printf '%s\n' "$override"
  else
    printf 'builtin:%s\n' "$1"
  fi
}

run_default() {
  gate=$1
  case $gate in
    provenance) printf 'source %s\n' "$source_sha" ;;
    nnue) "$script_dir/nnue-prefetch.sh" --verify-only ;;
    build) "$script_dir/build.sh" ;;
    uci) printf 'uci\nquit\n' | "$engine" ;;
    bench) "$engine" bench ;;
    perft) printf 'position startpos\ngo perft 2\nquit\n' | "$engine" ;;
    reprosearch)
      repro_dir=$(mktemp -d)
      ln -s "$engine" "$repro_dir/stockfish"
      repro_status=0
      (cd "$repro_dir" && "$root/tests/reprosearch.sh") || repro_status=$?
      cleanup_status=0
      rm -rf "$repro_dir" || cleanup_status=$?
      [ "$repro_status" -eq 0 ] || return "$repro_status"
      [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
      ;;
    smoke) printf 'uci\nisready\nposition startpos\ngo nodes 100\nquit\n' | "$engine" ;;
  esac
}

validate_output() {
  gate=$1
  path=$2
  case $gate in
    provenance) rg -qx "source $source_sha" "$path" ;;
    nnue) rg -qx '[A-Za-z0-9._-]+ [0-9a-f]{64}' "$path" ;;
    build) rg -q '^built Stockfish offline' "$path" && [ -x "$engine" ] ;;
    uci) rg -q '^id name Stockfish( |$)' "$path" && rg -qx 'uciok' "$path" ;;
    bench) [ "$(rg -o 'Nodes searched  : [0-9]+' "$path" | cut -d ' ' -f 5)" = "$expected_bench" ] ;;
    perft) rg -qx 'Nodes searched: 400' "$path" ;;
    reprosearch) rg -qx 'reprosearch testing OK' "$path" ;;
    smoke) rg -q '^bestmove [a-h][1-8][a-h][1-8][qrbn]?$' "$path" ;;
  esac
}

run_gate() {
  gate=$1
  order=$((order + 1))
  number=$(printf '%02d' "$order")
  command=$(command_for "$gate")
  raw="$work/.raw-$number"
  if [ "${command#builtin:}" != "$command" ]; then
    if run_default "$gate" >"$raw" 2>&1; then exit_code=0; else exit_code=$?; fi
  else
    if "$command" >"$raw" 2>&1; then exit_code=0; else exit_code=$?; fi
  fi
  log="logs/$number-$gate.log"
  size=$(wc -c <"$raw")
  gate_log_bytes=$max_log_bytes
  [ "$gate" != bench ] || gate_log_bytes=$bench_max_log_bytes
  dd if="$raw" of="$work/$log" bs=$gate_log_bytes count=1 2>/dev/null
  rm -f "$raw"
  status=pass
  [ "$exit_code" -eq 0 ] || status=fail
  [ "$size" -le "$gate_log_bytes" ] || status=fail
  if [ "$status" = pass ] && ! validate_output "$gate" "$work/$log"; then status=fail; fi
  result="results/$number-$gate.json"
  write_json "$work/$result" "$(python3 - "$command" "$exit_code" "$log" "$gate" "$order" "$previous" "$status" <<'PY'
import json, sys
print(json.dumps({"command":sys.argv[1], "exit_code":int(sys.argv[2]), "log":sys.argv[3], "name":sys.argv[4], "order":int(sys.argv[5]), "predecessor_sha256":None if sys.argv[6] == "null" else sys.argv[6], "status":sys.argv[7]}))
PY
)"
  previous=$(sha256sum "$work/$result" | cut -d ' ' -f 1)
  [ "$status" = pass ] || return 1
}

for gate in provenance nnue build uci bench perft reprosearch smoke; do
  run_gate "$gate" || exit 1
done
terminal_status=pass
if finalize; then
  trap - EXIT HUP INT TERM
  printf 'compatibility evidence passed: %s\n' "$run_path"
else
  finalize_status=$?
  trap - EXIT HUP INT TERM
  exit "$finalize_status"
fi
