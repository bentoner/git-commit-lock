## Review round 2 of the convergence loop, 2026-06-11 — CONVERGED

> Both round-2 reviewers returned **clean** verdicts. Claude: re-verified
> suite facts, lint gates (run locally, clean), bash-3.2 audit, budget
> arithmetic, and fetched the GitHub docs to confirm `matrix` context is
> valid in step-level `timeout-minutes` and that all five upload-artifact@v7
> inputs used are real; one leave-as-is NIT (the flakiness-policy
> GCL_TEST_FULL parenthetical reads as operative-today — true today via the
> default, no change made). Codex: "No findings. Clean verdict." Loop ends
> here by design: the remaining unknowns (macOS leg behaviour, real runner
> times) are exactly what the first CI run verifies more cheaply than
> further review rounds — see the Sequencing note's "that's the plan
> working, not failing".

## Review round 1 of the convergence loop, 2026-06-11 (fresh Claude + Codex)

> **Status: all findings folded same day (commit follows 39f71c2).** Claude:
> verdict clean — every load-bearing claim re-verified against the suites
> (counts 64/35/12 statically recounted, preserve semantics, lint gates
> actually run and clean, bash-3.2 grep audit, YAML dry-read); two
> non-blocking wording notes, both taken (GCL_TEST_FULL landing-order
> softened; TODO-main.md header counts annotated as of-that-wave). Codex: 4
> findings, all verified and taken — `upload-artifact` hides dotfiles by
> default, which would have dropped the integration suite's `.git/` lock-log
> diagnostics (`include-hidden-files: true` added); job-level timeout cancels
> rather than fails, so the upload guarantee moved to per-step
> `timeout-minutes` (job level is now a backstop only); action majors were
> stale (checkout v5→v6, upload-artifact v4→v7, verified against the releases
> pages 2026-06-11); GCL_TEST_FULL documented as an inert no-op until TODO 58
> lands.

## Review findings 2026-06-10 (post-wave consistency pass)

Fresh-context review against HEAD (e67f788), both suites' sources, TODO-main.md,
the lockfile plan, and the actions/runner-images repo (re-fetched today).

1. **BLOCKING — the unit-suite facts are stale vs the HEAD this plan was
   committed on.** Commit 840a4fd (2 minutes before this plan's reconciliation
   commit 6126cf6) raised the unit suite to **59** assertions (T8 net +1: the
   ungated STALE≥MAX_WAIT assertion became a gated negative+positive pair) and
   converted unit T4b and T8 from fixed sleeps to marker-polling. Three spots to
   fix: (a) "58 assertions across 17 tests" → 59 across 17; (b) the "fresh run
   of all three suites against HEAD … unit 56/58" predates 840a4fd — its T4b
   vacuous miss is the very flake 840a4fd fixed; post-fix runs recorded 59/59
   (840a4fd and e67f788 commit messages); (c) flakiness-policy item 2 still
   names **unit T4b** as a live "holds via a fixed sleep" margin item — it is
   already marker-polled; only interop T8a/T8b remain (consistent with TODO 55).
   No effect on the YAML, budgets, or design — but the plan's own "every fact
   re-verified against the current tree" claim is what these contradict.
   **ADDRESSED 2026-06-10 (final fix round):** all three spots fixed in the
   plan body below; counts updated again for the same round's test additions
   (unit 64 across 18, interop 35 across 12 — see Grounding).
2. **NOTE — cross-plan sequencing (neither plan mentions the other).** The
   lockfile plan (.plans/2026-06-10-main-lockfile-plan.md) rewrites the on-disk
   protocol this plan's grounding prose describes (dir-mtime stat branch, T3
   orphan, dir-era runtimes) and folds in the TODO 53–56 perf pass this plan's
   budgets defer to. No contradiction: the workflow YAML is protocol-agnostic
   (it only invokes the three suites + linters) and survives the lockfile change
   unedited. Recommended order: **this plan first** (matrix green on 3 OSes),
   then the lockfile port runs its Phase 3 gate under the matrix — its probes
   were Windows-only, so CI is exactly the verification it lacks. Add one
   sequencing sentence here; if the lockfile plan proceeds, the budget-revisit
   trigger ("after TODO 53–56 lands") arrives via that port.
   **ADDRESSED 2026-06-10 (final fix round):** sequencing sentence added to
   the Sequencing note below.
3. **NOTE — small double-claim on TODO 39.** This plan does the integration
   preserve-knob follow-up "before or with the workflow commit"; the lockfile
   plan's impact table lumps item 39 into its "mechanical port" row. Landing it
   here first is right; the lockfile row then goes moot (flagged there too).
   **ADDRESSED 2026-06-10 (final fix round):** the integration suite now
   honours `GCL_TEST_PRESERVE_DIR` and keeps its work dir on failure (unit
   suite semantics); TODO 39 / the lockfile row are moot.
