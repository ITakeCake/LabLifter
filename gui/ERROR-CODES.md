# LabLifter, Error Code Reference

Every error in the tool shows a code like `[E21]` on the card / status bar / dialog,
and writes `errorCode=E21` into `logs\*.log`. A tech only needs to report the code
and the app name (e.g. **"E21 on LabVIEW"**) for a remote diagnosis.

**Rule: codes are append-only.** Never renumber or reuse one, new codes get the
next free number in their range. Tens digit = category:

| Range | Category |
|---|---|
| E0x | Startup / config files |
| E1x | Scanning / detection |
| E2x | Install |
| E4x | Uninstall |
| E6x | Environment / prerequisites (the machine, not the drive) |
| E7x | Internal / unexpected |

---

## E0x: Startup / config

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E01 | rooms.json is missing | Incomplete copy to the drive | Recopy `LabDeploy\config\` from staging |
| E02 | apps.json is missing | Incomplete copy to the drive | Recopy `LabDeploy\config\` from staging |
| E03 | A config file is not valid JSON | Someone hand-edited a config and broke it (stray comma/quote/bracket) | Fix the file or replace with a known-good copy |
| E04 | Config missing its apps/rooms section | Config was emptied or wrong file saved over it | Replace with a known-good copy |

## E1x: Scanning / detection

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E10 | Scan failed for one app | Bad `detect` block in apps.json (e.g. invalid pathMustMatch regex) | Only that card is affected; fix that app's detect config |
| E11 | Unattended mode (-Auto) did nothing | Launch-Auto.bat was used on a machine whose hostname matches no room profile or deployment rule | Deliberate safety: the tool won't guess a package set. Pick a room and install by hand, or add a rule for this machine |
| E12 | Background index build failed, slow fallback used | Rare; runspace could not start | Cosmetic (scan is just slower). If constant, send the log |
| E13 | Fleet evidence conflict | Two sticks reported opposite things about one app at the exact same timestamp | Not resolvable from logs alone, run the tool on that machine (or Refresh that app's card) once; the fresh scan settles it |

## E2x: Install

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E20 | Unknown install method in config | Typo in apps.json `method` | Fix the config |
| E21 | Installer source file/folder missing from the drive | Incomplete USB copy, or the app's source folder is absent | Recopy that app's folder from staging |
| E22 | Installer failed to launch | Path/permission problem on this machine | Check the log's error text; try running the installer by hand once |
| E23 | Installer ran but exited with a failure code | Vendor-specific, the exit code is shown in the message | Look up the vendor's exit code; retry once; send the log |
| E24 | Install finished but app not detected afterward | Installer put it somewhere unexpected, or detection paths need updating | Click Refresh on the card; if still red, the app may still be fine, check the Start Menu |
| E25 | winget install failed | winget sources stale, or no internet | Run `winget source update` in a terminal, check internet, retry |
| E26 | MSI fatal error 1603 | Pending reboot, antivirus interference, or a broken earlier install | **Reboot the PC and retry.** If it persists: check AV, uninstall any broken prior copy. Then read `logs\<app>-msi-<machine>-<stamp>.log`, see "Reading an MSI failure" below, it names the action that actually failed |
| E27 | Offload staging copy failed | The copy of a big image to local disk failed (bad sectors, drive yanked) | Not fatal, the tool **automatically fell back** to installing from the drive. If it persists, uncheck "Offload big installers" |
| E28 | Not enough local disk to offload | Target PC doesn't have room for the local copy + install | Not fatal, **fell back** to installing from the drive. Free up space if you want offload's speed |

## E4x: Uninstall

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E40 | No uninstall configured for this app | Expected for some apps | Remove via Programs & Features |
| E41 | Uninstall target folder not found | Already removed | Click Refresh, probably already gone |
| E42 | No uninstaller found in Windows registry | App registers no uninstaller (NI-style) or was never properly installed | Tool opened Programs & Features, remove manually |
| E43 | Registry uninstall entry unusable | Vendor wrote a broken uninstall string | Tool opened Programs & Features, remove manually |
| E44 | Uninstaller failed to launch | Uninstaller exe missing/blocked | Remove via Programs & Features; send the log |
| E45 | Uninstaller exited with a failure code | Vendor uninstaller problem | Retry once; then manual removal |
| E46 | Leftover files outside app's folders, deletion refused | Safety guard: detection found files in a folder this app doesn't own | This is intentional protection. Verify what's at that path before deleting anything by hand |
| E47 | Vendor uninstall manager not found | e.g. NI Package Manager missing on this machine | Remove via Programs & Features, or install NIPM first |
| E48 | MSIX uninstall missing packageName in config | Config gap | Fix apps.json (detect.packageName) |

## E6x: Environment / prerequisites

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E60 | Admin rights required | Tool launched without elevation | Close and relaunch via **Launch.bat** (accept the UAC prompt) |
| E61 | winget is not installed on this machine | Fresh/locked-down account, "App Installer" missing | Click the **winget: MISSING** button to install it from the drive (offline), or skip winget apps (PuTTY) |
| E62 | Another installation is already in progress | Windows Installer is busy, something else is installing (possibly invisibly) | Wait a few minutes and retry. If it never clears: reboot. (Famous 1618) |
| E63 | Disk full / write failure | (Reserved, not yet wired to a specific check) | Check free disk space |
| E64 | winget bootstrap files missing from the drive | `WingetBootstrap` folder was deleted or not copied to this drive | Re-copy `LabDeploy-InstallerSources\WingetBootstrap` from the master drive |
| E65 | winget install failed | The App Installer package refused to install (policy block, corrupted file) | Send `LabDeploy\logs\*.log` back; try installing "App Installer" from the Microsoft Store instead |
| E66 | winget installed but not detected yet | Windows hasn't refreshed the app alias for this session | Log off and back on (or reboot), relaunch the tool, and the button should show green |
| E67 | Required dependency app could not be installed first | An app declares `requires` (Rockwell CCW needs .NET 3.5; RStudio needs R) and the automatic dependency install failed | Install the dependency app manually from its own card, check its error, then retry |
| E68 | Stick update/preview failed | robocopy exited 8+ while mirroring staging onto a USB stick (Master Mode) - drive unplugged mid-copy, full, or write-protected | Re-plug the stick, check free space, hit Rescan Drives and retry |
| E69 | Stick refused: not enough free space | Checked BEFORE copying. A new stick needs the whole staging payload (~55 GB) plus 1 GB headroom; an existing stick needs 2 GB of headroom for the delta | Use a larger USB drive (128 GB+ is comfortable), or free space on the existing one. Nothing was written - the stick is untouched |

## E7x: Internal

| Code | Meaning | Likely cause | What to do |
|---|---|---|---|
| E70 | Unexpected error while monitoring an install/uninstall | Unknown | Send `LabDeploy\logs\*.log` back for analysis |
| E71 | A post-install step did not complete | The app installed fine, but a vendor step that runs afterwards (e.g. Vivado's cable drivers) was missing, timed out, or failed to start | The app itself is usable. For Vivado, run `install_drivers.cmd` by hand from `C:\Xilinx\Vivado\<ver>\data\xicom\cable_drivers\nt64` as admin - without it, JTAG/USB programming cables will not be recognised |
| E72 | ConfigMgr action failed or the run stopped early | A specific client action threw (name + error are now in the log), the applet returned an empty list, or the loop hit an unexpected error | Check `logs\*.log` for `cm.action_failed` / `cm.loop_error` - the action NAME and message are recorded. The WMI fallback fires the 9 standard cycles regardless |
| E73 | Vendor licence code missing | The app's install arguments need a code that lives in `config\licences.json`, and this drive has no such file (or no such key in it). Codes are kept out of `apps.json` so they are never committed to git | On the MASTER, copy `config\licences.example.json` to `config\licences.json` and fill in the real codes, then re-sync the stick. **Nothing was installed** - the check runs before the installer starts, because `LICENCE=` with no code installs an unlicensed product that looks fine until a class opens it |

---

## What is in the logs folder

Everything below lands in `LabDeploy\logs\` on the stick, travels home with it, and
merges into the master ledger. Three kinds of file:

| File | Written by | Read it when |
|---|---|---|
| `LabDeploy_<machine>_<stamp>_<drive>.log` | The tool itself | Always. Every install's exact command line, exit code and outcome |
| `<app>-msi-<machine>-<stamp>.log` | msiexec (`/L*v`), added 2026-08-05 | An MSI card failed, especially on 1603 |
| `<installer>-<machine>.log` | The vendor wrapper scripts | LabVIEW, Logger Pro, Raven Lite, LabChart add-ons, Vernier, BLED112 |

### Reading an MSI failure

MSI exit codes say almost nothing on their own - 1603 is literally "fatal error
during installation". The `/L*v` log says which step broke. Jump straight to the
end and search backwards:

```
findstr /C:"Return value 3" logs\LabChart-msi-10108LAB31-01-*.log
```

`Return value 3` is a failed action, and the action name on the lines just above
it is the actual cause. `Product: ... -- Installation failed` near the end gives
the summary line. Common finds: a file locked by a running copy of the app, a
service that would not stop, or a missing prerequisite.

These logs are verbose (several MB each). The vendor-log cap keeps the newest
two per app per machine and purges the rest, so they cannot fill the stick.

---

*Tip: to find every occurrence of a code in the logs:*
`findstr "errorCode=E21" LabDeploy\logs\*.log`
