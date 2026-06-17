#!/usr/bin/env bash
# nightly-triage.sh — classify a nightly stress run's results and file/append a
# single labelled GitHub issue per (date, class), idempotently.
#
# Invoked by the `triage` job in .github/workflows/nightly.yml AFTER it has
# downloaded every matrix cell's `test-output/` artifact (each into a directory
# named `nightly-logs-<cell-id>/`) and written the per-cell job conclusions to a
# JSON file. It reads only files on disk + `gh`; it makes no test decisions of its
# own beyond parsing the preserved logs.
#
# CLASSIFICATION (per the Bucket 6 spec):
#   correctness  — any `^FAIL:` line in a suite log, OR a cell job concluded
#                  `failure`. Files/append a `nightly-correctness` issue. The one
#                  class that demands investigation.
#   envelope     — no FAIL anywhere, but at least one `WARN[env-relaxed]` line in a
#                  log of a cell that *succeeded*. Tracked (`nightly-envelope`); the
#                  three wall-clock envelope assertions stretched under load — by
#                  design under GCL_ENVELOPE_TIER=relax — so NO investigation action.
#   infra        — a cell's artifact is missing, the cell job neither succeeded nor
#                  cleanly failed-on-an-assertion (timeout / cancelled / checkout
#                  failure / errored before any suite ran), OR — the EMPTY-ROUND
#                  GUARD — *no* cell produced any log at all. Filed `nightly-infra`.
#                  Crucially, "0 FAIL across 0 logs" is NEVER read as green: with no
#                  evidence we classify infra, not success.
#
# Idempotency: one open issue per (run-date, class). We search open issues by a
# stable title prefix + label; if one exists we append a comment, else we create.
# Re-running triage for the same date therefore appends rather than spamming.
#
# All-green (every cell success, no FAIL, no env warn, every artifact present) ⇒
# NO issue of any kind is filed.
#
# Inputs (environment):
#   ARTIFACTS_DIR   dir holding the downloaded per-cell artifact directories
#                   (default: ./artifacts). Each cell dir is `nightly-logs-<id>/`.
#   CONCLUSIONS     path to a JSON object { "<cell-id>": "<conclusion>", ... } of
#                   each matrix cell job's `result` (success|failure|cancelled|
#                   skipped). Read from `<cell-dir>/cell-conclusion.txt`, which each
#                   stress cell writes (always()) into its own artifact — so the
#                   conclusion is ground truth PER CELL, never a matrix aggregate.
#   EXPECTED_CELLS  space-separated list of cell ids that were supposed to run
#                   (default: the six N1..N6 ids). Lets the empty-round / missing-
#                   artifact guard know what to expect.
#   RUN_DATE        UTC date stamp for the issue title (default: today, UTC).
#   GITHUB_REPOSITORY / GH_TOKEN(GITHUB_TOKEN)  the usual `gh` env.
#   DRY_RUN=1       print the `gh` actions instead of running them (for local tests).
set -uo pipefail

ARTIFACTS_DIR="${ARTIFACTS_DIR:-./artifacts}"
EXPECTED_CELLS="${EXPECTED_CELLS:-N1 N2 N3 N4 N5 N6}"
RUN_DATE="${RUN_DATE:-$(date -u +%Y-%m-%d)}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s\n' "$*" >&2; }

# A cell's log directory and its suite logs (may be absent ⇒ infra).
cell_logdir() { printf '%s/nightly-logs-%s' "$ARTIFACTS_DIR" "$1"; }

# ── Read a cell's OWN recorded conclusion from its artifact (ground truth: each
#    stress cell writes job.status to cell-conclusion.txt under always()). Absent
#    file ⇒ `unknown` (handled like a missing artifact). ──────────────────────────
cell_conclusion() {
  local cell="$1" f val=""
  f="$(cell_logdir "$cell")/cell-conclusion.txt"
  if [ -f "$f" ]; then
    val="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  fi
  printf '%s' "${val:-unknown}"
}

# ── Classify each expected cell. Accumulate evidence lines per class. ───────────
correctness_evidence=""
envelope_evidence=""
infra_evidence=""

any_log_seen=0          # for the empty-round guard

for cell in $EXPECTED_CELLS; do
  dir="$(cell_logdir "$cell")"
  concl="$(cell_conclusion "$cell")"

  # Gather this cell's suite logs (unit/interop/integration *.log under the artifact).
  logs=()
  if [ -d "$dir" ]; then
    while IFS= read -r f; do logs+=("$f"); done \
      < <(find "$dir" -type f -name '*.log' 2>/dev/null)
  fi

  if [ "${#logs[@]}" -eq 0 ]; then
    # No artifact / no logs for an expected cell. Distinguish: a clean job that
    # somehow uploaded nothing is still suspect ⇒ infra (we cannot prove it green).
    infra_evidence+="- ${cell}: no logs found (artifact missing or empty; job conclusion='${concl}')"$'\n'
    log "[$cell] INFRA: no logs (conclusion=$concl)"
    continue
  fi
  any_log_seen=1

  # Scan the logs.
  cell_fail=0
  cell_envwarn=0
  fail_lines=""
  for f in "${logs[@]}"; do
    if grep -qE '^FAIL:' "$f" 2>/dev/null; then
      cell_fail=1
      # Keep up to 5 FAIL lines per log as evidence.
      fail_lines+="$(grep -nE '^FAIL:' "$f" 2>/dev/null | head -5 | sed "s#^#    ${f##*/}: #")"$'\n'
    fi
    if grep -qE 'WARN\[env-relaxed\]' "$f" 2>/dev/null; then
      cell_envwarn=1
    fi
  done

  if [ "$cell_fail" -eq 1 ] || [ "$concl" = "failure" ]; then
    correctness_evidence+="- ${cell}: job='${concl}'"
    [ "$cell_fail" -eq 1 ] && correctness_evidence+=", FAIL lines present:"$'\n'"${fail_lines}" || correctness_evidence+=" (job failed; no ^FAIL: in logs — see job log)"$'\n'
    log "[$cell] CORRECTNESS (cell_fail=$cell_fail conclusion=$concl)"
  elif [ "$concl" != "success" ]; then
    # Logs exist but the job did not cleanly succeed and there is no assertion FAIL:
    # timeout / cancelled / errored late ⇒ infra, not green.
    infra_evidence+="- ${cell}: logs present but job conclusion='${concl}' (timeout/cancel/late error)"$'\n'
    log "[$cell] INFRA (conclusion=$concl, no FAIL)"
  elif [ "$cell_envwarn" -eq 1 ]; then
    envelope_evidence+="- ${cell}: succeeded with WARN[env-relaxed] (envelope assertion(s) stretched under load — expected)"$'\n'
    log "[$cell] ENVELOPE (success + env-relaxed warn)"
  else
    log "[$cell] OK (success, no FAIL, no env warn)"
  fi
