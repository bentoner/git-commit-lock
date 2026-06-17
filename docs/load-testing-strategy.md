# Load & matrix testing strategy — recommendation

**Status: RECOMMENDATION for Ben's decision — not an implementation.** Produced by a
considered, first-principles process (three parallel research agents — load fidelity, CI
matrix, test parametrization — synthesized and cross-checked against the code), deliberately
**not anchored** on the current `tests/with-load.sh` approach (which was thrown together from a
few lines of discussion). It answers: are we injecting load the right way / of the right
kinds; how to use the free public GitHub runners for a load×config matrix; and how to get more
from the existing tests routinely — while staying **considered, not maximalist**.

Grounded in `docs/failure-modes.md` (esp. §K and the correctness-vs-liveness split) and the
product/test code. Where it cites a fact about GitHub Actions limits, treat the number as
"current as of writing, confirm against GitHub docs before relying on it."

---

## 0. Headline recommendations (skim)

1. **Reframe load's job.** Correctness here is *load-independent* (O_EXCL + atomic rename +
   per-attempt tokens never consult the clock for a correctness decision). So load can't break
   exclusion or cause a silent lost update. Load has exactly two jobs: **(J1)** perturb
   scheduling so the protocol's multi-syscall sequences get preempted at adversarial points
   (race-surfacing), and **(J2)** broaden configs to exercise different code paths. Load
   *magnitude* past ~2× CPU oversubscription mostly manufactures *harness wall-clock flakes*,
   not bugs.
2. **The biggest race-coverage lever is NOT external load — it's deterministic steering.** The
   genuinely dangerous windows are reachable *deterministically* only by the in-process
   function-interposition the suite already uses. Invest there first; external load is a
   secondary, probabilistic complement for the few windows it can actually move.
3. **Three-tier CI:** a **Required** per-PR gate with **no artificial load** (so a red gate
   always means a real correctness bug); a **Nightly** non-blocking tier that adds calibrated
   load × kind and the parametrization sweeps, with wall-clock assertions relaxed to warnings;
   and an on-demand **Deep sweep** (the current stress design) for the 50-clean hunt.
4. **Fix the injection: calibrate, target, record.** Express load as an *oversubscription
   ratio* relative to core count (not an absolute hog count); prefer calibrated mechanisms
   (`stress-ng`, Linux cgroup `cpu.max`/`io.max`) over free-running spinners; write a per-run
   load-manifest artifact so a flake is reproducible.
5. **Embrace platform asymmetry** instead of a uniform injection layer: steering everywhere
   (portable); calibrated latency on the Linux leg only; plain CPU oversubscription as the
   macOS/Windows fallback — and record per-leg which regime actually ran.
6. **Get more from existing tests** via a *bounded* parametrization of a named handful (waiter
   count, fail-open ratio, poll cadence) — with strict correctness assertions kept
   config-independent and wall-clock assertions moved to the envelope tier.

---

## 1. What load testing is FOR here (the reframe that drives everything)

This is **not** a throughput-bound system whose correctness degrades under load. Per
`failure-modes.md` §1/§K, safety/exclusion rest on structural primitives (atomic
create/rename, per-attempt-token discovery) that never reference the clock for a *correctness*
decision. No amount of CPU/IO pressure makes `rename(2)` non-atomic or lets two O_EXCL creates
both win on a local FS.

So load's honest purpose is narrow: **make the protocol's multi-syscall sequences (which are
not individually atomic) get preempted at adversarial points, so the inter-process
interleavings the code claims to handle are actually exercised** — plus widen the few
genuinely timing-derived decisions (mtime staleness, the FILETIME-zero floor, empty-read
retries). The right metric for a load regime is *"does it raise the probability that process A
is suspended between syscall N and N+1 while process B advances?"* — **not** *"does it consume
the box?"*