4. **NOTE — the interop `touch -d` fix and the lockfile Phase 2 port touch the
   same lines.** The two GNU-only `touch -d "@epoch"` calls this plan flags
   (interop lines 160/184 — verified still present at HEAD) are the same
   fabrication sites the lockfile plan re-writes; whichever lands second must
   keep the portable `epoch_to_stamp`/`touch -t` pattern or macOS re-breaks.
   **ADDRESSED 2026-06-10 (final fix round):** both calls replaced with the
   unit suite's portable `epoch_to_stamp`/`backdate` helpers; the lockfile
   port (if it proceeds) must preserve that pattern.
5. **NOTE — Windows `GCL_TEST_PRESERVE_DIR` is a mixed-separator path**
   (`${{ github.workspace }}` renders `D:\a\…` and the YAML appends
   `/test-output/…`). MINGW coreutils accept Win32 paths in the suites'
   `mkdir -p`/`cp`, so expect-to-work — but the suites never `cd` in the main
   shell, so a workspace-relative value (`test-output/failed-work/unit`) dodges
   the seam entirely if it ever bites.
6. **NOTE — concurrency group shares the cron with pushes**: scheduled runs
   execute on `refs/heads/main`, so a weekly run colliding with an in-flight
   push run cancels it (or vice versa). Rare and harmless; key the group on
   `github.event_name` too if it ever annoys.

Verified clean (no findings needed): all runner-image claims re-confirmed
against actions/runner-images today — labels GA as stated; pwsh 7.4.16 on all
three images; ubuntu-24.04 bash 5.2.21 / git 2.54.0 / shellcheck 0.9.0-1 /
PSScriptAnalyzer 1.25.0 preinstalled; macos-15 bash 3.2.57; windows-2025 Git
for Windows 2.54.0 with Git Bash at `C:\Program Files\Git\bin\bash.exe`. Repo
facts re-confirmed: 96/97/98 contract, MAX_WAIT default 420, integration cap
240, T1 = 8×25, integration 12/11 assertions and unconditional cleanup trap,
unit/interop preserve semantics (contents-flat vs dir-itself), interop pwsh
skip-with-exit-0, ps1 SuppressMessageAttribute present, README portability
sentence and docs staleness paragraph as described, `.gitattributes` exists.
YAML dry-read: job-level `timeout-minutes` expressions have matrix context
(valid); `${{ !cancelled() }}` quoting fine; `bash -eo pipefail` propagates
`tee` pipeline failures; artifact names unique per leg (v4 requirement);
upload step's `cancelled()` runs on a timeout kill. Open-question
recommendations 1–7 all look sound.

---

# Plan: GitHub Actions CI for git-commit-lock

Date: 2026-06-10 · Branch: main · Status: **draft, awaiting Ben's review** (no
workflow implemented yet)

Reconciled 2026-06-10, post-fix-wave: the original draft predated the large fix
wave that landed the same day. Since then Phase 1's portability items have
landed (one exception, flagged below), a third test suite (end-to-end
integration) exists, the 96/97/98 exit-code contract replaced the old codes,
and lint baselines were taken (TODO items 48–49). Every fact below was
re-verified against the current tree — including a fresh run of all three
suites against HEAD; structure and design decisions are unchanged except where
marked.

Goal: a `.github/workflows/tests.yml` that runs all three test suites
(`git-commit-lock.test.sh`, `git-commit-lock.interop.test.sh`,
`git-commit-lock.integration.test.sh`) on Linux, macOS, and Windows on every
push/PR, plus a Linux-only lint job (shellcheck + PSScriptAnalyzer), ahead of
publishing the repo on GitHub. Ben explicitly asked for Linux and "can we get
mac that way too?" — yes: GitHub-hosted `macos-*` runners. Windows is included
because it's the tool's home turf (Git Bash + pwsh) and `windows-*` runners
ship both.

## Grounding: what the suites actually need (verified by reading + running)

