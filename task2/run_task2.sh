#!/usr/bin/env bash
# run_task2.sh - automate Task 2A / 2B experiments for ChampSim PA2
#
# Usage (from the repo root):
#   ./run_task2.sh 2a        # plain RRIP baseline + static I-RRIP variants
#   ./run_task2.sh 2b        # dynamic I-RRIP threshold sweep (+ duel extension)
#   ./run_task2.sh all       # both
#   ./run_task2.sh summary   # rebuild results/summary_task2.csv from existing results
#   ./run_task2.sh clean     # delete generated replacement/exp_*.l2c_repl files

set -euo pipefail

WARMUP=${WARMUP:-25000000}
SIM=${SIM:-25000000}
TRACES=${TRACES:-"Trace1 Trace2 Trace3"}
JOBS=${JOBS:-$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))}
FORCE=${FORCE:-0}                     # 1 = rerun even if a finished result exists
L1D_PF=${L1D_PF:-no}                  # first argument of build_champsim.sh

STATIC_BASE=${STATIC_BASE:-irrip}     # replacement/<name>.l2c_repl : static I-RRIP (Task 2A)
DYN_BASE=${DYN_BASE:-dyn_irrip}       # replacement/<name>.l2c_repl : dynamic I-RRIP (Task 2B)
RRIP_BASE=${RRIP_BASE:-rrip}          # replacement/<name>.l2c_repl : plain RRIP baseline

# 2A sweep, each entry "quota,inst_insert_rrpv,wb_insert_rrpv"
VARIANTS_2A=${VARIANTS_2A:-"8,2,2 8,0,2 4,2,2 12,2,2 8,2,3"}
# 2B sweep: instruction-share thresholds in percent
THRESHOLDS=${THRESHOLDS:-"10 25 40 55 70"}
# I-RRIP knobs used inside the dynamic policy
DYN_Q=${DYN_Q:-8}; DYN_I=${DYN_I:-2}; DYN_W=${DYN_W:-2}
# extra, older binaries to show in the summary
EXTRA_BINS=${EXTRA_BINS:-""}

BASE_BIN="l1no_l2rrip"

mkdir -p results logs

# ---------------------------------------------------------------- helpers
usage() { sed -n '2,15p' "$0"; }

check_files() {
  local f ok=1
  for f in "$@"; do
    [[ -f replacement/$f.l2c_repl ]] || { echo "ERROR: replacement/$f.l2c_repl not found" >&2; ok=0; }
  done
  [[ -x build_champsim.sh ]] || { echo "ERROR: run from repo root (build_champsim.sh missing)" >&2; ok=0; }
  [[ $ok == 1 ]] || exit 1
}

set_macro() {
  local f=$1 n=$2 v=$3
  if ! grep -qE "^#define[[:space:]]+${n}([[:space:]]|$)" "$f"; then
    echo "ERROR: '#define $n' not found as a single line in $f" >&2
    return 1
  fi
  sed -i -E 's|^#define[[:space:]]+'"$n"'([[:space:]].*)?$|#define '"$n $v"'|' "$f"
}

