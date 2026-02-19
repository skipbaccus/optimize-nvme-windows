# Windows Post-Install NVMe Optimization Specification

## Document Metadata
- **Version:** 4.0
- **Status:** Draft
- **Last Updated:** 2026-02-18

---

## Overview
This specification defines a deterministic, script-driven workflow for relocating high-I/O Windows components to a secondary NVMe drive after OS installation. The goal is to maximize performance on systems where the boot volume is slower than a high-speed NVMe workspace drive.

The workflow must be:
- Fully automatable via PowerShell
- Idempotent (safe to re-run)
- Deterministic (no conditional guessing)
- Safe (no relocation of unsupported Windows components)
- Reversible (manifest-driven undo script provided)
- Inspectable (dry-run mode shows all changes before applying)

---

## System Assumptions
- Windows 10 or Windows 11 (Pro or Workstation)
- Boot drive: C: (any media type)
- Workspace drive: a non-boot NVMe partition (auto-detected; see NVMe Drive Detection)
- Script targets the currently logged-in user only (HKCU changes apply to the running user)
- Script executed with administrative privileges (self-elevates if needed)
- Script is intended for use immediately after Windows setup, before heavy user activity

### Pre-Run Warning
At startup, before making any changes, the script must display a warning that includes:
- List of all operations about to be performed
- Which paths will be created on the NVMe drive
- Confirmation that no user documents or irreplaceable data are in scope (only caches, temp files, and system-managed data that Windows recreates automatically)
- Instruction to save all open files and close applications
- A prompt requiring the user to type `Y` to continue or any other key to exit

In `-DryRun` mode, the warning is displayed but no confirmation prompt is shown (the script proceeds to list all changes and exits).

### PowerShell Execution Policy
The scripts require an execution policy that allows local script execution (e.g., `RemoteSigned` or `Unrestricted`). If the current policy is `Restricted` (the Windows default), the script must:
1. Detect the restriction before failing
2. Display a clear message explaining the issue
3. Provide the exact command to fix it:

   ```
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
4. Exit cleanly (do not auto-modify the execution policy)

---

## NVMe Drive Detection

### Objective
Automatically identify candidate NVMe partitions and prompt the user to select the target before any changes are made.

### Requirements
- Query `MSFT_PhysicalDisk` (namespace: `root\microsoft\windows\storage`) for all disks where `BusType = 17` (NVMe)
- Map each NVMe physical disk to its partitions and logical volumes via the disk-to-partition-to-volume chain
- Display a numbered list of candidate **partitions** showing:
  - Drive letter
  - Volume label
  - Partition size (total)
  - Free space available
- Include C: in the list if it is on an NVMe disk, but if the user selects C:, display the message:

  > "C: is the boot drive and cannot be used as the optimization target. Please select a different drive."

  Then re-display the selection prompt.
- If only one non-boot NVMe partition is detected, display its details and ask the user to confirm it as the target (do not silently auto-select).
- If no non-boot NVMe partitions are detected, exit with message:

  > "No eligible NVMe partitions detected. Exiting."
- If `-NVMeDrive` parameter is provided, skip the interactive selection and use the specified drive letter (still validate it is NVMe and not the boot drive).

### Volume GUID Tracking
- After the user selects a target partition, resolve and store its **Volume GUID** (via `Get-Volume` / `Get-Partition`) alongside the drive letter
- The Volume GUID is recorded in the manifest and used as a fallback identity check
- Phase 2 and Undo scripts must verify that the Volume GUID still matches the expected drive letter before proceeding:
  - If the drive letter matches the stored GUID: proceed normally
  - If the GUID is found at a *different* drive letter: warn the user, display the old and new letters, and ask whether to update and continue or abort
  - If the GUID is not found on any mounted volume: warn that the NVMe drive is not available and handle gracefully (see Undo — NVMe Drive Missing)

### Free Space Validation
- After the user selects a partition, validate that free space >= total installed RAM + 10 GB
  - RAM portion covers the system-managed pagefile
  - 10 GB buffer covers browser caches, temp files, and search index
- If insufficient, exit with message indicating available vs. required space and that the script cannot proceed

---

## Components to Relocate

### 1. Pagefile (pagefile.sys)

**Objective:** Move the paging file from C: to the NVMe drive.

**Criticality: HIGH — if this step fails, Phase 1 must abort entirely.**

**Requirements:**
- Disable pagefile on C:
- Create pagefile on `$NVMeDrive` with size set to system-managed
- Registry key: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management`
- Value: `PagingFiles` (REG_MULTI_SZ)
- Change takes effect on reboot (deferred — no immediate reboot)