**Direct consequence (the most important single point):** beyond ~2× CPU oversubscription,
more load does not find new correctness bugs — it only stretches wall-clock latency and starts
blowing the suite's *Tier-2* wall-clock assertions (Test 21's ≤20s recovery, Test 22a's
warning timing, Test 29's poll-count), which `failure-modes.md` §K already identifies as
Tier-1-bound-on-a-Tier-2-quantity. The fix for those is to **scope the bound**, not pile on
load. This is why the strategy below puts load in non-blocking tiers and keeps the gate clean.

---

## 2. The biggest lever is deterministic steering, not load

The protocol's scary windows — and whether *external load* can even reach them:

| Window | Code | Reachable by external load? |
|---|---|---|
| create → read-back verify | `git-commit-lock.sh:1336-1357` | Only probabilistically (1 command-sub wide); deterministically via steering |
| **claim recheck → touch → re-verify → rename** (residual 1/2 — THE delicate path) | `:1092-1168` | Probabilistically via CPU preemption; deterministically only via steering |
| rename-over → read-back (steal install) | `:1168-1179` | Same — steering for determinism |
| **mtime staleness / fail-open boundary (B5)** | `:1408-1410`, `:928` | **Yes** — CPU/IO load stretches cadence and can push a contended holder past STALE → exercises the 98-detect lane. The most realistic "load surfaces a real lane" case. |
| two-poll wrong-type confirmation (ghosts) | `:1518-1567` | **Yes, but mostly the bad way** — oversubscription *starves* the poll headroom → manufactures the Test 22a-style flake rather than finding a bug |
| FILETIME-zero floor (Windows) | `:925`, `:1408` | **No** — a *create-churn* artifact, not load-driven |
| empty-read retry ladder (AV/create→write) | `:668-684` | Realistic trigger is Windows AV/filter-drivers, not synthetic load |

**Takeaway:** the windows where a *wrong interleaving could actually corrupt state*
(create→readback, claim→rename, rename→readback, release boundary) are reached *deterministically*
only by the in-process function-interposition steering the suite already does (`clone_fn`,
`tests/git-commit-lock.test.sh:127-136`). External load merely raises the background
probability of hitting an interleaving nobody scripted. **So the primary race-coverage
investment is MORE STEERED SCENARIOS** (portable, deterministic, attributable) — e.g. steered
cases that park the claimant between recheck and rename, and between touch and rename, firing a
clearer + rival. External load is a *secondary, probabilistic* complement, valuable mainly for
the staleness/fail-open boundary (B5) it can genuinely move.

A corollary for triage: because external load *cannot* break correctness, a load run that
produces a *correctness* failure is surfacing either (a) a real logic bug in a steering-only
window (high value) or (b) a *test-harness* setup race (`sync_waiting_fresh`/`backdate_ghost`
losing its race under load) — a harness fix, not a code fix. Prefer deterministic mechanisms so
an observed failure is *attributable*.

---

## 3. Fix the load injection: calibrate, target, record

**Critique of the current `tests/with-load.sh`** (N bare CPU spinners + N `dd … conv=fsync`
create/write/delete loops): it is a *reasonable background-jitter generator* and adequate for
"run the whole suite under generic pressure," but from first principles it is:
- **Uncalibrated / non-reproducible:** `LOAD=N` spinners produce wildly different real
  preemption pressure on a 2-core vs 4-core runner, so "we tested at load N" doesn't mean a
  fixed thing — violating the reproducible-experiments requirement.
- **Untargeted:** a box-wide hog perturbs *everyone uniformly* (including the rival you wanted
  to advance), so it adds jitter but doesn't *bias* the interleaving toward the adversarial
  order. The high-value windows need a *scalpel* (slow one syscall in one process), which it
  can't do.
- **Blind to two windows:** it can't widen the create→write gap (the lock create is one
  redirect, no fsync to delay) and can't *produce* the Windows delete-pending ghost (it churns
  unrelated files); its main effect on those is the *poll-starvation false-flake* direction.
- **Self-defeating at high N:** on a 2-core runner it pushes wall-clock far enough to blow the
  harness's own timeouts (the workflow already had to raise every step timeout 2–3×) — load
  manufacturing churn, not findings.

**Recommendations:**
- **Express load as an oversubscription ratio `R = stressors / nproc`** (e.g. R ∈ {0, 1, 2}),
  not an absolute hog count, so a level is runner-independent.
