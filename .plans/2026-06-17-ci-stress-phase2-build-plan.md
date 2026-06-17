# Phase 2 plan: implement the guarantees-and-coverage build (Buckets 2/3/4/6/8)

Status: **PROPOSAL — Phase 2 of the [guarantees-and-coverage
plan](2026-06-17-ci-stress-guarantees-and-coverage-plan.md).** Awaiting Ben's
gate. No implementation (Phase 3) until approved.

## What this plans
The concrete build that follows from the (committed, queued) Phase 1 outputs:
- `docs/guarantees.md` — the normative contract (Phase 1a).
- `docs/steering-coverage.md` — the prioritized steering-coverage gap list (Phase 1c).
- `docs/failure-modes.md` §4 — the accepted scope decisions (incl. Ben's §4.5
  override to add fault-injection coverage).
- `docs/load-testing-strategy.md` §9 — accepted load/matrix recommendations.

It turns those into: new tests (Bucket 2 — the Tier-A steering + Tier-B
fault-injection gaps), documentation edits (Bucket 3), the correctness/envelope
test split (Bucket 4 / D-c, via `GCL_ENVELOPE_TIER=relax`), the CI matrix wiring
(Bucket 6), and harness ergonomics (Bucket 8). **Verification is CI-first** (the
new tests run across the matrix); local runs are allowed but the box lags under
heavy fan-out.

Each section gives per-item designs concrete enough for Phase 3 to implement
directly. Three sections (Bucket 2 Tier-B, Bucket 6, Bucket 8) are being
feasibility-validated by parallel design agents and are integrated below.

---

## Bucket 2A — Tier-A steering tests (portable, deterministic; the bulk of the value)

From `steering-coverage.md` §3 Tier A. All are new `clone_fn`/shadow tests in
`tests/git-commit-lock.test.sh` (unit suite), runnable on every CI leg — no
fault-injection fragility. The audit already established each steering technique;
line anchors are current-tree and may drift (re-locate at build).

