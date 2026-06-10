# Plan: GitHub Actions CI for git-commit-lock

Date: 2026-06-10 · Branch: main · Status: **draft, awaiting Ben's review** (no implementation yet)

Goal: a `.github/workflows/tests.yml` that runs both test suites
(`git-commit-lock.test.sh`, `git-commit-lock.interop.test.sh`) on Linux, macOS, and
Windows on every push/PR, ahead of publishing the repo on GitHub. Ben explicitly asked
for Linux and "can we get mac that way too?" — yes: GitHub-hosted `macos-*` runners.
Windows is included because it's the tool's home turf (Git Bash + pwsh) and `windows-*`
runners ship both.

## Grounding: what the suites actually need (verified by reading + running)

- Both suites are self-contained bash scripts using throwaway temp dirs; exit 0 = pass.
  The bash suite spawns ~200 short-lived `bash` processes (8 rounds × 25 workers) plus
  per-test holders/waiters with real sleeps. The interop suite spawns 8 bash + 8 pwsh
  workers sharing one lock, plus ordering/steal tests; it **skips with exit 0 if `pwsh`
  is not on PATH** (line 18), so it is safe to invoke unconditionally on every OS.
- Timing knobs: tests shrink windows via `AGENT_LOCK_STALE_SECS` / `AGENT_LOCK_POLL_SECS`
  / `AGENT_LOCK_MAX_WAIT` env vars. Defaults that matter for CI budgets:
  `AGENT_LOCK_MAX_WAIT=420s` — a single pathological hang (a regression where a waiter
  never sees staleness) costs up to **7 minutes** before the suite itself fails.
- Measured locally 2026-06-10: bash suite **19/19 pass in 6m09s wall** on Ben's heavily
  loaded Windows box (Git Bash). GitHub Linux runners spawn processes far faster; expect
  1–3 min there, with Windows the slowest runner.
- Lock-protocol logs (`ACQUIRED`/`RELEASED`/`STALE`/`STOLE`/`WARNING` lines) are written
  to per-test log files **inside the temp `$WORK` dir, which the EXIT trap deletes** —
  so today a CI failure would destroy exactly the evidence needed to debug it remotely.
  Phase 1 item 4 fixes that.
- Windows path assumptions are confined to the interop suite and already have POSIX
  fallbacks: `cygpath -w … || echo "$path"` (line 15) and `$WORK` derived from pwsh's
  `[IO.Path]::GetTempPath()` (returns `/tmp/…` on Linux/macOS). The "run from MINGW, not
  WSL" header constraint is about both sides agreeing on `C:/…` paths **on Windows**;
  on Linux/macOS both sides natively agree on POSIX paths, so the suite should be
  portable — Phase 1 item 5 is "run it and see" per OS rather than assuming.

### Runner-image facts (verified vs assumed)

Verified 2026-06-10 from `actions/runner-images` (repo README + per-image software
lists):

- `ubuntu-latest` → Ubuntu 24.04; `macos-latest` → macOS 15 (arm64);
  `windows-latest` → Windows Server 2025. Current GA labels include `ubuntu-24.04`,
  `macos-15`, `windows-2025`.
- **PowerShell 7.4.16 is preinstalled on all three images** (ubuntu-24.04, macos-15,
  windows-2025 software lists each state "PowerShell 7.4.16") — so the interop suite
  can run everywhere, not just Windows.
- ubuntu-24.04: Bash 5.2.21, Git 2.54.0. windows-2025: Git for Windows 2.54.0 with
  Git Bash at `C:\Program Files\Git\bin\bash.exe` (this is what `shell: bash` uses on
  Windows runners — i.e. MINGW bash, exactly what the interop suite requires).
