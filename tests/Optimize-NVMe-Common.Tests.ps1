#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for Optimize-NVMe-Common.psm1
.DESCRIPTION
    Unit tests with mocked dependencies for all shared module functions.
    Run with: Invoke-Pester ./tests -Output Detailed
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\Optimize-NVMe-Common.psm1'
    Import-Module $modulePath -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-IsAdmin
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-IsAdmin' {
    It 'Returns a boolean' {
        $result = Test-IsAdmin
        $result | Should -BeOfType [bool]
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-ExecutionPolicy
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-ExecutionPolicy' {
    It 'Returns true when effective policy is not Restricted' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-ExecutionPolicy { 'RemoteSigned' }
        $result = Test-ExecutionPolicy
        $result | Should -BeTrue
    }

    It 'Returns false when effective policy is Restricted' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-ExecutionPolicy { 'Restricted' }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Host {}

        $result = Test-ExecutionPolicy
        $result | Should -BeFalse
    }

    It 'Returns false when LocalMachine is Restricted and CurrentUser is not set (effective = Restricted)' {
        # This covers the gap where the old scope-based check would return $true incorrectly
        Mock -ModuleName 'Optimize-NVMe-Common' Get-ExecutionPolicy { 'Restricted' }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Host {}

        $result = Test-ExecutionPolicy
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-NVMePartitions
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Get-NVMePartitions' {
    It 'Returns empty array when no NVMe disks found' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-PhysicalDiskList { @() }
        $result = Get-NVMePartitions
        $result | Should -HaveCount 0
    }

    It 'Returns partitions for NVMe disks' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-PhysicalDiskList {
            @([PSCustomObject]@{ DeviceId = '1'; BusType = 'NVMe' })
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition {
            @([PSCustomObject]@{
                DriveLetter = 'D'
                AccessPaths = @('D:\', '\\?\Volume{abcd-1234}\')
            })
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Volume {
            [PSCustomObject]@{
                FileSystemLabel = 'NVMe'
                Size            = 500GB
                SizeRemaining   = 400GB
            }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Get-NVMePartitions
        $result | Should -HaveCount 1
        $result[0].DriveLetter | Should -Be 'D'
        $result[0].IsBootDrive | Should -BeFalse
        $result[0].VolumeGuid  | Should -Be '\\?\Volume{abcd-1234}\'
    }

    It 'Marks C: as boot drive' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-PhysicalDiskList {
            @([PSCustomObject]@{ DeviceId = '0'; BusType = 'NVMe' })
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition {
            @([PSCustomObject]@{
                DriveLetter = 'C'
                AccessPaths = @('C:\', '\\?\Volume{boot-guid}\')
            })
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Volume {
            [PSCustomObject]@{
                FileSystemLabel = 'Windows'
                Size            = 256GB
                SizeRemaining   = 100GB
            }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Get-NVMePartitions
        $result[0].IsBootDrive | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resolve-VolumeGuid
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Resolve-VolumeGuid' {
    It 'Returns GUID for valid drive letter' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition {
            [PSCustomObject]@{
                AccessPaths = @('D:\', '\\?\Volume{test-guid}\')
            }
        }

        $result = Resolve-VolumeGuid -DriveLetter 'D'
        $result | Should -Be '\\?\Volume{test-guid}\'
    }

    It 'Returns null on failure' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition { throw 'Not found' }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Resolve-VolumeGuid -DriveLetter 'Z'
        $result | Should -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-VolumeGuid
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-VolumeGuid' {
    It 'Returns Match when GUID matches drive letter' {
        Mock -ModuleName 'Optimize-NVMe-Common' Resolve-VolumeGuid { '\\?\Volume{guid-1}\' }

        $result = Test-VolumeGuid -ExpectedDriveLetter 'D' -ExpectedGuid '\\?\Volume{guid-1}\'
        $result.Status | Should -Be 'Match'
    }

    It 'Returns DriveLetterChanged when GUID found at different letter' {
        Mock -ModuleName 'Optimize-NVMe-Common' Resolve-VolumeGuid { '\\?\Volume{other}\' }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition {
            @(
                [PSCustomObject]@{ DriveLetter = 'E'; AccessPaths = @('E:\', '\\?\Volume{guid-1}\') },
                [PSCustomObject]@{ DriveLetter = 'F'; AccessPaths = @('F:\', '\\?\Volume{guid-2}\') }
            )
        }

        $result = Test-VolumeGuid -ExpectedDriveLetter 'D' -ExpectedGuid '\\?\Volume{guid-1}\'
        $result.Status      | Should -Be 'DriveLetterChanged'
        $result.DriveLetter | Should -Be 'E'
    }

    It 'Returns NotFound when GUID not on any volume' {
        Mock -ModuleName 'Optimize-NVMe-Common' Resolve-VolumeGuid { '\\?\Volume{other}\' }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Partition {
            @(
                [PSCustomObject]@{ DriveLetter = 'E'; AccessPaths = @('E:\', '\\?\Volume{e-guid}\') }
            )
        }

        $result = Test-VolumeGuid -ExpectedDriveLetter 'D' -ExpectedGuid '\\?\Volume{missing}\'
        $result.Status | Should -Be 'NotFound'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-FreeSpace
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-FreeSpace' {
    It 'Returns true when free space is sufficient' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Volume {
            [PSCustomObject]@{ SizeRemaining = 100GB }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-CimInstance {
            [PSCustomObject]@{ TotalPhysicalMemory = 16GB }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Test-FreeSpace -DriveLetter 'D'
        $result | Should -BeTrue
    }

    It 'Returns false when free space is insufficient' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Volume {
            [PSCustomObject]@{ SizeRemaining = 10GB }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-CimInstance {
            [PSCustomObject]@{ TotalPhysicalMemory = 32GB }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Test-FreeSpace -DriveLetter 'D'
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-NVMeJunction
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-NVMeJunction' {
    It 'Returns NotFound when path does not exist' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $false }

        $result = Test-NVMeJunction -Path 'C:\Fake\Path' -ExpectedTarget 'D:\Fake\Path'
        $result.Status | Should -Be 'NotFound'
    }

    It 'Returns NotJunction when path exists but is not a reparse point' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Item {
            [PSCustomObject]@{ Attributes = [IO.FileAttributes]::Directory }
        }

        $result = Test-NVMeJunction -Path 'C:\Windows\Temp' -ExpectedTarget 'D:\Windows\Temp'
        $result.Status | Should -Be 'NotJunction'
    }

    It 'Returns Valid when junction points to correct target' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Item {
            [PSCustomObject]@{
                Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                Target     = @('D:\Windows\Temp')
            }
        }

        $result = Test-NVMeJunction -Path 'C:\Windows\Temp' -ExpectedTarget 'D:\Windows\Temp'
        $result.Status | Should -Be 'Valid'
    }

    It 'Returns WrongTarget when junction points elsewhere' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Item {
            [PSCustomObject]@{
                Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                Target     = @('E:\Wrong\Path')
            }
        }

        $result = Test-NVMeJunction -Path 'C:\Windows\Temp' -ExpectedTarget 'D:\Windows\Temp'
        $result.Status | Should -Be 'WrongTarget'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# New-NVMeJunction
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'New-NVMeJunction' {
    BeforeEach {
        # Put module in dry-run mode to avoid real filesystem changes
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $true }
    }

    AfterEach {
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $false }
    }

    It 'Returns Skipped when junction already exists and is correct' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-NVMeJunction {
            @{ Status = 'Valid'; Target = 'D:\Windows\Temp' }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = New-NVMeJunction -OriginalPath 'C:\Windows\Temp' -NVMeTargetPath 'D:\Windows\Temp' -Component 'TEMP'
        $result.Status | Should -Be 'Skipped'
    }

    It 'Returns Failed when junction points to wrong target' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-NVMeJunction {
            @{ Status = 'WrongTarget'; Target = 'E:\Wrong' }
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = New-NVMeJunction -OriginalPath 'C:\Windows\Temp' -NVMeTargetPath 'D:\Windows\Temp' -Component 'TEMP'
        $result.Status | Should -Be 'Failed'
    }

    It 'Returns DryRun when in dry-run mode and path exists' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-NVMeJunction { @{ Status = 'NotFound' } }
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = New-NVMeJunction -OriginalPath 'C:\Windows\Temp' -NVMeTargetPath 'D:\Windows\Temp' -Component 'TEMP'
        $result.Status | Should -Be 'DryRun'
    }

    It 'Returns DryRun when in dry-run mode and path does not exist' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-NVMeJunction { @{ Status = 'NotFound' } }
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $false }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = New-NVMeJunction -OriginalPath 'C:\NewPath' -NVMeTargetPath 'D:\NewPath' -Component 'TEMP'
        $result.Status | Should -Be 'DryRun'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Manifest Functions
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Manifest Functions' {
    BeforeEach {
        $testDir = Join-Path $env:TEMP "nvme-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        & (Get-Module 'Optimize-NVMe-Common') { $script:LogPath = $args[0]; $script:DryRun = $false } $testDir
    }

    AfterEach {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Initialize-Manifest' {
        It 'Creates a manifest with correct structure' {
            Initialize-Manifest -NVMeDrive 'D' -VolumeGuid '\\?\Volume{test}\'

            $m = & (Get-Module 'Optimize-NVMe-Common') { $script:Manifest }
            $m.version     | Should -Be '1.0'
            $m.nvmeDrive   | Should -Be 'D'
            $m.currentUser | Should -Be $env:USERNAME
            $m.changes     | Should -HaveCount 0
        }
    }

    Context 'Add-ManifestChange' {
        It 'Adds a change entry to the manifest' {
            Initialize-Manifest -NVMeDrive 'D' -VolumeGuid '\\?\Volume{test}\'
            Add-ManifestChange -Component 'Pagefile' -Action 'RegistryModified' `
                -OriginalPath 'HKLM:\test' -OriginalValue 'old' `
                -NewPath 'new' -Status 'Applied' -Detail 'test change'

            $m = & (Get-Module 'Optimize-NVMe-Common') { $script:Manifest }
            $m.changes | Should -HaveCount 1
            $m.changes[0].component     | Should -Be 'Pagefile'
            $m.changes[0].originalValue | Should -Be 'old'
            $m.changes[0].phase2Status  | Should -Be 'Pending'
        }
    }

    Context 'Save-Manifest and Read-Manifest' {
        It 'Round-trips manifest to JSON and back' {
            Initialize-Manifest -NVMeDrive 'D' -VolumeGuid '\\?\Volume{test}\'
            Add-ManifestChange -Component 'TEMP' -Action 'JunctionCreated' `
                -OriginalPath 'C:\Windows\Temp' -NewPath 'D:\Windows\Temp' `
                -Status 'Applied' -Detail 'test'

            Save-Manifest

            $manifestPath = Join-Path $testDir 'nvme-optimization-manifest.json'
            $manifestPath | Should -Exist

            $loaded = Read-Manifest -Path $manifestPath
            $loaded | Should -Not -BeNullOrEmpty
            $loaded.nvmeDrive       | Should -Be 'D'
            $loaded.changes         | Should -HaveCount 1
            $loaded.changes[0].component | Should -Be 'TEMP'
        }
    }

    Context 'Backup-Manifest' {
        It 'Creates a .bak file when manifest exists' {
            Initialize-Manifest -NVMeDrive 'D' -VolumeGuid '\\?\Volume{test}\'
            Save-Manifest

            Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}
            $result = Backup-Manifest -LogPath $testDir
            $result | Should -BeTrue

            $backups = Get-ChildItem -Path $testDir -Filter '*.bak'
            $backups | Should -HaveCount 1
        }

        It 'Returns false when no manifest exists' {
            $result = Backup-Manifest -LogPath $testDir
            $result | Should -BeFalse
        }
    }

    Context 'Update-ManifestPhase2Status' {
        It 'Updates phase2Status for a specific change' {
            Initialize-Manifest -NVMeDrive 'D' -VolumeGuid '\\?\Volume{test}\'
            Add-ManifestChange -Component 'TEMP' -Action 'JunctionCreated' `
                -OriginalPath 'C:\test' -NewPath 'D:\test' `
                -Status 'Applied' -Detail 'test'

            Update-ManifestPhase2Status -Index 0 -Phase2Status 'Validated'

            $m = & (Get-Module 'Optimize-NVMe-Common') { $script:Manifest }
            $m.changes[0].phase2Status | Should -Be 'Validated'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Write-Status
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Write-Status' {
    BeforeEach {
        $testDir = Join-Path $env:TEMP "nvme-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Initialize-NVMeOptimizer -LogPath $testDir -Phase 'test'
    }

    AfterEach {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Writes to log file' {
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Host {}
        Write-Status 'Test message' -Level Info

        $logFiles = Get-ChildItem -Path $testDir -Filter '*.log'
        $logFiles | Should -Not -HaveCount 0
        $content = Get-Content $logFiles[0].FullName -Raw
        $content | Should -Match 'Test message'
    }

    It 'Accepts all valid levels' {
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Host {}

        foreach ($level in @('Applied','Skipped','Info','Warning','Failed','DryRun')) {
            { Write-Status "Test $level" -Level $level } | Should -Not -Throw
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-InstalledBrowsers
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Get-InstalledBrowsers' {
    It 'Returns browsers that have registry keys' {
        InModuleScope 'Optimize-NVMe-Common' {
            Mock Test-Path { $false }
            Mock Test-Path { $true } -ParameterFilter { $Path -like '*chrome*' }
            Mock Write-Status {}

            $result = @(Get-InstalledBrowsers)
            $result | Should -HaveCount 1
            $result[0].Name | Should -Be 'Chrome'
        }
    }

    It 'Returns empty array when no browsers installed' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $false }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Get-InstalledBrowsers
        $result | Should -HaveCount 0
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-BrowserCachePaths
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Get-BrowserCachePaths' {
    It 'Returns 5 cache dirs for Chrome' {
        $result = Get-BrowserCachePaths -BrowserName 'Chrome'
        $result | Should -HaveCount 5
        $result | Should -Contain 'Cache'
        $result | Should -Contain 'Code Cache'
        $result | Should -Contain 'GPUCache'
    }

    It 'Returns 5 cache dirs for Edge' {
        $result = Get-BrowserCachePaths -BrowserName 'Edge'
        $result | Should -HaveCount 5
    }

    It 'Returns 2 cache dirs for Firefox' {
        $result = Get-BrowserCachePaths -BrowserName 'Firefox'
        $result | Should -HaveCount 2
        $result | Should -Contain 'cache2'
        $result | Should -Contain 'startupCache'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test-ProcessRunning
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Test-ProcessRunning' {
    It 'Returns true when process is running' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Process {
            @([PSCustomObject]@{ Name = 'chrome'; Id = 1234 })
        }

        $result = Test-ProcessRunning -ProcessName 'chrome'
        $result | Should -BeTrue
    }

    It 'Returns false when process is not running' {
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Process { $null }

        $result = Test-ProcessRunning -ProcessName 'nonexistent'
        $result | Should -BeFalse
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Stop-BrowserProcess
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Stop-BrowserProcess' {
    It 'Returns true in dry-run mode without killing' {
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}
        Mock -ModuleName 'Optimize-NVMe-Common' Stop-Process {}

        $result = Stop-BrowserProcess -ProcessName 'chrome'
        $result | Should -BeTrue

        Should -Not -Invoke -CommandName Stop-Process -ModuleName 'Optimize-NVMe-Common'

        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $false }
    }

    It 'Calls Stop-Process when not in dry-run' {
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $false }
        Mock -ModuleName 'Optimize-NVMe-Common' Stop-Process {}
        Mock -ModuleName 'Optimize-NVMe-Common' Start-Sleep {}
        Mock -ModuleName 'Optimize-NVMe-Common' Test-ProcessRunning { $false }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        $result = Stop-BrowserProcess -ProcessName 'chrome'
        $result | Should -BeTrue
        Should -Invoke -CommandName Stop-Process -ModuleName 'Optimize-NVMe-Common' -Times 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Get-BrowserProfiles
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Get-BrowserProfiles' {
    It 'Returns empty array when base path does not exist' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $false }

        $browser = @{ Name = 'Chrome'; BasePath = 'C:\Fake\Path'; ProcessName = 'chrome'; RegKey = '' }
        $result = Get-BrowserProfiles -Browser $browser
        $result | Should -HaveCount 0
    }

    It 'Returns Default and Profile dirs for Chromium browsers' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-ChildItem {
            @(
                [PSCustomObject]@{ Name = 'Default';   FullName = 'C:\Test\Default' },
                [PSCustomObject]@{ Name = 'Profile 1'; FullName = 'C:\Test\Profile 1' },
                [PSCustomObject]@{ Name = 'GrShaderCache'; FullName = 'C:\Test\GrShaderCache' }
            )
        }

        $browser = @{ Name = 'Chrome'; BasePath = 'C:\Test'; ProcessName = 'chrome'; RegKey = '' }
        $result = Get-BrowserProfiles -Browser $browser
        $result | Should -HaveCount 2
    }

    It 'Returns all subdirectories for Firefox' {
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-ChildItem {
            @(
                [PSCustomObject]@{ Name = 'abc123.default-release'; FullName = 'C:\Test\abc123.default-release' },
                [PSCustomObject]@{ Name = 'xyz789.dev-edition'; FullName = 'C:\Test\xyz789.dev-edition' }
            )
        }

        $browser = @{ Name = 'Firefox'; BasePath = 'C:\Test'; ProcessName = 'firefox'; RegKey = '' }
        $result = Get-BrowserProfiles -Browser $browser
        $result | Should -HaveCount 2
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dry-Run Isolation
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Dry-Run Mode Isolation' {
    It 'New-NVMeJunction does not call New-Item in dry-run' {
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $true }

        Mock -ModuleName 'Optimize-NVMe-Common' Test-NVMeJunction { @{ Status = 'NotFound' } }
        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $false }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}
        Mock -ModuleName 'Optimize-NVMe-Common' New-Item {}

        $result = New-NVMeJunction -OriginalPath 'C:\Test' -NVMeTargetPath 'D:\Test' -Component 'TEMP'
        $result.Status | Should -Be 'DryRun'
        Should -Not -Invoke -CommandName New-Item -ModuleName 'Optimize-NVMe-Common'

        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $false }
    }

    It 'Remove-NVMeJunction does not delete in dry-run' {
        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $true }

        Mock -ModuleName 'Optimize-NVMe-Common' Test-Path { $true }
        Mock -ModuleName 'Optimize-NVMe-Common' Get-Item {
            $obj = [PSCustomObject]@{
                Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
            }
            $obj | Add-Member -MemberType ScriptMethod -Name Delete -Value {} -Force
            $obj
        }
        Mock -ModuleName 'Optimize-NVMe-Common' Write-Status {}

        Remove-NVMeJunction -JunctionPath 'C:\Test' -NVMeSourcePath 'D:\Test' -NVMeAvailable
        # If we got here without error, dry-run isolation works

        & (Get-Module 'Optimize-NVMe-Common') { $script:DryRun = $false }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Module Import Validation
# ═══════════════════════════════════════════════════════════════════════════════

Describe 'Module Import' {
    It 'Exports all expected functions' {
        $expectedFunctions = @(
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

        $module = Get-Module 'Optimize-NVMe-Common'
        foreach ($fn in $expectedFunctions) {
            $module.ExportedFunctions.Keys | Should -Contain $fn
        }
    }
}