**Idempotency:**
- If pagefile is already configured solely on `$NVMeDrive`: log as Skipped
- If pagefile exists on both C: and `$NVMeDrive`: remove C: entry only, log as Partial Fix Applied
- If pagefile is on C: only: apply full change, log as Applied

**Known Limitation — hiberfil.sys:**
- `hiberfil.sys` (hibernation file) cannot be moved to a non-boot drive. The Windows bootloader reads it before storage drivers for secondary drives are loaded. It will remain on C: permanently. This is a firmware-level constraint, not a script limitation.

**Phase 2 (post-reboot):**
- Confirm pagefile.sys exists on `$NVMeDrive` and does not exist on C:
- Log result; no cleanup required (pagefile.sys is system-managed)

---

### 2. TEMP and TMP Directories (System + User)

**Objective:** Redirect all temporary file I/O to the NVMe drive using NTFS junctions.

**Criticality: NORMAL — if this step fails, log and continue to next component.**

**Target Paths (mirroring C: structure):**

| Original Path | NVMe Target |
|---|---|
| `C:\Windows\Temp` | `$NVMeDrive:\Windows\Temp` |
| `C:\Users\<User>\AppData\Local\Temp` | `$NVMeDrive:\Users\<User>\AppData\Local\Temp` |

**Note on `C:\Windows\Temp`:** This is an intentional exception to the Out of Scope rule for `C:\Windows`. Only the `Temp` subdirectory is modified (via junction). The junction is transparent to the OS and applications. Compatibility with early-boot services and antivirus software will be validated during testing.

**Requirements:**
- Create target directories on `$NVMeDrive` if they do not exist
- For each path:
  1. Attempt to move existing contents to NVMe target (skip locked files, log each one)
  2. Delete the original directory on C:
  3. Create NTFS junction at original path pointing to NVMe target
- No environment variable changes are required — junctions redirect transparently
- Both system TEMP and user TEMP are always redirected (not independently toggleable)

**Idempotency:**
- If junction already exists at original path and points to correct NVMe target: log as Skipped
- If junction exists but points to wrong target: log as Warning, exit — do not silently overwrite

**Phase 2 (post-reboot):**
- Validate each junction resolves to the correct NVMe path
- Delete any residual files that were locked during Phase 1 and could not be moved
- Log result

---

### 3. Browser Caches

**Objective:** Redirect browser cache directories to the NVMe drive using NTFS junctions.

**Criticality: NORMAL — if this step fails for any browser, log and continue to the next browser/component.**

**Supported Browsers:**
- Microsoft Edge (Chromium)
- Google Chrome
- Mozilla Firefox

