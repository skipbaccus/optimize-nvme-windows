#Requires -Version 5.1
# Optimize-NVMe-Common.psm1 -- Shared module for NVMe optimization scripts

# ── Module-scoped state ──────────────────────────────────────────────────────
$script:LogFilePath = $null
$script:DryRun      = $false
$script:Force       = $false
$script:LogPath     = 'C:\.logs'
$script:Manifest    = $null
$script:ScriptVersion = '1.0.0'

# ── Initialization ───────────────────────────────────────────────────────────

function Initialize-NVMeOptimizer {
    param(
        [string]$LogPath  = 'C:\.logs',
        [string]$Phase    = 'phase1',
        [switch]$DryRun,
        [switch]$Force
    )

    $script:LogPath = $LogPath
    $script:DryRun  = $DryRun.IsPresent
    $script:Force   = $Force.IsPresent

    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }

    $timestamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dryRunSuffix    = $(if ($script:DryRun) { '-dryrun' } else { '' })
    $script:LogFilePath = Join-Path $LogPath "nvme-optimize-${Phase}${dryRunSuffix}-${timestamp}.log"

    Write-Log "=== NVMe Optimization -- $Phase v$($script:ScriptVersion) ==="
    Write-Log "Timestamp : $(Get-Date -Format 'o')"
    Write-Log "DryRun    : $($script:DryRun)"
    Write-Log "Force     : $($script:Force)"
    Write-Log "LogPath   : $LogPath"
    Write-Log "User      : $env:USERNAME"
    Write-Log "Host      : $env:COMPUTERNAME"
    Write-Log "PS Version: $($PSVersionTable.PSVersion)"
    Write-Log '==================================================='
}

# ── Logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    if ($script:LogFilePath) {
        $entry | Out-File -FilePath $script:LogFilePath -Append -Encoding utf8
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Applied','Skipped','Info','Warning','Failed','DryRun')]
        [string]$Level = 'Info'
    )

    $colors = @{
        Applied  = 'Green'
        Skipped  = 'Gray'
        Info     = 'Cyan'
        Warning  = 'Yellow'
        Failed   = 'Red'
        DryRun   = 'Magenta'
    }

    $prefix = "[$($Level.ToUpper())]"
    Write-Host "$prefix $Message" -ForegroundColor $colors[$Level]
    Write-Log "$prefix $Message"
}

# ── Admin / Elevation ────────────────────────────────────────────────────────

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [System.Collections.IDictionary]$Parameters = @{}
    )

    $argParts = @("-File `"$ScriptPath`"")
    foreach ($key in $Parameters.Keys) {
        $val = $Parameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argParts += "-$key" }
        }
        elseif ($val -eq $true)  { $argParts += "-$key" }
        elseif ($val -eq $false) { <# skip #> }
        elseif ($null -ne $val)  { $argParts += "-$key `"$val`"" }
    }

    $argString = $argParts -join ' '
    $psExe = (Get-Process -Id $PID).Path
    Write-Host "Requesting administrator privileges..." -ForegroundColor Cyan
    Start-Process $psExe -ArgumentList $argString -Verb RunAs
}

function Test-ExecutionPolicy {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq 'Restricted') {
        $machinePolicy = Get-ExecutionPolicy -Scope LocalMachine
        if ($machinePolicy -eq 'Restricted' -or $machinePolicy -eq 'Undefined') {
            Write-Host ''
            Write-Host 'ERROR: PowerShell execution policy is set to Restricted.' -ForegroundColor Red
            Write-Host 'Scripts cannot run under this policy.' -ForegroundColor Red
            Write-Host ''
            Write-Host 'To fix, run this command in an elevated PowerShell prompt:' -ForegroundColor Yellow
            Write-Host '  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser' -ForegroundColor White
            Write-Host ''
            return $false
        }
    }
    return $true
}

# ── NVMe Detection ──────────────────────────────────────────────────────────

function Get-PhysicalDiskList {
    Get-PhysicalDisk -ErrorAction Stop
}

function Get-NVMePartitions {
    try {
        $nvmeDisks = Get-PhysicalDiskList | Where-Object { $_.BusType -eq 'NVMe' }
    }
    catch {
        Write-Status "Could not query physical disks: $($_.Exception.Message)" -Level Failed
        return @()
    }

    if (-not $nvmeDisks) { return @() }

    $results = @()
    foreach ($disk in $nvmeDisks) {
        try {
            $diskNumber = [int]$disk.DeviceId
            $partitions = Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
                Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 }

            foreach ($part in $partitions) {
                $vol  = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction Stop
                $guid = ($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }) |
                    Select-Object -First 1

                $results += [PSCustomObject]@{
                    DriveLetter = [string]$part.DriveLetter
                    Label       = $vol.FileSystemLabel
                    SizeGB      = [math]::Round($vol.Size / 1GB, 2)
                    FreeSpaceGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
                    FreeSpace   = $vol.SizeRemaining
                    VolumeGuid  = $guid
                    IsBootDrive = ($part.DriveLetter -eq 'C')
                }
            }
        }
        catch {
            Write-Status "Error mapping disk $($disk.DeviceId): $($_.Exception.Message)" -Level Warning
        }
    }

    return $results
}

function Resolve-VolumeGuid {
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    try {
        $part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $guid = ($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }) |
            Select-Object -First 1
        return $guid
    }
    catch {
        Write-Status "Could not resolve Volume GUID for ${DriveLetter}: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Test-VolumeGuid {
    param(
        [Parameter(Mandatory)]
        [string]$ExpectedDriveLetter,

        [Parameter(Mandatory)]
        [string]$ExpectedGuid
    )

    $currentGuid = Resolve-VolumeGuid -DriveLetter $ExpectedDriveLetter
    if ($currentGuid -eq $ExpectedGuid) {
        return @{ Status = 'Match'; DriveLetter = $ExpectedDriveLetter }
    }

    # GUID not at expected letter -- scan all volumes
    try {
        $allPartitions = Get-Partition -ErrorAction Stop |
            Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 }

        foreach ($part in $allPartitions) {
            $guid = ($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }) |
                Select-Object -First 1
            if ($guid -eq $ExpectedGuid) {
                return @{
                    Status      = 'DriveLetterChanged'
                    DriveLetter = [string]$part.DriveLetter
                    OldLetter   = $ExpectedDriveLetter
                }
            }
        }
    }
    catch {
        # Fall through to NotFound
    }

    return @{ Status = 'NotFound' }
}

function Test-FreeSpace {
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    try {
        $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        $freeSpace = $vol.SizeRemaining
    }
    catch {
        Write-Status "Could not query volume ${DriveLetter}: $($_.Exception.Message)" -Level Failed
        return $false
    }

    $ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    $requiredBytes = $ramBytes + (10GB)
    $freeGB     = [math]::Round($freeSpace   / 1GB, 2)
    $requiredGB = [math]::Round($requiredBytes / 1GB, 2)

    if ($freeSpace -ge $requiredBytes) {
        Write-Status "Free space check passed: ${freeGB} GB available, ${requiredGB} GB required" -Level Info
        return $true
    }
    else {
        Write-Status "Insufficient free space on ${DriveLetter}: ${freeGB} GB available, ${requiredGB} GB required" -Level Failed
        return $false
    }
}

# ── Junction Operations ─────────────────────────────────────────────────────

function Test-NVMeJunction {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedTarget
    )

    if (-not (Test-Path $Path)) {
        return @{ Status = 'NotFound' }
    }

    $item = Get-Item $Path -Force
    $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)

    if (-not $isReparse) {
        return @{ Status = 'NotJunction'; IsDirectory = $true }
    }

    $target = $(if ($item.Target) { $item.Target[0] } else { $null })

    # Normalize trailing backslashes for comparison
    $normalizedTarget   = $(if ($target) { $target.TrimEnd('\') } else { '' })
    $normalizedExpected = $ExpectedTarget.TrimEnd('\')

    if ($normalizedTarget -eq $normalizedExpected) {
        return @{ Status = 'Valid'; Target = $target }
    }
    else {
        return @{ Status = 'WrongTarget'; Target = $target; Expected = $ExpectedTarget }
    }
}

function New-NVMeJunction {
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath,

        [Parameter(Mandatory)]
        [string]$NVMeTargetPath,

        [Parameter(Mandatory)]
        [string]$Component
    )

    # Idempotency check
    $check = Test-NVMeJunction -Path $OriginalPath -ExpectedTarget $NVMeTargetPath
    switch ($check.Status) {
        'Valid' {
            Write-Status "Junction already correct: $OriginalPath -> $NVMeTargetPath" -Level Skipped
            return @{
                Status       = 'Skipped'
                Action       = 'JunctionCreated'
                OriginalPath = $OriginalPath
                NewPath      = $NVMeTargetPath
                Detail       = 'Junction already exists and points to correct target'
            }
        }
        'WrongTarget' {
            Write-Status "Junction exists but points to wrong target: $OriginalPath -> $($check.Target) (expected $NVMeTargetPath)" -Level Warning
            return @{
                Status       = 'Failed'
                Action       = 'JunctionCreated'
                OriginalPath = $OriginalPath
                NewPath      = $NVMeTargetPath
                Detail       = "Junction points to wrong target: $($check.Target)"
            }
        }
    }

    # Dry-run
    if ($script:DryRun) {
        if (Test-Path $OriginalPath) {
            Write-Status "Would move contents: $OriginalPath -> $NVMeTargetPath" -Level DryRun
        }
        Write-Status "Would create junction: $OriginalPath -> $NVMeTargetPath" -Level DryRun
        return @{
            Status       = 'DryRun'
            Action       = 'JunctionCreated'
            OriginalPath = $OriginalPath
            NewPath      = $NVMeTargetPath
            Detail       = 'Dry run -- no changes made'
        }
    }

    try {
        # Create target directory on NVMe
        if (-not (Test-Path $NVMeTargetPath)) {
            New-Item -ItemType Directory -Path $NVMeTargetPath -Force | Out-Null
            Write-Status "Created directory: $NVMeTargetPath" -Level Info
        }

        # Move existing contents
        if (Test-Path $OriginalPath) {
            $items = Get-ChildItem -Path $OriginalPath -Force -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                try {
                    Move-Item -Path $item.FullName -Destination $NVMeTargetPath -Force -ErrorAction Stop
                }
                catch {
                    Write-Status "Could not move (locked?): $($item.Name) -- $($_.Exception.Message)" -Level Warning
                }
            }

            # Remove original directory
            try {
                Remove-Item -Path $OriginalPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                # Retry with cmd for stubborn directories
                cmd /c "rmdir /s /q `"$OriginalPath`"" 2>$null
                if (Test-Path $OriginalPath) {
                    Write-Status "Cannot remove original directory: $OriginalPath" -Level Failed
                    return @{
                        Status       = 'Failed'
                        Action       = 'JunctionCreated'
                        OriginalPath = $OriginalPath
                        NewPath      = $NVMeTargetPath
                        Detail       = 'Could not remove original directory (files locked)'
                    }
                }
            }
        }

        # Ensure parent directory exists
        $parent = Split-Path -Parent $OriginalPath
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        # Create junction
        New-Item -ItemType Junction -Path $OriginalPath -Target $NVMeTargetPath -Force | Out-Null
        Write-Status "Junction created: $OriginalPath -> $NVMeTargetPath" -Level Applied

        return @{
            Status       = 'Applied'
            Action       = 'JunctionCreated'
            OriginalPath = $OriginalPath
            NewPath      = $NVMeTargetPath
            Detail       = "Junction created: $OriginalPath -> $NVMeTargetPath"
        }
    }
    catch {
        Write-Status "Failed to create junction $OriginalPath -> $NVMeTargetPath : $($_.Exception.Message)" -Level Failed
        return @{
            Status       = 'Failed'
            Action       = 'JunctionCreated'
            OriginalPath = $OriginalPath
            NewPath      = $NVMeTargetPath
            Detail       = $_.Exception.Message
        }
    }
}

function Remove-NVMeJunction {
    param(
        [Parameter(Mandatory)]
        [string]$JunctionPath,

        [string]$NVMeSourcePath,
        [switch]$NVMeAvailable
    )

    if (-not (Test-Path $JunctionPath)) {
        Write-Status "Path does not exist: $JunctionPath" -Level Skipped
        return
    }

    $item = Get-Item $JunctionPath -Force
    $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)

    if (-not $isReparse) {
        Write-Status "Path is not a junction: $JunctionPath" -Level Warning
        return
    }

    if ($script:DryRun) {
        Write-Status "Would remove junction: $JunctionPath" -Level DryRun
        if ($NVMeAvailable -and $NVMeSourcePath) {
            Write-Status "Would move contents back: $NVMeSourcePath -> $JunctionPath" -Level DryRun
        }
        return
    }

    # Remove junction (does NOT delete target contents)
    $item.Delete()
    Write-Status "Removed junction: $JunctionPath" -Level Applied

    # Recreate as regular directory
    New-Item -ItemType Directory -Path $JunctionPath -Force | Out-Null

    # Move contents back if NVMe is available
    if ($NVMeAvailable -and $NVMeSourcePath -and (Test-Path $NVMeSourcePath)) {
        $items = Get-ChildItem -Path $NVMeSourcePath -Force -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            try {
                Move-Item -Path $i.FullName -Destination $JunctionPath -Force -ErrorAction Stop
            }
            catch {
                Write-Status "Could not move back: $($i.Name) -- $($_.Exception.Message)" -Level Warning
            }
        }
        Write-Status "Restored contents: $NVMeSourcePath -> $JunctionPath" -Level Applied
    }
}

# ── Manifest ─────────────────────────────────────────────────────────────────

function Initialize-Manifest {
    param(
        [Parameter(Mandatory)]
        [string]$NVMeDrive,

        [Parameter(Mandatory)]
        [string]$VolumeGuid
    )

    $script:Manifest = @{
        version        = '1.0'
        timestamp      = (Get-Date -Format 'o')
        nvmeDrive      = $NVMeDrive
        nvmeVolumeGuid = $VolumeGuid
        currentUser    = $env:USERNAME
        logPath        = $script:LogPath
        dryRun         = $script:DryRun
        changes        = @()
    }
}

function Add-ManifestChange {
    param(
        [Parameter(Mandatory)] [string]$Component,
        [Parameter(Mandatory)] [string]$Action,
        [string]$OriginalPath  = '',
        [string]$OriginalValue = '',
        [string]$NewPath       = '',
        [Parameter(Mandatory)] [string]$Status,
        [string]$Detail        = ''
    )

    if (-not $script:Manifest) { return }

    $entry = @{
        component     = $Component
        action        = $Action
        originalPath  = $OriginalPath
        originalValue = $OriginalValue
        newPath       = $NewPath
        status        = $Status
        detail        = $Detail
        phase2Status  = 'Pending'
    }

    $script:Manifest.changes += $entry

    if (-not $script:DryRun) {
        Save-Manifest
    }
}

function Save-Manifest {
    if (-not $script:Manifest) { return }
    $manifestPath = Join-Path $script:LogPath 'nvme-optimization-manifest.json'
    $script:Manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8
}

function Read-Manifest {
    param(
        [string]$Path
    )

    if (-not $Path) {
        $Path = Join-Path $script:LogPath 'nvme-optimization-manifest.json'
    }

    if (-not (Test-Path $Path)) {
        Write-Status "Manifest not found: $Path" -Level Failed
        return $null
    }

    try {
        $json = Get-Content -Path $Path -Raw -Encoding utf8
        $manifest = $json | ConvertFrom-Json
        # Convert back to a mutable hashtable structure for easy updates
        $ht = @{
            version        = $manifest.version
            timestamp      = $manifest.timestamp
            nvmeDrive      = $manifest.nvmeDrive
            nvmeVolumeGuid = $manifest.nvmeVolumeGuid
            currentUser    = $manifest.currentUser
            logPath        = $manifest.logPath
            dryRun         = $manifest.dryRun
            changes        = @()
        }
        foreach ($change in $manifest.changes) {
            $ht.changes += @{
                component     = $change.component
                action        = $change.action
                originalPath  = $change.originalPath
                originalValue = $change.originalValue
                newPath       = $change.newPath
                status        = $change.status
                detail        = $change.detail
                phase2Status  = $change.phase2Status
            }
        }
        $script:Manifest = $ht
        return $ht
    }
    catch {
        Write-Status "Failed to read manifest: $($_.Exception.Message)" -Level Failed
        return $null
    }
}

function Backup-Manifest {
    param(
        [string]$LogPath
    )

    if (-not $LogPath) { $LogPath = $script:LogPath }
    $manifestPath = Join-Path $LogPath 'nvme-optimization-manifest.json'

    if (Test-Path $manifestPath) {
        $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $LogPath "nvme-optimization-manifest-${timestamp}.json.bak"
        Copy-Item -Path $manifestPath -Destination $backupPath -Force
        Write-Status "Existing manifest backed up to: $backupPath" -Level Info
        return $true
    }
    return $false
}

function Update-ManifestPhase2Status {
    param(
        [Parameter(Mandatory)] [int]$Index,
        [Parameter(Mandatory)] [string]$Phase2Status
    )

    if (-not $script:Manifest -or $Index -ge $script:Manifest.changes.Count) { return }
    $script:Manifest.changes[$Index].phase2Status = $Phase2Status

    if (-not $script:DryRun) {
        Save-Manifest
    }
}

# ── Browser Detection ────────────────────────────────────────────────────────

function Get-InstalledBrowsers {
    $browsers = @(
        @{
            Name        = 'Edge'
            RegKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
            ProcessName = 'msedge'
            BasePath    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        },
        @{
            Name        = 'Chrome'
            RegKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
            ProcessName = 'chrome'
            BasePath    = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        },
        @{
            Name        = 'Firefox'
            RegKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe'
            ProcessName = 'firefox'
            BasePath    = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
        }
    )

    $installed = @()
    foreach ($browser in $browsers) {
        if (Test-Path $browser.RegKey) {
            $installed += $browser
            Write-Status "$($browser.Name) detected" -Level Info
        }
        else {
            Write-Status "$($browser.Name) not installed" -Level Skipped
        }
    }

    return $installed
}

function Get-BrowserProfiles {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Browser
    )

    $basePath = $Browser.BasePath
    if (-not (Test-Path $basePath)) { return @() }

    $profiles = @()

    if ($Browser.Name -eq 'Firefox') {
        # Firefox profiles are named like xxxxxxxx.default-release
        $dirs = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $profiles += $dir.FullName
        }
    }
    else {
        # Chromium: Default, Profile 1, Profile 2, etc.
        $dirs = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }
        foreach ($dir in $dirs) {
            $profiles += $dir.FullName
        }
    }

    return $profiles
}

function Get-BrowserCachePaths {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Edge','Chrome','Firefox')]
        [string]$BrowserName
    )

    switch ($BrowserName) {
        'Edge'    { @('Cache','Code Cache','GPUCache','Service Worker\CacheStorage','Service Worker\ScriptCache') }
        'Chrome'  { @('Cache','Code Cache','GPUCache','Service Worker\CacheStorage','Service Worker\ScriptCache') }
        'Firefox' { @('cache2','startupCache') }
    }
}

function Test-ProcessRunning {
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    return [bool]$procs
}

function Stop-BrowserProcess {
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    if ($script:DryRun) {
        Write-Status "Would kill process: $ProcessName" -Level DryRun
        return $true
    }

    try {
        Stop-Process -Name $ProcessName -Force -ErrorAction Stop
        Start-Sleep -Seconds 2  # Allow time for process cleanup
        if (Test-ProcessRunning -ProcessName $ProcessName) {
            Write-Status "Process $ProcessName still running after kill attempt" -Level Warning
            return $false
        }
        Write-Status "Killed process: $ProcessName" -Level Applied
        return $true
    }
    catch {
        Write-Status "Failed to kill $ProcessName : $($_.Exception.Message)" -Level Failed
        return $false
    }
}

# ── User Prompts ─────────────────────────────────────────────────────────────

function Read-UserConfirmation {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$Default = 'N'
    )

    if ($script:Force) { return $true }

    $options = if ($Default -eq 'Y') { '(Y/n)' } else { '(y/N)' }
    Write-Host "$Prompt $options " -ForegroundColor Yellow -NoNewline
    $response = Read-Host

    if ([string]::IsNullOrWhiteSpace($response)) {
        return ($Default -eq 'Y')
    }

    return ($response.Trim().ToUpper() -eq 'Y')
}

function Read-UserChoice {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string[]]$Options
    )

    Write-Host $Prompt -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])" -ForegroundColor White
    }

    while ($true) {
        Write-Host "Enter choice (1-$($Options.Count)): " -ForegroundColor Yellow -NoNewline
        $userInput = Read-Host
        $choice = 0
        if ([int]::TryParse($userInput, [ref]$choice) -and $choice -ge 1 -and $choice -le $Options.Count) {
            return $choice
        }
        Write-Host "Invalid selection. Please enter a number between 1 and $($Options.Count)." -ForegroundColor Red
    }
}

# ── Export ───────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Initialize-NVMeOptimizer'
    'Write-Log'
    'Write-Status'
    'Test-IsAdmin'
    'Invoke-SelfElevation'
    'Test-ExecutionPolicy'
    'Get-NVMePartitions'
    'Resolve-VolumeGuid'
    'Test-VolumeGuid'
    'Test-FreeSpace'
    'Test-NVMeJunction'
    'New-NVMeJunction'
    'Remove-NVMeJunction'
    'Initialize-Manifest'
    'Add-ManifestChange'
    'Save-Manifest'
    'Read-Manifest'
    'Backup-Manifest'
    'Update-ManifestPhase2Status'
    'Get-InstalledBrowsers'
    'Get-BrowserProfiles'
    'Get-BrowserCachePaths'
    'Test-ProcessRunning'
    'Stop-BrowserProcess'
    'Read-UserConfirmation'
    'Read-UserChoice'
)