| ID | Gap (location) | Steering mechanism | Asserts | Platform | Priority |
|---|---|---|---|---|---|
| **A1** | `CLAIM-ABORT (rename-refused)` — wrong-type object at the lock path mid-steal (`:1195-1202`) | `clone_fn _lock_verify_stale` (or shadow `mv`) to `mkdir` a directory onto `$AGENT_LOCK_PATH` immediately before the rename | `CLAIM-ABORT (rename-refused)` + "non-file at the lock path" log; claim deleted; discovery read; **no false hold**; ghost handled | all | **HIGH** — the only acquire/steal *verdict* branch with no test; its own log string |
| **A2** | step-3.3 pre-rename CLAIM-ABORT block (`:1151-1160`; kcov hits=0) | `_lock_verify_stale` shadow with a **call-counter**: pass on call 1 (step-2), flip to `not stale` (gone/wrongtype/fresh) on call 2 (step-3.3) | the step-3.3 abort reason-map fires; claim-delete + discovery + `return 1`; no false hold | all | **HIGH** — a whole unexercised abort lane |
| **A3** | `foreign` claim-recheck branch (`:1103-1106`; kcov hits=0) | shadow the claim read at recheck to return a *foreign* token (a clearer removed our claim, a rival re-claimed) | leave the foreign claim; discovery read; back off; no 98-on-mere-claim | all | MED-HIGH |
| **A4** | `exec`-bypass / §H4 no-silent-loss boundary (`lock_run` runs `"$@"` in the wrapper shell, `:1733`) | **(corrected, verified empirically)** the exec must run in the lock-holding shell: `run -- exec true` or sourced `lock_acquire; exec true` — **NOT** `run -- bash -c 'exec true'` (that execs a child, releases normally) | (a) benign: no `RELEASED` line / lock left held; (b) displaced (backdated lease + parked contender) + exec 0 → caller sees 0 with **no** 98 — pins `guarantees.md` OOS-5 | all (bash) | **HIGH** — the one silent-loss boundary |
| **A5** | forward clock-jump → premature steal of a live lock (§E2; `:928,1409`) | `clone_fn _lock_now` to return now+offset on the poll while the live holder's mtime stays current | the live lock is judged stale and stolen; the victim's release hits **98** (clock-driven analogue of Test 4b) | all | MED |
| **A6** | mtime-unreadable fail-safe (§E3; `:639-645`, consumed `:912-926`) | `clone_fn _lock_stat_mtime` (the **inner** stat probe at `:606`) to return empty on a *present* file — **NOT** `_lock_path_mtime`, which is the function that *emits* the warn-once (`:639-643`); shadowing it would defeat the assertion | warn-once "Staleness detection is BROKEN"; **no steal**; waiter → 97; (closes BE-3's "coverage planned") | all (bash; + ps1 parity if feasible) | MED |
| **A7** | malformed/unreadable content classification tails (`_lock_verify_stale` `:940-949`; in-acquire steal guard `:1429-1443`; claim-stale-check `:1240-1249`) | fabricate a line-1-whitespace file (non-empty blank line 1 = `#18`); shadow a read-fault (`#17`) | no steal; the right `not a lock/claim file` / `unreadable` warning; covers several sibling branches per test | all | LOW-MED (cheap, multi-branch) |
| **A8** | socket & device-node wrong-type arms (`:1474-1475` claim, `:1561-1562` lock; kcov-new) | bind a unix socket / reference a device node (`/dev/null`) at the path | refusal (never stolen/deleted); the `-S`/`-b`/`-c` arms execute | POSIX | LOW (cheap; sibling of tested guard) |
| **A9** | log rotation past 1 MB (`:558-559`; kcov-new) | pre-write a >1 MB `$AGENT_LOCK_LOG`, trigger a log call | truncate-restart (log shrinks; lock unaffected) | all | LOW (trivial, no injection) |
| **A10** | EXIT-trap no-hold arc-end (`:1009,1017-1018`; kcov hits=0) | a sourced `lock_acquire` that `exit`s while still *waiting* (no hold, no in-flight claim) | the no-hold cleanup/restore path runs (vs the TERM twin already tested) | all | LOW |
| **A11** | `mv -T` fallback forced on (`:969,976-977`) | pre-set `_LOCK_MVT=0` (or shadow the probe's `mv -T` to fail) in a sourced steering shell, then run a steal + a steal-into-a-directory | the BSD/macOS unlink+bare-`mv` lane + the `[ -d ]` last-instant guard execute on Linux/MINGW | all (forces the lane) | LOW-MED (closes an engine lane on the common leg) |

**Sequencing:** A1/A2/A4 first (high value, real verdict/abort/silent-loss lanes);
A3/A5/A6 next; A7-A11 as a cheap batch. Each is a self-contained unit test using
the existing fabricate + backdate + `clone_fn` idioms.

---

## Bucket 2B — Tier-B fault-injection tests (empirically feasibility-validated)

Each injection was prototyped against the real `git-commit-lock.sh` (Git Bash + WSL).
The §4.5 discipline applies: **ship only lanes that inject portably/deterministically;
flag the rest rather than ship a flake.** This **refines the original D-b** (which had
F3 in the first cut) based on the feasibility results.

| Lane | Injection | Asserts | Guard | Status |
|---|---|---|---|---|
| **F4 — unwritable lock dir → 97** | `chmod 0555` the lock dir; create fails O_EXCL every poll. Cap `MAX_WAIT=1-2`, `POLL=0.1`. | `rc==97`; command never ran (no marker); no lock created; log `WAITING` then `TIMEOUT after Ns` | **POSIX-only** (guard is **load-bearing**: `chmod 0555` is a *no-op for writes* on Git Bash/NTFS → would falsely pass rc=0; skip-with-note like Test 17's symlink branch) | **First cut.** Deterministic (5/5 rc=97 on WSL). The §F4 highest-value lane (most likely real misconfig). |
| **F2/J1 — failing log → lock works, write swallowed** | Point `AGENT_LOCK_LOG` at `<regular-file>/x.log` so every append fails **ENOTDIR** (portable; no chmod/perms). | `rc==0`; command ran (marker); lock cleaned up (gone); log **not written** (`[ ! -s "$LOG" ]` / uncreated). Covers F2 **and** J1 in one test. | **Portable — no guard.** | **First cut.** Deterministic, both platforms. **Caveat:** bash's redirection-open failure leaks to stderr (the `||true` is on the write, not the open) — do **not** assert clean stderr, and do **not** `grep RELEASED "$LOG"` (nothing is written). |
| **F1 — ENOSPC on create/write** | Real full FS only: `sudo mount -t tmpfs -o size=400k` + `dd` fill, point the lock there. | `rc==97`; command never ran; an **empty-orphan lock left behind** (create 0-byte, write failed — matches §F1) | **Linux-only AND needs root/sudo** | **Second cut — gated, or document-only.** Behavior validated end-to-end on WSL. **`ulimit -f 0` is a trap** — it raises SIGXFSZ (rc=153) killing the *wrapper*, not the create. **No portable injection.** |
| **F3 — FD / inode exhaustion** | (intended `ulimit -n` / small-inode FS) | (intended `rc==97`, create-fail→wait) | Linux-only; inode→root | **Document-only.** **Cannot inject deterministically:** the create uses **~1 FD**, so any `ulimit -n` low enough to fail *it* first starves bash's own startup (machine-/load-dependent harness corruption, not the lib's 97 lane). Inode exhaustion needs root. §F3 is already reasoned-correct (same shape as F1). |

**D-b tier split (refined by feasibility):**
- **First cut (implement now):** F4 (POSIX-guarded) + F2/J1 (portable). Both deterministic,
  single-shot (no fan-out), ~3-4 s total. These close the resource-lane coverage on every
  leg with zero flake risk.
- **Second cut:** F1 — **recommend** a Linux-only test gated behind both `uname`==Linux
  **and** a `sudo -n true` capability probe that **skips-with-note** when sudo is
  unavailable (never fails the suite), with `sudo umount` in cleanup (GitHub `ubuntu-*`
  runners have passwordless sudo). *Alternative:* document-only, since the behavior is
  validated. *(Decision point for Ben — see Open decisions.)*
- **Document-only:** F3 (and F1 if Ben prefers zero root in the suite). Note the validated
  behavior in `failure-modes.md` §F1/§F3 (the empty-orphan→97 path) rather than shipping a
  flaky/non-portable test. **This supersedes `steering-coverage.md` §3 B4's "portable POSIX"
  rating and the failure-modes §4.5/Q5 "`ulimit -n` for FDs" suggestion** — the empirical
  check shows the create needs ~1 FD, so no `ulimit -n` fails it without first starving
  bash's own startup (harness corruption). `steering-coverage.md` B4 is corrected to match.

**Implementation notes (match existing idioms):** use the `LOCK`/`LOG`/`AGENT_LOCK_*` env
vocabulary and the `rc=$?; [ "$rc" = 97 ] && ok … || bad …` + `grep -q "TIMEOUT after"`
pattern; mirror Test 17's `2> "$WORK/tNN.err"` capture and skip-with-note. **F4 cleanup is
load-bearing:** a `chmod 0555` dir blocks `rm -rf` of its *contents* — keep that lock dir
**empty** (nothing is created in it) so the suite's `cleanup()` `rm -rf "$WORK"` succeeds.
**F2 assertion polarity** is inverted: assert the log was **not** written; the lock-success
signal is `rc==0` + the command's marker + lock-file-gone, not a log line.

---

## Bucket 3 — Documentation edits (exact text)

Small, concrete edits surfacing the boundaries the analysis decided to document.

### C-envelope (§4.1) → `docs/git-commit-lock.md`
Add, near the staleness/clock discussion (after the "One caveat on the mtime
clock" block, ~`:283-293`), a short **operating-envelope** statement:
> **Correctness is load-independent; latency is not.** Exclusion, no-silent-loss,
> and eventual recovery rest on atomic create/rename + per-attempt tokens and hold
> under any load. The wall-clock bounds — recovery latency (≈ STALE + poll
> cadence), the `MAX_WAIT` timeout, and the ~1.3 s read-retry ladder — are
> best-effort and scale with scheduling: under CPU oversubscription or a slow FS
> they stretch, but the protocol still recovers and never loses an update.

### C-clock (§4.2) → `docs/git-commit-lock.md`
One sentence in the same caveat block:
> The tool assumes a **single time source** — single-host use (the common case,
> all contenders share one checkout hence one clock), or a shared FS with one
> server clock. A local clock jump is correctness-safe: a forward jump can make a
> live lock look stale and be prematurely stolen, but that degrades to the
> detected exit-98 lane, never a silent double-commit.

### C-netfs (§4.3) → `README.md`
The boundary is in the design doc (`git-commit-lock.md:122-126`) but not the
README, where operators look. Add to "How it works" (after the atomic-create
sentence, ~`README.md:57`):
> The protocol's correctness rests on these operations being atomic, which holds
> on local filesystems (ext4, APFS, NTFS, and kin) but **not** on network or
> sync-backed storage — NFS, SMB shares, Dropbox/OneDrive-synced directories —
> where exclusion may silently fail. Keep the repo (and so its `.git/`) on a local
> disk. (The default lock lives in `.git`, which almost always is.)

### C-mixedver (§I2) → `README.md`
The "upgrade both together" rule is design-doc-only (`git-commit-lock.md:251-256`).
Add to the two-implementations section (~`README.md:82-95`):
> **Upgrade both implementations together.** Older releases stole with an
> unserialized move-aside instead of the claim protocol, so the
> no-displacement-during-recovery guarantee holds only when every party in a tree
> runs a current version; a mixed-version tree degrades that prevention to
> detection (exit 98) and can leave `.dead.*` files current versions don't clean.

### C-misc (§4.6, optional) → `docs/git-commit-lock.md`
One line each (low priority): case-insensitive FS is a non-issue (the lock/claim
paths never collide under case folding); the mixed-version `.dead.*` litter note
cross-referenced.

---

## Bucket 4 — Correctness/envelope test split (D-c; `GCL_ENVELOPE_TIER=relax`)

D-c is implemented as a **tagged assertion downgrade**, not a physical file split
(a file split would duplicate Test 21/29's heavy `clone_fn` setup and break the
single-suite kcov measurement). Add an `ok`/`bad`-adjacent helper pair (in
`tests/_harness.sh` once Bucket 8 item 3 lands; inline in the unit suite until
then — same signature, so the later move is mechanical):

```bash
ENVELOPE_TIER="${GCL_ENVELOPE_TIER:-strict}"   # default strict; nightly/deep set relax
ENV_WARN=0
# TAP-aware (Bucket 8 item 1 lands FIRST, so TAPN/GCL_TAP already exist — review catch).
# An envelope PASS is a normal `ok`; an envelope FAIL is a hard `bad` in strict, but in
# relax it is a TAP-passing line with a `# env-relaxed` directive — it counts toward the
# 1..N plan and bumps ENV_WARN (for triage), and NEVER reds the run.
ok_envelope()  { PASS=$((PASS+1)); TAPN=$((TAPN+1)); echo "PASS[env]: $*"
                 [ "${GCL_TAP:-0}" = 1 ] && echo "ok $TAPN - $*"; return 0; }
bad_envelope() {
  if [ "$ENVELOPE_TIER" = relax ]; then
    ENV_WARN=$((ENV_WARN+1)); TAPN=$((TAPN+1)); echo "WARN[env-relaxed]: $*"
    [ "${GCL_TAP:-0}" = 1 ] && echo "ok $TAPN - $* # env-relaxed"
  else
    FAIL=$((FAIL+1)); TAPN=$((TAPN+1)); echo "FAIL: $*"
    [ "${GCL_TAP:-0}" = 1 ] && echo "not ok $TAPN - $*"
  fi; return 0; }
```

- **`ok`/`bad` = the strict-correctness tier** (always hard, both tiers);
  **`ok_envelope`/`bad_envelope` = the latency/envelope tier** (hard in `strict`,
  warn-only in `relax`). Exit code is driven by real `FAIL` only — `ENV_WARN` never
  reds a run; the summary prints the `ENV_WARN` count so it's visible.
- **The three (and only three) downgraded call sites** — swap `ok`/`bad` →
  `*_envelope` on the *wall-clock* assertion only; every neighbouring correctness
  assertion (rc=97, no-steal, dir-untouched, STOLE-BY-CLAIM, …) **keeps `ok`/`bad`**:
  - **Test 21** `:1144` — recovery latency `≤20s`.
  - **Test 22a** — downgrade ONLY the *warning-fired-at-all* assertion (`:1167`,
    `grep -q "is not a claim file"`, i.e. count `≥1`), which depends on two-poll-confirm
    headroom under load. Keep the warn-once **correctness** strict: **split** the current
    `n==1` check (`:1170`) into `n≥1` (→ `bad_envelope`, timing) **+** `n≤1` (→ `bad`,
    strict — the dedup property: never warns twice), and **guard** "names the type"
    (`:1168`) on a warning having fired (assert strictly only when `n≥1`). So a real
    warn-once regression (n≥2, or wrong type) stays a hard FAIL even under `relax`.
    (Mapping `:1167`/`:1168`/`:1170` verified against the current tree — a reviewer's
    alternate line numbers were a mislocation; re-confirm at build.) The never-steal /
    never-delete assertions (`:1171`/`:1172`) stay strict.
  - **Test 29** `:1531` — `≥2` CLAIM lines (poll-count).
- **Required CI sets `strict` (or leaves it unset)** — at zero artificial load the
  three pass comfortably, so the gate behavior is unchanged; **nightly/deep set
  `relax`** so an oversubscribed runner can't turn an envelope miss into a red.
- Anchors are current-tree; re-locate the three sites at build (each is the single
  `-le 20` / warning-count / `-ge 2` line).

---

## Bucket 6 — CI matrix wiring (the accepted load-strategy §9 decisions)

**Three-workflow structure** (revised after review — a `workflow_dispatch` run
publishes check contexts on the head SHA, so keeping Deep in `tests.yml` under shared
job names risks a failed Deep run gating a PR; separate files + a stable required
aggregator remove that risk *and* the event-conditional concurrency):
- **`tests.yml`** — Tier R (required): the 4-cell `test` matrix + `lint` + a single
  stable **`tests-passed` aggregator** (`needs: [test, lint]`, `if: always()`, succeeds
  iff every needed job *succeeded or was skipped*). **Branch protection requires ONLY
  `tests-passed`**, not the per-cell matrix contexts. Concurrency: `group: ${{
  github.workflow }}-${{ github.ref }}` + `cancel-in-progress`.
- **`nightly.yml`** — Tier N + the kcov job + triage (`issues: write`, `schedule`, its
  own `concurrency: nightly`).
- **`deep-sweep.yml`** — Tier D (`workflow_dispatch` only), with **distinct job names**
  (`deep-*`) so it never publishes the `tests-passed` context, and per-run-unique
  concurrency.
This also fixes the **`paths-ignore`-on-required gotcha** cleanly: path-filter the
expensive `test`/`lint` jobs (they *skip* on doc-only PRs) while `tests-passed` always
runs and reports green (its needs were skipped, not failed) — so a doc-only PR satisfies
the one required context without the expensive jobs running.

**Tier R — Required / per-PR (blocking), `tests.yml`.** The current 4 cells
unchanged (ubuntu all / macos all / windows unit / windows interop+integration),
**no load**, `GCL_ENVELOPE_TIER=strict` (default — the 3 wall-clock assertions pass
comfortably at zero load), `GCL_TEST_FULL=1`. Diff from today: **revert** the
per-run-unique concurrency group (`980856b`) → `group: ${{ github.workflow }}-${{
github.ref }}` + `cancel-in-progress`; **drop** the `GCL_STRESS_*` env + `with-load.sh`
wrap + raised timeouts from the required job (`b430d73`'s workflow half); restore the
original step/job timeouts. Target < ~8 min. A red here is therefore never a
stress-manufactured flake.

**Tier N — Nightly (non-blocking, triaged), new `nightly.yml`.** `schedule` (daily,
off-peak) + `workflow_dispatch`; one oversubscribed level **R≈2**;
`GCL_ENVELOPE_TIER=relax` + `GCL_TEST_SWEEP=1`; `concurrency: nightly` + cancel
(one run at a time). **6 explicit cells** (`matrix.include`): N1 ubuntu/cpu, N2
ubuntu/disk, N3 ubuntu/both, N4 macos/disk (the single harsh macOS cell — scarce/slow/
5-job sub-limit), N5 windows interop+integration/disk (highest-value: delete-pending
ghosts + 5.1 unlink-then-move under churn), N6 windows unit/both. 6 cells + kcov +
triage ≈ 8 jobs → one wave under the ~20/5 ceiling. Nightly steps keep the raised
timeouts (correct here).

**Tier D — Deep sweep (`deep-sweep.yml`, `workflow_dispatch` only, never gates).**
Inputs `stress_kind`/`stress_load`/**`repeat`**/`envelope_tier` (default relax). Its
jobs use **distinct names** (`deep-*`) so a failed dispatch never publishes the
`tests-passed` required context (the review catch), with per-run-unique concurrency
(`group: deep-${{ github.run_id }}`, `cancel-in-progress: false`) so many parallel
dispatches each run and accept queue waves. Living in its own file removes any need for
an event-conditional concurrency expression.

**Axis-A waiter-count sweep {4,12,24}** under `GCL_TEST_SWEEP=1` (nightly/deep only;
unset per-PR → today's floor `N=4`, deterministic). A `T_AXIS_A` list read at suite
top; each of **Test 2b / Test 20 / interop Test 16** loops `N` over it, naming `N` in
every message. Anti-flake discipline baked into the loop: keep correctness assertions
config-independent (hold `STALE ≫ hold` so "zero-98 / one-steal" holds at every N —
these stay `ok`/`bad` strict, *not* `_envelope`), and **scale `MAX_WAIT` with N** so a
large-N run doesn't time out and look like a product failure. Mechanism generalizes to
Axis B/C later (deferred per §9.4).

**kcov coverage job** (nightly.yml, Linux-only): build kcov v43 from source (no
apt/prebuilt), run the **unit suite at FULL, strict, no-load** (`--include-path=git-
commit-lock.sh`), upload HTML + cobertura (30-day retention), and gate on a
**conservative line-coverage floor of 0.80** (below the current 83.1%, above noise;
the Linux ceiling is ~94% because ~30 lines are platform-gated). **Ratchet the floor up
toward ~0.90 as Bucket-2 lands the Tier-A tests** — the floor tracks achieved coverage,
it doesn't lead it.

**Nightly issue auto-triage** (nightly.yml, `if: always()`, `issues: write`): parse the
preserved logs — `^FAIL:` and/or job `failure` → **correctness** (file/append a
labelled issue, investigate); no FAIL but `WARN[env-relaxed]` and job `success` →
**envelope-flake** (tracked, no action); timeout/checkout failure → **infra**.
Idempotent (search-then-append, one issue per (date, class); no all-green spam).
**Empty-round guard (learned-once):** every cell's artifact missing / workflow errored
before any suite ran is an **infra** failure — do NOT read "0 FAIL across 0 logs" as
green. Upload nightly logs on success too (need the negatives to read the positives).

**Load calibration** (`with-load.sh` graduates from scaffolding): express load as
oversubscription ratio `R = stressors/nproc` (cap `R_total`), prefer `stress-ng`
(Windows spinner fallback) and a **probe-gated** Linux cgroup CPU-quota path for the
calibrated envelope leg (IO throttling experimental — don't rely on it); emit a per-run
**load-manifest** artifact (`{kind, R, nproc, achieved-slowdown, tool versions, os/arch,
sha}`) uploaded on success too.

**What lands on `main` vs stays scaffolding (refines Bucket 5 / D-d):**
- **Graduate to `main`:** the calibrated `with-load.sh` (strip the do-not-merge banner;
  add ratio calibration + load-manifest); `ok_envelope`/`bad_envelope` + the 3
  reassigned assertions; `GCL_TEST_SWEEP` + Axis-A loop (default-off → per-PR identical
  to today); the new `nightly.yml`; the `tests.yml` event-conditional-concurrency edit +
  dispatch inputs. So `b430d73` is **not** wholly do-not-merge — its `with-load.sh`
  payload graduates; only its *required-job wiring* is dropped.
- **Revert / drop:** `980856b` (flat per-run-unique group); `b430d73`'s load-wrap +
  raised-timeouts **on the required job** (they move to nightly.yml).

**§7 GitHub-Actions gotchas the diff MUST honor:**
- **`paths-ignore` on a *required* check blocks doc-only PRs** (skipped workflow → checks
  Pending → merge blocked). **Fixed** by the `tests-passed` aggregator above: it is the
  sole required context and always runs (green when the path-filtered `test`/`lint` jobs
  skip), so doc-only PRs merge. Branch protection must require **`tests-passed`**, NOT the
  per-cell matrix contexts (else skipped cells sit Pending).
- **`max-parallel` is intra-matrix only** — bound Deep/Nightly with workflow-level
  `concurrency` groups (done), never `max-parallel`.
- **`schedule` auto-disables after ~60 days of repo inactivity** — note in `nightly.yml`;
  rely on `workflow_dispatch` to re-trigger. A successor should know an empty nightly
  history may mean "disabled," not "passing."
- **Artifact names** unique per `(os, leg, kind)`; keep `include-hidden-files: true`
  (the lock logs live under the scratch `.git/`). `fail-fast: false` stays (per-OS
  signal + triage needs every cell's verdict). 256-job cap irrelevant at this scale.

---

## Bucket 8 — Harness ergonomics (zero-dep; prototype-validated)

Tests are straight-line `echo "== Test N: … =="` blocks (no registry): **43** in the
unit suite (the "~36" figure was stale), 25 interop, 2+1 integration. Sequencing is
**TAP → selector → extract** (each its own commit).

**Item 1 — TAP + `1..N` plan line + the undercount fix (do FIRST, ~20 lines/suite).**
The bug: under `set -uo pipefail` (no `-e`), an early `exit`/crash terminates the
suite before the final `echo RESULT` + `[ "$FAIL" = 0 ]`, dropping later assertions
from the count — and a stray `exit 0` after a recorded FAIL exits **0 with no RESULT
line** (a *silent green*). Fix, three parts (all prototype-validated):
- Make `ok`/`bad` TAP-aware, gated by `GCL_TAP=1` (dev runs byte-unchanged): bump a
  running `TAPN` and emit `ok N - desc` / `not ok N - desc`; keep the `return 0` that
  the `A && ok || bad` idiom needs.
- Emit a **trailing `1..$TAPN`** plan line before the verdict — a consumer fails on a
  short count.
- A **"reached-the-end" sentinel**: `DONE=0` set to `1` as the last action before the
  verdict; a `finish` EXIT trap (wrapping the existing per-suite `cleanup`) that, if it
  fires with `DONE!=1`, prints `Bail out!` and **`exit 1`**. (Key validated detail: a
  bare trap *return* is ignored — the script keeps its pre-trap code — so the guard
  needs an explicit `exit 1`; this is what converts the silent early-`exit 0`-after-FAIL
  into a red.) No hand-maintained expected-count constant — the sentinel catches *any*
  premature termination with zero upkeep. Apply to all three suites.

**Item 2 — `GCL_TEST_ONLY=<regex>` selector (SECOND; 43 mechanical header rewrites).**
Wrap each block: `echo "== Test N: … =="` → `if section "Test N: …"; then … fi`, where
`section` echoes the header and returns success iff `GCL_TEST_ONLY` is unset or its
regex matches the label. **Care point:** a few blocks do trailing cleanup *after* the
last assertion before the next header — those lines must move *inside* the `fi`.
**Integration is EXCLUDED by design:** its Tests 1-3 share one repo + `ALL_IDS`
accumulator (Test 3 audits 1+2's output), so it is one indivisible scenario — it
must *note-and-ignore* `GCL_TEST_ONLY` (loud stderr note), never per-block select.
Unit first; interop the same treatment (lower priority). Anchoring tip for docs:
`'Test 2'` also matches `Test 2b/20/25` — use `'Test 2:'` / `'Test 2b'`. **Zero-match
guard (review catch):** `section` bumps a `SECTIONS_RUN` counter when it runs a block;
at the end, if `GCL_TEST_ONLY` is set and `SECTIONS_RUN==0`, fail loudly — a typo'd regex
must not report a vacuous `PASS=0 FAIL=0` green (same spirit as the undercount sentinel).

**Item 3 — extract `tests/_harness.sh` (LAST; pure dedup, largest diff).** Source one
shared file from each suite. Tier 1 (all three): the `PASS/FAIL/TAPN/DONE` inits +
`GCL_TAP`/`GCL_TEST_ONLY` reads, `ok`/`bad`, `section`, the `finish`/sentinel helper,
and the shared shellcheck disables. Tier 2 (unit+interop only — integration uses none):
`epoch_to_stamp`, `backdate`, `backdate_ghost`, `sync_waiting_fresh`, `fabricate_lock`,
`wait_for_grep`, `clone_fn` + its `export -f` line. Tier 3: keep **both** poll helpers
under their existing names/semantics (`wait_for_file` `$2`=seconds, interop's `wait_for`
`$2`=50ms-iterations) — do *not* unify signatures this pass (would touch every call site
on the most fragile timing axis). **Do NOT extract `cleanup`** — it closes over each
suite's `$WORK` and interop's body genuinely differs; the shared `finish` just calls the
suite-local `cleanup`. Do it last so the final TAP/selector code is extracted once.
Verify byte-identical behavior by diffing a FULL run's sorted `PASS:`/`FAIL:` set
before/after (CI or local).

Prototypes (gitignored, `.agent-testing/bucket8-proto/`) validate TAP emission, the
trailing plan, selector matching, TAP+selector composition, and the sentinel closing
the exact silent-green bug.

---

## Phasing for Phase 3 (the build)

Order chosen so cheap, enabling work lands first and each step is CI-verifiable:

1. **Bucket 8 items 1-2 first** (TAP + `GCL_TEST_ONLY`) — they make iterating on
   ~15 new tests far cheaper and give machine-readable CI output to read the new
   tests' results back from. (Per the harness design's safe-increment order.)
2. **Bucket 3 doc edits** — independent, low-risk, can land anytime; do early so
   the docs match the contract.
3. **Bucket 4 envelope switch** (`GCL_ENVELOPE_TIER`) — needed before the nightly
   CI tier and before scoping Test 21/22a/29.
4. **Bucket 2A steering tests** (A1/A2/A4 first, then the rest) — the coverage core.
5. **Bucket 2B fault-injection tests** (the feasible D-b first cut; flag/defer any
   non-portable lane).
6. **Bucket 8 item 3** (`_harness.sh` extraction) — after the new tests exist, so
   the shared helpers are settled.
7. **Bucket 6 CI matrix** — wire the three tiers + kcov leg + parametrization last,
   once the tests and the envelope switch exist for it to orchestrate.

Each step commits incrementally under the commit-lock; verification dispatches
`tests.yml` on `ci-stress`. **Build vs Workflow:** decide hand-run vs a Claude Code
Workflow once the final test count is known (plan D-e) — likely a Workflow for the
~15 steering tests (fan-out write + per-test CI verify).

## Logging / observability design (per engineering practices)
- **New tests** assert on the product's existing protocol log strings (the coverage
  proxy the audit used) — every new steering test greps a specific log line, so a
  silent behavior change is caught.
- **TAP output** (Bucket 8) makes each assertion's pass/fail individually visible in
  CI logs, and the `1..N` plan line makes a truncated run fail loudly (closing the
  silent-undercount gap).
- **The load-manifest artifact** (Bucket 6) records `{kind, R, nproc,
  achieved-slowdown, tool versions, runner os/arch, git sha}` per nightly/deep run,
  uploaded on success too, so any flake is reproducible (the reproducible-experiments
  requirement).
- **kcov coverage artifact** (Bucket 6) uploaded per Linux run; the gap list in
  `steering-coverage.md` is the baseline to diff against.
- **Nightly auto-triage** tags a failing scheduled run `correctness` (investigate)
  vs `envelope` (expected under load), so scheduled reds are visible, not silent.

## Open decisions for Ben
- **D-b tiering (confirm):** build all of Tier A (A1-A11) + the Tier-B first cut
  (F4, F2/J1) now? The original D-b's "second tier" items are all accounted for —
  E3 → **A6** (steering, not fault-injection), F2-audit #7 (rename-refused) → **A1**,
  #8 (Windows blocked-unlink) → **Tier C** (platform-only, verified on the Windows
  leg); only **F1/F3** are genuinely not portably injectable. (Recommend: yes — Tier A
  is all portable; defer only F1/F3.)
- **F1 (ENOSPC) — gated test vs document-only:** F1's behavior is validated but its
  injection needs Linux root (`mount`). Ship as a Linux-only test gated behind a
  `sudo -n` capability probe (skip-with-note elsewhere, `sudo umount` in cleanup), or
  document-only? (Recommend: the **gated test** — GitHub `ubuntu-*` runners have
  passwordless sudo so it actually runs there and skips cleanly everywhere else; falls
  back to document-only if you'd rather keep zero root in the suite.) **F3 is
  document-only either way** (no deterministic injection exists — the create needs ~1 FD).
- **Build mechanism (D-e):** hand-run Phase 3, or a Claude Code Workflow for the test
  fan-out? (Recommend: decide once the count is final — ~13 steering + 2-3 fault tests;
  lean Workflow for the steering batch, hand-run the CI/doc edits.)
- Anything else needing a call is surfaced inline in the integrated sections.

## Changelog (Phase 3 implementation)
- **Step 1 (commit `3789be9`) — Bucket 8 item 1 done.** TAP + `1..N` + the
  `DONE`/`finish` undercount sentinel in all three suites. Unit validated locally
  (220/220 REDUCED + matching plan line, exit 0, sentinel does not false-fire);
  interop/integration syntax-checked, full runs via CI.
- **Deviation — defer Bucket 8 item 2 (the `GCL_TEST_ONLY` selector).** Wrapping 43
  blocks in `if section …; then … fi` is a large, boundary-sensitive change whose only
  benefit is per-test iteration speed; for this batch the steering tests are validated
  by a full-suite run, so it doesn't justify front-loading its risk. Bundled with item 3
  (`_harness.sh` extraction — also a large harness change) into one validated
  harness-restructure step near the end. **Revised phasing: 8.1 → 3 → 4 → 2A → 2B →
  (8.2 + 8.3 together) → 6.**