- All three suites are self-contained bash scripts using throwaway temp dirs;
  exit 0 = pass. Current shape (assertion counts confirmed by running each
  suite against HEAD on 2026-06-10):
  - **Unit** (`git-commit-lock.test.sh`) — 64 assertions across 18 tests
    (59×17 after reconciliation commit 840a4fd; the 2026-06-10 final fix
    round added the missing-token unverifiable-release test and an
    age-gated-sweep assertion). Test 1 alone spawns ~200 short-lived `bash`
    lock invocations (8 rounds × 25 workers), plus per-test holders/waiters
    with real sleeps.
  - **Interop** (`git-commit-lock.interop.test.sh`) — 35 assertions across
    12 tests (30×10 at reconciliation; the final fix round added cross-impl
    missing-token and fractional-knob parity tests): 8 bash + 8 pwsh workers
    sharing one lock, ordering/steal tests, and the cross-impl exit-code
    contract. **Skips with exit 0 if `pwsh` is not on PATH** (header check),
    so it is safe to invoke unconditionally on every OS.
  - **Integration** (`git-commit-lock.integration.test.sh`) — 12 assertions
    (11 without pwsh); the end-to-end suite: 2 rounds × 12 concurrent bash
    workers plus one mixed round of 5 bash + 5 pwsh workers each make REAL
    `git add`/`git commit`s into one shared scratch repo via the documented
    `run` forms, then the resulting history is audited (every commit lands,
    linear history, no sweep-up, balanced lock log, clean tree, no leftover
    lock). Degrades cleanly without pwsh: the bash-only swarm still runs; only
    the mixed round skips. See [Integration test in CI](#integration-test-in-ci).
- The suites assert the documented exit-code contract — **96 usage / 97 lock
  timeout / 98 stolen mid-hold** (landed in the fix wave). Irrelevant to the
  YAML; noted so nobody reconciles this plan against the old pre-wave codes.
- Timing knobs: tests shrink windows via `AGENT_LOCK_STALE_SECS` /
  `AGENT_LOCK_POLL_SECS` / `AGENT_LOCK_MAX_WAIT` env vars. Defaults that matter
  for CI budgets: `AGENT_LOCK_MAX_WAIT=420s` — a single pathological hang (a
  regression where a waiter never sees staleness) costs up to **7 minutes**
  before the suite itself fails. (The integration suite caps its own workers at
  `AGENT_LOCK_MAX_WAIT=240`.)
- Measured 2026-06-10 on Ben's Windows box under HEAVY load (a second agent
  active; `sys` time ≈ 2× wall — treat as worst-case): unit **20m10s**,
  interop **3m01s**, integration **2m52s**. That run PREDATES commit 840a4fd:
  its unit 56/58 and interop 28/30 misses were the robbed-holder vacuous flake
  whose unit-side fixed sleep 840a4fd's marker conversion removed — post-fix
  runs record full unit passes (59/59 at 840a4fd/e67f788; 64/64 after the
  final fix round), with only interop T8a/T8b still on fixed sleeps (flakiness
  policy, item 2). Under normal load the same box recorded 67–85 s for the
  integration suite (its commit message) and 6m09s for the pre-expansion unit
  suite — so the 20 min is extreme load + suite growth, not the expected CI
  number. GitHub Linux runners spawn processes far faster; expect a few minutes
  total there, with Windows the slowest leg.
- **A queued performance pass will shrink these runtimes** (TODO items 53–56:
  lazy gitdir resolution — the biggest single win, ~2 `git rev-parse` forks per
  lock invocation × 200 invocations in unit Test 1 alone; bash-builtin hot-path
  replacements; fixed-sleep→marker-polling conversions; a `WAITING` log line).
  It is planned, not landed: the budgets below are sized for TODAY's suites —
  tighten them after that pass lands, not before.
- Failure diagnosability — **landed, all three suites** (was Phase 1 item 4):
  every suite now preserves its work dir on any failure (path printed) and
  copies all logs/outputs to `$GCL_TEST_PRESERVE_DIR` when it is set (the CI
  knob). The integration suite gained both in the 2026-06-10 final fix round
  (it previously deleted `$WORK` unconditionally), using the unit suite's
  semantics (contents copied flat into the target).
- Windows path assumptions are confined to the interop and integration suites
  and have POSIX fallbacks: `cygpath -w … || echo "$path"` in both, and the
  interop `$WORK` derived from pwsh's `[IO.Path]::GetTempPath()` (returns
  `/tmp/…` on Linux/macOS). The "run from MINGW, not WSL" header constraint is
  about both sides agreeing on `C:/…` paths **on Windows**; on Linux/macOS both
  sides natively agree on POSIX paths, so the suites should be portable —
  Phase 1 item 5 stays "run it and see" per OS rather than assuming.

### Runner-image facts (verified vs assumed)

Verified 2026-06-10 from `actions/runner-images` (repo README + per-image
software lists; the ubuntu list re-checked at reconciliation):

- `ubuntu-latest` → Ubuntu 24.04; `macos-latest` → macOS 15 (arm64);
  `windows-latest` → Windows Server 2025. Current GA labels include
  `ubuntu-24.04`, `macos-15`, `windows-2025`.
