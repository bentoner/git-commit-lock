#!/usr/bin/env bash
# with-load.sh — run a command under a calibrated, reproducible background load.
#
# Usage:   bash tests/with-load.sh <cmd> [args...]
# Example: bash tests/with-load.sh bash tests/git-commit-lock.test.sh
#
# Wraps "$@", applies artificial background load for the command's lifetime, then
# tears the load down (by EXACT spawned PIDs — never by name, so it is safe on a
# shared dev box and doubly safe on an ephemeral CI runner) and exits with the
# wrapped command's exit code.
#
# WHY load exists here (see docs/load-testing-strategy.md §1): this protocol's
# *correctness* is load-independent (O_EXCL + atomic rename + per-attempt tokens
# never consult the clock for a correctness decision), so load cannot break
# exclusion. Load's only jobs are (J1) perturb scheduling so the protocol's
# multi-syscall sequences get preempted at adversarial points, and (J2) stretch
# the few genuinely timing-derived decisions. Magnitude past ~2x CPU
# oversubscription mostly manufactures harness wall-clock flakes, not bugs — which
# is why load is expressed as an oversubscription RATIO and the total ratio is
# CAPPED.
#
# ── Calibrated interface (the contract nightly/deep-sweep CI calls against) ──────
#
#   GCL_STRESS_KIND        none | cpu | disk | both        (default: none)
#                          none/unset => CLEAN PASS-THROUGH: zero added load, the
#                          command's exit code is propagated verbatim.
#
#   GCL_STRESS_RATIO       Oversubscription ratio R = stressors / nproc, PER KIND.
#                          (default: 1)  Stressors-per-kind = round(R * nproc),
#                          floored at 1 when a kind is selected. Runner-independent:
#                          "R=2" means the same pressure on a 2-core and a 32-core box,
#                          whereas a raw hog count does not.
#
#   GCL_STRESS_RATIO_MAX   Cap on the TOTAL oversubscription ratio across all kinds
#                          (default: 2). `both` runs cpu + disk, so its total ratio is
#                          2*R; this cap scales each kind's stressor count down
#                          proportionally so the runner is never wedged. Set the
#                          deep-sweep flake-hunt higher deliberately.
#
#   GCL_STRESS_LOAD        BACK-COMPAT raw-count override. If set to a positive
#                          integer it REPLACES the ratio computation: exactly N
#                          stressors per selected kind (still capped by RATIO_MAX
#                          unless GCL_STRESS_RATIO_MAX is also raised). Empty/unset =>
#                          use the ratio. Kept so the existing deep-sweep
#                          `stress_load=N` dispatch input keeps working.
#
#   GCL_STRESS_CGROUP      1 => on Linux with a writable cgroup v2 cpu controller,
#                          PROBE the calibrated cgroup CPU-quota path (envelope leg).
#                          The probe is recorded in the manifest. cgroup IO throttling
#                          is experimental and intentionally NOT attempted here.
#                          (default: 0)  Absent/unwritable => fall back to spinners.
#
#   GCL_LOAD_MANIFEST      Path for the per-run load-manifest JSON
#                          (default: test-output/load-manifest.<pid>.json, created
#                          under a known dir so CI can upload it). One file per run,
#                          capturing {kind, R, nproc, stressor counts, achieved
#                          slowdown, tool versions, os/arch, git sha} so any flake is
#                          reproducible. Written on success too.
#
# CPU stressor: `stress-ng --cpu` when available (calibrated, measurable), else a
#               portable bash spin loop (one busy core each).
# Disk stressor: a tight create / write+fsync / delete loop over a small file on the
#               same volume as the test scratch dir — metadata + write-back pressure
#               that contends with the lock-file create/delete the suite itself does.
#               (Always the portable shell hog; cross-platform, low-fidelity but real
#               metadata-op pressure — see strategy §4.)
set -uo pipefail

# ── Inputs ───────────────────────────────────────────────────────────────────
kind="${GCL_STRESS_KIND:-none}"
nproc_count="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
case "$nproc_count" in ''|*[!0-9]*) nproc_count=4 ;; esac
[ "$nproc_count" -lt 1 ] && nproc_count=1

ratio="${GCL_STRESS_RATIO:-1}"
case "$ratio" in ''|*[!0-9]*) ratio=1 ;; esac   # integer ratios only (R in {0,1,2,…})

ratio_max="${GCL_STRESS_RATIO_MAX:-2}"
case "$ratio_max" in ''|*[!0-9]*) ratio_max=2 ;; esac

raw_load="${GCL_STRESS_LOAD:-}"
case "$raw_load" in *[!0-9]*) raw_load="" ;; esac   # non-numeric => ignore, use ratio

manifest="${GCL_LOAD_MANIFEST:-test-output/load-manifest.$$.json}"

# ── Stressor-count calibration ─────────────────────────────────────────────────
# Per-kind count: raw-count override wins, else round(R * nproc) floored at 1.
if [ -n "$raw_load" ]; then
  per_kind="$raw_load"
