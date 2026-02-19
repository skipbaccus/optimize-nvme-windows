#Requires -Version 5.1
<#
.SYNOPSIS
    Recovery -- Reverses all NVMe optimizations using the manifest.
.DESCRIPTION
    Reads the manifest created by Phase 1, displays a summary of changes,
    and reverses each one with user confirmation. Handles the case where
    the NVMe drive is no longer available.
.PARAMETER DryRun
    Show what would be undone without making changes.
.PARAMETER Force
    Skip all confirmation prompts (undo everything automatically).
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
Initialize-NVMeOptimizer -LogPath $LogPath -Phase 'undo' -DryRun:$DryRun -Force:$Force

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║     NVMe Optimization -- Undo                    ║' -ForegroundColor Cyan
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

Write-Status 'Checking NVMe drive availability...' -Level Info

$nvmeAvailable  = $false
$undoMode       = 'full'  # full | partial | registryOnly

$guidCheck = Test-VolumeGuid -ExpectedDriveLetter $targetDrive -ExpectedGuid $targetGuid

switch ($guidCheck.Status) {
    'Match' {
        Write-Status "NVMe drive ${targetDrive}: is available" -Level Info
        $nvmeAvailable = $true
    }
    'DriveLetterChanged' {
        $newLetter = $guidCheck.DriveLetter
        Write-Status "NVMe drive letter changed: was ${targetDrive}: now ${newLetter}:" -Level Warning
        $targetDrive   = $newLetter
        $nvmeAvailable = $true
    }
    'NotFound' {
        Write-Host ''
        Write-Host "  NVMe drive ${targetDrive}: (GUID: $targetGuid) is not available." -ForegroundColor Red
        Write-Host '  File-based operations cannot be fully reversed.' -ForegroundColor Red
        Write-Host ''

        if ($Force) {
            $undoMode = 'partial'
            Write-Status 'Using partial undo mode (-Force)' -Level Info
        }
        else {
            $choice = Read-UserChoice -Prompt '  How would you like to proceed?' -Options @(
                'Partial undo -- remove broken junctions, recreate empty dirs, restore registry'
                'Registry only -- restore registry settings only, leave junctions untouched'
                'Abort -- exit without changes'
            )

            switch ($choice) {
                1 { $undoMode = 'partial' }
                2 { $undoMode = 'registryOnly' }
                3 {
                    Write-Status 'Undo aborted by user.' -Level Info
                    exit 0
                }
            }
        }
    }
}

# ── Display summary ──────────────────────────────────────────────────────────

$appliedChanges = @($manifest.changes | Where-Object { $_.status -eq 'Applied' })

if ($appliedChanges.Count -eq 0) {
    Write-Status 'No applied changes found in manifest. Nothing to undo.' -Level Info
    exit 0
}

Write-Host ''
Write-Host '  Changes that will be reversed:' -ForegroundColor Yellow
Write-Host '  ─────────────────────────────────────────────────' -ForegroundColor Gray

foreach ($change in $appliedChanges) {
    $desc = "$($change.component) / $($change.action)"
    if ($change.detail) { $desc += " -- $($change.detail)" }
    Write-Host "  • $desc" -ForegroundColor White
}

Write-Host ''

if (-not $Force -and -not $DryRun) {
    if (-not (Read-UserConfirmation -Prompt '  This will undo all NVMe optimizations. Are you sure?')) {
        Write-Status 'Undo cancelled by user.' -Level Info
        exit 0
    }
}

# ── Process changes in reverse order ─────────────────────────────────────────

$undoneCount  = 0
$skippedCount = 0
$failedCount  = 0

$undoAll = $Force  # If Force, undo everything without per-component prompts

# Reverse the applied changes list
[array]::Reverse($appliedChanges)