- **macos-15: Bash 3.2.57** (Apple's ancient /bin/bash). Audited both suites and the
  lock script for bash-4+ features: indexed arrays, `$(( ))`, `${BASH_SOURCE[0]}`,
  `local`, `trap` — all bash-3.2-safe; no associative arrays / `mapfile` / `${var,,}`.
  Expect-to-pass; CI confirms.

Assumed (to verify at implementation time): `actions/checkout@v5` and
`actions/upload-artifact@v4` are the current majors; the bare `macos-15` label's
architecture (arm64 vs x64 — immaterial to this tool either way); fractional `sleep`
(`sleep 0.05`) works on macOS (BSD sleep accepts decimals — high confidence, but
exercised only via CI).

## Phase 1 — portability fixes (before any workflow lands)

Items 1–2 came from a parallel code review (taken as input, then confirmed against the
source); 3–6 found while grounding this plan.

1. **`_lock_dir_mtime` is unreadable on macOS** (`git-commit-lock.sh:111-113`, review
   finding, confirmed). `stat -c %Y` is GNU; on BSD/macOS it fails, and the fallback
   `date -r "$path" +%s` is also GNU-only — BSD `date -r` takes **epoch seconds**, not a
   file, so a path argument errors → function returns empty → no lock is ever classed
   stale on macOS → stale/steal tests (bash suite 2–3, interop 4–5) fail or hang to
   MAX_WAIT. Fix — add the BSD branch between the GNU attempt and the GNU-date fallback:

   ```sh
   _lock_dir_mtime() {
     stat -c %Y "$AGENT_LOCK_DIR" 2>/dev/null \
       || stat -f %m "$AGENT_LOCK_DIR" 2>/dev/null \
       || date -r "$AGENT_LOCK_DIR" +%s 2>/dev/null \
       || true
   }
   ```

   (GNU first: it's the hot path on Linux/MINGW. BSD `date -r` with a path errs and is
   suppressed, so the trailing GNU fallback stays harmless.) Update the comment at
   line 110 and the `stat -c %Y` mention in `docs/git-commit-lock.md:51`.

2. **`touch -d "@epoch"` backdating is GNU-only** (review asked to check for further
   GNU-isms; this is the main one). Used in `git-commit-lock.test.sh:23` (`backdate`)
   and inline twice in `git-commit-lock.interop.test.sh:116,129`. BSD touch's `-d`
   wants ISO-8601, not `@epoch`. Fix — one portable helper in both suites (replace the
   interop inlines with calls to it):

   ```sh
   backdate() {  # $1=path  $2=seconds-ago
     local t=$(( $(date +%s) - $2 ))
     touch -d "@$t" "$1" 2>/dev/null \
       || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"
   }
   ```

   (On BSD, `date -r <secs> +fmt` formats an epoch — the same flag that's a file-mtime
   read on GNU, which is why the branches must stay ordered GNU-first.)

3. **Other GNU-ism audit — clean.** `mktemp -d` with no template works on modern macOS;
   `seq`, `grep -c`, `tr`, `wc`, fractional `sleep` are all present/portable; the
   `timeout` command is **not used anywhere** in the suites (so no coreutils-via-brew
   dependency); `cygpath` already has a fallback. No changes needed beyond 1–2.

4. **Failure diagnosability: preserve the lock logs** (new; required by our logging
   standards — today the EXIT trap deletes them). Add to both suites' `cleanup()`:

   ```sh
   cleanup() {
     if [ "${FAIL:-0}" != 0 ] && [ -n "${GCL_TEST_PRESERVE_DIR:-}" ]; then
       mkdir -p "$GCL_TEST_PRESERVE_DIR" 2>/dev/null \
         && cp -R "$WORK" "$GCL_TEST_PRESERVE_DIR/" 2>/dev/null || true
     fi
     rm -rf "$WORK" 2>/dev/null || true
   }
   ```

   On a local run nothing changes (var unset). CI sets `GCL_TEST_PRESERVE_DIR` so a
   failing run uploads the per-test lock logs — the full ACQUIRED/RELEASED/STOLE
   history is precisely what's needed to diagnose a timing flake remotely.

5. **Interop suite on Linux/macOS: run-and-see, not assume.** Reading says it should
   work post-fix-2 (POSIX `$WORK`, cygpath fallback, .NET-API-only pwsh worker bodies).
   It cannot be fully verified from this Windows machine (the header's no-WSL caveat is
   a Windows path-agreement issue, not a Linux one), so the first CI run is the test
   bed: expect possibly 1–2 follow-up commits after observing real runs. One cosmetic
   POSIX gap spotted: `git-commit-lock.ps1:93` uses `$env:COMPUTERNAME` (empty on
   Linux/macOS → owner logs as `host=`); optional nicety to switch to
   `[Environment]::MachineName`. Logging-only, not a blocker.

6. **Run both suites locally on Windows after the fixes** (regression check on home
   turf) before committing Phase 1.

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
    timeout-minutes: ${{ matrix.os == 'windows-2025' && 30 || 15 }}
    defaults:
      run:
        shell: bash                  # on windows-2025 this is Git Bash (MINGW) — what the interop suite requires
    env:
      GCL_TEST_PRESERVE_DIR: ${{ github.workspace }}/test-output/failed-work
    steps:
      - uses: actions/checkout@v5

      - name: Toolchain versions (for reconstructing failures)
        run: |
          uname -a
          bash --version | head -1
          git --version
          if command -v pwsh >/dev/null; then
            pwsh -NoProfile -Command '"pwsh " + $PSVersionTable.PSVersion.ToString()'
          else
            echo "pwsh: NOT FOUND (interop suite will skip)"
          fi
          stat --version 2>/dev/null | head -1 || echo "stat: BSD variant"

      - name: Bash suite
        run: |
          mkdir -p test-output
          bash git-commit-lock.test.sh 2>&1 | tee test-output/bash-suite.log

      - name: Interop suite (bash + pwsh)
        if: ${{ !cancelled() }}      # run even if the bash suite failed — both signals are useful
        run: |
          mkdir -p test-output
          bash git-commit-lock.interop.test.sh 2>&1 | tee test-output/interop-suite.log

      - name: Upload failure diagnostics
        if: ${{ failure() || cancelled() }}   # cancelled() covers a timeout-minutes kill
        uses: actions/upload-artifact@v4
        with:
          name: test-logs-${{ matrix.os }}
          path: test-output/
          if-no-files-found: warn
          retention-days: 14
```

Design decisions and justifications:

- **Explicit runner pins** (`ubuntu-24.04`, `macos-15`, `windows-2025`), per our CI
  conventions: these are today's GA images — the very ones the `-latest` aliases
  currently resolve to — so we get identical coverage without a surprise migration when
  GitHub repoints `-latest`. Upgrades become deliberate one-line PRs.
- **`concurrency` + `cancel-in-progress`** keyed on workflow+ref: rapid pushes to main
  coalesce; PR pushes cancel the stale run for that branch.
- **`paths-ignore` for docs-only commits**: CI executes only the two self-contained
  suites; nothing extracts or runs the command snippets embedded in `README.md` /
  `docs/*.md`, so a docs-only commit cannot change a test outcome. If we ever add
  doc-snippet testing, remove the ignore in that same change. One caveat to remember:
  if branch protection with *required* status checks is ever enabled, path-filtered
  workflows leave the check pending and block merges — no branch protection exists on
  this repo today, so this is a note, not a problem.
- **`timeout-minutes` 15 (Linux/macOS) / 30 (Windows)**: budget = expected runtime +
  one full internal hang + margin. Expected: 1–3 min/suite on Linux; measured 6m09 for
  the bash suite on a *heavily loaded* Windows box (an idle Windows runner should beat
  that, but Windows process spawn is the slow axis and the two suites together spawn
  ~250 processes). The suites' own `AGENT_LOCK_MAX_WAIT=420s` cap bounds a single
  pathological hang at 7 min before the suite fails itself — so 15/30 min covers normal
  runtime plus one such hang, while still killing a doubly-wedged job. On a
  timeout-kill, the `cancelled()` condition still uploads the partial `tee` logs.
- **`shell: bash` everywhere**: GitHub's bash steps run `bash -eo pipefail`, so the
  `… | tee …` pipelines propagate suite failure correctly; on Windows this is Git
  Bash/MINGW — the exact environment the interop suite's header mandates.
- **No `pwsh` setup step**: PowerShell 7.4 is preinstalled on all three images
  (verified above), and the interop suite degrades to an explicit `SKIP` (exit 0) if
  that ever changes — the versions step makes such a skip visible in the log.
- **Logging/diagnosability**: full suite stdout tee'd to `test-output/*.log`; failed
  runs additionally preserve every per-test lock log via `GCL_TEST_PRESERVE_DIR`
  (Phase 1 item 4); the versions step pins down the exact toolchain; artifacts named
  per-OS, kept 14 days. Together that's enough to reconstruct a remote timing flake:
  which worker held the lock when, who stole what, and on which bash/pwsh/OS.

### Flakiness policy: fix margins, never auto-retry

No retry action and no `nick-fields/retry`-style wrappers. The 25-worker exclusion test
exists precisely to catch a ~1-in-25-runs race (it found two real bugs that way);
auto-retry would launder a genuine exclusion regression into "flaky, re-ran, green".
On a CI failure:

1. Read the uploaded lock logs and classify: **race regression** (violations, wrongful
   STOLE, unbalanced acquire/release) → it's a bug, fix the lock; vs **load-margin
   miss** (ordering test lost because a fixed head-start sleep lost to slow process
   start) → fix the margin *in the suite* as a correctness change.
2. Known margin watch-item (don't fix preemptively; fix properly if it bites): interop
   Tests 2–3 give the holder a 0.6–0.8 s head start before launching the waiter —
   pwsh cold-start on a loaded runner could exceed that (Test 3's pwsh holder might not
   have acquired before the bash waiter arrives, inverting the expected order). The
   correct fix if observed is to poll for the holder's start marker in `$ORDER` before
   launching the waiter, not to inflate sleeps or add retries.
3. Manual re-run (`workflow_dispatch` / re-run button) is acceptable only for pure
   infra failures (runner died, network), never to get past a reproducible failure.

## Phase 3 — README badge + docs updates

1. Workflow badge at the top of `README.md`
   (`[![tests](…/actions/workflows/tests.yml/badge.svg)](…)` — exact URL once the
   GitHub repo path is known).
2. Rewrite `README.md:72-73` — "so far they have been exercised mainly on Windows
   (Git Bash + PowerShell 7)" → state that both suites run in CI on Linux, macOS, and
   Windows (keep the note that Windows remains the richest-exercised environment if Ben
   wants the nuance).
3. "Running the tests" section: mention CI runs them on all three OSes; document
   `GCL_TEST_PRESERVE_DIR` in one line.
4. `docs/git-commit-lock.md:51`: update the staleness-clock sentence to mention the
   GNU/BSD `stat` branches (matches Phase 1 item 1).

## Open questions for Ben (each with a recommendation; silence = go with it)

1. **Windows in the matrix?** Recommend **yes** — it's the tool's home turf and the
   interop suite's primary target; the plan includes it.
2. **Pin a pwsh version (setup step) vs use the image's?** Recommend **image's pwsh**
   (7.4.16 on all three today): the tool targets "whatever pwsh the agent has", and the
   versions step + weekly cron will surface drift if an image bump breaks something.
3. **Weekly cron run?** Recommend **yes** (in the YAML above): this repo will be
   quiet post-publish, and the cron catches runner-image/toolchain drift between
   pushes. Drop the `schedule:` block if you'd rather not get unattended failure email.
4. **Gitea Actions parity?** A near-identical workflow could run on gitea.npium.com,
   but the `alpine-host` runner has no pwsh (PowerShell on Alpine is awkward), so it
   would cover the bash suite only, on Linux only — a subset of what GitHub gives us.
   Recommend **defer**; GitHub is the ask. Revisit if we want CI on private pre-push
   branches.
5. **Broader matrix (ubuntu-22.04, macos-14, windows-2022)?** Recommend **no** — the
   portability risk here is OS-family (GNU vs BSD vs MINGW), not OS version; three
   current images cover all three families.
6. **`fail-fast: false` + docs `paths-ignore` as drafted?** Recommend **yes** as
   justified above; flagging because both are judgement calls.

## Sequencing note

Phases 1 and 2 land as separate commits but should be implemented together: macOS
cannot be tested from this machine, so the first real verification of Phase 1's BSD
branches *is* the first CI run after publish. Expect possibly a short fix-iterate loop
on macOS (that's the plan working, not failing). Phase 3 lands once the matrix is
green, since the badge and the reworded portability claim depend on that.
