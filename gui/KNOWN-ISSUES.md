# LabDeploy: Known Issues (deferred from the 2026-07-22 ultracode review)

These were found by the multi-agent review and judged real, but deferred as
lower-priority / higher-risk-to-change. None block normal use. Listed so they
aren't rediscovered from scratch.

## Uninstall path (rare operation)
- ~~**Registry uninstall picks the FIRST DisplayName match.**~~ **FIXED
  2026-07-27.** Candidates are now RANKED (InstallLocation matching the
  detected install dir > exact DisplayName > EstimatedSize, minus penalties for
  sub-component/plumbing names, minus a length penalty since the base product
  has the shortest name). And when there are >=4 candidates with no exact name
  match it **refuses to guess** and hands off to Programs & Features (E42)
  rather than removing an arbitrary component. Verified against this machine's
  real registry: Keil now resolves to "Keil uVision4" (the old code picked
  "Windows Driver Package - KEIL ..." - it would have uninstalled a USB driver);
  Visual Studio still resolves to "Visual Studio Installer"; Python's 10
  component entries now correctly trigger the manual handoff.
- ~~**Uninstall-string parser** mishandles unquoted registry paths containing
  spaces and appends silent switches to uninstallers that aren't silent-capable~~
  **FIXED 2026-07-27.** Unquoted strings are now resolved by walking the tokens
  and keeping the LONGEST leading run that is a real file on disk, so
  `C:\Program Files\App\unins000.exe /x` no longer parses as `C:\Program`.
  Generic `/S /VERYSILENT /NORESTART` is only appended for uninstaller families
  that document those switches (unins*.exe / uninstall.exe / uninst.exe /
  setup.exe, or an existing /uninstall|--uninstall|/x arg); anything else runs
  exactly as registered and is logged (uninstall.no_silent_switches) so it can
  never sit hidden behind a dialog. 7-case test green, including the
  unquoted-with-spaces case and the non-silent custom uninstaller.

## UI responsiveness
- ~~**winget catalog self-heal / repair blocks the UI thread up to 120 s**~~
  **FIXED 2026-07-27.** Added `Invoke-UiDoEvents` (WPF DispatcherFrame DoEvents)
  + `Wait-ProcessResponsive`; both `WaitForExit(120000)` call sites now pump the
  message queue while waiting, so the window keeps repainting instead of going
  "Not Responding". Same timeout budget. Tested both paths (returns on exit;
  honours the timeout).

## Copy-method installs are ADDITIVE, not a clean mirror  (found 2026-07-27)
The `copy` install method walks the source and `Copy-Item -Force`s each file
over the destination. It creates missing folders but **never deletes files the
previous version left behind**. Affects ArduinoIDE, ImageJ and AfterMath.

- On a FRESH machine (the normal case) this is irrelevant - the destination
  doesn't exist yet.
- On a VERSION UPGRADE it can leave a hybrid: files renamed or dropped between
  versions survive alongside the new ones. Last year's SCI-1 script deliberately
  did `Remove-Item $dest -Recurse` then `robocopy /MIR` for exactly this reason.

NOT auto-fixed on purpose: making the install wipe its destination first is
destructive, and a wrong/mis-typed `destination` would then delete the wrong
folder. The risk asymmetry favours leaving it additive.

WORKAROUND until reviewed: to upgrade a copy-deploy app, hit **Uninstall first**
(that branch already deletes the destination cleanly, with an explicit
confirmation) and then Install. A future fix could mirror safely by refusing to
delete unless the destination is a subfolder of Program Files AND matches the
app's own detect path.

## Minor / edge
- ~~**Scan ERRORS (E10) are classified Status='Missing'**~~ **FIXED 2026-07-27** -
  now Status='ScanError' (unknown, not known-absent), excluded from "Install All
  Missing", counted separately in the summary.
- ~~**Install All + dependency chain double-installs the dependency**~~
  **FIXED 2026-07-27** - Resume-InstallQueue re-checks detection as it dequeues
  and skips anything already installed. (This DID go live: the imported SCI-1
  room 209 listed RStudio before its R dependency.) Room lists also get a
  topological pass so dependencies always precede dependents.
- ~~**Window-close during an offload copy** leaves robocopy writing to
  `C:\LabDeployOffload_Temp`.~~ **FIXED 2026-07-27**: the copy is now stopped
  and its temp reclaimed on close, instead of relying on the startup janitor to
  clean up on the next launch (which raced the still-running robocopy). See
  "Install-engine crash/cancel paths" below.

## The interrupted review: RECOVERED AND CLOSED 2026-07-27
The 2026-07-22 workflow (run id wf_661e38a7-d10) hit the session usage cap
mid-verification: 57 agents started, only 12 returned. Those 12 returns were
still on disk in the run journal, and **48 findings were recovered from it** and
verified against current code rather than re-running the review from scratch.

Outcome: the large majority were already fixed by the 2026-07-26/27 work
(batch abort, scan-error classification, uninstall ranking, uninstall-string
parser, winget dispatcher blocking, GP `[uint32]` overflow, dependency
double-install, room-combo desync, copy-method exit codes, PKI logging,
wildcard detect paths in the leftover-files allowlist). **Five were still live
and are now fixed, see "Install-engine crash/cancel paths" below.**

Not worth re-running the workflow: it was verifying a version of the file that
no longer exists. The recovered findings were the valuable part.

## Install-engine crash/cancel paths: FIXED 2026-07-27 (from the recovered review)