done

# ── EMPTY-ROUND GUARD: if not a single expected cell produced any log, the run
#    errored before any suite ran (checkout failure, total infra collapse). That is
#    INFRA, never green — do not let "0 FAIL across 0 logs" pass as success. ──────
if [ "$any_log_seen" -eq 0 ]; then
  empty_msg="EMPTY ROUND: none of the expected cells (${EXPECTED_CELLS}) produced any suite log. The workflow errored before any suite ran (checkout failure / total infra collapse) — this is NOT a passing nightly."
  infra_evidence="${empty_msg}"$'\n'"${infra_evidence}"
  log "EMPTY-ROUND GUARD fired: no logs from any cell."
fi

# ── File/append issues, idempotently, one per (date, class). ────────────────────
# Title prefix is stable per class+date so search-then-append is reliable.
file_issue() {  # $1=class-label  $2=title  $3=body
  local label="$1" title="$2" body="$3" existing=""

  if [ "$DRY_RUN" = 1 ]; then
    log "DRY_RUN: would search open issues label=$label title~='$title'"
    log "DRY_RUN: title='$title'"
    log "DRY_RUN: body:"; printf '%s\n' "$body" >&2
    return 0
  fi

  # Search OPEN issues with this label whose title exactly matches (idempotency key).
  # `gh issue list --search` uses GitHub search; we additionally filter the JSON by
  # exact title to avoid a substring collision.
  existing="$(gh issue list --state open --label "$label" \
                --search "$title in:title" --json number,title \
                --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null | head -1)"

  if [ -n "$existing" ]; then
    log "Appending to existing issue #$existing ($label)"
    if gh issue comment "$existing" --body "$body" >/dev/null; then
      log "Appended comment to #$existing"
    else
      log "WARN: failed to append to #$existing"
    fi
  else
    log "Creating new issue ($label): $title"
    if gh issue create --title "$title" --label "$label" --body "$body" >/dev/null; then
      log "Created issue ($label)"
    else
      log "WARN: failed to create issue ($label)"
    fi
  fi
}

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
filed=0

if [ -n "$correctness_evidence" ]; then
  body="Nightly stress run on **${RUN_DATE}** has CORRECTNESS failures (a \`FAIL:\` assertion and/or a cell job concluded \`failure\`). **Investigate.**

$correctness_evidence
Run: ${run_url}

(Auto-filed by nightly-triage.sh; idempotent per (date, class) — re-runs append.)"
  file_issue "nightly-correctness" "Nightly correctness failure — ${RUN_DATE}" "$body"
  filed=1
fi

if [ -n "$infra_evidence" ]; then
  body="Nightly stress run on **${RUN_DATE}** had INFRA issues (missing artifact / timeout / cancel / errored before suites ran). Not a product failure, but the run did not produce trustworthy results — re-dispatch or investigate the runner.

$infra_evidence
Run: ${run_url}

(Auto-filed by nightly-triage.sh; idempotent per (date, class).)"
  file_issue "nightly-infra" "Nightly infra issue — ${RUN_DATE}" "$body"
  filed=1
fi

# Envelope is filed ONLY when there is no correctness failure (a correctness issue
# subsumes it — under a red run the env warns are noise). Tracked, no action.
if [ -z "$correctness_evidence" ] && [ -n "$envelope_evidence" ]; then
  body="Nightly stress run on **${RUN_DATE}**: no correctness failures, but envelope (wall-clock) assertions were relaxed under load (\`WARN[env-relaxed]\`). This is EXPECTED under GCL_ENVELOPE_TIER=relax — tracked, **no investigation needed** unless it becomes persistent at low load.

$envelope_evidence
Run: ${run_url}

(Auto-filed by nightly-triage.sh; idempotent per (date, class).)"
  file_issue "nightly-envelope" "Nightly envelope warning — ${RUN_DATE}" "$body"
  filed=1
fi

if [ "$filed" -eq 0 ]; then
  log "ALL GREEN: every expected cell succeeded, no FAIL, no env warn, all artifacts present. No issue filed."
fi

# Triage itself succeeds whenever it ran to completion — it must not red the
# workflow for finding failures (those are surfaced as issues). It only fails if it
# could not run at all (handled by `set -uo pipefail` on a genuine scripting error).
exit 0