else
  per_kind=$(( ratio * nproc_count ))
  [ "$ratio" -gt 0 ] && [ "$per_kind" -lt 1 ] && per_kind=1
fi

# How many kinds spawn stressors.
n_kinds=0
case "$kind" in
  cpu|disk) n_kinds=1 ;;
  both)     n_kinds=2 ;;
esac

# R_total cap: total stressors must not exceed ratio_max * nproc. `both` would
# otherwise be 2*per_kind; scale each kind down proportionally if it would breach.
cpu_count=0
disk_count=0
capped="no"
if [ "$n_kinds" -gt 0 ] && [ "$per_kind" -gt 0 ]; then
  total_cap=$(( ratio_max * nproc_count ))
  [ "$total_cap" -lt "$n_kinds" ] && total_cap="$n_kinds"   # always allow >=1 per active kind
  requested_total=$(( per_kind * n_kinds ))
  if [ "$requested_total" -gt "$total_cap" ]; then
    per_kind=$(( total_cap / n_kinds ))
    [ "$per_kind" -lt 1 ] && per_kind=1
    capped="yes"
  fi
  case "$kind" in
    cpu)  cpu_count="$per_kind" ;;
    disk) disk_count="$per_kind" ;;
    both) cpu_count="$per_kind"; disk_count="$per_kind" ;;
  esac
fi

# ── Tool discovery ─────────────────────────────────────────────────────────────
stress_ng_bin="$(command -v stress-ng 2>/dev/null || true)"
stress_ng_ver="none"
[ -n "$stress_ng_bin" ] && stress_ng_ver="$("$stress_ng_bin" --version 2>/dev/null | head -1 | tr -d '\r')"
bash_ver="$(bash --version 2>/dev/null | head -1 | tr -d '\r')"
os_uname="$(uname -srm 2>/dev/null | tr -d '\r' || echo unknown)"
git_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# CPU mechanism actually used.
cpu_mech="none"
[ "$cpu_count" -gt 0 ] && { [ -n "$stress_ng_bin" ] && cpu_mech="stress-ng" || cpu_mech="spinner"; }

# ── cgroup v2 CPU-quota probe (Linux envelope leg only; probe-gated) ───────────
# We only PROBE writability + record it; we do not create scopes here (that needs a
# usable systemd manager — see strategy §3). IO throttling is experimental: skipped.
cgroup_probe="not-requested"
if [ "${GCL_STRESS_CGROUP:-0}" = 1 ]; then
  cgroup_probe="unavailable"
  if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    if grep -qw cpu /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
      # cpu controller present at the v2 root; is a cpu.max writable in our subtree?
      if [ -w /sys/fs/cgroup/cgroup.subtree_control ] 2>/dev/null; then
        cgroup_probe="writable"   # the calibrated quota path is reachable on this leg
      else
        cgroup_probe="present-not-delegated"
      fi
    else
      cgroup_probe="no-cpu-controller"
    fi
  else
    cgroup_probe="no-cgroup-v2"
  fi
fi

# ── Stressor scratch dir (same volume as the test scratch) ─────────────────────
hogdir="${TMPDIR:-/tmp}/gcl-stress.$$"
mkdir -p "$hogdir" 2>/dev/null || hogdir="."

# ── Spawn / teardown (track EXACT PIDs; kill only those) ───────────────────────
hogs=()

spawn_cpu() {
  local i
  if [ "$cpu_mech" = "stress-ng" ]; then
    # One stress-ng manager spawning $cpu_count workers; reap the manager's PID.
    "$stress_ng_bin" --cpu "$cpu_count" --cpu-load 100 >/dev/null 2>&1 &
    hogs+=("$!")
  else
    for ((i = 0; i < cpu_count; i++)); do
      bash -c 'while :; do :; done' &
      hogs+=("$!")
    done
  fi
}

spawn_disk() {
  local i
  for ((i = 0; i < disk_count; i++)); do
    bash -c '
      d="$1"; j=0
      while :; do
        f="$d/dh.$$.$((j % 24))"
        dd if=/dev/zero of="$f" bs=32k count=8 conv=fsync 2>/dev/null
        rm -f "$f"
        j=$((j + 1))
      done' _ "$hogdir" &
    hogs+=("$!")
  done
}

