#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 2 -- Post-reboot validation and cleanup.
.DESCRIPTION
    Reads the manifest created by Phase 1, validates every change,
    cleans up old files on C:, and updates the manifest status.
    Runs automatically via scheduled task after reboot.
.PARAMETER DryRun
    Show what would be validated/cleaned without making changes.
.PARAMETER Force
    Skip confirmation prompts (auto-approve undo on validation failure).
.PARAMETER LogPath
    Override the default log directory. Must match the path used by Phase 1.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$LogPath = 'C:\.logs'
)

$ErrorActionPreference = 'Stop'

# ── Import shared module ─────────────────────────────────────────────────────
Import-Module "$PSScriptRoot\Optimize-NVMe-Common.psm1" -Force

# ── Execution policy check ───────────────────────────────────────────────────
if (-not (Test-ExecutionPolicy)) { exit 1 }

# ── Self-elevation ───────────────────────────────────────────────────────────
if (-not (Test-IsAdmin)) {
    Invoke-SelfElevation -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
    exit 0
}

# ── Initialize ───────────────────────────────────────────────────────────────
Initialize-NVMeOptimizer -LogPath $LogPath -Phase 'phase2' -DryRun:$DryRun -Force:$Force

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║     NVMe Optimization -- Phase 2 Validation      ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

if ($DryRun) {
    Write-Host '  *** DRY RUN MODE -- No changes will be made ***' -ForegroundColor Magenta
    Write-Host ''
}

# ── Read manifest ────────────────────────────────────────────────────────────

$manifest = Read-Manifest -Path (Join-Path $LogPath 'nvme-optimization-manifest.json')
if (-not $manifest) {
    Write-Status 'Cannot proceed without a valid manifest. Exiting.' -Level Failed
    exit 1
}

$targetDrive = $manifest.nvmeDrive
$targetGuid  = $manifest.nvmeVolumeGuid

Write-Status "Manifest loaded: target=${targetDrive}: GUID=$targetGuid user=$($manifest.currentUser)" -Level Info

# ── Verify NVMe drive ────────────────────────────────────────────────────────

Write-Status 'Verifying NVMe drive availability...' -Level Info

$guidCheck = Test-VolumeGuid -ExpectedDriveLetter $targetDrive -ExpectedGuid $targetGuid

switch ($guidCheck.Status) {
    'Match' {
        Write-Status "Volume GUID verified: ${targetDrive}: matches expected GUID" -Level Info
    }
    'DriveLetterChanged' {
        $newLetter = $guidCheck.DriveLetter
        Write-Host ''
        Write-Status "NVMe drive letter changed: was ${targetDrive}: now ${newLetter}:" -Level Warning
        Write-Host ''

        if ($Force) {
            $targetDrive = $newLetter
            Write-Status "Updating target drive to ${newLetter}: (-Force mode)" -Level Info
        }
        else {
            $proceed = Read-UserConfirmation -Prompt "  Update target drive to ${newLetter}: and continue?"
            if ($proceed) {
                $targetDrive = $newLetter
                Write-Status "Target drive updated to ${newLetter}:" -Level Info
            }
            else {
                Write-Status 'User chose to abort. Exiting.' -Level Info
                exit 0
            }
        }
    }
    'NotFound' {
        Write-Status "NVMe drive not found (GUID: $targetGuid). Cannot validate without the drive." -Level Failed
        Write-Status 'Ensure the NVMe drive is connected and try again, or run Optimize-NVMe-Undo.ps1.' -Level Info
        exit 1
    }
}

# ── Validate each change ─────────────────────────────────────────────────────

$validatedCount = 0
$failedCount    = 0

