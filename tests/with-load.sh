#!/usr/bin/env bash
# STRESS-BRANCH ONLY — do NOT merge to main.
#
# Run "$@" while artificial CPU and/or disk load saturates the runner, to widen the
# timing windows that latency/race flakes depend on (e.g. Test 17d's churn "absent
# window" — driven by both CPU descheduling of the churner AND slow file create/delete
# IO). Hogs are reaped by their EXACT PIDs afterward (never by name), so this is safe on
# a shared machine; on an ephemeral CI runner it is doubly safe.
#
#   GCL_STRESS_KIND = none | cpu | disk | both   (default: both)
#   GCL_STRESS_LOAD = N hogs of EACH selected kind (default: detected core count)
#
# CPU hog  = a bare bash spin loop (one core each).
# Disk hog = a tight create / write+fsync / delete loop of a small file on the same
#            volume as the test's scratch dir (TMPDIR) — metadata + write-back pressure
#            that contends with the lock-file create/delete the suite itself does.
set -uo pipefail

kind="${GCL_STRESS_KIND:-both}"
cores="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
load="${GCL_STRESS_LOAD:-$cores}"
case "$load" in ''|*[!0-9]*) load="$cores" ;; esac   # guard non-numeric / empty

hogdir="${TMPDIR:-/tmp}/gcl-stress.$$"
mkdir -p "$hogdir" 2>/dev/null || hogdir="."

hogs=()
spawn_cpu() {
  local i
  for ((i = 0; i < load; i++)); do
    bash -c 'while :; do :; done' &
    hogs+=("$!")
  done
}
spawn_disk() {
  local i
  for ((i = 0; i < load; i++)); do
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
  rm -rf "$hogdir" 2>/dev/null
}
trap cleanup EXIT INT TERM

case "$kind" in
  cpu)  spawn_cpu ;;
  disk) spawn_disk ;;
  both) spawn_cpu; spawn_disk ;;
  none) : ;;
  *) echo "with-load: unknown GCL_STRESS_KIND='$kind' — running with NO load" >&2 ;;
esac
echo "stress: kind=$kind load=$load cores=$cores hogs=${#hogs[@]} :: $*"

"$@"
rc=$?

cleanup
hogs=()
echo "stress: hogs reaped; wrapped command rc=$rc"
exit "$rc"