cleanup() {
  local p
  for p in "${hogs[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  # stress-ng forks workers under its manager; kill the worker group too (only the
  # manager PIDs we spawned are used as the group leader — never a name match).
  if [ "$cpu_mech" = "stress-ng" ]; then
    for p in "${hogs[@]:-}"; do
      [ -n "$p" ] && kill -- "-$p" 2>/dev/null   # negative PID = the manager's process group
    done
  fi
  rm -rf "$hogdir" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── Achieved-slowdown micro-benchmark (cheap fixed busy-loop, baseline vs loaded) ─
# A small fixed integer loop timed once unloaded (baseline) and once mid-load gives a
# coarse, reproducible "how much did this load slow a CPU-bound task" figure for the
# manifest. Pure bash, no deps. Only run when load is actually applied — on the
# none/pass-through path it would be pure overhead.
micro_bench() {
  local start end k=0
  start="$(date +%s%N 2>/dev/null || echo 0)"
  while [ "$k" -lt 50000 ]; do k=$((k + 1)); done
  end="$(date +%s%N 2>/dev/null || echo 0)"
  echo $(( (end - start) / 1000000 ))   # ms
}

# Will any stressors spawn? (kind selected AND a positive per-kind count.)
will_load="no"
case "$kind" in
  cpu)  [ "$cpu_count"  -gt 0 ] && will_load="yes" ;;
  disk) [ "$disk_count" -gt 0 ] && will_load="yes" ;;
  both) { [ "$cpu_count" -gt 0 ] || [ "$disk_count" -gt 0 ]; } && will_load="yes" ;;
esac

base_ms=0
loaded_ms=0
slowdown="1.00"
[ "$will_load" = yes ] && base_ms="$(micro_bench)"

# ── Apply load ─────────────────────────────────────────────────────────────────
case "$kind" in
  cpu)  spawn_cpu ;;
  disk) spawn_disk ;;
  both) spawn_cpu; spawn_disk ;;
  none) : ;;
  *) echo "with-load: unknown GCL_STRESS_KIND='$kind' — running with NO load" >&2; kind="none" ;;
esac

if [ "${#hogs[@]}" -gt 0 ] && [ "$base_ms" -gt 0 ]; then
  loaded_ms="$(micro_bench)"
  # slowdown = loaded/base to 2 dp, integer-only arithmetic. Pad the centi-value to
  # >=3 digits so the integer part is always whatever precedes the last 2 digits
  # (handles slowdown <1.00 from timing noise, e.g. 80 -> "0.80").
  centi="$(( loaded_ms * 100 / base_ms ))"
  while [ "${#centi}" -lt 3 ]; do centi="0$centi"; done
  slowdown="${centi%??}.${centi: -2}"
fi

# ── Write the load-manifest (best-effort; never fails the run) ──────────────────
write_manifest() {
  local dir
  dir="$(dirname "$manifest")"
  mkdir -p "$dir" 2>/dev/null || return 0
  # Hand-rolled JSON (no jq/python dependency on the runner). Escape the JSON-special
  # chars in string values: backslash, double-quote, and the control chars that the
  # wrapped command line can legitimately contain (newline/tab/CR) — a raw newline in
  # a value is invalid JSON. awk keeps this robust where sed's newline handling is not.
  esc() {
    printf '%s' "$1" | awk '
      BEGIN { ORS = "" }
      {
        if (NR > 1) printf "\\n"          # join input lines with an escaped newline
        gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
        print
      }'
  }
  {
    printf '{\n'
    printf '  "kind": "%s",\n'            "$(esc "$kind")"
    printf '  "ratio_R": %s,\n'          "$ratio"
    printf '  "ratio_max": %s,\n'        "$ratio_max"
    printf '  "raw_load_override": "%s",\n' "$(esc "${raw_load:-}")"
    printf '  "nproc": %s,\n'            "$nproc_count"
    printf '  "cpu_stressors": %s,\n'    "$cpu_count"
    printf '  "disk_stressors": %s,\n'   "$disk_count"
    printf '  "total_stressors": %s,\n'  "${#hogs[@]}"
    printf '  "ratio_total_capped": "%s",\n' "$capped"
    printf '  "cpu_mechanism": "%s",\n'  "$(esc "$cpu_mech")"
    printf '  "cgroup_cpu_probe": "%s",\n' "$(esc "$cgroup_probe")"
    printf '  "baseline_ms": %s,\n'      "$base_ms"
    printf '  "loaded_ms": %s,\n'        "$loaded_ms"
    printf '  "achieved_slowdown": %s,\n' "$slowdown"
    printf '  "stress_ng_version": "%s",\n' "$(esc "$stress_ng_ver")"
    printf '  "bash_version": "%s",\n'   "$(esc "$bash_ver")"
    printf '  "os_arch": "%s",\n'        "$(esc "$os_uname")"
    printf '  "git_sha": "%s",\n'        "$(esc "$git_sha")"
    printf '  "command": "%s"\n'         "$(esc "$*")"
    printf '}\n'
  } > "$manifest" 2>/dev/null || true
}
write_manifest "$@"

echo "stress: kind=$kind R=$ratio nproc=$nproc_count cpu=$cpu_count disk=$disk_count" \
     "mech=$cpu_mech capped=$capped slowdown=${slowdown}x manifest=$manifest :: $*"

# ── Run the wrapped command, tear down, propagate its exit code ─────────────────
"$@"
rc=$?

cleanup
hogs=()
echo "stress: hogs reaped; wrapped command rc=$rc"
exit "$rc"
