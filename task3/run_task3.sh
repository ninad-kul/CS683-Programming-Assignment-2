#!/usr/bin/env bash
# run_task3.sh - automate Task 3 experiments for ChampSim PA2
#
# Usage (from the repo root):
#   ./run_task3.sh           # compile, run traces, and generate summary
#   ./run_task3.sh summary   # rebuild results/summary_task3.csv from existing results
#   ./run_task3.sh clean     # delete task 3 logs and results

set -euo pipefail

WARMUP=${WARMUP:-25000000}
SIM=${SIM:-25000000}
TRACES=${TRACES:-"Trace1 Trace2 Trace3"}
JOBS=${JOBS:-$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))}
FORCE=${FORCE:-0}                     # 1 = rerun even if result exists
L1D_PF="spp"                          # L1D prefetcher for Task 3

REPL_POLICY="pfa_dyn_irrip"           # replacement/pfa_dyn_irrip.l2c_repl
RRIP_BASE="rrip"                      # baseline replacement policy

BIN_BASELINE="l1spp_l2rrip"
BIN_TASK3="l1spp_l2pfa_dyn_irrip"

mkdir -p results logs

# ---------------------------------------------------------------- helpers
check_files() {
  local ok=1
  [[ -f replacement/${REPL_POLICY}.l2c_repl ]] || { echo "ERROR: replacement/${REPL_POLICY}.l2c_repl not found" >&2; ok=0; }
  [[ -f replacement/${RRIP_BASE}.l2c_repl ]] || { echo "ERROR: replacement/${RRIP_BASE}.l2c_repl not found" >&2; ok=0; }
  [[ -f prefetcher/${L1D_PF}.cc ]] || { echo "ERROR: prefetcher/${L1D_PF}.cc not found" >&2; ok=0; }
  [[ -x build_champsim.sh ]] || { echo "ERROR: run from repo root (build_champsim.sh missing)" >&2; ok=0; }
  [[ $ok == 1 ]] || exit 1
}

build() {
  local repl=$1 bin=$2
  rm -f bin/*-1core-"$bin"
  echo "[build] prefetcher=$L1D_PF replacement=$repl binary-suffix=$bin"
  ./build_champsim.sh "$L1D_PF" "$repl" "$bin" > "logs/build_${bin}.log" 2>&1 || true
  if ! ls bin/*-1core-"$bin" > /dev/null 2>&1; then
    echo "[build] FAILED for $bin - check logs/build_${bin}.log"
    tail -n 6 "logs/build_${bin}.log"
    return 1
  fi
}

run_traces() {
  local bin=$1 exe t tl out
  exe=$(ls -t bin/*-1core-"$bin" 2>/dev/null | head -n1)
  [[ -n "$exe" ]] || return 1
  for t in $TRACES; do
    tl=${t,,}
    out=results/${bin}_${tl}.txt
    if [[ $FORCE != 1 ]] && grep -q "Region of Interest Statistics" "$out" 2>/dev/null; then
      echo "[run] skip (done): $out"; continue
    fi
    while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n; done
    echo "[run] $bin on $t"
    ( "./$exe" -warmup_instructions "$WARMUP" -simulation_instructions "$SIM" \
        -traces "traces/$t.gz" > "$out" 2>&1 ) &
  done
}

# ---------------------------------------------------------------- parsers
ipc_of()  { grep -m1 '^CPU 0 cumulative IPC' "$1" | awk '{print $5}'; }
mpki_of() { grep -m1 -E "$2" "$1" | awk '{print $NF}'; }
done_ok() { grep -q "Region of Interest Statistics" "$1" 2>/dev/null; }

pf_acc() {
  grep -m1 'L1D USEFUL LOAD PREFETCHES:' "$1" | awk '{print $NF}'
}

pf_cov() {
  local u m
  u=$(grep -m1 'L1D USEFUL LOAD PREFETCHES:' "$1" | awk '{print $5}')
  m=$(grep -m1 '^L1D LOAD ' "$1" | awk '{print $8}')
  awk -v useful="${u:-0}" -v miss="${m:-0}" 'BEGIN {
    total = useful + miss;
    if (total > 0) printf "%.2f%%", (useful / total) * 100;
    else print "0.00%";
  }'
}

# ---------------------------------------------------------------- summary
summary() {
  local out=results/summary_task3.csv f base_f t tl
  local ipc_v base_ipc sp acc cov l1d_m l2c_m l2c_i l2c_d label

  echo "config,trace,ipc,speedup_vs_spp_rrip,l1d_pf_accuracy,l1d_pf_coverage,l1d_load_mpki,l2c_load_mpki,l2c_inst_load_mpki,l2c_data_load_mpki" > "$out"

  for bin_name in "$BIN_BASELINE" "$BIN_TASK3"; do
    label=${bin_name#l1spp_l2}
    for t in $TRACES; do
      tl=${t,,}
      f="results/${bin_name}_${tl}.txt"
      base_f="results/${BIN_BASELINE}_${tl}.txt"

      done_ok "$f" || continue

      ipc_v=$(ipc_of "$f")
      sp="1.0000"
      if [[ "$bin_name" != "$BIN_BASELINE" ]] && done_ok "$base_f"; then
        base_ipc=$(ipc_of "$base_f")
        sp=$(awk -v a="$ipc_v" -v b="$base_ipc" 'BEGIN{printf "%.4f", a/b}')
      fi

      acc=$(pf_acc "$f")
      cov=$(pf_cov "$f")
      l1d_m=$(mpki_of "$f" '^L1D LOAD ')
      l2c_m=$(mpki_of "$f" '^L2C LOAD +ACCESS')
      l2c_i=$(mpki_of "$f" '^L2C INSTRUCTION LOAD MPKI:')
      l2c_d=$(mpki_of "$f" '^L2C DATA LOAD MPKI:')

      echo "$label,$t,$ipc_v,$sp,$acc,$cov,$l1d_m,$l2c_m,$l2c_i,$l2c_d" >> "$out"
    done
  done

  echo; echo "== $out =="; column -t -s, "$out" 2>/dev/null || cat "$out"
}

# ---------------------------------------------------------------- main
case "${1:-run}" in
  run)
    check_files
    build "$RRIP_BASE" "$BIN_BASELINE" && run_traces "$BIN_BASELINE"
    build "$REPL_POLICY" "$BIN_TASK3"   && run_traces "$BIN_TASK3"
    wait
    summary
    ;;
  summary)
    summary
    ;;
  clean)
    rm -f results/l1spp_*.txt logs/build_l1spp_*.log results/summary_task3.csv
    echo "Cleaned Task 3 logs and results."
    ;;
  *)
    echo "Usage: $0 [run|summary|clean]"
    ;;
esac