- **A failed install advanced the queue TWICE, a regression from that same
  night's batch-abort fix.** `Resume-InstallQueue` was added inside the failure
  branch, but the branch then fell through to the handler's common tail, which
  dequeues again. With >=2 apps left after a failure, two installs started
  **concurrently**; `$script:installProcess` was overwritten by the second, so
  the first was untracked and its card sat on "Installing" forever with an inert
  Cancel (per-card Refresh refuses to touch an 'Installing' card). The trailing
  `Clear-OffloadTemp` could also delete the staged copy of the install that had
  just started. Invisible in the LabVIEW->MATLAB run because only ONE app
  remained. **Fixed** with an explicit `return`; reproduced and verified across
  0/1/2/3-apps-remaining (old: 2 concurrent; fixed: exactly 1).
- **Install-timer E70 catch stranded the card**: no card reset, `installProcess`
  left pointing at the exited process (so a later Cancel could `taskkill` a
  recycled PID), and the rest of the batch abandoned. **Fixed**: card re-detected
  and repainted, process refs cleared, `Resume-InstallQueue` keeps the batch alive.
- **Offload-copy catch orphaned robocopy**: it nulled the only handle without
  killing the process, so a multi-GB mirror kept writing to
  `C:\LabDeployOffload_Temp` with the Cancel path already disarmed. **Fixed**:
  same taskkill + temp cleanup the Cancel path uses, then repaint the card.
- **Closing the window during an offload copy** left that robocopy running for a
  session that no longer existed, nothing would ever consume the staged files.
  **Fixed**: the copy is stopped and its temp reclaimed on close. A vendor
  *installer* is still deliberately left running, exactly as the dialog promises.
- **`installQueue.Clear()` silently dropped re-queued retries.** The winget
  fallback and catalog auto-fix repaint a card ("will retry automatically...")
  and disable its Install button before re-queueing at the back. Cancelling any
  other app wiped that retry, leaving a greyed-out card advertising a retry that
  never came. **Fixed**: `Clear-InstallQueue` repaints every dropped entry from
  real detection, so each card tells the truth and its button returns.

## Final ledger for the recovered review: CLOSED 2026-07-27

48 raw findings recovered from the dead run's journal collapse to **30 unique
issues** (18 were the same defect reported by different agents). Every one is
now accounted for. Recorded so nobody re-opens a fixed item or re-runs the
workflow looking for these.

**Fixed in this pass (8)**
1. Failure path advanced the queue TWICE, regression from the batch-abort fix
2. Install-timer E70 catch stranded the card, kept a stale PID, killed the batch
3. Offload-copy catch orphaned a multi-GB robocopy
4. Window close during an offload copy left that robocopy running
5. `installQueue.Clear()` silently dropped re-queued winget retries
6. Npcap could be swept into an All-view batch, **licence breach risk**
7. Three rooms violated `rooms.json`'s own `_install_order` policy
8. `ERROR-CODES.md` E67 still used the obsolete "Logisim needs OpenJDK" example

**Verified ALREADY FIXED, do not re-open (17)**
offload-temp janitor dead code · original batch-abort · winget 120 s dispatcher
block · uninstall picked FIRST DisplayName match · uninstall-string parser ·
card left stranded on ordinary failure paths · copy-method exit codes judged by
the powershell rule (not robocopy) · room-combo desync (reverts with a
re-entrancy guard) · GP `[uint32]` overflow · dependency strands parent ·
dependency double-install · scan errors classified `Missing` · leftover-files
allowlist aborting on wildcard paths · PKI button logging · verify-retry timer
rebuilding stale indexes · the doc set (Logisim, MATLAB-DEPLOY-NOTES banner,
E61/E21, ShowPreview comment, uninstall-button comment, QUARC prereq) · apps in
no room (was 18 of 39, now 6 of 40, 2 documented + Npcap now flagged)

**Open, a deliberate call (1)**
Two orphaned vendor installers on the drive (NI Package Manager *online*,
Xilinx Unified *web*). Wrong-version risk, not a space problem. See ROADMAP.

**Corrected, not defects (4)**
- `labchart lic.txt` is NOT a leak to purge; it is the licence code the tech
  needs when the interactive LabChart wizard prompts. Keep.
- `passwords.txt`, the legacy 745-line monolithic installer `.bat`, and the
  duplicated top-level helper scripts were all reported on the drive but **are
  not present**, already removed before this pass.

## QC battery findings: FIXED 2026-08-02 (found by the three new test suites)
- **R card's `pathMustMatch` was an invalid regex.** apps.json held
  `(?i)\R\R-`; `\R` is not a .NET escape, so the fallback exe-search for R
  threw the moment it ran on a lab machine (surfacing only as a generic E10
  at scan time). Under-escaped JSON, the OpenJDK card shows the correct
  `\\` convention. Fixed to `(?i)\\R\\R-` (snapshot taken first).
  Caught by `tests\test-configlint.ps1`, which now compiles every regex
  field in the catalog on every run.
- **All-success Install All batches skipped the drain contract.** The install
  timer's success tail dequeued the next app DIRECTLY instead of calling
  Resume-InstallQueue, silently bypassing all three things that only live in
  Resume: the already-installed skip (a dependency chain's early install got
  fully REINSTALLED when its own queue turn came), the `installall.finished`
  ledger, and the batch's closing Verify Shortcuts sweep. Only batches where
  something failed (or hit the verify-retry timer) ever wrote a ledger, which
  is why it looked fine in the field. The tail now routes through
  Resume-InstallQueue, which owns queue advancement (its own stated rule).
  Caught and now locked in by `tests\test-installpipe.ps1` section 7.
- (Same session, test-side: `test-lastbatch` section 2 was still asserting the
  pre-Rail chip contract and `shoot-gui -Tab Fleet` silently shot the Deploy
  tab after the header renames, both updated; `test-e70fix` no longer dies
  when the staging tree is absent, it reads stagingRoot from
  `C:\LabDeployMaster\master-config.json` and SKIPs the 3 staging checks.)