foreach ($change in $appliedChanges) {
    Write-Host ''

    # Per-component confirmation (unless Force or user chose "All")
    if (-not $DryRun -and -not $undoAll) {
        Write-Host "  Undo $($change.component) / $($change.action)?" -ForegroundColor Yellow
        Write-Host '  [Y]es  [N]o  [A]ll remaining  [Q]uit' -ForegroundColor Gray
        Write-Host '  Choice: ' -ForegroundColor Yellow -NoNewline
        $response = Read-Host

        switch ($response.Trim().ToUpper()) {
            'N' {
                Write-Status "Skipped: $($change.component) / $($change.action)" -Level Skipped
                $skippedCount++
                continue
            }
            'A' { $undoAll = $true }
            'Q' {
                Write-Status 'Undo stopped by user.' -Level Info
                break
            }
        }
    }

    switch ($change.action) {
        'JunctionCreated' {
            if ($undoMode -eq 'registryOnly') {
                Write-Status "Skipping junction (registry-only mode): $($change.originalPath)" -Level Skipped
                $skippedCount++
                continue
            }

            if ($DryRun) {
                Write-Status "Would remove junction: $($change.originalPath)" -Level DryRun
                if ($nvmeAvailable) {
                    Write-Status "Would move contents back from: $($change.newPath)" -Level DryRun
                }
                else {
                    Write-Status "Would recreate empty directory: $($change.originalPath)" -Level DryRun
                }
                $undoneCount++
            }
            else {
                try {
                    Remove-NVMeJunction -JunctionPath $change.originalPath `
                        -NVMeSourcePath $change.newPath `
                        -NVMeAvailable:$nvmeAvailable
                    $undoneCount++
                }
                catch {
                    Write-Status "Failed to undo junction $($change.originalPath): $($_.Exception.Message)" -Level Failed
                    $failedCount++
                }
            }
        }

        'RegistryModified' {
            $regPath = $change.originalPath
            $origVal = $change.originalValue

            if (-not $origVal) {
                Write-Status "No original value recorded for: $regPath (cannot restore)" -Level Warning
                $skippedCount++
                continue
            }

            if ($DryRun) {
                Write-Status "Would restore registry: $regPath" -Level DryRun
                Write-Status "  Original value: $origVal" -Level DryRun
                $undoneCount++
            }
            else {
                try {
                    # Determine the correct registry path and value name
                    if ($change.component -eq 'Pagefile') {
                        $valueName = 'PagingFiles'
                        # PagingFiles was stored with | separator
                        $pipeSep = '\|'
                        $restoredValue = @($origVal -split $pipeSep)
                        Set-ItemProperty -Path $regPath -Name $valueName -Value $restoredValue -ErrorAction Stop
                        Write-Status "Restored PagingFiles: $origVal" -Level Applied
                    }
                    elseif ($change.component -eq 'SearchIndex') {
                        # Extract value name from path (last segment after \)
                        if ($regPath -match '\\([^\\]+)$') {
                            $valueName = $Matches[1]
                            $parentPath = $regPath -replace '\\[^\\]+$', ''
                        }
                        else {
                            $valueName = 'DataDirectory'
                            $parentPath = $regPath
                        }
                        Set-ItemProperty -Path $parentPath -Name $valueName -Value $origVal -ErrorAction Stop
                        Write-Status "Restored $valueName : $origVal" -Level Applied
                    }

                    $undoneCount++
                }
                catch {
                    Write-Status "Failed to restore registry $regPath : $($_.Exception.Message)" -Level Failed
                    $failedCount++
                }
            }
        }

        'ServiceStopped' {
            # Service restarts on reboot; no action needed during undo
            Write-Status "Service $($change.originalPath) will restart after reboot (no action needed)" -Level Info
        }

        default {
            Write-Status "Unknown action type: $($change.action) -- skipping" -Level Warning
            $skippedCount++
        }
    }
}

# ── Save manifest ────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Save-Manifest
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Cyan
Write-Host '  │  Undo Summary                                    │' -ForegroundColor Cyan
Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Cyan
Write-Host "  Undone   : $undoneCount"  -ForegroundColor Green
Write-Host "  Skipped  : $skippedCount" -ForegroundColor Gray
$failedColor = $(if ($failedCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Failed   : $failedCount"  -ForegroundColor $failedColor
Write-Host ''

$summary = "Undo Summary: Undone=$undoneCount Skipped=$skippedCount Failed=$failedCount Mode=$undoMode"
Write-Log $summary
Write-Log "Undo completed at $(Get-Date -Format 'o')"

if ($DryRun) {
    Write-Status "Dry run complete. Log: $($script:LogFilePath)" -Level Info
    exit 0
}

# ── Reboot prompt ────────────────────────────────────────────────────────────

if ($undoneCount -gt 0) {
    Write-Host ''
    Write-Status 'A reboot is recommended to finalize the undo.' -Level Warning

    if ($Force) {
        Write-Status 'Rebooting now (-Force mode)...' -Level Info
        shutdown /r /t 5 /c "NVMe Optimization -- Undo complete. Rebooting."
    }
    else {
        $doReboot = Read-UserConfirmation -Prompt '  Reboot now?'
        if ($doReboot) {
            shutdown /r /t 5 /c "NVMe Optimization -- Undo complete. Rebooting."
        }
        else {
            Write-Status 'Please reboot manually when ready.' -Level Info
        }
    }
}