build() {
  local repl=$1 bin=$2
  rm -f bin/*-1core-"$bin"
  echo "[build] replacement=$repl  binary-suffix=$bin"
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

# ---------------------------------------------------------------- experiments
exp_baseline() {
  build "$RRIP_BASE" "$BASE_BIN" && run_traces "$BASE_BIN"
}

exp_2a() {
  exp_baseline
  local v q i w name src dst
  for v in $VARIANTS_2A; do
    IFS=, read -r q i w <<< "$v"
    name="exp_irrip_q${q}_i${i}_w${w}"
    src="replacement/${STATIC_BASE}.l2c_repl"; dst="replacement/${name}.l2c_repl"
    cp "$src" "$dst"
    set_macro "$dst" INST_QUOTA "$q"         || continue
    set_macro "$dst" INST_INSERT_RRPV "$i"   || continue
    set_macro "$dst" WB_INSERT_RRPV "$w"     || continue
    build "$name" "l1no_l2_${name}" && run_traces "l1no_l2_${name}"
  done
}

exp_2b() {
  local t name src dst
  src="replacement/${DYN_BASE}.l2c_repl"
  for t in $THRESHOLDS; do
    name="exp_dyn_t${t}"
    dst="replacement/${name}.l2c_repl"
    cp "$src" "$dst"
    set_macro "$dst" THRESH_PCT "$t"           || continue
    set_macro "$dst" USE_DUEL 0                || continue
    set_macro "$dst" PF_AWARE 0                || continue
    set_macro "$dst" INST_QUOTA "$DYN_Q"       || continue
    set_macro "$dst" INST_INSERT_RRPV "$DYN_I" || continue
    set_macro "$dst" WB_INSERT_RRPV "$DYN_W"   || continue
    build "$name" "l1no_l2_${name}" && run_traces "l1no_l2_${name}"
  done
  
  name="exp_dyn_duel_t25"
  dst="replacement/${name}.l2c_repl"
  cp "$src" "$dst"
  set_macro "$dst" THRESH_PCT 25               && \
  set_macro "$dst" USE_DUEL 1                  && \
  set_macro "$dst" PF_AWARE 0                  && \
  set_macro "$dst" INST_QUOTA "$DYN_Q"        && \
  set_macro "$dst" INST_INSERT_RRPV "$DYN_I"  && \
  set_macro "$dst" WB_INSERT_RRPV "$DYN_W"    && \
  build "$name" "l1no_l2_${name}" && run_traces "l1no_l2_${name}"
}

# ---------------------------------------------------------------- summary
ipc_of()  { grep -m1 '^CPU 0 cumulative IPC' "$1" | awk '{print $5}'; }
mpki_of() { grep -m1 -E "$2" "$1" | awk '{print $NF}'; }
done_ok() { grep -q "Region of Interest Statistics" "$1" 2>/dev/null; }

summary() {
  local out=results/summary_task2.csv bins b t tl f base ipc_v sp label
  echo "config,trace,ipc,speedup_vs_rrip,l2c_load_mpki,l2c_inst_load_mpki,l2c_data_load_mpki,l2c_total_mpki" > "$out"
  bins=$(ls results/*_trace?.txt 2>/dev/null | sed -E 's#^results/(.*)_trace[0-9]+\.txt$#\1#' | sort -u || true)
  for b in $bins; do
    case "$b" in
      "$BASE_BIN"|l1no_l2_exp_*) ;;
      *) [[ " $EXTRA_BINS " == *" $b "* ]] || continue ;;
    esac
    label=${b#l1no_l2_}; [[ $b == "$BASE_BIN" ]] && label="rrip_baseline"
    for t in $TRACES; do
      tl=${t,,}; f=results/${b}_${tl}.txt
      done_ok "$f" || continue
      ipc_v=$(ipc_of "$f")
      base=results/${BASE_BIN}_${tl}.txt
      sp=NA
      if done_ok "$base"; then
        sp=$(awk -v a="$ipc_v" -v b="$(ipc_of "$base")" 'BEGIN{printf "%.4f", a/b}')
      fi
      echo "$label,$t,$ipc_v,$sp,$(mpki_of "$f" '^L2C LOAD +ACCESS'),$(mpki_of "$f" '^L2C INSTRUCTION LOAD MPKI'),$(mpki_of "$f" '^L2C DATA LOAD MPKI'),$(mpki_of "$f" '^L2C TOTAL +ACCESS')" >> "$out"
    done
  done
  echo; echo "== $out =="; column -t -s, "$out" 2>/dev/null || cat "$out"
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  2a)      check_files "$STATIC_BASE" "$RRIP_BASE"; exp_2a; wait; summary ;;
  2b)      check_files "$DYN_BASE"; exp_2b; wait; summary ;;
  all)     check_files "$STATIC_BASE" "$DYN_BASE" "$RRIP_BASE"; exp_2a; exp_2b; wait; summary ;;
  summary) summary ;;
  clean)   rm -f replacement/exp_*.l2c_repl; echo "removed generated replacement/exp_*.l2c_repl" ;;
  *)       usage ;;
esac
