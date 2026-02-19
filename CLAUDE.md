# Project: optimize-nvme-windows

## What This Is
A PowerShell utility (3 scripts + 1 shared module) that relocates high-I/O Windows components from a SATA boot drive (C:) to a secondary NVMe drive after a fresh OS install.

## Architecture
- `Optimize-NVMe.ps1` — Phase 1: applies all changes, schedules Phase 2, reboots
- `Optimize-NVMe-Validate.ps1` — Phase 2: post-reboot validation + cleanup (runs via scheduled task)
- `Optimize-NVMe-Undo.ps1` — Recovery: reverses all changes using manifest
- `Optimize-NVMe-Common.psm1` — Shared module imported by all three scripts
- `tests/` — Pester unit tests with mocked dependencies

## Key Design Decisions
- **Junctions** for TEMP, browser caches (not env vars or browser policies)
- **Registry** for pagefile and Windows Search index (native mechanism)
- **Volume GUID tracking** for drive identity (survives drive letter changes)
- **Two-tier error handling**: pagefile failure = abort; everything else = log and continue
- **Mirror C: structure** on NVMe for all paths (e.g., `C:\Windows\Temp` → `D:\Windows\Temp`)
- **Always rebuild** search index (never move)
- **Single reboot** at end of Phase 1

## Parameters (all scripts)
- `-DryRun` — show changes without applying (no manifest, no reboot)
- `-Force` — skip all prompts (unattended mode)
- `-NVMeDrive <letter>` — override auto-detection (Phase 1 only)
- `-LogPath <path>` — override default `C:\.logs\`

## Manifest
- Lives at `$LogPath\nvme-optimization-manifest.json`
- Source of truth for validate and undo scripts
- Stores Volume GUID, originalValue for registry changes
- Backed up with timestamp on re-run

## Conventions
- PowerShell 5.1+ compatible (also works with pwsh/PowerShell 7)
- Self-elevates via UAC using the same PS executable that invoked the script
- Colored console output: green=success, yellow=warning, red=error, cyan=info, magenta=dryrun, gray=skipped
- Log prefixes: `[APPLIED]`, `[SKIPPED]`, `[INFO]`, `[WARNING]`, `[FAILED]`, `[DRYRUN]`
- Tests use Pester with mocked WMI, registry, filesystem, service, and process calls

## Spec
Full specification: `optimize-nvme-windows-fsd.md` (always check this before making design changes)

## Do NOT
- Move `hiberfil.sys` (cannot be moved — firmware constraint)
- Touch `C:\Windows` (except `C:\Windows\Temp`), Program Files, user profile root, WinSxS, System32
- Auto-modify execution policy
- Create manifest during dry-run
- Silently overwrite junctions that point to wrong targets (warn and exit)