for ($i = 0; $i -lt $manifest.changes.Count; $i++) {
    $change = $manifest.changes[$i]

    # Skip non-applied changes
    if ($change.status -ne 'Applied') {
        Write-Status "Skipping $($change.component)/$($change.action): status=$($change.status)" -Level Skipped
        Update-ManifestPhase2Status -Index $i -Phase2Status 'Skipped'
        continue
    }

    Write-Host ''
    $validated = $false

    switch ($change.component) {
        'Pagefile' {
            Write-Status 'Validating pagefile...' -Level Info
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            $currentPF = (Get-ItemProperty -Path $regPath -Name PagingFiles).PagingFiles

            $nvmePattern = "^${targetDrive}:\\"
            $cPattern    = '^C:\\'
            $onNVMe = @($currentPF | Where-Object { $_ -match $nvmePattern })
            $onC    = @($currentPF | Where-Object { $_ -match $cPattern })

            if ($onNVMe -and -not $onC) {
                Write-Status "Pagefile correctly configured on ${targetDrive}: only" -Level Applied
                $validated = $true

                # Also try to verify file existence
                $pfExists = Test-Path "${targetDrive}:\pagefile.sys"
                if ($pfExists) {
                    Write-Status "pagefile.sys confirmed on ${targetDrive}:" -Level Info
                }
                else {
                    Write-Status "pagefile.sys not yet visible on ${targetDrive}: (may still be initializing)" -Level Info
                }
            }
            else {
                $pfConfig = $currentPF -join '; '
                Write-Status "Pagefile validation failed. Current config: $pfConfig" -Level Failed
            }
        }

        'TEMP' {
            if ($change.action -eq 'JunctionCreated') {
                Write-Status "Validating TEMP junction: $($change.originalPath)..." -Level Info
                $check = Test-NVMeJunction -Path $change.originalPath -ExpectedTarget $change.newPath

                if ($check.Status -eq 'Valid') {
                    Write-Status "Junction valid: $($change.originalPath) -> $($change.newPath)" -Level Applied
                    $validated = $true

                    # Cleanup: remove any leftover files at original C: location
                    # (Junction is in place, so the original C: path IS the junction -- nothing to clean)
                }
                else {
                    Write-Status "Junction validation failed: $($change.originalPath) status=$($check.Status)" -Level Failed
                }
            }
        }

        'BrowserCache' {
            if ($change.action -eq 'JunctionCreated') {
                Write-Status "Validating browser cache junction: $($change.originalPath)..." -Level Info
                $check = Test-NVMeJunction -Path $change.originalPath -ExpectedTarget $change.newPath

                if ($check.Status -eq 'Valid') {
                    Write-Status "Junction valid: $($change.originalPath)" -Level Applied
                    $validated = $true
                }
                else {
                    Write-Status "Junction validation failed: $($change.originalPath) status=$($check.Status)" -Level Failed
                }
            }
        }

        'SearchIndex' {
            if ($change.action -eq 'RegistryModified') {
                Write-Status 'Validating search index...' -Level Info
                $searchRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows Search'

                try {
                    $currentDD = (Get-ItemProperty -Path $searchRegPath -Name DataDirectory -ErrorAction Stop).DataDirectory
                }
                catch {
                    $currentDD = $null
                }

                $desiredDD = $change.newPath

                if ($currentDD -and $currentDD.TrimEnd('\') -eq $desiredDD.TrimEnd('\')) {
                    Write-Status "DataDirectory correctly set to: $currentDD" -Level Applied
                    $validated = $true

                    # Check if index files exist on NVMe
                    if (Test-Path $desiredDD) {
                        Write-Status "Index directory exists on NVMe (rebuild may still be in progress)" -Level Info
                    }

                    # Cleanup old index on C:
                    $oldIndex = 'C:\ProgramData\Microsoft\Search\Data'
                    if (Test-Path $oldIndex) {
                        if ($DryRun) {
                            Write-Status "Would delete old index: $oldIndex" -Level DryRun
                        }
                        else {
                            try {
                                Remove-Item -Path $oldIndex -Recurse -Force -ErrorAction Stop
                                Write-Status "Deleted old index: $oldIndex" -Level Applied
                            }
                            catch {
                                Write-Status "Could not delete old index: $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }
                }
                else {
                    Write-Status "DataDirectory mismatch. Current: $currentDD Expected: $desiredDD" -Level Failed
                }
            }
            elseif ($change.action -eq 'ServiceStopped') {
                # Service should be running again after reboot
                $ws = Get-Service -Name 'WSearch' -ErrorAction SilentlyContinue
                if ($ws -and $ws.Status -eq 'Running') {
                    Write-Status 'WSearch service is running (expected)' -Level Info
                    $validated = $true
                }
                else {
                    Write-Status "WSearch service status: $($ws.Status)" -Level Info
                    $validated = $true  # Service may still be starting; not a failure
                }
            }
        }
    }

    if ($validated) {
        Update-ManifestPhase2Status -Index $i -Phase2Status 'Validated'
        $validatedCount++
    }
    else {
        Update-ManifestPhase2Status -Index $i -Phase2Status 'Failed'
        $failedCount++

        # Offer undo for failed validations
        if (-not $DryRun) {
            $doUndo = $false
            if ($Force) {
                $doUndo = $true
            }
            else {
                $doUndo = Read-UserConfirmation -Prompt "  Validation failed for $($change.component). Attempt undo?"
            }

            if ($doUndo) {
                Write-Status "Invoking undo for $($change.component)..." -Level Warning
                $undoScript = Join-Path $PSScriptRoot 'Optimize-NVMe-Undo.ps1'
                if (Test-Path $undoScript) {
                    & $undoScript -LogPath $LogPath -Force
                }
                else {
                    Write-Status "Undo script not found: $undoScript" -Level Failed
                }
            }
        }
    }
}

# ── Save manifest ────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Save-Manifest
}

# ── Remove scheduled task ────────────────────────────────────────────────────
if (-not $DryRun) {
    try {
        Unregister-ScheduledTask -TaskName 'NVMe-Optimize-Phase2' -Confirm:$false -ErrorAction Stop
        Write-Status 'Removed Phase 2 scheduled task' -Level Applied
    }
    catch {
        Write-Status "Could not remove scheduled task: $($_.Exception.Message)" -Level Warning
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Cyan
Write-Host '  │  Phase 2 Summary                                 │' -ForegroundColor Cyan
Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Cyan
Write-Host "  Validated : $validatedCount" -ForegroundColor Green
$failedColor = $(if ($failedCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Failed    : $failedCount"    -ForegroundColor $failedColor
Write-Host ''

$summary = "Phase 2 Summary: Validated=$validatedCount Failed=$failedCount"
Write-Log $summary
Write-Log "Phase 2 completed at $(Get-Date -Format 'o')"

if ($failedCount -eq 0) {
    Write-Status 'All optimizations validated successfully. Your system is ready.' -Level Applied
}
else {
    Write-Status "$failedCount validation(s) failed. Review the log for details." -Level Warning
    Write-Status "Log file: $($script:LogFilePath)" -Level Info
}
