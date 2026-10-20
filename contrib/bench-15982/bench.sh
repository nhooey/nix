#!/usr/bin/env bash
# Count the source trees `nix flake lock` fetches with two Nix binaries,
# master (baseline) and NixOS/nix#15982 (candidate), on two flake graphs:
#
#   control:  top -> middle -> library -> sub          (all absolute path: inputs)
#   relative: top -> middle -> library -> path:./sub   (the #14762 graph)
#
# Each graph is locked with no lock file (fresh), then again from the lock
# file the candidate wrote (relock). The count is the number of `got tree`
# lines in each --debug log.
#
# Usage: bench.sh <baseline-nix> <candidate-nix> [<out-dir>]
# Writes summary.md and logs/ to <out-dir> (default ./bench-out). The graphs
# go in a new temporary directory, outside any Git repository, so Nix reads
# them as path: flakes.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <baseline-nix> <candidate-nix> [<out-dir>]" >&2
  exit 2
fi

declare -A bin=([baseline]="$(realpath "$1")" [candidate]="$(realpath "$2")")
out="$(realpath -m "${3:-bench-out}")"
mkdir -p "$out/logs"
work="$(realpath "$(mktemp -d)")"

export NIX_CONFIG="experimental-features = nix-command flakes
warn-dirty = false"

# Build a four-level graph under $1; $2 is how 'library' refers to 'sub'.
mk_graph() {
  local root="$1" sub_url="$2"
  mkdir -p "$root/library/sub" "$root/middle" "$root/top"
  echo '{ outputs = _: { }; }' >"$root/library/sub/flake.nix"
  cat >"$root/library/flake.nix" <<NIX
{
  inputs.sub.url = "$sub_url";
  outputs = _: { };
}
NIX
  cat >"$root/middle/flake.nix" <<NIX
{
  inputs.library.url = "path:$root/library";
  outputs = _: { };
}
NIX
  cat >"$root/top/flake.nix" <<NIX
{
  inputs.middle.url = "path:$root/middle";
  outputs = _: { };
}
NIX
}

mk_graph "$work/control" "path:$work/control/library/sub"
mk_graph "$work/relative" "path:./sub"

# 'middle' carries its own lock, so locking 'top' takes 'library' from it
# through the lazy "keep existing input" path. Lock it with the candidate,
# which locks both graphs, so both binaries start from the same file.
setup_lock() {
  local log="$out/logs/$2.log"
  "${bin[candidate]}" flake lock "$1" >"$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
}
for g in control relative; do
  setup_lock "$work/$g/middle" "$g-middle"
done

# Trees fetched by one `nix flake lock` of graph $1 with binary $2, or "fails".
trees() {
  local g="$1" b="$2" scenario="$3"
  local log="$out/logs/$g-$scenario-$b.log"
  if "${bin[$b]}" flake lock --debug "$work/$g/top" >"$log" 2>&1; then
    grep -c "^got tree " "$log" || true
  else
    echo fails
  fi
}

declare -A n
rows=()
for g in control relative; do
  lock="$work/$g/top/flake.lock"
  for scenario in fresh relock; do
    if [[ $scenario = relock ]]; then
      rm -f "$lock"
      setup_lock "$work/$g/top" "$g-relock-setup"
      cp "$lock" "$work/$g.lock"
    fi
    for b in baseline candidate; do
      if [[ $scenario = fresh ]]; then
        rm -f "$lock"
      else
        cp "$work/$g.lock" "$lock"
      fi
      n[$g $scenario $b]="$(trees "$g" "$b" "$scenario")"
    done
    rows+=("$g $scenario")
  done
done

declare -A label=(
  [control fresh]="control: \`top → middle → library → sub\`, absolute paths"
  [relative fresh]="relative: \`top → middle → library → ./sub\`, the #14762 graph"
)

same=0
differ=()
for r in "${rows[@]}"; do
  if [[ ${n[$r baseline]} = "${n[$r candidate]}" ]]; then
    same=$((same + 1))
  else
    differ+=("$r: master ${n[$r baseline]}, this PR ${n[$r candidate]}")
  fi
done
verdict="Same trees fetched in $same of ${#rows[@]} rows."
if [[ ${#differ[@]} -gt 0 ]]; then
  verdict+=" Differs: ${differ[0]}"
  for d in "${differ[@]:1}"; do verdict+="; $d"; done
  verdict+="."
fi

{
  echo "Source trees fetched by \`nix flake lock\`:"
  echo
  echo "| Graph | Lock | master | this PR |"
  echo "| --- | --- | --- | --- |"
  for r in "${rows[@]}"; do
    echo "| ${label[$r]:-${r% *}} | ${r#* } | ${n[$r baseline]} | ${n[$r candidate]} |"
  done
  echo
  echo "$verdict"
  echo
  echo "- master: \`$("${bin[baseline]}" --version)\`"
  echo "- this PR: \`$("${bin[candidate]}" --version)\`"
  echo "- relock starts from the lock file this PR wrote, since master can't write one for the relative graph"
  echo "- each count is the \`got tree\` lines in a \`--debug\` log under \`logs/\`"
} >"$out/summary.md"

printf '%-9s %-7s %7s %8s\n' Graph Lock master "this PR"
for r in "${rows[@]}"; do
  printf '%-9s %-7s %7s %8s\n' "${r% *}" "${r#* }" "${n[$r baseline]}" "${n[$r candidate]}"
done
echo
echo "$verdict"
echo "Logs and summary.md: $out"
echo "Graphs: $work"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  cat "$out/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi
