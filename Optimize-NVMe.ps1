#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 1 -- Relocate high-I/O Windows components to a secondary NVMe drive.
.DESCRIPTION
    Configures pagefile, TEMP directories, browser caches, and Windows Search
    index to use an NVMe drive instead of the boot drive (C:).
.PARAMETER DryRun
    Show all changes that would be made without applying them.
.PARAMETER Force
    Skip all confirmation prompts for fully unattended execution.
.PARAMETER NVMeDrive
    Override NVMe auto-detection with a specific drive letter (e.g., D).
.PARAMETER LogPath
    Override the default log and manifest directory (default: C:\.logs).
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$NVMeDrive,
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
Initialize-NVMeOptimizer -LogPath $LogPath -Phase 'phase1' -DryRun:$DryRun -Force:$Force

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║     NVMe Optimization -- Phase 1                 ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

if ($DryRun) {
    Write-Host '  *** DRY RUN MODE -- No changes will be made ***' -ForegroundColor Magenta
    Write-Host ''
}

# ── Counters ─────────────────────────────────────────────────────────────────
$counts = @{ Applied = 0; Skipped = 0; Info = 0; Warning = 0; Failed = 0; DryRun = 0 }

function Update-Count {
    param([string]$Status)
    switch ($Status) {
        'Applied' { $counts.Applied++ }
        'Skipped' { $counts.Skipped++ }
        'Failed'  { $counts.Failed++  }
        'DryRun'  { $counts.DryRun++  }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: NVMe Drive Detection
# ══════════════════════════════════════════════════════════════════════════════

Write-Status 'Detecting NVMe drives...' -Level Info

$nvmePartitions = Get-NVMePartitions

if (-not $nvmePartitions -or $nvmePartitions.Count -eq 0) {
    Write-Status 'No eligible NVMe partitions detected. Exiting.' -Level Failed
    exit 1
}

# Display detected partitions
Write-Host ''
Write-Host '  Detected NVMe partitions:' -ForegroundColor White
Write-Host '  ─────────────────────────────────────────────────' -ForegroundColor Gray
Write-Host ('  {0,-5} {1,-8} {2,-20} {3,-12} {4,-12}' -f '#', 'Drive', 'Label', 'Size (GB)', 'Free (GB)') -ForegroundColor Gray

$idx = 0
foreach ($p in $nvmePartitions) {
    $idx++
    $bootTag = $(if ($p.IsBootDrive) { ' [BOOT]' } else { '' })
    Write-Host ('  {0,-5} {1,-8} {2,-20} {3,-12} {4,-12}' -f "[$idx]", "$($p.DriveLetter):$bootTag", $p.Label, $p.SizeGB, $p.FreeSpaceGB)
}
Write-Host ''

# Select target drive
$selectedPartition = $null

if ($NVMeDrive) {
    # User provided via parameter
    $selectedPartition = $nvmePartitions | Where-Object { $_.DriveLetter -eq $NVMeDrive }
    if (-not $selectedPartition) {
        Write-Status "${NVMeDrive}: is not an NVMe partition. Exiting." -Level Failed
        exit 1
    }
    if ($selectedPartition.IsBootDrive) {
        Write-Status 'C: is the boot drive and cannot be used as the optimization target. Exiting.' -Level Failed
        exit 1
    }
}
else {
    # Interactive selection
    $nonBootPartitions = @($nvmePartitions | Where-Object { -not $_.IsBootDrive })

    if ($nonBootPartitions.Count -eq 0) {
        Write-Status 'No non-boot NVMe partitions available. Exiting.' -Level Failed
        exit 1
    }

    if ($nonBootPartitions.Count -eq 1 -and $nvmePartitions.Count -eq 1) {
        # Only one NVMe partition total and it's not boot
        $selectedPartition = $nonBootPartitions[0]
        Write-Host "  Only one NVMe partition found: $($selectedPartition.DriveLetter): ($($selectedPartition.Label))" -ForegroundColor White
        if (-not $Force) {
            if (-not (Read-UserConfirmation -Prompt '  Use this partition?')) {
                Write-Status 'User cancelled. Exiting.' -Level Info
                exit 0
            }
        }
    }
    else {
        # Multiple partitions -- interactive selection
        while (-not $selectedPartition) {
            if ($Force) {
                # In force mode, pick the non-boot partition with the most free space
                $selectedPartition = $nonBootPartitions | Sort-Object FreeSpace -Descending | Select-Object -First 1
            }
            else {
                Write-Host '  Enter the number of the partition to use: ' -ForegroundColor Yellow -NoNewline
                $choice = Read-Host
                $choiceIdx = 0
                if ([int]::TryParse($choice, [ref]$choiceIdx) -and $choiceIdx -ge 1 -and $choiceIdx -le $nvmePartitions.Count) {
                    $pick = $nvmePartitions[$choiceIdx - 1]
                    if ($pick.IsBootDrive) {
                        Write-Host '  C: is the boot drive and cannot be used as the optimization target. Please select a different drive.' -ForegroundColor Red
                    }
                    else {
                        $selectedPartition = $pick
                    }
                }
                else {
                    Write-Host "  Invalid selection. Enter a number between 1 and $($nvmePartitions.Count)." -ForegroundColor Red
                }
            }
        }
    }
}

$targetDrive = $selectedPartition.DriveLetter
$targetGuid  = $selectedPartition.VolumeGuid
Write-Status "Target NVMe drive: ${targetDrive}: (GUID: $targetGuid)" -Level Info
Write-Log "Selected drive: ${targetDrive}: Label=$($selectedPartition.Label) FreeGB=$($selectedPartition.FreeSpaceGB) GUID=$targetGuid"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Free Space Validation
# ══════════════════════════════════════════════════════════════════════════════

if (-not (Test-FreeSpace -DriveLetter $targetDrive)) {
    Write-Status 'Insufficient free space. Exiting.' -Level Failed
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Pre-run Warning
# ══════════════════════════════════════════════════════════════════════════════

$currentUser = $env:USERNAME

Write-Host ''
Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Yellow
Write-Host '  │  The following changes will be made:             │' -ForegroundColor Yellow
Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Yellow
Write-Host ''
Write-Host "  1. PAGEFILE    Move pagefile.sys to ${targetDrive}:" -ForegroundColor White
Write-Host "  2. TEMP        Junction C:\Windows\Temp -> ${targetDrive}:\Windows\Temp" -ForegroundColor White
Write-Host "                 Junction C:\Users\${currentUser}\AppData\Local\Temp -> ${targetDrive}:\Users\${currentUser}\AppData\Local\Temp" -ForegroundColor White
Write-Host "  3. BROWSERS    Junction cache dirs for installed browsers to ${targetDrive}:" -ForegroundColor White
Write-Host "  4. SEARCH      Move Windows Search index to ${targetDrive}:" -ForegroundColor White
Write-Host ''
Write-Host '  All relocated items are caches or system-managed data.' -ForegroundColor Gray
Write-Host '  No user documents or irreplaceable data will be affected.' -ForegroundColor Gray
Write-Host ''
Write-Host '  A reboot is required after changes are applied.' -ForegroundColor Yellow
Write-Host '  Please SAVE ALL OPEN FILES and CLOSE APPLICATIONS before continuing.' -ForegroundColor Yellow
Write-Host ''

if (-not $DryRun -and -not $Force) {
    if (-not (Read-UserConfirmation -Prompt '  Ready to proceed?')) {
        Write-Status 'User cancelled. Exiting.' -Level Info
        exit 0
    }
}

# ── Initialize manifest ─────────────────────────────────────────────────────
if (-not $DryRun) {
    Backup-Manifest -LogPath $LogPath
    Initialize-Manifest -NVMeDrive $targetDrive -VolumeGuid $targetGuid
}
else {
    Initialize-Manifest -NVMeDrive $targetDrive -VolumeGuid $targetGuid
}

# ══════════════════════════════════════════════════════════════════════════════
# COMPONENT 1: Pagefile  [CRITICAL -- abort on failure]
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Status '── Pagefile ──────────────────────────────────────' -Level Info

$regPath    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$currentPF  = @((Get-ItemProperty -Path $regPath -Name PagingFiles).PagingFiles)
$desiredPF  = "${targetDrive}:\pagefile.sys 0 0"
$pipeSep = '|'
$origPFValue = $currentPF -join $pipeSep

$pfLogStr = $currentPF -join '; '
Write-Log "Current PagingFiles: $pfLogStr"

# Determine current state
$cDrivePattern = "^(C:|[?]:)\\"
$nvmePattern   = "^${targetDrive}:\\"
$onC    = @($currentPF | Where-Object { $_ -match $cDrivePattern })
$onNVMe = @($currentPF | Where-Object { $_ -match $nvmePattern })

if ($onC.Count -eq 0 -and $onNVMe.Count -gt 0) {
    Write-Status "Pagefile already configured on ${targetDrive}: only" -Level Skipped
    Add-ManifestChange -Component 'Pagefile' -Action 'RegistryModified' `
        -OriginalPath $regPath -OriginalValue $origPFValue `
        -NewPath $desiredPF -Status 'Skipped' -Detail 'Already on NVMe'
    Update-Count -Status 'Skipped'
}
else {
    if ($DryRun) {
        Write-Status "Would set PagingFiles to: $desiredPF" -Level DryRun
        Add-ManifestChange -Component 'Pagefile' -Action 'RegistryModified' `
            -OriginalPath $regPath -OriginalValue $origPFValue `
            -NewPath $desiredPF -Status 'DryRun' -Detail 'Dry run'
        Update-Count -Status 'DryRun'
    }
    else {
        try {
            Set-ItemProperty -Path $regPath -Name PagingFiles -Value @($desiredPF) -ErrorAction Stop
            Write-Status "Pagefile configured on ${targetDrive}: (system-managed). Takes effect after reboot." -Level Applied

            $detail = 'Pagefile moved to NVMe'
            if ($onC.Count -gt 0 -and $onNVMe.Count -gt 0) {
                $detail = 'Removed C: pagefile entry (was on both drives)'
            }

            Add-ManifestChange -Component 'Pagefile' -Action 'RegistryModified' `
                -OriginalPath $regPath -OriginalValue $origPFValue `
                -NewPath $desiredPF -Status 'Applied' -Detail $detail
            Update-Count -Status 'Applied'
        }
        catch {
            Write-Status "CRITICAL: Failed to configure pagefile -- $($_.Exception.Message)" -Level Failed
            Add-ManifestChange -Component 'Pagefile' -Action 'RegistryModified' `
                -OriginalPath $regPath -OriginalValue $origPFValue `
                -NewPath $desiredPF -Status 'Failed' -Detail $_.Exception.Message
            Write-Status 'Aborting Phase 1 due to critical pagefile failure.' -Level Failed
            exit 1
        }
    }
}

# ── hiberfil.sys info ────────────────────────────────────────────────────────
Write-Status 'Note: hiberfil.sys cannot be moved (firmware constraint). It will remain on C:.' -Level Info

# ══════════════════════════════════════════════════════════════════════════════
# COMPONENT 2: TEMP and TMP Directories
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Status '── TEMP Directories ────────────────────────────' -Level Info

$tempPaths = @(
    @{
        Original = 'C:\Windows\Temp'
        Target   = "${targetDrive}:\Windows\Temp"
    },
    @{
        Original = "C:\Users\${currentUser}\AppData\Local\Temp"
        Target   = "${targetDrive}:\Users\${currentUser}\AppData\Local\Temp"
    }
)

foreach ($tp in $tempPaths) {
    $result = New-NVMeJunction -OriginalPath $tp.Original -NVMeTargetPath $tp.Target -Component 'TEMP'
    Add-ManifestChange -Component 'TEMP' -Action $result.Action `
        -OriginalPath $result.OriginalPath -NewPath $result.NewPath `
        -Status $result.Status -Detail $result.Detail
    Update-Count -Status $result.Status

    if ($result.Status -eq 'Failed' -and $result.Detail -match 'wrong target') {
        Write-Status "Junction points to wrong target. Manual intervention required. Continuing..." -Level Warning
        $counts.Warning++
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# COMPONENT 3: Browser Caches
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Status '── Browser Caches ─────────────────────────────' -Level Info

$browsers = Get-InstalledBrowsers

foreach ($browser in $browsers) {
    Write-Host ''
    Write-Status "Processing $($browser.Name)..." -Level Info

    # Check if browser is running
    if (Test-ProcessRunning -ProcessName $browser.ProcessName) {
        if ($DryRun) {
            Write-Status "$($browser.Name) is running (would need to be closed)" -Level DryRun
        }
        elseif ($Force) {
            Write-Status "$($browser.Name) is running. Killing process..." -Level Warning
            $killed = Stop-BrowserProcess -ProcessName $browser.ProcessName
            if (-not $killed) {
                Write-Status "Could not stop $($browser.Name). Skipping." -Level Failed
                $counts.Failed++
                continue
            }
        }
        else {
            Write-Host ''
            Write-Host "  $($browser.Name) is currently running. Options:" -ForegroundColor Yellow
            Write-Host '  [1] Let the script close it automatically' -ForegroundColor White
            Write-Host '  [2] I will close it myself (press Enter when done)' -ForegroundColor White
            Write-Host '  [3] Skip this browser' -ForegroundColor White
            Write-Host '  Choice: ' -ForegroundColor Yellow -NoNewline
            $choice = Read-Host

            switch ($choice) {
                '1' {
                    $killed = Stop-BrowserProcess -ProcessName $browser.ProcessName
                    if (-not $killed) {
                        Write-Status "Could not stop $($browser.Name). Skipping." -Level Failed
                        $counts.Failed++
                        continue
                    }
                }
                '2' {
                    Write-Host '  Press Enter after closing the browser...' -ForegroundColor Gray
                    Read-Host | Out-Null
                    if (Test-ProcessRunning -ProcessName $browser.ProcessName) {
                        Write-Status "$($browser.Name) is still running. Skipping." -Level Warning
                        $counts.Warning++
                        continue
                    }
                }
                default {
                    Write-Status "Skipping $($browser.Name) by user choice" -Level Skipped
                    $counts.Skipped++
                    continue
                }
            }
        }
    }

    # Get profiles
    $profiles = Get-BrowserProfiles -Browser $browser
    if (-not $profiles -or $profiles.Count -eq 0) {
        Write-Status "No profiles found for $($browser.Name)" -Level Skipped
        $counts.Skipped++
        continue
    }

    # Get cache subdirectories to junction
    $cacheDirs = Get-BrowserCachePaths -BrowserName $browser.Name

    foreach ($profilePath in $profiles) {
        $profileName = Split-Path -Leaf $profilePath

        foreach ($cacheDir in $cacheDirs) {
            $originalCache = Join-Path $profilePath $cacheDir

            # Build mirrored NVMe path
            # Original: C:\Users\<User>\AppData\Local\<BrowserPath>\<Profile>\<Cache>
            # Target:   D:\Users\<User>\AppData\Local\<BrowserPath>\<Profile>\<Cache>
            $relativePath = $originalCache
            if ($relativePath.StartsWith('C:\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $relativePath = $relativePath.Substring(3)
            }
            $nvmeCache = "${targetDrive}:\$relativePath"

            # Only create junction if the cache directory exists or the parent profile exists
            # (For proactive junctions, we create even if cache dir doesn't exist yet)
            $parentExists = Test-Path (Split-Path -Parent $originalCache)
            if (-not $parentExists -and -not (Test-Path $originalCache)) {
                # Parent path doesn't exist either -- browser profile not set up yet
                continue
            }

            $result = New-NVMeJunction -OriginalPath $originalCache -NVMeTargetPath $nvmeCache -Component 'BrowserCache'
            Add-ManifestChange -Component 'BrowserCache' -Action $result.Action `
                -OriginalPath $result.OriginalPath -NewPath $result.NewPath `
                -Status $result.Status -Detail "$($browser.Name) / $profileName / $cacheDir"
            Update-Count -Status $result.Status
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# COMPONENT 4: Windows Search Index
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Status '── Windows Search Index ────────────────────────' -Level Info

$searchRegPath  = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
$desiredDataDir = "${targetDrive}:\ProgramData\Microsoft\Search\Data\"

try {
    $currentDataDir = (Get-ItemProperty -Path $searchRegPath -Name DataDirectory -ErrorAction Stop).DataDirectory
}
catch {
    $currentDataDir = $null
    Write-Status "Could not read current DataDirectory: $($_.Exception.Message)" -Level Warning
}

Write-Log "Current Search DataDirectory: $currentDataDir"

if ($currentDataDir -and $currentDataDir.TrimEnd('\') -eq $desiredDataDir.TrimEnd('\')) {
    Write-Status "Search index already configured on ${targetDrive}:" -Level Skipped
    Add-ManifestChange -Component 'SearchIndex' -Action 'RegistryModified' `
        -OriginalPath "$searchRegPath\DataDirectory" -OriginalValue $currentDataDir `
        -NewPath $desiredDataDir -Status 'Skipped' -Detail 'Already on NVMe'
    Update-Count -Status 'Skipped'
}
else {
    if ($DryRun) {
        Write-Status "Would stop WSearch service" -Level DryRun
        Write-Status "Would set DataDirectory to: $desiredDataDir" -Level DryRun
        Write-Status "Would set SetupCompletedSuccessfully to 0 (force rebuild)" -Level DryRun
        Add-ManifestChange -Component 'SearchIndex' -Action 'RegistryModified' `
            -OriginalPath "$searchRegPath\DataDirectory" -OriginalValue $currentDataDir `
            -NewPath $desiredDataDir -Status 'DryRun' -Detail 'Dry run'
        Update-Count -Status 'DryRun'
    }
    else {
        try {
            # Stop Windows Search service
            $wsService = Get-Service -Name 'WSearch' -ErrorAction SilentlyContinue
            if ($wsService -and $wsService.Status -eq 'Running') {
                Stop-Service -Name 'WSearch' -Force -ErrorAction Stop
                Write-Status 'Stopped WSearch service' -Level Applied
                Add-ManifestChange -Component 'SearchIndex' -Action 'ServiceStopped' `
                    -OriginalPath 'WSearch' -OriginalValue 'Running' `
                    -NewPath 'Stopped' -Status 'Applied' -Detail 'Service stopped for index relocation'
            }

            # Create target directory
            if (-not (Test-Path $desiredDataDir)) {
                New-Item -ItemType Directory -Path $desiredDataDir -Force | Out-Null
            }

            # Update DataDirectory
            Set-ItemProperty -Path $searchRegPath -Name DataDirectory -Value $desiredDataDir -ErrorAction Stop
            Write-Status "DataDirectory set to: $desiredDataDir" -Level Applied

            # Force rebuild
            Set-ItemProperty -Path $searchRegPath -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction Stop
            Write-Status 'SetupCompletedSuccessfully set to 0 (index will rebuild after reboot)' -Level Applied

            Add-ManifestChange -Component 'SearchIndex' -Action 'RegistryModified' `
                -OriginalPath "$searchRegPath\DataDirectory" -OriginalValue $currentDataDir `
                -NewPath $desiredDataDir -Status 'Applied' -Detail 'Index will rebuild on NVMe after reboot'
            Update-Count -Status 'Applied'

            Write-Status 'The search index will rebuild after reboot. This may take minutes to hours depending on the number of files. Search may be degraded until complete.' -Level Info
        }
        catch {
            Write-Status "Failed to configure search index: $($_.Exception.Message)" -Level Failed
            Add-ManifestChange -Component 'SearchIndex' -Action 'RegistryModified' `
                -OriginalPath "$searchRegPath\DataDirectory" -OriginalValue $currentDataDir `
                -NewPath $desiredDataDir -Status 'Failed' -Detail $_.Exception.Message
            Update-Count -Status 'Failed'
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary & Reboot
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Cyan
Write-Host '  │  Phase 1 Summary                                 │' -ForegroundColor Cyan
Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Cyan

Write-Host "  Applied : $($counts.Applied)" -ForegroundColor Green
Write-Host "  Skipped : $($counts.Skipped)" -ForegroundColor Gray
Write-Host "  Warning : $($counts.Warning)" -ForegroundColor Yellow
Write-Host "  Failed  : $($counts.Failed)"  -ForegroundColor Red
if ($DryRun) {
    Write-Host "  DryRun  : $($counts.DryRun)" -ForegroundColor Magenta
}
Write-Host ''

$summary = "Summary: Applied=$($counts.Applied) Skipped=$($counts.Skipped) Warning=$($counts.Warning) Failed=$($counts.Failed) DryRun=$($counts.DryRun)"
Write-Log $summary
Write-Log "Phase 1 completed at $(Get-Date -Format 'o')"

# Save final manifest
if (-not $DryRun) {
    Save-Manifest
}

if ($DryRun) {
    Write-Status "Dry run complete. Log written to: $($script:LogFilePath)" -Level Info
    Write-Host '  No changes were made. Review the log and re-run without -DryRun to apply.' -ForegroundColor Magenta
    exit 0
}

# ── Register Phase 2 scheduled task ──────────────────────────────────────────

Write-Status 'Registering Phase 2 validation task...' -Level Info

try {
    $validateScript = Join-Path $PSScriptRoot 'Optimize-NVMe-Validate.ps1'
    $psExe = (Get-Process -Id $PID).Path
    $taskArgs = "-File `"$validateScript`" -LogPath `"$LogPath`""

    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName 'NVMe-Optimize-Phase2' `
        -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Status 'Phase 2 task registered (runs at next logon)' -Level Applied
}
catch {
    Write-Status "Failed to register Phase 2 task: $($_.Exception.Message)" -Level Warning
    Write-Status 'You can run Optimize-NVMe-Validate.ps1 manually after reboot.' -Level Info
}

# ── Reboot ───────────────────────────────────────────────────────────────────

Write-Host ''
if ($Force) {
    Write-Status 'Rebooting now (-Force mode)...' -Level Info
    shutdown /r /t 5 /c "NVMe Optimization -- Phase 1 complete. Rebooting for Phase 2."
}
else {
    Write-Host '  All changes applied. A reboot is required to complete the optimization.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  The system will reboot in 60 seconds.' -ForegroundColor Yellow
    Write-Host '  Press Ctrl+C to cancel (you can reboot manually later).' -ForegroundColor Gray
    Write-Host ''

    try {
        shutdown /r /t 60 /c "NVMe Optimization -- Phase 1 complete. Rebooting in 60 seconds for Phase 2."
        Write-Status 'Reboot scheduled in 60 seconds. Run "shutdown /a" to cancel.' -Level Info
    }
    catch {
        Write-Status "Could not schedule reboot: $($_.Exception.Message)" -Level Warning
        Write-Status 'Please reboot manually to complete the optimization.' -Level Warning
    }
}