- **Prefer calibrated mechanisms:** `stress-ng --cpu $((R*nproc)) --cpu-load … --metrics`
  (defined, measurable) over bare spinners; on **Linux**, prefer **cgroup throttling**
  (`systemd-run --user --scope -p CPUQuota=…` / `io.max`) which gives *deterministic,
  reproducible* latency — the right tool for **envelope validation** (a 10% CPU quota means the
  same everywhere; "8 hogs" does not).
- **Record a per-run `load-manifest`** artifact next to the suite logs: `{kind, R, nproc,
  achieved-slowdown, tool versions, runner os/arch, git sha}`, uploaded on *success too* (you
  need the negatives to interpret the positives). Optionally probe achieved slowdown with a
  fixed micro-benchmark before/during load.
- **Cap routine load at ~2× oversubscription;** higher R only on the deep-sweep flake-hunt leg
  (whose *correctness* assertions stay strict but *wall-clock* assertions are relaxed).

---

## 4. Embrace platform asymmetry (don't build a uniform injection layer)

The platforms diverge too much for a "uniform" load layer (cgroups & FUSE are Linux-only;
macOS SIP blocks `DYLD_INSERT_LIBRARIES` on system binaries; Windows has neither). Don't fight
it — structure around it and **record which regime ran per leg**:

- **Deterministic steering** — *everywhere* (portable bash; pwsh equivalent). The real
  race-coverage tool.
- **Calibrated latency** (cgroup `cpu.max`/`io.max`; optionally `strace -e inject` to slow one
  syscall in one process; a FUSE fsync-delay shim only if window W7 is prioritized) — **Linux
  leg only**.
- **CPU oversubscription** (`stress-ng` or the bash-spinner fallback) — the **macOS/Windows**
  fallback, uncalibrated; document the asymmetry.

