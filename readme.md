# optimize-nvme-windows

A PowerShell-based tool for relocating high-I/O Windows components to a secondary NVMe drive after a fresh OS install. Designed for systems where the boot drive is slower than an available NVMe workspace drive.

---

## What it does

After a clean Windows install, this tool automatically moves the following to your NVMe drive:

| Component | Method | Details |
|---|---|---|
| Pagefile (`pagefile.sys`) | Registry — system-managed size | N/A |
| System and user TEMP directories | NTFS junction | N/A |
| Edge cache | NTFS junction — all profiles | Cache, Code Cache, GPUCache, Service Worker |
| Chrome cache | NTFS junction — all profiles | Cache, Code Cache, GPUCache, Service Worker |
| Firefox cache | NTFS junction — all profiles | cache2, startupCache |
| Windows Search index | Registry — forced clean rebuild on NVMe | N/A |

All NVMe paths mirror the original C: directory structure for easy debugging. Nothing is moved blindly — every change is logged, tracked by Volume GUID, and recorded in a manifest file.

---

## Requirements

- Windows 10 or Windows 11 (Pro or Workstation)
- A secondary NVMe drive with free space >= installed RAM + 10 GB
- PowerShell 5.1 or later (works with both `powershell` and `pwsh`)
- Administrator privileges (scripts self-elevate via UAC)
- PowerShell execution policy must allow local scripts (see below)

### Execution policy

If your PowerShell execution policy is set to `Restricted` (the default), the script will detect this and tell you how to fix it. Run this command first if needed:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Scripts

| Script | Purpose |
|---|---|
| `Optimize-NVMe.ps1` | Phase 1 — applies all changes, schedules validation, reboots |
| `Optimize-NVMe-Validate.ps1` | Phase 2 — runs automatically after reboot, validates and cleans up |
| `Optimize-NVMe-Undo.ps1` | Recovery — reverses all changes using the manifest |
| `Optimize-NVMe-Common.psm1` | Shared module — imported by all three scripts |

### How to run

```powershell
# Preview all changes without applying them
.\Optimize-NVMe.ps1 -DryRun

# Run for real (interactive — prompts for confirmation)
.\Optimize-NVMe.ps1

# Fully unattended
.\Optimize-NVMe.ps1 -Force

# Override NVMe drive selection
.\Optimize-NVMe.ps1 -NVMeDrive D

# Custom log directory
.\Optimize-NVMe.ps1 -LogPath "E:\MyLogs"
```

**Typical workflow:**
1. Run `.\Optimize-NVMe.ps1 -DryRun` to inspect changes
2. Run `.\Optimize-NVMe.ps1` to apply changes (reboots at the end)
3. After reboot, `Optimize-NVMe-Validate.ps1` runs automatically
4. Your machine is ready to use

If something goes wrong at any point, run `.\Optimize-NVMe-Undo.ps1` to reverse all changes. It works even if the NVMe drive is no longer available (junctions are cleaned up and registry settings restored).

### Parameters

All three scripts support these common parameters:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DryRun` | Switch | off | Show what would happen without making changes |
| `-Force` | Switch | off | Skip all confirmation prompts |
| `-LogPath` | String | `C:\.logs\` | Override default log and manifest directory |

`Optimize-NVMe.ps1` also supports:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-NVMeDrive` | String | auto-detect | Specify target drive letter (still validated) |

---

## Dry-run mode

Run any script with `-DryRun` to see exactly what would happen:

```
[DRYRUN] Would disable pagefile on C:
[DRYRUN] Would set PagingFiles to "D:\pagefile.sys" (system-managed)
[DRYRUN] Would create directory: D:\Windows\Temp
[DRYRUN] Would move contents: C:\Windows\Temp → D:\Windows\Temp
[DRYRUN] Would create junction: C:\Windows\Temp → D:\Windows\Temp
...
```

No filesystem, registry, service, or scheduled task changes are made. A dry-run log file is written for review.

---

## Error handling

- **Pagefile** is the critical step. If it fails, the script aborts entirely — no reboot, no partial state.
- **All other components** (TEMP, browser caches, search index) fail gracefully. Failures are logged and the script continues to the next component.
- **After reboot**, if Phase 2 validation detects a problem, it prompts you before attempting any undo.
- **Running browsers** are detected and you're given the option to let the script kill them or close them yourself.

---

## Logging and manifest

All logs are written to `C:\.logs\` by default (override with `-LogPath`).

| File | Purpose |
|---|---|
| `nvme-optimize-phase1-<timestamp>.log` | Phase 1 run log |
| `nvme-optimize-phase1-dryrun-<timestamp>.log` | Phase 1 dry-run log |
| `nvme-optimize-phase2-<timestamp>.log` | Phase 2 validation log |
| `nvme-optimize-undo-<timestamp>.log` | Undo run log |
| `nvme-optimization-manifest.json` | Change manifest — used by validate and undo scripts |

The manifest tracks every change with its original value, Volume GUID, and validation status. It is never deleted. If the script is re-run, the previous manifest is backed up with a timestamp.

---

## Safety

- No user documents, application binaries, or Windows system files are moved
- Only caches, temp files, and system-managed data that Windows recreates automatically are in scope
- Every change is idempotent — safe to re-run
- Drive identity is tracked by Volume GUID, not just drive letter — survives drive letter reassignment
- If validation fails after reboot, the script prompts before attempting undo
- If the NVMe drive is missing during undo, the script offers partial recovery (remove broken junctions, restore registry)
- `hiberfil.sys` (hibernation file) is intentionally left on C: — it cannot be moved due to a firmware-level constraint

### What is never touched

- `C:\Windows` (except `C:\Windows\Temp` — junctioned by design)
- `C:\Program Files` / `Program Files (x86)`
- `C:\Users\<User>` (entire profile)
- WinSxS, System32
- Registry keys outside those documented in the spec

---

## Testing

### Automated (Pester)

Unit tests with mocked dependencies cover all shared module functions:

```powershell
Invoke-Pester ./tests -Output Detailed
```

### Manual integration

See the [full specification](optimize-nvme-windows-fsd.md#testing-strategy) for the 12-step integration test matrix covering dry-run, live run, idempotency, undo, force mode, error cases, and missing-drive scenarios.

---

## Specification

The full functional specification is in [optimize-nvme-windows-fsd.md](optimize-nvme-windows-fsd.md).

---

## License

[MIT](LICENSE)

---

## Planned for future versions

- OneDrive cache relocation
- Windows Update download cache (`SoftwareDistribution\Download`)
- Visual Studio intermediate build directories
- Docker data root
- WSL VHDX files
