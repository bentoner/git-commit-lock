# Deterministic-steering coverage: audit and gap list

**Status: analysis / work-scoping.** This document maps the protocol's
race-critical windows and branches to their deterministic-steering tests (or
gaps), and scopes the test work that closes the gaps. It is the output of Phase
1c of the [guarantees-and-coverage plan](../.plans/2026-06-17-ci-stress-guarantees-and-coverage-plan.md)
(Bucket 7). Gap-*filling* is Phase 3 (bundled with the Bucket 2 fault-injection
tests); this doc decides *what* to fill and *how*.

**Why steering, not load.** As [`load-testing-strategy.md`](load-testing-strategy.md)
establishes, the protocol's correctness rests on structural properties (O_EXCL
create + atomic rename + per-attempt tokens), so the primary coverage lever is
**in-process function interposition** — the test suite's `clone_fn` mechanism
shadows internal `_lock_*` functions (and `mv`/`rm`/`touch`) to force an exact
interleaving deterministically. External load only *probabilistically* widens
the same windows. This audit therefore measures *steering* coverage, with an
objective `kcov` line-coverage pass as a cross-check.

---

## 1. Method and headline numbers

Three independent inputs, reconciled below:

1. **Manual window audit — acquire + steal paths.** Every branch/residual mapped
   to its steering test or a gap.
2. **Manual window audit — hold + release + discovery + staleness/mtime paths.**
3. **`kcov` objective line coverage** (the mechanical cross-check) — built from
   source (kcov v43; no apt package / prebuilt binary exists) and run on the unit
   suite at FULL fan-out under WSL Ubuntu-24.04. Artifacts (gitignored):
   `.agent-testing/kcov/` (`cobertura.xml`, merged unit+integration, line-by-line
   HTML). Repro commands in [§5](#5-kcov-reproduction).

**kcov result: 83.1% line coverage — 451 / 543 instrumented lines; 92 never
executed.** (kcov does not do real branch coverage on bash — its branch numbers
are trivially 1.0 and must be ignored.) The integration suite added **zero** lines
over the unit suite, so the unit suite is the comprehensive measurement.

Of the 92 uncovered lines:

- **~30 are platform-gated and *correctly* unreachable on Linux** — ~23 in the
  Windows no-delete-share handle lanes (an open handle blocking `unlink`/`rename`,
  which never happens on POSIX), plus 3 in the macOS/BSD `mv` fallback. These are
  covered on the **Windows** CI leg (interop Tests 13/31d/33c) and would need a
  **macOS/BSD** leg for the `mv` fallback. They are **not** Linux gaps. The
  practical Linux line-coverage ceiling is therefore ~94% ((543−30)/543), not
  100%.
- **~62 are Linux-reachable** — the real targets, prioritized in [§3](#3-the-gap-list-prioritized).

**The cross-check earned its place.** kcov objectively corrected **three
over-credits** in the manual audit — branches the manual reasoning inferred were
covered, but which `kcov` shows were never executed:

| Branch | Manual audit said | kcov (objective) | Reconciled |
|---|---|---|---|
| step-3.3 pre-rename CLAIM-ABORT block (`:1151-1160`) | covered via the step-2 / `deletion-gone` matrix positions | **hits=0** | **GAP** — the step-2 twin is steered, the near-identical step-3.3 twin is not |
| `foreign` claim-recheck branch (`:1103-1106`) | covered via Test 33b + the matrix | **hits=0** | **GAP** — only the `gone` recheck leg is steered |
| EXIT-trap no-hold arc-end (`:1009,1017-1018`) | transitively covered | **hits=0** | **GAP** — only the *signal* (TERM) no-hold twin is steered, not the EXIT-while-waiting one |

This is the value of a mechanical pass over correlated manual reasoning: trust the
instance, verify the output against the tool. Where this doc and a manual claim
disagree, **kcov's `hits=0` wins**.

(Line numbers below are anchors against the current `ci-stress` tree and may drift
a few lines; the manual audits re-located everything and found the
failure-modes.md anchors had moved ~9 lines.)

---

## 2. What is already well covered (for confidence)

The audit confirms the protocol's *delicate* paths are strongly steered, so the
gaps are at the edges, not the core:

- **The two read-back "twins"** are each independently steered with opposite
  claim-token gates: the create-path "I twin" (`acquire verification FAILED`,
  `:1354-1361`) by **Test 32**, and the steal-path "F2 twin" (`steal rename
  completed but read-back`, `:1171-1179`) by **Test 32b**.
- **The discovery rule** — the ownership-discovery read on every non-rename exit —
  by **Test 25**'s 7-position matrix (`step2-fresh`, `recheck-gone`, `touch-gone`,
  `lock-gone`, `contested`, `deletion-gone`, `source-gone`), each steering a rival
  install to an exact protocol point.
- **The two discovery routes** (direct `_lock_discover` vs the per-poll
  leaked-token-memory check) each independently steered (Test 25 vs Test 31b),
  with Test 31a deliberately accepting *either* route on the genuine scheduling
  race between them.
- **The claim re-verify / touch / lease-reset lane** (Tests 23/24/26/27), the
  leaked-claim family (Tests 31/35/36), the never-steal guards for dir/symlink/FIFO
  at both lock and claim paths (Tests 17/22), and the trap-time claim cleanup
  (Test 33).

---

## 3. The gap list, prioritized

Each gap: location, what it is, how to steer it, and a priority. "Portable
interposition" = a `clone_fn`/shadow test that runs on every OS (the cheapest,
most valuable kind). "Fault injection" = needs a real resource/IO failure. "Platform"
= only reachable / only meaningful on a specific OS leg.

