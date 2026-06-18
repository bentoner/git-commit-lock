# git-commit-lock: CI & load-testing strategy

This is the rationale for *why the CI is shaped the way it is* — the principles
behind the three workflows (`tests.yml`, `nightly.yml`, `deep-sweep.yml`), the load
wrapper (`tests/with-load.sh`), and the two test-level levers (the Axis-A sweep and
the envelope tier). It describes the system as it stands; for the correctness
guarantees the suites assert against, see `docs/guarantees.md` and
`docs/failure-modes.md`.

---

## 1. The principle: correctness is load-independent

This is not a throughput-bound system whose correctness degrades under load. Safety
and exclusion rest on structural primitives — `O_EXCL` create, atomic `rename(2)`,
per-attempt token discovery — that never consult the clock for a *correctness*
decision (`guarantees.md` §2A, BE-1; `failure-modes.md` §K). No amount of CPU or IO
pressure makes a rename non-atomic or lets two `O_EXCL` creates both win on a local
filesystem.

So load does not *change what is correct* — it only *surfaces races*. Its sole job
is to widen the timing windows in the protocol's multi-syscall sequences (which are
not individually atomic) so that the inter-process interleavings the code claims to
handle are actually exercised. The right question to ask of a load regime is "does
this raise the probability that process A is suspended between syscall N and N+1
while process B advances?" — not "does it consume the box?". Past roughly 2× CPU
oversubscription, more load finds no new correctness bugs; it only stretches
wall-clock latency and starts tripping the suite's best-effort timing assertions.

Two consequences shape the whole design:

- **The per-PR gate runs no load** (strict, fast). A red required check is then
  always actionable — a real correctness bug or genuine infra drift, never a
  stress-manufactured wall-clock flake.
- **Load lives in non-blocking tiers** (nightly, deep-sweep), where the
  load-sensitive timing assertions are relaxed to warnings so an oversubscribed
  runner cannot turn a latency stretch into a red.

## 2. Deterministic steering is the primary race-coverage lever

The protocol's genuinely dangerous windows — create → read-back verify; the claim
recheck → touch → re-verify → rename residual; rename-over → read-back on a steal;
the release boundary — are ones where a *wrong interleaving could actually corrupt
state*. External load can only reach those windows *probabilistically*: it raises
the background chance of hitting an interleaving nobody scripted.

The suite reaches them *deterministically* instead, by in-process function
interposition. `clone_fn` (`tests/_harness.sh`) clones a library internal (or
shadows a command like `mv`/`rm`/`touch` with a shell function) so a steering test
can land "the rival's rename" at an exact protocol position, then call the original
through the clone (the Test 23–36 steered scenarios in
`tests/git-commit-lock.test.sh`). This hits the exact protocol window every run,
attributably — which is why it, not external load, is the primary race-coverage
investment.

External load is the secondary, broad-net lever. It earns its place mainly on the
one window it can genuinely move: the mtime-staleness / fail-open boundary, where
CPU/IO pressure stretches a contended holder past the STALE threshold and exercises
the detected-98 lane. A corollary for triage: because external load *cannot* break
correctness, a load run that produces a *correctness* failure is surfacing either a
real logic bug in a steering-reachable window (high value) or a test-harness setup
race (a harness fix, not a code fix).

## 3. The three tiers

### Tier R — required, per-PR (`tests.yml`)

The blocking gate. It runs every suite (unit, interop, integration, and the
full-width concurrency canary as its own parallel cell) at full fan-out
(`GCL_TEST_FULL=1`) with **no load** and the **strict** envelope tier (the default —
the workflow sets no `GCL_ENVELOPE_TIER`, so every timing assertion is hard). The
matrix is:

| Cell | OS | Engines / leg | Buys |
|---|---|---|---|
| ubuntu-24.04 `all` + `canary` | Linux | bash + pwsh7 | Linux correctness + interop baseline |
| macos-15 `all` + `canary` | macOS | bash + pwsh7 | BSD `stat`/`mv` lanes |
| windows-2025 `unit` | Windows | bash (MINGW) | delete-pending ghosts, FILETIME floor |
| windows-2025 `interop-integration` | Windows | bash + pwsh7 + **PowerShell 5.1** | the 5.1 non-atomic-fallback path + real NTFS commit swarm |
| windows-2025 `canary` | Windows | bash (MINGW) | full-width concurrency under process-spawn overhead |

The canary runs as a separate parallel cell on every arch because it is about half
the Windows unit wall-clock; suites must *not* run concurrently inside one runner
(they are timing-sensitive on 2-core runners). Triggers: `pull_request` and
`push: main` (both `paths-ignore` docs/`.plans`/license), a weekly `schedule` to
catch runner-image and tool drift, and `workflow_dispatch`. The concurrency group is
`${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`, so rapid
pushes coalesce. A separate `lint` job gates shellcheck (pinned v0.11.0, `-S style`)
and PSScriptAnalyzer (warning severity).