- **PowerShell 7.4.16 is preinstalled on all three images** — so the interop
  and integration suites run fully everywhere, not just Windows. Note:
  runner-images has announced a PowerShell **7.4 → 7.6 LTS** upgrade across
  all images (runner-images issue #14150); the versions step + weekly cron
  below will surface it when it lands.
- ubuntu-24.04: Bash 5.2.21, Git 2.54.0, and — relevant to the new lint job —
  **shellcheck 0.9.0-1 (apt) and the PSScriptAnalyzer 1.25.0 PowerShell module
  preinstalled** (verified in the Ubuntu2404 software list), so the lint job
  needs no installs. windows-2025: Git for Windows 2.54.0 with Git Bash at
  `C:\Program Files\Git\bin\bash.exe` (this is what `shell: bash` uses on
  Windows runners — i.e. MINGW bash, exactly what the interop suite requires).
- **macos-15: Bash 3.2.57** (Apple's ancient /bin/bash). The lock script and
  the unit + interop suites were audited for bash-4+ features (indexed arrays,
  `$(( ))`, `${BASH_SOURCE[0]}`, `local`, `trap` — all bash-3.2-safe; no
  associative arrays / `mapfile` / `${var,,}`). The integration suite postdates
  that audit; a quick scan shows only bash-3.2-era constructs (indexed arrays,
  `+=()`, process substitution). Expect-to-pass; CI confirms.

Action majors verified 2026-06-11 against the releases pages:
`actions/checkout@v6` (latest v6.0.3) and `actions/upload-artifact@v7`
(latest v7.0.1) are current; `include-hidden-files` (default **false** since
upload-artifact v4.4) is available and is required here, because the
integration suite's primary diagnostics live under the scratch repo's
`.git/`. Still assumed: the bare `macos-15`
label's architecture (arm64 vs x64 — immaterial to this tool either way);
fractional `sleep` (`sleep 0.05`) works on macOS (BSD sleep accepts decimals —
high confidence, but exercised only via CI).

## Phase 1 — portability fixes (LANDED, one residual)

The items below landed in the 2026-06-10 fix wave; re-verified against HEAD at
reconciliation. Recorded as what actually shipped vs the original sketches.

1. **DONE — `_lock_dir_mtime` BSD branch** (was: `stat -c %Y` GNU-only →
   staleness silently dead on macOS). `git-commit-lock.sh` now probes
   `stat -c %Y` → `stat -f %m` → `date -r` in the planned GNU-first order, with
   hardening beyond the sketch: numeric validation of the result, a 3-probe
   retry loop (under contention the dir routinely vanishes mid-probe), and a
   loud one-time stderr WARNING + log line if the mtime is genuinely unreadable
   (instead of silently never stealing). **The BSD branch has NOT yet executed
   on real macOS** — the first CI run is that verification (see Sequencing
   note).
2. **DONE — portable backdating (completed in the 2026-06-10 final fix
   round).** The unit suite's `backdate` converts the target epoch to a
   `touch -t` stamp via `epoch_to_stamp` (GNU `date -d @…` with BSD
   `date -r …` fallback). The interop suite's two inline GNU-only
   `touch -d "@epoch"` calls (the known macOS blocker — BSD touch rejects
   `-d @epoch`, so the lock never looked stale and interop Tests 4–5 would
   fail) now use the same `epoch_to_stamp`/`backdate` helpers.
3. **Other GNU-ism audit — clean** (unchanged): `mktemp -d` with no template,
   `seq`, `grep -c`, `tr`, `wc`, fractional `sleep` all present/portable; the
   `timeout` command is not used anywhere in the suites; `cygpath` has
   fallbacks everywhere it appears.
4. **DONE (all three suites) — preserve the lock logs.** Landed in a slightly
   different shape than sketched: the suites copy the work dir/outputs to
   `$GCL_TEST_PRESERVE_DIR` whenever it is set (not only on failure) AND keep
   the work dir on disk on any failure (path printed). The integration suite
   gained this in the 2026-06-10 final fix round — see Grounding.
5. **Interop suite on Linux/macOS: still run-and-see.** Unchanged assessment;
   the first CI run is the test bed (expect possibly 1–2 follow-up commits
   after observing real runs — beyond item 2's known fix). The cosmetic
   `$env:COMPUTERNAME` nit (owner logs `host=` on Linux/macOS) was deliberately
   not taken — logging-only, still optional (`[Environment]::MachineName` if it
   ever bothers anyone).
6. **DONE — local Windows runs.** Run repeatedly through the fix wave (counts
   recorded in commit messages). The reconciliation re-run (unit 56/58,
   interop 28/30, integration 12/12) predates 840a4fd: its four misses were
   two instances of the SAME known load-margin item (the robbed-holder tests
   on a pathologically loaded box), classified from the preserved lock logs as
   vacuous misses — the thief acquired only after the victim's clean release,
   so no steal ever happened and no lock regression is indicated. 840a4fd's
   marker conversion fixed the unit-side instance (T4b); post-fix runs record
   full unit passes (59/59, then 64/64 after the final fix round), with only
   interop T8a/T8b still exposed. See the flakiness policy, item 2.

## Phase 2 — the workflow

`.github/workflows/tests.yml`:

```yaml
name: tests

on:
  push:
    branches: [main]
    paths-ignore:
      - '**.md'
      - 'LICENSE'
      - '.gitattributes'
      - '.plans/**'
  pull_request:
    paths-ignore:
      - '**.md'
      - 'LICENSE'
      - '.gitattributes'
      - '.plans/**'
  schedule:
    - cron: '17 3 * * 1'   # weekly Monday run: catches runner-image/tool drift
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: ${{ matrix.os }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false               # an OS-specific failure is the signal we want; let the others finish
      matrix:
        os: [ubuntu-24.04, macos-15, windows-2025]
    timeout-minutes: ${{ matrix.os == 'windows-2025' && 65 || 40 }}   # backstop only: sum of step budgets + upload headroom
    defaults:
      run:
        shell: bash                  # on windows-2025 this is Git Bash (MINGW) — what the interop suite requires
    env:
      GCL_TEST_FULL: 1               # full fan-out — CI runners are dedicated; the reduced default protects live dev boxes (TODO 58)
    steps:
      - uses: actions/checkout@v6

      - name: Toolchain versions (for reconstructing failures)
        run: |
          uname -a
          bash --version | head -1
          git --version
          if command -v pwsh >/dev/null; then
            pwsh -NoProfile -Command '"pwsh " + $PSVersionTable.PSVersion.ToString()'
          else
            echo "pwsh: NOT FOUND (interop suite will skip; integration runs bash-only)"
          fi
          stat --version 2>/dev/null | head -1 || echo "stat: BSD variant"

      - name: Unit suite
        timeout-minutes: ${{ matrix.os == 'windows-2025' && 35 || 15 }}   # a step timeout FAILS the step, so the upload step reliably runs
        env:
          GCL_TEST_PRESERVE_DIR: ${{ github.workspace }}/test-output/failed-work/unit
        run: |
          mkdir -p test-output
          bash git-commit-lock.test.sh 2>&1 | tee test-output/unit-suite.log

      - name: Interop suite (bash + pwsh)
        if: ${{ !cancelled() }}      # run even if an earlier suite failed — every signal is useful
        timeout-minutes: ${{ matrix.os == 'windows-2025' && 12 || 10 }}
        env:
          GCL_TEST_PRESERVE_DIR: ${{ github.workspace }}/test-output/failed-work/interop
        run: |
          mkdir -p test-output
          bash git-commit-lock.interop.test.sh 2>&1 | tee test-output/interop-suite.log

      - name: Integration suite (real concurrent commits)
        if: ${{ !cancelled() }}
        timeout-minutes: ${{ matrix.os == 'windows-2025' && 12 || 10 }}
        env:
          GCL_TEST_PRESERVE_DIR: ${{ github.workspace }}/test-output/failed-work/integration
        run: |
          mkdir -p test-output
          bash git-commit-lock.integration.test.sh 2>&1 | tee test-output/integration-suite.log

      - name: Upload failure diagnostics
        if: ${{ failure() || cancelled() }}   # failure() covers step timeouts (they fail the step); cancelled() is best-effort cover for manual cancels / the job-level backstop
        uses: actions/upload-artifact@v7
        with:
          name: test-logs-${{ matrix.os }}
          path: test-output/
          include-hidden-files: true   # the integration suite's key diagnostics (lock log, repo state) live under the scratch repo's .git/ — excluded by default since upload-artifact v4.4; contents are suite-generated, no secrets
          if-no-files-found: warn
          retention-days: 14

  lint:
    runs-on: ubuntu-24.04            # static analysis is OS-independent; one fast leg (see Lint job below)
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v6

      - name: shellcheck (gate at warning severity)
        run: |
          shellcheck --version
          shellcheck -S warning \
            git-commit-lock.sh \
            git-commit-lock.test.sh \
            git-commit-lock.interop.test.sh \
            git-commit-lock.integration.test.sh \
            install.sh

      - name: PSScriptAnalyzer (gate at warning severity)
        shell: pwsh
        run: |
          if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
            # ubuntu-24.04 preinstalls 1.25.0; this fallback fires only if an image bump drops it.
            Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
          }
          Get-Module -ListAvailable PSScriptAnalyzer | ForEach-Object { "PSScriptAnalyzer $($_.Version)" }
          $r = Invoke-ScriptAnalyzer -Path ./git-commit-lock.ps1 -Severity Warning,Error
          if ($r) { $r | Format-Table -AutoSize | Out-String | Write-Host; exit 1 }
          'PSScriptAnalyzer: clean'
```

Design decisions and justifications:

- **Explicit runner pins** (`ubuntu-24.04`, `macos-15`, `windows-2025`), per our
  CI conventions: these are today's GA images — the very ones the `-latest`
  aliases currently resolve to — so we get identical coverage without a
  surprise migration when GitHub repoints `-latest`. Upgrades become deliberate
  one-line PRs.
- **`concurrency` + `cancel-in-progress`** keyed on workflow+ref: rapid pushes
  to main coalesce; PR pushes cancel the stale run for that branch.
- **`paths-ignore` for docs-only commits**: CI executes only the three
  self-contained suites and two linters; nothing extracts or runs the command
  snippets embedded in `README.md` / `docs/*.md`, so a docs-only commit cannot
  change a test or lint outcome. If we ever add doc-snippet testing, remove the
  ignore in that same change. One caveat to remember: if branch protection with
  *required* status checks is ever enabled, path-filtered workflows leave the
  check pending and block merges — no branch protection exists on this repo
  today, so this is a note, not a problem.
- **Timeouts are per-STEP, with the job level as backstop only.** A job-level
  `timeout-minutes` *cancels* the job when it fires, and a cancelled job does
  not reliably run later steps — so hanging a "upload the partial logs"
  guarantee off a job timeout is wrong. Instead each suite step carries its
  own `timeout-minutes`; a step timeout FAILS the step (it does not cancel the
  job), so `failure()` reliably triggers the diagnostics upload with the
  partial `tee` logs. The job-level value (40 Linux/macOS / 65 Windows = sum
  of step budgets + upload headroom) remains only as a backstop against a
  wedged runner; if IT fires, the upload is best-effort (`cancelled()`).
  Step sizing: budget = expected runtime + one full internal hang + margin.
  Expected: a few minutes per suite on Linux/macOS; Windows worst-case
  measured 20m10s + 3m01s + 2m52s ≈ 26 min total on a pathologically loaded
  box (an idle windows-2025 runner should beat that comfortably — the same box
  did the integration suite in 67–85 s under normal load — but Windows process
  spawn is the slow axis and the three suites together spawn ~300+ processes).
  The suites' own `AGENT_LOCK_MAX_WAIT` caps bound a single pathological hang
  at 7 min (4 min in integration) before the suite fails itself — hence unit
  15/35, interop and integration 10/12 (Linux+macOS/Windows). **Revisit
  downward after the performance pass (TODO 53–56) lands and after observing
  real runner times** — don't tighten on predictions.
- **`shell: bash` everywhere**: GitHub's bash steps run `bash -eo pipefail`, so
  the `… | tee …` pipelines propagate suite failure correctly; on Windows this
  is Git Bash/MINGW — the exact environment the interop suite's header
  mandates.
- **No `pwsh` setup step**: PowerShell 7.4 is preinstalled on all three images
  (verified above); the interop suite degrades to an explicit `SKIP` (exit 0)
  and the integration suite to bash-only if that ever changes — the versions
  step makes such a degradation visible in the log.
- **`GCL_TEST_FULL: 1` (new, 2026-06-11 — TODO 58).** The heavy fan-out tests
  (unit T1's 8×25 ≈ 200 bash spawns, the interop and integration swarms) are
  CI-strength exclusion canaries, but agents run the suites routinely during
  development on a live shared machine, and full fan-out there lags the whole
  box. The suites are being changed (TODO 58) to default to REDUCED fan-out
  (~1/8 the spawn load, still a real exclusion signal) and run full strength
  only under `GCL_TEST_FULL=1`. CI is the dedicated environment, so the job
  sets the flag from day one — and the landing order doesn't matter: today
  full strength IS the default, so the env var is an inert no-op until TODO 58
  lands, and carrying it now means a later landing can't silently weaken CI.
  Each suite prints which mode ran, so a reduced local pass can never
  masquerade as the full canary. The budgets and measured runtimes in this
  plan are full-strength numbers and stay valid for CI.
- **Per-suite preserve dirs** (`failed-work/unit|interop|integration`): the
  unit and integration suites copy their work dir's *contents* flat into the
  target while the interop suite copies the dir *itself* — distinct parents
  keep the artifact layout unambiguous whichever suites fail.
- **Logging/diagnosability**: full suite stdout tee'd to `test-output/*.log`;
  failed runs additionally preserve every per-test lock log via
  `GCL_TEST_PRESERVE_DIR` (all three suites); the versions step pins down the
  exact toolchain; artifacts named per-OS, kept 14 days, **hidden paths
  included** (`include-hidden-files: true` — the integration scratch repo's
  `.git/` holds the lock log and history that ARE the diagnosis). Together that's
  enough to reconstruct a remote timing flake: which worker held the lock
  when, who stole what, and on which bash/pwsh/OS.

### Lint job (new — TODO items 48–49)

- **shellcheck** over the five shell scripts (lock script, three suites,
  `install.sh`), gated at `-S warning` (warnings and errors fail; info/style
  notes don't). Verified clean at this gate against HEAD with shellcheck 0.11.0
  locally on 2026-06-10. The ~40 info/style notes (SC2015, SC2310/SC2312
  errexit-interaction notes) remain non-blocking; TODO 48's deliberate triage
  of them (suppress-with-rationale where intentional) stays open and does not
  gate.
- **PSScriptAnalyzer** on `git-commit-lock.ps1` at Warning+Error severity. The
  deliberate swallow-and-continue catch blocks are suppressed in-file via a
  file-level `SuppressMessageAttribute` with a written justification
  (lock-path I/O must never abort the holder), so the gate needs no exclusion
  flags. That suppression landed in `840a4fd` (mid-reconciliation); the file
  verified clean at this gate with PSScriptAnalyzer 1.25.0 on 2026-06-10
  (pre-suppression it showed 14× PSAvoidUsingEmptyCatchBlock).
- **Tool versions — recommend the image's, not pins** (consistent with open
  question 2's philosophy): ubuntu-24.04 preships shellcheck 0.9.0-1 and
  PSScriptAnalyzer 1.25.0 — the latter the exact version of the local baseline
  — so the default run installs nothing, and the printed versions + weekly cron
  make drift visible. The local shellcheck baseline was 0.11.0 vs the image's
  0.9.0; older shellcheck has strictly fewer checks, so clean-at-0.11 should be
  clean-at-0.9 (CI confirms). If a future image/tool bump ever turns the gate
  red for tool reasons rather than code reasons, pin then
  (`Install-Module -RequiredVersion`, apt-pinned shellcheck) in the same commit
  that triages the new findings.
- **Ubuntu-only — recommended**: both tools are static analyzers whose verdicts
  are properties of the checked-out bytes, not of the execution OS, so three
  legs would add wall time and zero information. Ubuntu is the fastest,
  cheapest leg and the only one needing no installs.

### Integration test in CI

The integration suite is the single most valuable CI signal of the three:

- **It tests what the tool is FOR** — real concurrent `git add`/`git commit`s
  into one shared repository via the exact `run` invocations README.md gives
  agents, under the DEFAULT lock location. On its very first local run it
  caught a real cross-impl bug the other suites structurally could not:
  the ps1 default-lock-location regression (fixed in `aff3018` —
  `Select-Object -First 1` after native git left `$LASTEXITCODE` unset on
  pwsh 7.5, so `Get-LockBase` silently fell back to `<cwd>/commit.lock` and the
  pwsh side never contended with the bash side's default lock). The unit and
  interop suites missed it because they always set `AGENT_LOCK_DIR` explicitly;
  only a suite driving the documented defaults could see it.
- **Its strict no-shortfall assertions make it the canary for
  runner-environment weirdness.** Unlike the interop exclusion test's
  launch-flake allowance, the integration suite tolerates nothing: every worker
  must launch and commit rc 0, the commit count must be exact, every commit
  must touch exactly its own file, the lock log must balance with zero
  steals/timeouts, and the tree must end clean. Slow process spawn, odd
  temp-path semantics, or git-config surprises on a runner show up here as a
  hard failure rather than a quietly weakened pass. Its sizing comment encodes
  the policy: if heavy fan-out ever makes launches flaky at this size, reduce N
  rather than tolerate loss.
- **It is CI-ready by construction**: scratch repo with all-local config
  (identity, `gpgsign=false`, `autocrlf=false`, isolated `hooksPath`), so
  runners need no git identity/signing setup.

### Flakiness policy: fix margins, never auto-retry

No retry action and no `nick-fields/retry`-style wrappers. The 25-worker
exclusion test exists precisely to catch a ~1-in-25-runs race (it found two
real bugs that way); auto-retry would launder a genuine exclusion regression
into "flaky, re-ran, green". (CI always runs it at full strength via
`GCL_TEST_FULL=1`; the reduced default is purely a live-dev-box protection —
TODO 58.) On a CI failure:

1. Read the uploaded lock logs and classify: **race regression** (violations,
   wrongful STOLE, unbalanced acquire/release) → it's a bug, fix the lock; vs
   **load-margin miss** (an expected interaction didn't happen because process
   start lost to load) → fix the margin *in the suite* as a correctness change.
2. Known margin watch-item — updated at reconciliation and again in the final
   fix round. The original watch-item (interop Tests 2–3 fixed head-start
   sleeps racing pwsh cold-start) was fixed the way this plan prescribed: the
   holder now writes a ready-marker inside its critical section and the waiter
   launches only after it. Unit T4b was likewise converted to marker-polling
   in 840a4fd after a load flake. The live margin item is now the
   **interop robbed-holder tests (T8a/T8b) only**: the victim holds via a
   fixed `sleep` while a thief is expected to arrive and steal mid-hold; under
   heavy load the thief can spawn so slowly that the victim releases cleanly
   first — no steal happens and the "exits 98 + theft WARNING" assertions miss
   vacuously. Observed exactly this during reconciliation on a pathologically
   loaded box (then-unconverted unit T4b and interop T8a; the preserved lock
   logs show the thief ACQUIRING seconds after the victim's clean RELEASE).
   The proper fix is already queued as TODO items 55–56
   (hold-until-WAITING-observed instead of fixed sleeps); if CI hits this
   first, pull that fix forward — not retries, not bigger sleeps.
3. Manual re-run (`workflow_dispatch` / re-run button) is acceptable only for
   pure infra failures (runner died, network), never to get past a reproducible
   failure.

## Phase 3 — README badge + docs updates

1. Workflow badge at the top of `README.md`
   (`[![tests](…/actions/workflows/tests.yml/badge.svg)](…)` — exact URL once
   the GitHub repo path is known).
2. Rewrite the README portability sentence — it still reads "so far they have
   been exercised mainly on Windows (Git Bash + PowerShell 7)" → state that all
   three suites run in CI on Linux, macOS, and Windows (keep the note that
   Windows remains the richest-exercised environment if Ben wants the nuance).
3. "Running the tests" section: mention CI runs the suites on all three OSes;
   document `GCL_TEST_PRESERVE_DIR` in one line (all three suites honour it).
4. ~~`docs/git-commit-lock.md` staleness-clock sentence~~ — **done/moot**: the
   docs wave rewrote that paragraph and it no longer cites `stat -c %Y`; the
   GNU/BSD probe order lives in the implementation comment, and an unreadable
   mtime now announces itself via the loud runtime WARNING. Nothing to do.

## Open questions for Ben (each with a recommendation; silence = go with it)

1. **Windows in the matrix?** Recommend **yes** — it's the tool's home turf and
   the interop suite's primary target; the plan includes it.
2. **Pin a pwsh version (setup step) vs use the image's?** Recommend **image's
   pwsh** (7.4.16 on all three today; a 7.6 LTS image upgrade is announced):
   the tool targets "whatever pwsh the agent has", and the versions step +
   weekly cron will surface drift if an image bump breaks something.
3. **Weekly cron run?** Recommend **yes** (in the YAML above): this repo will
   be quiet post-publish, and the cron catches runner-image/toolchain drift
   between pushes. Drop the `schedule:` block if you'd rather not get
   unattended failure email.
4. **Gitea Actions parity?** A near-identical workflow could run on
   gitea.npium.com, but the `alpine-host` runner has no pwsh (PowerShell on
   Alpine is awkward), so it would cover the bash-only paths on Linux only — a
   subset of what GitHub gives us. Recommend **defer**; GitHub is the ask.
   Revisit if we want CI on private pre-push branches.
5. **Broader matrix (ubuntu-22.04, macos-14, windows-2022)?** Recommend **no**
   — the portability risk here is OS-family (GNU vs BSD vs MINGW), not OS
   version; three current images cover all three families.
6. **`fail-fast: false` + docs `paths-ignore` as drafted?** Recommend **yes**
   as justified above; flagging because both are judgement calls.
7. **Lint job as drafted (ubuntu-only, image tool versions, warning-severity
   gate)?** Recommend **yes** — justified in the Lint job section; flagging
   because "a future tool bump may redden the gate, triage then" is a deliberate
   trade against pinning.

## Sequencing note

Phase 1 has fully landed (the interop `touch -d` residual and the integration
preserve knob both closed in the 2026-06-10 final fix round; the ps1
`SuppressMessageAttribute` the lint gate needs landed in `840a4fd`). The
original framing otherwise holds: macOS cannot be tested from this machine, so
the first real verification of the landed-but-BSD-untested `stat -f %m` branch
and of the bash-3.2 audit *is* the first CI run after publish. Expect possibly
a short fix-iterate loop on macOS (that's the plan working, not failing).
Phase 3 lands once the matrix is green, since the badge and the reworded
portability claim depend on that.

Cross-plan sequencing: **CI lands first**; the lockfile plan
(`.plans/2026-06-10-main-lockfile-plan.md`) then ports the on-disk protocol
under the green matrix — its probes were Windows-only, so the matrix is
exactly the verification that port lacks.