### Tier A — Portable deterministic steering (do these first; no fault injection)

These are new `clone_fn`/shadow tests in the unit suite, runnable on every leg.

- **A1 — `CLAIM-ABORT (rename-refused)`: wrong-type object at the lock path
  mid-steal** (`:1195-1202`). *Headline gap.* The only acquire/steal **verdict**
  branch with no steering test, and it has its own log string. (This is the
  F2-audit #7 lane; the strategy doc's §2 reachability table missed it.) *Steer:*
  `clone_fn _lock_verify_stale` (or shadow `mv`) to `mkdir` a directory onto the
  lock path immediately before the rename; assert `rename-refused` + claim deleted
  + discovery + no false hold. **Highest value.**

- **A2 — step-3.3 pre-rename CLAIM-ABORT block** (`:1151-1160`; kcov-corrected
  over-credit). The `gone`/`wrongtype`/`fresh` reason map + claim-delete +
  discovery + `return 1`, near-identical to the step-2 block but separately
  reachable. *Steer:* a `_lock_verify_stale` shadow with a call-counter that flips
  to not-stale on the **second** call (step-3.3), the first call (step-2) passing.
  **High value** (a whole unexercised abort lane).

- **A3 — `foreign` claim-recheck branch** (`:1103-1106`; kcov-corrected
  over-credit). A clearer removed our claim and a rival re-claimed → leave it,
  discovery read, back off. *Steer:* shadow the claim read at recheck to return a
  foreign token. **Medium-high.**

- **A4 — `exec`-bypass of release / the §H4 no-silent-loss boundary** (`lock_run`
  runs the wrapped command vector in the wrapper shell, `:1733`). No test exercises
  the bash bypass; the ps1 `[Environment]::Exit()` twin *is* (interop Test 5).
  **Empirically verified (2026-06-17):** the bypass needs the exec to run in the
  **lock-holding shell itself** — `run -- exec true` (the wrapped command *is* an
  exec), or a sourced `lock_acquire; exec true` — **not** `run -- bash -c 'exec
  true'`, which execs a *child* and lets the wrapper release normally (so that
  recipe would silently pass without testing anything). *Steer, two parts:* (a)
  benign — `run -- exec true` (or sourced `lock_acquire; exec …`) and assert no
  `RELEASED` line / lock left held; (b) the silent-loss — backdate the lease + park
  a contender so the holder is *displaced*, then exec a 0-exit and assert the caller
  sees 0 with **no** 98 (pinning [`guarantees.md`](guarantees.md) OOS-5). **High
  value** — the one interleaving that can silently lose an update. *Note:* this
  corrected the original audit recipe, which used the non-bypassing `bash -c 'exec'`
  form — a foreign-model (Codex) review + a 4-line empirical check caught it; the
  manual audit and a same-model reviewer both had it wrong.

- **A5 — forward clock-jump → premature steal of a live lock** (§E2; age = now −
  mtime, `:928,1409`). Code-safe (degrades to the detected-98 lane) but untested.
  *Steer:* `clone_fn _lock_now` to return now+offset on the poll while the real
  holder's mtime stays current, forcing age ≥ STALE on a live lock; assert the
  victim's release hits 98 (a clock-driven analogue of Test 4b). **Medium.**

- **A6 — mtime-unreadable fail-safe** (§E3; `:639-645` warn, `:912-926` consume).
  Only a *negative* assertion exists (the warning must NOT fire under normal
  contention, Test 1). *Steer:* `clone_fn` the mtime helper (`_lock_path_mtime` /
  the `stat` shadow) to return empty on a present file; assert the warn-once fires,
  no steal occurs, and a waiter reaches 97. **Medium** (it is the clean reason
  recovery is Tier-1-*within-envelope*, so worth pinning).

- **A7 — malformed/unreadable content classification tails** (the `_lock_verify_stale`
  tail `:940-949`; the in-acquire steal content guard `:1429-1443`; the
  `_lock_claim_stale_check` content tail `:1240-1249`). The `tok.`-prefixed and
  empty-orphan lanes are covered; the **non-empty-blank-line-1** (`#18`),
  **unreadable-content steal-skip** (`#17`), and **vanished-mid-check** sibling
  branches are not. *Steer:* fabricate a line-1-whitespace file and a
  read-fault shadow; backdate; assert no-steal + the right warning. **Low-medium,
  cheap** (several branches per small test).

- **A8 — socket & device-node wrong-type arms** (`:1474-1475` claim path,
  `:1561-1562` lock path; kcov-new). The dir/symlink/FIFO arms are tested; the
  socket (`-S`) and device (`-b/-c`) arms are not. *Steer:* bind a unix socket /
  reference a device node (`/dev/null`) at the path; assert refusal. **Low, cheap**
  (sibling arms of a tested guard; both creatable on Linux).

- **A9 — log rotation past 1 MB** (`:558-559`; kcov-new). *Steer:* pre-write a
  >1 MB log, trigger a log call, assert truncate-restart. **Low, trivial** (no
  fault injection).

- **A10 — EXIT-trap no-hold arc-end** (`:1009,1017-1018`; kcov-corrected
  over-credit). EXIT while *waiting* without a hold or in-flight claim. *Steer:* a
  sourced `lock_acquire` that exits while still blocked; assert the no-hold
  cleanup/restore path runs. **Low.**

- **A11 — `mv -T` fallback forced on** (`:969,976-977`). Naturally hit only on
  BSD/macOS, but **made Linux-steerable** by forcing `_LOCK_MVT=0` (or shadowing
  the probe's `mv -T` to fail) in a sourced steering shell, then running a steal —
  and a steal-into-a-directory to hit the `[ -d ]` guard (dovetails with A1).
  **Low-medium** (closes a real engine lane on the common leg instead of waiting
  for a BSD runner).

### Tier B — Fault injection (real resource/IO failures; mostly POSIX-only)

These are the [`failure-modes.md`](failure-modes.md) §4.5 lanes (Ben's override to
add coverage) plus the read-fault siblings. They need a real failure, not
interposition; guard by platform and **flag any that can't be injected portably
rather than shipping a flake** (per the §4.5 decision).

- **B1 — Unwritable lock dir/parent → clean 97** (F4). `chmod` the dir.
  POSIX; the cheapest and highest-value fault-injection test. **High.**
- **B2 — Unwritable/failing log path → lock still works, log swallowed** (F2/J1).
  Bad/again-`chmod`'d log path. POSIX. **Medium-high.**
- **B3 — ENOSPC during claim/lock create+write** (F1; the create write-fail branch
  `#5` and the read-fault lanes `:848,871-873`). Small dedicated tmpfs/quota.
  Linux-friendliest; flag if not portable. **Medium.**
- **B4 — FD exhaustion via `ulimit -n`** (F3). Portable POSIX; inode exhaustion
  only if cleanly injectable. **Medium.**

### Tier C — Platform-only (verify off-Linux; not a Linux gap)

- **C1 — Windows no-delete-share handle lanes** (~23 lines: `:881-890,993,
  1639-1647,1700-1712`). Already covered by interop Tests 13/31d/33c on the Windows
  CI leg. *Action:* confirm the Windows leg's coverage exercises them (it does by
  construction); no Linux work. Consider a kcov-equivalent on Windows is
  impractical — rely on the explicit interop tests.
- **C2 — macOS/BSD `mv` fallback real path** (`:969,976-977`). A11 makes this
  Linux-steerable by forcing the probe off; a *genuine* BSD `mv` exercise needs a
  macOS leg. *Action:* prefer A11 (portable) and treat a macOS leg as optional
  per the load-strategy matrix.

### Tier D — Bounded residuals: document, don't test

Low-value, bounded, detected, or self-healing; the manual audits rate these
not worth a dedicated test. *Action:* ensure each is named in the code header /
`guarantees.md` as an accepted residual; fold into a broader test opportunistically
if cheap, but do not build bespoke tests.

- **D1 — residual-1** (verify→rename: our rename clobbers a freshly-created rival
  lock → victim detects 98). Detection is covered structurally; the specific
  interleaving is bounded + detected.
- **D2 — residual-3** (claimant suspended between touch and rename installs an
  aged-mtime lock). Bounded shortfall, self-healing; the *positive* lease-reset is
  covered (Test 26).
- **D3 — leaked-resolve rare arc-end legs** (`:755-758,1260-1262`) and the
  release boundary-re-read in isolation (`R2`). Reachable only with a non-empty
  leaked set; transitively exercised.

---

## 4. Scoping summary for Phase 2

- **Tier A (11 tests, portable interposition)** is the bulk of the value and the
  bulk of the work — all runnable on every CI leg, no fault-injection fragility.
  A1, A2, A4 are the high-value three (a real verdict branch, a whole unexercised
  abort lane, and the single silent-loss boundary). Bundle these into the unit
  suite alongside the Bucket-2 work.
- **Tier B (4 tests, fault injection)** is the failure-modes §4.5 set; platform-gate
  them and flag any non-portable lane in the Phase-2 plan rather than shipping a
  flake.
- **Tier C** is verification on the Windows leg (already covered) + an optional
  macOS leg; **Tier D** is documentation, not tests.
- **Expected effect:** closing Tier A + the Linux-injectable parts of Tier B should
  take Linux line coverage from 83.1% toward the ~94% platform ceiling; the
  remaining ~6% is the Windows/BSD platform-gated lanes covered on their own legs.
- **Harness ergonomics (Bucket 8)** pay off here: a `GCL_TEST_ONLY=<regex>`
  selector and TAP output make iterating on ~15 new steered tests far cheaper —
  schedule them before/with the test build.

---

## 5. kcov reproduction

For re-running the objective coverage measurement (per the reproducible-experiments
principle). All from Git Bash; `MSYS_NO_PATHCONV=1` stops Git Bash mangling a
leading `/tmp` arg into a Windows path before WSL sees it.

```bash
# Build kcov v43 (no apt package; upstream ships no prebuilt binary):
wsl.exe -d Ubuntu-24.04 -e bash -c 'sudo apt-get install -y cmake libdw-dev libelf-dev \
  binutils-dev libcurl4-openssl-dev zlib1g-dev libiberty-dev'
wsl.exe -d Ubuntu-24.04 -e bash -c '
  cd /tmp && curl -fsSL https://github.com/SimonKagstrom/kcov/archive/refs/tags/v43.tar.gz \
    | tar xz && mkdir kcov-build && cd kcov-build && cmake ../kcov-43 && make -j"$(nproc)"'

# Run the unit suite under kcov (FULL fan-out) and list never-executed lines:
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -e bash -c '
  cd /mnt/c/agent_data/commit-lock/worktrees/ci-stress &&
  GCL_TEST_FULL=1 /tmp/kcov-build/src/kcov --include-path=git-commit-lock.sh \
    /tmp/gcl-cov tests/git-commit-lock.test.sh'
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -e bash -c '
  F=/tmp/gcl-cov/git-commit-lock.test.sh.*/cobertura.xml;
  grep -oE "<line number=\"[0-9]+\" hits=\"[0-9]+\"/>" $F |
    sed -E "s/.*number=\"([0-9]+)\" hits=\"([0-9]+)\".*/\1 \2/" |
    awk "\$2==0 {print \$1}" | sort -n'
```

When the kcov pass becomes a permanent CI leg (Phase 3 / Bucket 7), it runs on the
Linux runner against the unit suite at FULL, and the platform-gated ~30 lines (§1)
are expected-uncovered there by design.