**Detection:**
- Detect installed browsers via registry install keys only (not file system):
  - Edge: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`
  - Chrome: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe`
  - Firefox: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe`
- If a browser is not installed, skip it and log as Not Installed (do not pre-seed policy keys)
- Script can be re-run after installation to apply settings for newly installed browsers

**Running Process Detection:**
- Before touching any browser's cache, detect if the browser process is running
- If running: warn the user and offer two options:
  1. Script kills the process and proceeds
  2. User closes it manually and presses any key to continue
- If the browser cannot be closed, skip that browser and log as Skipped (Process Running)
- In `-Force` mode: kill processes automatically without prompting
- In `-DryRun` mode: report running processes but take no action

**Cache Directories (all profiles, mirroring C: structure):**

For each browser, enumerate all user profile directories (Default, Profile 1, Profile 2, etc.) and apply junctions to each cache subdirectory listed below.

**Chromium Browsers (Edge and Chrome):**

| Cache Directory | Description |
|---|---|
| `<Profile>\Cache` | Main HTTP cache |
| `<Profile>\Code Cache` | Compiled JavaScript/WASM cache |
| `<Profile>\GPUCache` | GPU shader cache |
| `<Profile>\Service Worker\CacheStorage` | Service worker cached assets |
| `<Profile>\Service Worker\ScriptCache` | Service worker compiled scripts |

Base paths:
- Edge: `C:\Users\<User>\AppData\Local\Microsoft\Edge\User Data\`
- Chrome: `C:\Users\<User>\AppData\Local\Google\Chrome\User Data\`

**Firefox:**

| Cache Directory | Description |
|---|---|
| `<Profile>\cache2` | Main HTTP cache |
| `<Profile>\startupCache` | Startup cache |

Base path: `C:\Users\<User>\AppData\Local\Mozilla\Firefox\Profiles\`

**NVMe targets mirror the C: structure.** For example:
- `C:\Users\<User>\AppData\Local\Google\Chrome\User Data\Default\Cache`
- becomes: `$NVMeDrive:\Users\<User>\AppData\Local\Google\Chrome\User Data\Default\Cache`

**Junction Mechanism (applies to all cache directories):**
1. Create NVMe target directory
2. Move existing cache contents to NVMe target
3. Delete original cache directory on C:
4. Create NTFS junction at original path pointing to NVMe target

**Idempotency:**
- If junction already exists and points to correct NVMe target: log as Skipped
- If junction exists but points to wrong target: log as Warning, exit — do not silently overwrite

**Phase 2 (post-reboot):**
- Validate all junctions resolve to correct NVMe paths
- Delete any residual files from Phase 1 that could not be moved
- Log result per browser and per profile

---

### 4. Windows Search Index

**Objective:** Relocate the Windows Search index database to the NVMe drive.

**Criticality: NORMAL — if this step fails, log and continue.**

**Registry Configuration:**
- Key: `HKLM\SOFTWARE\Microsoft\Windows Search`
- Value: `DataDirectory` (REG_SZ)
- New value: `$NVMeDrive:\ProgramData\Microsoft\Search\Data\`
- To force a clean rebuild: set `SetupCompletedSuccessfully` (DWORD) to `0` in the same key

**Approach: Always Rebuild (Never Move)**
- Moving a live index is unreliable and can result in corruption
- The script will always configure the new path and set `SetupCompletedSuccessfully = 0`
- Windows will rebuild the index from scratch after reboot
- This is the safe, guaranteed-clean approach

**Phase 1 Steps:**
1. Stop the Windows Search service (`WSearch`)
2. Record the current `DataDirectory` value as `originalValue` in the manifest
3. Update `DataDirectory` to NVMe target path
4. Set `SetupCompletedSuccessfully = 0`
5. Do NOT restart the service — reboot at end of Phase 1 handles this

**User Information (not a warning):**
- Inform the user during Phase 1 that the Windows Search index will rebuild after reboot
- Rebuild can take minutes to hours depending on the number of indexed files
- Search functionality will be degraded until rebuild completes; this is expected

**Idempotency:**
- If `DataDirectory` already points to correct NVMe path: log as Skipped

**Phase 2 (post-reboot):**
- Validate `DataDirectory` registry value points to NVMe path
- Validate `$NVMeDrive:\ProgramData\Microsoft\Search\Data\` directory exists and contains index files
- Delete `C:\ProgramData\Microsoft\Search\Data` if it still exists (old index)
- Log result

---

## Script Architecture

### Script Inventory

| Script | Purpose | Requires Admin |
|---|---|---|
| `Optimize-NVMe.ps1` | Phase 1 — all configuration changes, registers Phase 2 task, reboots | Yes — self-elevates |
| `Optimize-NVMe-Validate.ps1` | Phase 2 — post-reboot validation and cleanup, runs via scheduled task | Yes — self-elevates |
| `Optimize-NVMe-Undo.ps1` | Recovery — reads manifest, reverses all changes with user confirmation | Yes — self-elevates |
| `Optimize-NVMe-Common.psm1` | Shared module — imported by all three scripts | N/A (not run directly) |

All three scripts must self-elevate via UAC at startup if not already running as Administrator. The elevation must use the same PowerShell executable that invoked the script (to handle both `powershell` and `pwsh`):
```powershell
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process (Get-Process -Id $PID).Path -ArgumentList "-File `"$PSCommandPath`"" -Verb RunAs
    exit
}
```

### Script Parameters