Low-yield, **avoid:** memory/swap pressure (trivial allocation surface; risks OOM-killing the
harness), raw disk-bandwidth saturation (doesn't touch metadata-op latency), de-prioritizing
the background hogs. `ulimit`/inode/FD exhaustion belong to the *fault-injection tests* (the
§4.5 work), not the timing-load regime.

---

## 5. The three-tier CI structure (the matrix)

The organizing recommendation. It maps directly onto the already-decided correctness/envelope
test split (D-c).

### Tier R — Required / per-PR (blocking) — KEEP the existing 4 cells, STRIP the load
| Cell | OS | Engines | Buys |
|---|---|---|---|
| R1 | ubuntu | bash + pwsh7 (all suites) | Linux correctness + interop baseline |
| R2 | macos | bash + pwsh7 (all suites) | BSD `stat`/`mv` lanes (D1/E3) — *only* place these run |
| R3 | windows (unit leg) | bash (MINGW) | delete-pending ghosts, FILETIME floor |
| R4 | windows (interop+integration leg) | bash + pwsh7 + **PowerShell 5.1** | the 5.1 non-atomic-fallback path (D1) + real NTFS commit swarm |

This is exactly today's matrix **minus the stress env**. Running it at **`none` load** means it
only ever asserts Tier-1 correctness — it *cannot* flake on a Tier-2 wall-clock bound, so **a
red required check always means a real bug.** Target < ~8 min. (Also: flip the concurrency group
back to `${{ github.workflow }}-${{ github.ref }}` + `cancel-in-progress: true` — the current
per-run-unique group is a *deep-sweep* setting, which is exactly why the stress branch is marked
"do NOT merge to main.")

### Tier N — Nightly / scheduled (non-blocking, triaged)
~6 cells adding load **kind** (cpu / disk / both) at **one** oversubscribed level (R≈2), plus
the §6 parametrization sweeps. Run with **`GCL_ENVELOPE_TIER=relax`** so the three known
load-sensitive assertions (Test 21 ≤20s, Test 22a warning, Test 29 poll-count) **downgrade to
warnings** while correctness assertions stay hard. Example cells: ubuntu×{disk, both, cpu},
macos×disk, windows×{disk on the interop+5.1 leg — highest-value, both on the unit leg}.
Auto-file a triaged issue on failure tagged `correctness` (investigate) vs `envelope-flake`
(expected). macOS gets one harsh cell only (it's the scarce/slow runner); ubuntu absorbs the
extra kinds (cheapest).

### Tier D — On-demand deep sweep (`workflow_dispatch`, never gates)
The current stress-branch design *is* this tier — keep its `stress_kind`/`stress_load` inputs
and per-run-unique concurrency (many parallel dispatches), add `repeat` (run a cell K times)
and `width` inputs. This is the "50-clean under both/8-hog" hunt: informational, time-boxed by
choice, never a contract.

**Why this is the linchpin:** keeping artificial load *off the required gate* is what makes the
gate trustworthy; putting all load in non-blocking tiers with the envelope assertions relaxed is
what stops load from manufacturing flakes that erode trust. The split needs a small product/test
change: a `GCL_ENVELOPE_TIER=relax` env that downgrades the wall-clock assertions — nightly/deep
set it, required never does.

---

## 6. Get more from existing tests: bounded parametrization

Today there are only two coarse knobs: `GCL_TEST_FULL` (global fan-out) and per-case
hard-coded `AGENT_LOCK_*` values (never swept). Add **one** mechanism — a per-axis sweep over a
**named handful** of tests (sum the axes, do **not** cross-product):

- **Axis A — waiter/stealer count (highest value):** T2b (frozen at 4), T20, interop T16. Sweep
  N ∈ {4, 12, 24}. Widens the thundering-herd/claim-serialization and displacement windows that
  re-running N=4 never will.
- **Axis B — fail-open ratio (hold ÷ STALE):** a parametrized T4b/T1 variant running hold ≪
  STALE / hold ≈ STALE / hold > STALE, asserting the *correct verdict per regime* (clean → 0
  steals; over → exactly one steal + a 98).
- **Axis C — poll cadence:** {fast 0.05, **default 2s**}. The shipped 2s default is currently
  never exercised under contention.
- **Axis D — CLAIM_STALE depth (lower value):** {2, 60} on T21.

**Do not sweep:** round count (keep as the nightly *soak* dial, not a coverage axis), MAX_WAIT
(timeout-only), the deterministic steered protocol tests (T23–T36 — re-running reruns the same
steered path), or the integration suite's worker count beyond FULL/REDUCED (it's strict in both
modes by design and wall-clock-bound by serialized commits).

**Flakiness discipline (critical):** keep correctness assertions **config-independent** — when
sweeping N, hold STALE ≫ hold so "zero-98 / one-steal" stays a pure correctness statement, and
**scale MAX_WAIT with N** (more waiters = more serialized turns) so a large-N run doesn't time
out and *look* like a product failure. Move wall-clock/poll-count assertions to the envelope
tier. Keep the existing `sync_waiting_fresh`/`backdate_ghost` scaffolding — at higher N it
matters more.

**Cadence:** per-PR runs the floor point of each axis (today's behavior, deterministic);
nightly runs the sweeps under a `GCL_TEST_SWEEP=1` gate. The sweep (per-suite fan-out/knobs) is
*orthogonal* to the OS/leg matrix — compose additively (per-PR = matrix × floor; nightly =
matrix × sweep), never multiply everything on every PR.

---

## 7. GitHub Actions realities (the real constraints — confirm against current docs)

- **Minutes are free on public repos, but concurrency is the real ceiling.** Free/public
  accounts cap concurrent jobs on the order of ~20 (with a much smaller macOS sub-limit). A
  matrix past that **queues** (serialises into waves), it doesn't fail. Design any single
  triggered workflow to ≤ ~15–20 jobs to run in one wave; the deep sweep intentionally exceeds
  this and accepts waves.
- **Runner scarcity ≠ billing:** even free, **macOS runners are scarce/slow (~10× cost-weight),
  windows ~2×, ubuntu 1×.** Be stingy with macOS cells, liberal with ubuntu.
- **`strategy.matrix`:** `fail-fast: false` (keep — an OS-specific failure is the signal);
  `max-parallel` on nightly/deep so a big sweep doesn't starve the required gate of runners;
  256-job hard cap per workflow (irrelevant at our scale).
- **Triggers:** required on `pull_request` + `push: main`; nightly on `schedule` (cron,
  off-peak minute) + `workflow_dispatch`; deep on `workflow_dispatch` only — heavy load never
  sits in a PR's critical path. Keep `paths-ignore` (`**.md`, `.plans/**`) on required.
  (Note: `schedule` triggers are auto-disabled after ~60 days of repo inactivity.)
- **Artifacts:** keep the existing `upload-artifact` (with `include-hidden-files` for the
  `.git/`-buried lock logs); name uniquely per (os, leg, kind, level) so parallel cells don't
  collide.

---

## 8. Considered, not maximalist — the decision rule

> **A cell enters the routine matrix (R or N) only if it can surface a bug class no other
> routine cell can. Otherwise it's a deep-sweep cell, or it doesn't exist.**

- Cap the routine matrix: **R ≤ 4, N ≤ ~8.** New routine cells must *displace* one, forcing the
  "does this find something the others can't?" question.
- **Earn the slot:** a config/cell graduates deep → nightly only after the deep sweep actually
  caught a distinct failure there (mirrors the project's own "tested edge cases earn confidence"
  philosophy). Demote a cell that's been green for ~60 days and whose window is a subset of
  another green cell's.
- Prefer *one* oversubscribed level over a level sweep; prefer *attributable* single-kind cells
  over `both`-only when you want to localise a flake.
- **Trustworthiness invariant:** required = always-meaningful-red; nightly = triaged-amber-
  tolerant; deep = noise-by-design. Don't retry-mask the required tier (a retry that hides a
  1-in-20 real race is exactly the silent-loss class this tool exists to prevent).

---

## 9. Open decisions for Ben (what to pick before Phase 2 plans the build)

1. **Nightly aggressiveness:** ~6 cells, cron daily vs weekly? (rec: ~6 cells, daily off-peak;
   start smaller and grow by the earn-the-slot rule.)
2. **Linux load mechanism:** adopt calibrated cgroup `cpu.max`/`io.max` throttling on the Linux
   leg (reproducible, the right envelope-validation tool) vs keep the simple wrapper but
   calibrate it by oversubscription ratio? (rec: cgroup on Linux for the envelope leg; keep a
   ratio-calibrated `stress-ng`/spinner as the cross-platform race-jitter lane.)
3. **`stress-ng` dependency:** add an install step (apt/brew) vs keep a pure bash spinner
   (zero-dep, uncalibrated)? (rec: `stress-ng` where available + spinner fallback on Windows.)
4. **Parametrization scope now:** Axis A (waiter count) only, or A+B+C? (rec: A first — highest
   value, lowest flake risk — then B, then C.)
5. **The envelope-tier switch** (`GCL_ENVELOPE_TIER=relax`): confirm this is how we implement the
   D-c correctness/envelope split (a small test-harness change downgrading the 3 wall-clock
   assertions to warnings under load). (rec: yes — it's the cleanest implementation of D-c.)
6. **Nightly triage channel:** auto-file/track issues on nightly failure, tagged correctness vs
   envelope? (rec: yes — otherwise scheduled-run reds are invisible.)

These choices feed **Phase 2** (the implementation plan). This doc is a recommendation only —
no code, no workflow changes, until you've decided.

---

## Appendix — provenance
Synthesized from three parallel first-principles research passes (load fidelity & injection
mechanisms; CI matrix on free public runners; existing-test parametrization), each grounded in
`git-commit-lock.sh`/`.ps1`, the three suites, `tests/with-load.sh`, `.github/workflows/tests.yml`,
and `docs/failure-modes.md`, and cross-checked against the code (one agent's claim that
`tests/with-load.sh` was absent was verified false — it exists and is tracked). Pending: a
foreign-model (Codex) review pass over the GitHub-Actions limit claims and the load-mechanism
portability claims before this is treated as settled.