### Tier N — nightly, scheduled (`nightly.yml`)

A non-blocking scheduled stress run (08:23 UTC daily, plus `workflow_dispatch`).
This project has **no branch protection** (single-dev, decision 2026-06-18), so
nightly never gates a PR; its job is to catch the load-sensitive flakes and coverage
regressions the no-load per-PR gate cannot.

Six `stress` cells run the suites wrapped in `tests/with-load.sh` at one
oversubscription level (`GCL_STRESS_RATIO=2`, R≈2), one `GCL_STRESS_KIND` each:
ubuntu×{cpu, disk, both}, macos×disk, windows interop-integration×disk, windows
unit×both. macOS gets a single cell (it is the scarce, slow pool); ubuntu absorbs
the extra kinds (cheapest). The whole workflow runs with two test-level levers
turned on (§4): `GCL_ENVELOPE_TIER=relax` (the three load-sensitive timing
assertions warn instead of failing; correctness assertions stay hard) and
`GCL_TEST_SWEEP=1` (the Axis-A waiter-count sweep). Each cell writes its own
`cell-conclusion.txt` (ground truth, captured under `always()`) and uploads its logs
plus the load-manifest on success too — the negatives are needed to read the
positives.

A separate `kcov` job runs the unit + canary suites under kcov v43 (built from
source) on Linux, **no load, strict envelope, full fan-out**, and gates line
coverage of `git-commit-lock.sh` at a 0.80 floor (tracks ~0.83 achieved; ratchets up
as tests land). It explicitly overrides the workflow-level `relax` back to `strict`
so coverage is measured on a clean run.

A `triage` job (`always()`) downloads every cell's artifact and classifies each into
one labelled issue per (date, class): `nightly-correctness` (a correctness assertion
failed — investigate), `nightly-envelope` (a relaxed timing miss — expected,
tracked), or `nightly-infra` (missing artifact / timeout / errored — not a product
failure). An empty-round guard prevents "0 FAIL across 0 logs" being misread as
green when an artifact set is entirely missing.

### Tier D — on-demand deep sweep (`deep-sweep.yml`)

`workflow_dispatch`-only; it never runs on push/PR and never gates anything. This is
the deep flake-hunting instrument — the "50-clean hunt". A dispatch picks a
`stress_kind`, an optional raw `stress_load` override, a `repeat` count, and an
`envelope_tier` (defaults `relax`). Each suite is run `repeat` times under load in a
fail-fast loop that names the failing iteration. The concurrency group is per-run
(`deep-${{ github.run_id }}`) so many parallel dispatches fan out freely and accept
queue waves rather than cancelling each other. Timeouts are deliberately generous
(deep + loaded + repeated is far slower than the gate).

## 4. The two test-level levers

These let the existing tests yield more under load without touching the per-PR
gate's behaviour.