**Optimize-NVMe.ps1:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DryRun` | Switch | `$false` | Show all changes that would be made without applying them. Writes a dry-run log. No reboot. |
| `-Force` | Switch | `$false` | Skip all confirmation prompts (pre-run warning, browser kill, reboot). Use for fully unattended execution. |
| `-NVMeDrive` | String | Auto-detect | Override NVMe auto-detection with a specific drive letter (e.g., `-NVMeDrive D`). Still validates it is NVMe and not the boot drive. |
| `-LogPath` | String | `C:\.logs\` | Override the default log and manifest directory. |

**Optimize-NVMe-Validate.ps1:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DryRun` | Switch | `$false` | Show what would be validated and cleaned up without making changes. |
| `-Force` | Switch | `$false` | Skip confirmation prompts (auto-approve undo on validation failure). |
| `-LogPath` | String | `C:\.logs\` | Override the default log directory. Must match the path used by Phase 1 to find the manifest. |

**Optimize-NVMe-Undo.ps1:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DryRun` | Switch | `$false` | Show what would be undone without making changes. |
| `-Force` | Switch | `$false` | Skip all confirmation prompts (undo everything without per-component prompts). |
| `-LogPath` | String | `C:\.logs\` | Override the default log directory. Must match the path used by Phase 1 to find the manifest. |

### Dry-Run Mode

When any script is invoked with `-DryRun`:
- **No changes are made** to the filesystem, registry, services, or scheduled tasks
- **No reboot** is triggered
- The script runs through its entire logic, evaluating every condition and decision point
- Each action that *would* be taken is printed to the console with a `[DRYRUN]` prefix
- A dry-run log file is written to the log directory with the naming format: `nvme-optimize-<phase>-dryrun-<YYYYMMDD-HHmmss>.log`
- NVMe detection, free space checks, and idempotency checks all run normally (these are read-only)
- The manifest is **not** created or modified during dry-run

**Console output example:**
```
[DRYRUN] Would disable pagefile on C:
[DRYRUN] Would set PagingFiles to "D:\pagefile.sys" (system-managed)
[DRYRUN] Would create directory: D:\Windows\Temp
[DRYRUN] Would move contents: C:\Windows\Temp → D:\Windows\Temp
[DRYRUN] Would create junction: C:\Windows\Temp → D:\Windows\Temp
[DRYRUN] Would stop service: WSearch
[DRYRUN] Would set DataDirectory to "D:\ProgramData\Microsoft\Search\Data\"
...
```

### Shared Module: Optimize-NVMe-Common.psm1

All three scripts import a shared PowerShell module to avoid code duplication.

**Import mechanism** (at the top of each script):
```powershell
Import-Module "$PSScriptRoot\Optimize-NVMe-Common.psm1" -Force
```

**Exported functions:**

| Function | Purpose |
|---|---|
| `Test-IsAdmin` | Check if current session has admin privileges |
| `Invoke-SelfElevation` | Re-launch the script elevated via UAC |
| `Test-ExecutionPolicy` | Check execution policy and display fix instructions if restricted |
| `Get-NVMePartitions` | Query WMI for NVMe partitions, return drive letter + label + size + free space |
| `Resolve-VolumeGuid` | Get Volume GUID for a given drive letter |
| `Test-VolumeGuid` | Verify a Volume GUID matches the expected drive letter; return status |
| `Test-FreeSpace` | Validate free space meets minimum (RAM + 10 GB) |
| `New-NVMeJunction` | Create an NTFS junction with full move-delete-link workflow |
| `Remove-NVMeJunction` | Remove a junction and restore the original directory |
| `Test-NVMeJunction` | Check if a junction exists and points to the correct target |
| `Read-Manifest` | Load manifest from JSON |
| `Write-Manifest` | Write or update manifest to JSON |
| `Backup-Manifest` | Back up existing manifest with timestamp |
| `Write-Log` | Write a log entry to file and optionally to console |
| `Write-Status` | Write colored console output (green=success, yellow=warning, red=error, cyan=info, magenta=dryrun) |
| `Get-InstalledBrowsers` | Query registry for installed browser paths |
| `Get-BrowserProfiles` | Enumerate all profile directories for a given browser |
| `Test-ProcessRunning` | Check if a named process is running |
| `Stop-BrowserProcess` | Kill a browser process by name |

### Console Output

All scripts use colored output for readability:

| Color | Meaning | Prefix |
|---|---|---|
| Green | Success / Applied | `[APPLIED]` |
| Yellow | Warning / Attention needed | `[WARNING]` |
| Red | Error / Failure | `[FAILED]` |
| Cyan | Informational | `[INFO]` |
| Gray | Skipped / No action needed | `[SKIPPED]` |
| Magenta | Dry-run (would-be action) | `[DRYRUN]` |

### Manifest File

**Location:** `$LogPath\nvme-optimization-manifest.json` (default: `C:\.logs\nvme-optimization-manifest.json`)

**Purpose:** Single source of truth for all three scripts. Records every change made during Phase 1 so Phase 2 can validate and Undo can reverse.

**Re-Run Behavior:** If Phase 1 detects an existing manifest at startup, it must:
1. Back up the existing manifest as `nvme-optimization-manifest-<YYYYMMDD-HHmmss>.json.bak`
2. Log that a backup was created
3. Create a fresh manifest for the current run
4. Previous backups are preserved in the log directory for manual recovery if needed

**Schema:**
```json
{
  "version": "1.0",
  "timestamp": "ISO-8601 datetime",
  "nvmeDrive": "D",
  "nvmeVolumeGuid": "\\\\?\\Volume{GUID}\\",
  "currentUser": "username",
  "logPath": "C:\\.logs",
  "dryRun": false,
  "changes": [
    {
      "component": "Pagefile | TEMP | BrowserCache | SearchIndex",
      "action": "JunctionCreated | RegistryModified | FileMoved | ServiceStopped",
      "originalPath": "original path or registry key",
      "originalValue": "original registry value or null for junctions",
      "newPath": "new path or value",
      "status": "Applied | Skipped | Failed",
      "detail": "human-readable description of what was done",
      "phase2Status": "Pending | Validated | CleanedUp | Failed"
    }
  ]
}
```

### General Requirements
- Must run as Administrator (self-elevate)
- Must check PowerShell execution policy and instruct the user if it blocks execution
- Must validate NVMe drive presence and free space before any changes
- Must be idempotent (safe to re-run)
- Must fail safely — see Error Handling Strategy
- Must update manifest after each individual change (not batched at the end)

### Error Handling Strategy

Components are classified into two criticality tiers:

| Tier | Component | On Failure |
|---|---|---|
| **Critical** | Pagefile | Abort Phase 1 entirely. Log the failure. Do not proceed to other components. Do not reboot. |
| **Normal** | TEMP/TMP, Browser Caches, Search Index | Log the failure, mark as Failed in manifest, continue to the next component. |

Rationale: Pagefile relocation provides the largest performance impact and involves the fewest moving parts. If this straightforward registry change fails, it signals a deeper system issue that warrants investigation before continuing.

### Logging Requirements

**Log location:** `$LogPath` (default: `C:\.logs\`, created if it does not exist)

**Log filename format:** `nvme-optimize-<phase>-<YYYYMMDD-HHmmss>.log`
**Dry-run log format:** `nvme-optimize-<phase>-dryrun-<YYYYMMDD-HHmmss>.log`

**Each log must record:**
- Script name and version
- Parameters used (including DryRun, Force, NVMeDrive, LogPath)
- Start and end timestamps
- Detected drives and selected NVMe target (drive letter + Volume GUID)
- Current user
- Per-component status:
  - `[APPLIED]` — change successfully made
  - `[SKIPPED]` — already correctly configured
  - `[INFO]` — informational, no action taken
  - `[WARNING]` — unexpected state detected; user intervention may be needed
  - `[FAILED]` — error with reason and exception detail
  - `[DRYRUN]` — change that would be made (dry-run mode only)
- Final summary line: count of Applied, Skipped, Info, Warning, Failed (or DryRun)

### Reboot Strategy

**One reboot only, at the very end of Phase 1.**

Phase 1 execution order is designed so all changes can be made before a reboot:
1. Pagefile — registry change only (deferred, takes effect on reboot) — **Critical: abort if failed**
2. TEMP/TMP — junctions (no reboot needed)
3. Browser caches — junctions (no reboot needed)
4. Search index — registry change + service stop (deferred, rebuilds after reboot)

Before reboot:
- Register `Optimize-NVMe-Validate.ps1` as a one-time scheduled task:
  - Trigger: at next logon for the current user
  - Principal: current user with `RunLevel = Highest` (ensures HKCU access and admin privileges)
  - Delete task after successful run
- Display final message listing all changes applied and informing user that the machine will reboot in 60 seconds (with option to cancel and reboot manually)
- In `-Force` mode: reboot immediately without countdown
- In `-DryRun` mode: no reboot, no scheduled task registration

### Phase 2: Optimize-NVMe-Validate.ps1

Runs automatically after reboot via scheduled task.

**Steps:**
1. Self-elevate if needed
2. Read manifest from `$LogPath\nvme-optimization-manifest.json`
3. Verify NVMe drive is available by checking the Volume GUID against the expected drive letter
   - If drive letter changed: warn and offer to update or abort
   - If NVMe not found: warn and exit (cannot validate without the drive)
4. For each change in the manifest, run the appropriate validation check
5. For each validated change, perform cleanup (delete old C: remnants)
6. If any validation fails:
   - Log as `[FAILED]`
   - Display a prompt: "Validation failed for [component]. Would you like to attempt undo? (Y/N)"
   - In `-Force` mode: auto-approve undo
   - If Y: invoke `Optimize-NVMe-Undo.ps1` for that component
   - If N: log and continue
7. Update `phase2Status` in manifest for each entry
8. Write Phase 2 log to `$LogPath`
9. Remove scheduled task on completion

### Phase 3: Optimize-NVMe-Undo.ps1

Standalone recovery script. Can be run at any time by the user.

**Steps:**
1. Self-elevate if needed
2. Read manifest from `$LogPath\nvme-optimization-manifest.json`
3. Verify NVMe drive availability via Volume GUID (see NVMe Drive Missing below)
4. Display a summary of all changes that would be reversed
5. Prompt: "This will undo all NVMe optimizations. Are you sure? (Y/N)"
   - In `-Force` mode: skip this prompt
6. For each manifest entry in **reverse order**:
   - Display what will be undone
   - Prompt: "Undo [component]? (Y/N/All/Quit)"
   - In `-Force` mode: undo all without per-component prompts
   - Execute reversal based on action type:
     - `JunctionCreated`: remove junction, move files back from NVMe to original C: path, restore original directory
     - `RegistryModified`: restore `originalValue` from manifest to the original registry key
     - `FileMoved`: move files back from NVMe to original C: path
   - Log result
7. Prompt user to reboot after undo completes

**NVMe Drive Missing:**

If the NVMe Volume GUID is not found on any mounted volume, the undo script must handle this gracefully:
1. Display warning: "NVMe drive [letter] (Volume GUID: [guid]) is not available. File-based operations cannot be reversed."
2. Offer three options:
   - **Partial undo** — remove broken junctions and recreate empty original directories on C:, restore all registry settings
   - **Registry only** — restore registry settings only, leave junctions untouched
   - **Abort** — exit without making changes
3. In `-Force` mode: auto-select Partial undo
4. Log which operations were reversed and which were skipped due to missing drive

---

## Testing Strategy

### Overview
Testing is split into two tiers: automated unit tests (run in any environment) and manual integration tests (require a real system with an NVMe drive).

### Automated Tests (Pester)

All shared module functions are tested using Pester (PowerShell's testing framework) with mocked dependencies. Tests live in the `tests/` directory.

**Test file naming:** `<FunctionGroup>.Tests.ps1`

**What is mocked:**
- WMI/CIM calls (`MSFT_PhysicalDisk`, `Get-Volume`, `Get-Partition`)
- Registry reads and writes (`Get-ItemProperty`, `Set-ItemProperty`, `New-ItemProperty`)
- Filesystem operations (`New-Item`, `Remove-Item`, `Move-Item`, `Test-Path`, `Get-Item`)
- Service management (`Get-Service`, `Stop-Service`)
- Process management (`Get-Process`, `Stop-Process`)
- Scheduled task management (`Register-ScheduledTask`, `Unregister-ScheduledTask`)

**Test categories:**

| Category | Tests |
|---|---|
| NVMe Detection | Finds NVMe disks, maps to partitions, excludes C:, handles no-NVMe scenario |
| Volume GUID | Resolves GUID, detects drive letter changes, detects missing drive |
| Free Space | Passes when sufficient, fails when insufficient, calculates RAM + 10 GB correctly |
| Pagefile | Registry reads/writes, idempotency (already on NVMe, on both, on C: only) |
| TEMP Junctions | Junction creation, idempotency, wrong-target detection, locked file handling |
| Browser Detection | Finds installed browsers, handles missing browsers, enumerates all profiles |
| Browser Cache Junctions | All cache subdirectories handled, per-browser per-profile coverage |
| Search Index | DataDirectory read/write, SetupCompletedSuccessfully flag, service stop |
| Manifest | Create, read, backup on re-run, schema validation, phase2Status updates |
| Logging | Log file creation, all status prefixes, summary line |
| Dry-Run | No side effects for every component, correct [DRYRUN] output |
| Force Mode | All prompts skipped, auto-kill processes, auto-reboot |
| Undo | Reverse each action type, restore originalValue, handle missing NVMe |
| Elevation | Detects admin, detects non-admin, correct re-launch executable |
| Execution Policy | Detects Restricted, displays correct instructions |

**Running tests:**
```powershell
Invoke-Pester ./tests -Output Detailed
```

### Manual Integration Tests

These require a real Windows system with a secondary NVMe drive. Run after all Pester tests pass.

| # | Test | Expected Result |
|---|---|---|
| 1 | Run `Optimize-NVMe.ps1 -DryRun` | All changes listed with `[DRYRUN]`, no modifications made, dry-run log created, no reboot |
| 2 | Run `Optimize-NVMe.ps1` on clean system | All components applied, manifest created, scheduled task registered, system reboots |
| 3 | After reboot: validate Phase 2 ran | Phase 2 log exists, manifest updated, scheduled task removed, old C: remnants cleaned up |
| 4 | Run `Optimize-NVMe.ps1` again (idempotency) | All components report Skipped, previous manifest backed up, no reboot needed |
| 5 | Run `Optimize-NVMe-Undo.ps1 -DryRun` | All reversals listed with `[DRYRUN]`, no modifications made |
| 6 | Run `Optimize-NVMe-Undo.ps1` | All junctions removed, registry restored, original directories recreated, user prompted to reboot |
| 7 | After undo reboot: verify clean state | Pagefile on C:, no junctions remain, search index on C:, TEMP dirs on C: |
| 8 | Run with `-Force` flag | No prompts, fully unattended, all changes applied |
| 9 | Run with `-NVMeDrive X` (invalid) | Graceful error: "X: is not an NVMe partition" |
| 10 | Run on system with no NVMe | Graceful exit: "No eligible NVMe partitions detected" |
| 11 | Run with browser open | Detects running browser, offers kill option |
| 12 | Remove NVMe drive, run Undo | Graceful handling: offers partial undo, registry-only, or abort |

---

## Out of Scope

The following must **not** be relocated or modified:

| Item | Reason |
|---|---|
| `C:\Windows` (except `C:\Windows\Temp`) | Core OS files. The `Temp` subdirectory is an intentional exception — see Section 2. Antivirus and early-boot service compatibility with this junction will be validated during testing. |
| `C:\Program Files` / `Program Files (x86)` | Application binaries |
| `C:\Users\<User>` (entire profile) | User data |
| WinSxS | Windows component store; cannot be moved |
| System32 | Core OS directory |
| Registry hives outside documented keys | Risk of system instability |
| `hiberfil.sys` | Must reside on boot volume; bootloader reads it before secondary drive drivers load |

---

## Future Enhancements (v2 Candidates)

The following are explicitly out of scope for v1 but are valid candidates for future versions:

- Relocate OneDrive cache
- Relocate Windows Update download cache (`C:\Windows\SoftwareDistribution\Download`)
- Relocate Visual Studio intermediate build directories
- Relocate Docker data root
- Relocate WSL VHDX files

---

## Acceptance Criteria

### Phase 1 Complete (`Optimize-NVMe.ps1`)
- [ ] Script detected execution policy and either proceeded or instructed the user to fix it
- [ ] Script self-elevated to Administrator successfully
- [ ] NVMe partition(s) detected and listed with size and free space
- [ ] User selected a non-boot NVMe partition and confirmed (or `-NVMeDrive` accepted)
- [ ] Volume GUID resolved and stored for the selected partition
- [ ] Free space validated as sufficient (>= installed RAM + 10 GB)
- [ ] Pre-run warning displayed; user confirmed to proceed (skipped in `-Force` mode)
- [ ] Pagefile registry configured for NVMe; C: pagefile disabled
- [ ] TEMP/TMP junctions created for system and user paths
- [ ] Browser cache junctions created for all detected browsers, all profiles, and all cache subdirectories
- [ ] Windows Search `DataDirectory` updated; `SetupCompletedSuccessfully` set to 0
- [ ] Log directory exists
- [ ] Phase 1 log written with all parameters recorded
- [ ] Manifest written to log directory (existing manifest backed up if present)
- [ ] Manifest contains Volume GUID, `originalValue` for all registry changes, and `logPath`
- [ ] `Optimize-NVMe-Validate.ps1` registered as scheduled task for current user at next logon with highest privileges
- [ ] System rebooted (or reboot scheduled with user acknowledgment)
- [ ] If pagefile step failed: Phase 1 aborted, no reboot, failure logged
- [ ] If any normal component failed: logged, marked Failed in manifest, remaining components still processed

### Phase 1 Dry-Run (`-DryRun`)
- [ ] All checks and evaluations performed (NVMe detection, free space, idempotency)
- [ ] Every would-be action printed with `[DRYRUN]` prefix
- [ ] Dry-run log written to log directory
- [ ] No filesystem, registry, service, or scheduled task changes made
- [ ] No manifest created or modified
- [ ] No reboot triggered

### Phase 2 Complete (`Optimize-NVMe-Validate.ps1`)
- [ ] Script ran automatically after reboot via scheduled task
- [ ] Script self-elevated to Administrator successfully
- [ ] Volume GUID verified against expected drive letter
- [ ] Pagefile.sys confirmed present on NVMe; absent from C:
- [ ] TEMP/TMP junctions confirmed pointing to correct NVMe targets
- [ ] Browser cache junctions confirmed pointing to correct NVMe targets for all profiles and all cache subdirectories
- [ ] Windows Search DataDirectory confirmed pointing to NVMe path
- [ ] Windows Search index files confirmed present on NVMe
- [ ] Old `C:\ProgramData\Microsoft\Search\Data` deleted
- [ ] Residual locked files from Phase 1 cleaned up
- [ ] Manifest `phase2Status` updated to `Validated` or `CleanedUp` for all entries
- [ ] Phase 2 log written to log directory
- [ ] Scheduled task removed
- [ ] System boots cleanly and is ready for normal use

### Undo Complete (`Optimize-NVMe-Undo.ps1`)
- [ ] Script self-elevated to Administrator successfully
- [ ] Manifest read successfully from log directory
- [ ] Volume GUID check performed; missing-drive scenario handled gracefully if applicable
- [ ] User presented with full summary of changes to be reversed (skipped in `-Force` mode)
- [ ] User confirmed undo per component (or all, or `-Force` auto-approved)
- [ ] All selected junctions removed and original directories restored (or empty directories created if NVMe unavailable)
- [ ] All selected registry keys restored to `originalValue` from manifest
- [ ] Undo log written to log directory
- [ ] User prompted to reboot

### Manifest File
- [ ] `nvme-optimization-manifest.json` exists in log directory after Phase 1
- [ ] Contains schema `version` field
- [ ] Contains Volume GUID for the selected NVMe partition
- [ ] Contains `originalValue` for every registry modification
- [ ] Contains `detail` field for every change with human-readable description
- [ ] Contains `logPath` used during this run
- [ ] Contains an entry for every change attempted (Applied, Skipped, or Failed)
- [ ] `phase2Status` populated for each entry after Phase 2 runs
- [ ] Previous manifest backed up with timestamp if Phase 1 was re-run
- [ ] File remains intact and is not deleted by any script (preserved for audit/undo)
- [ ] Not created or modified during dry-run

### Automated Tests
- [ ] All Pester test categories pass
- [ ] Every shared module function has at least one test
- [ ] Dry-run mode produces zero side effects across all components
- [ ] Force mode skips all prompts across all scripts
- [ ] Undo correctly reverses every action type including missing-NVMe scenario