**The Axis-A waiter-count sweep** (`GCL_TEST_SWEEP`, `T_AXIS_A` in
`tests/_harness.sh`). By default `T_AXIS_A="4"`, so per-PR and plain dev runs are
byte-identical to the historical behaviour. Under `GCL_TEST_SWEEP=1` (nightly and
deep only) it becomes `"4 12 24"`, and the fan-out/contention tests iterate over it —
unit Test 2b, unit Test 20 (which composes its own list from its mode-driven floor
plus the sweep's higher counts), and interop Test 16 — each naming N in every
assertion message so a sweep failure says which N broke. This widens the
thundering-herd / claim-serialization and displacement windows that re-running N=4
never will. Correctness assertions are kept config-independent (e.g. hold ≫ STALE so
"zero-98 / one-steal" stays a pure correctness statement) and MAX_WAIT scales with N,
so a large-N run doesn't time out and *look* like a product failure.

**The envelope tier** (`GCL_ENVELOPE_TIER`, default `strict`, in
`tests/git-commit-lock.test.sh`). A wall-clock or poll-count bound is a best-effort
liveness property (`guarantees.md` BE-1), not a correctness one. The `ok_envelope` /
`bad_envelope` assertion helpers behave exactly like the hard `ok`/`bad` under
`strict`; under `relax` a `bad_envelope` becomes a `WARN` that does not increment
FAIL. Three assertions are tiered this way — recovery latency ≤20s (Test 21), the
claim-path config warning firing (Test 22a), and the failed-steal's claim being
re-created rather than left to age out (Test 29). Nightly and deep set `relax`;
per-PR and the kcov job never do. So an oversubscribed runner can stretch wall-clock
to a warning without reddening correctness, while correctness assertions stay hard in
both tiers.

## 5. How load is calibrated (`tests/with-load.sh`)

The wrapper runs a command under a calibrated, reproducible background load, then
tears it down by *exact spawned PIDs* (never by name — safe on a shared box and on an
ephemeral runner) and propagates the wrapped command's exit code.

- **Load is an oversubscription ratio**, not an absolute hog count:
  `GCL_STRESS_RATIO` (R, default 1) gives stressors-per-kind = `round(R × nproc)`,
  floored at 1 for a selected kind. "R=2" means the same pressure on a 2-core and a
  32-core runner, where a raw hog count would not.
- **The total ratio is capped** by `GCL_STRESS_RATIO_MAX` (default 2). `both` runs
  cpu + disk, so its total would be 2R; the cap scales each kind down proportionally
  so the runner is never wedged. The deep-sweep flake hunt can raise it deliberately.
- **`GCL_STRESS_KIND`** selects `none` (clean pass-through, zero added load),
  `cpu`, `disk`, or `both`. **`GCL_STRESS_LOAD`** is a back-compat raw per-kind
  count override (kept so the deep-sweep `stress_load` input keeps working); empty
  ⇒ use the ratio.
- **CPU stressor:** `stress-ng --cpu` when available (calibrated, measurable), else a
  portable bash spin loop. **Disk stressor:** a tight create / write+fsync / delete
  loop over a small file on the test scratch volume — real metadata + write-back
  pressure that contends with the lock-file create/delete the suite itself does
  (always the portable shell hog; cross-platform, low-fidelity but real).
- **A per-run `load-manifest` JSON** is written next to the suite logs (on success
  too): `{kind, R, ratio_max, raw-load override, nproc, cpu/disk/total stressor
  counts, capped?, cpu mechanism, cgroup probe, baseline/loaded ms, achieved
  slowdown, tool versions, os/arch, git sha, command}`, so any flake is reproducible.
  A cheap fixed bash micro-benchmark, timed unloaded then mid-load, records a coarse
  achieved-slowdown figure (only when load is actually applied).

### Platform asymmetry (current operating facts)

The platforms diverge too much for a uniform calibrated injection layer, so the
wrapper is honest about which regime ran:

- Deterministic steering is portable (bash everywhere; pwsh equivalent) — the real
  race-coverage tool, on every leg.
- Calibrated CPU throttling via a cgroup v2 quota is **Linux-only and probe-gated**:
  `GCL_STRESS_CGROUP=1` makes the wrapper *probe* for a writable cgroup v2 cpu
  controller and record the result in the manifest (`writable` /
  `present-not-delegated` / `no-cpu-controller` / `no-cgroup-v2`); it does not create
  scopes here (that needs a usable systemd manager). IO cgroup throttling is
  experimental and intentionally not attempted.
- Everywhere else (macOS, Windows) load is blunt CPU/disk oversubscription —
  uncalibrated but real pressure.

## 6. GitHub Actions operating facts

- **Minutes are free on public repos; concurrency is the real ceiling.** Free-plan
  accounts cap concurrent jobs (~20 total, with a smaller macOS sub-limit). A matrix
  past that *queues* into waves, it doesn't fail. The required gate stays small
  enough to run in one wave; the deep sweep intentionally exceeds it and accepts
  waves. macOS is the slowest and scarcest pool, so it is kept sparse across all
  tiers; ubuntu (cheapest) is used liberally.
- **`fail-fast: false`** on every matrix — an OS-specific failure is exactly the
  signal we want, so the other legs finish.
- **`paths-ignore` and required checks:** `tests.yml` filters docs/`.plans`/license
  paths. A workflow whose jobs are *required* checks would leave those checks
  Pending (blocking merge) when skipped by a path filter — but this project has no
  branch protection, so the filter just saves runner minutes on doc-only pushes
  without that hazard.
- **Artifacts** are uploaded with `include-hidden-files: true` (the integration
  suite's key diagnostics — lock log, repo state — live under the scratch repo's
  `.git/`) and named uniquely per cell so parallel uploads never collide.
- All actions are SHA-pinned.

## 7. The discipline: required = always-meaningful-red

The invariant that ties it together: **required is always-meaningful-red; nightly is
triaged-amber-tolerant; deep is noise-by-design.** Keeping artificial load off the
required gate is what makes a red gate trustworthy; putting all load in non-blocking
tiers with the envelope assertions relaxed is what stops load from manufacturing
flakes that erode that trust. The required tier is never retry-masked — a retry that
hid a 1-in-20 real race would defeat the silent-loss class this tool exists to
prevent.
