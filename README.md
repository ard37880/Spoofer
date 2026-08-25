# Spoofer

A hardware identifier tool for Windows 10 and 11. It rewrites the values Windows
exposes to software as "which machine is this" - and puts every one of them back
on request.

Nothing is changed without being recorded first. Each run writes a backup session
containing the original value of everything it touched, and `-Action Restore`
replays that session to return the machine to exactly the state it was in.

```powershell
.\Spoofer.ps1 -Action Status                     # what the identifiers are now
.\Spoofer.ps1 -Action Spoof -DryRun              # what would change
.\Spoofer.ps1 -Action Spoof                      # change them
.\Spoofer.ps1 -Action Restore -BackupId latest   # change them back
```

## Requirements

- Windows 10 or 11 (build 10240 or later)
- Windows PowerShell 5.1, which ships with both, or PowerShell 7+
- An elevated **64-bit** shell for `Spoof` and `Restore`

A 32-bit PowerShell on 64-bit Windows is refused rather than run: registry writes
would be redirected into `WOW6432Node` and would silently miss the real values.

## Getting started

```powershell
git clone https://github.com/ard37880/Spoofer.git
cd Spoofer

# Look before you leap: reads only, no elevation needed for most of it.
.\Spoofer.ps1 -Action Status

# Show every change that would be made, and write nothing.
.\Spoofer.ps1 -Action Spoof -DryRun
```

Then, from an elevated prompt:

```powershell
.\Spoofer.ps1 -Action Spoof
```

`Spoofer.cmd` does the elevation for you if you would rather double-click; it
forwards its arguments to the script and bypasses the execution policy for that
one process only.

## What it changes

Run `.\Spoofer.ps1 -Action Modules` for the current list with full detail.

| Module | Tier | What it rewrites |
|---|---|---|
| `machineguid` | Standard | `Cryptography\MachineGuid`, the value most software treats as the machine ID |
| `machineid` | Standard | SQM/telemetry machine id, Windows Media unique id, Remote Desktop client hardware id |
| `hwprofile` | Standard | `HwProfileGuid` for every hardware profile |
| `windowsinstall` | Standard | Build GUID and the OS install timestamp |
| `telemetry` | Standard | Windows Update client id, per-user advertising id |
| `smbios` | Advanced | Cached SMBIOS strings: manufacturer, model, family, SKU, BIOS vendor/version/date |
| `computername` | Advanced | Hostname, in all four places Windows keeps it (needs a restart) |
| `mac` | Advanced | A locally administered MAC address on each physical adapter |
| `diskid` | Advanced | GPT disk GUID, or the MBR signature on non-boot disks |
| `productid` | Risky | The Windows `ProductId` string |
| `volumeserial` | Risky | The `XXXX-XXXX` serial in each non-system volume's boot record |

Tiers describe blast radius, not effectiveness:

- **Standard** - reversible registry values, no restart, nothing else depends on them.
- **Advanced** - touches devices or the partition table, or needs a restart.
- **Risky** - can disturb software licensing or, for `volumeserial`, writes a raw
  disk sector. Not selected unless you ask: `-IncludeRisky`, or name the module.

By default `Spoof` runs the Standard and Advanced tiers.

## Usage

```
.\Spoofer.ps1 [-Action <Status|Spoof|Restore|List|Remove|Modules>]
              [-Module <names>] [-Tier <Standard|Advanced|Risky>] [-IncludeRisky]
              [-Seed <int>] [-BackupId <id|latest>] [-Note <text>]
              [-DryRun] [-Force] [-Yes]
              [-IncludeVirtualAdapters] [-AllowVolumeDismount]
              [-NoRestartPrompt] [-LogLevel <Debug|Info|Warn|Error>]
```

### Actions

| Action | What it does |
|---|---|
| `Status` | Prints the current value of every identifier. The default. |
| `Spoof` | Backs up, then changes, the selected identifiers. |
| `Restore` | Replays a backup session, putting the original values back. |
| `List` | Lists stored backups and whether each has been restored. |
| `Remove` | Deletes a stored backup. |
| `Modules` | Describes every module and the exact values it owns. |

### Examples

```powershell
# Just the machine IDs and the MAC addresses.
.\Spoofer.ps1 -Action Spoof -Module machineguid,machineid,mac

# Everything, including the risky tier, without prompting.
.\Spoofer.ps1 -Action Spoof -IncludeRisky -Yes

# Reproducible identity: the same seed always generates the same values.
.\Spoofer.ps1 -Action Spoof -Seed 20260825 -Note 'test rig profile A'

# Undo the last spoof.
.\Spoofer.ps1 -Action Restore -BackupId latest

# Undo one module from an older backup, leaving the rest of it in place.
.\Spoofer.ps1 -Action Restore -BackupId 20260825-121500 -Module mac

# What have I got stored?
.\Spoofer.ps1 -Action List
```

## Reverting

Every `Spoof` writes a session under `%ProgramData%\Spoofer\backups\<id>\`:

```
manifest.json     every original value, with its registry type preserved
files\            raw blobs, such as a volume's original boot sector
```

`-Action Restore` replays a session's entries in reverse order, so changes unwind
in the opposite order they were made. Points worth knowing:

- **`latest` means the newest backup you have not restored yet.** Spoof twice and
  restore twice, and you walk back through the stack one step at a time.
- **A partial restore stays open.** If an entry fails, the session is left marked
  un-restored so you can fix the cause and run the same command again. One
  failing entry never stops the others.
- **Restores are verified where it matters.** A disk is checked against its
  recorded serial, and a volume against its filesystem, before anything is
  written - so a reformat or a drive-letter change since the backup is refused
  rather than acted on.
- **A backup is worth keeping until you are sure.** `-Action Remove` warns before
  deleting one that has not been restored, because that is the only record of
  the original values.

Set `SPOOFER_ROOT` to move the backup and log directory somewhere else - onto a
removable drive, for instance, so the record does not live on the machine being
changed.

## What it does not do

Some identifiers are not writable from user mode at all, and some regenerate on
their own. Check before assuming a
value stayed changed.

In short: this changes what Windows *reports*. It does not reflash firmware, and
it does not touch anything a kernel driver reads directly from hardware.

## Development

### Layout

```
Spoofer.ps1              command line entry point
Spoofer.cmd              elevating launcher
src/
  Common.psm1            logging, environment probes, identifier generation
  Native.psm1            P/Invoke: token privileges, locked boot-sector I/O
  BackupStore.psm1       backup sessions and the restore dispatcher
  RegistryHelper.psm1    registry read/write with automatic backup
  ProviderCommon.psm1    shared helpers for registry-backed providers
  ProviderRegistry.psm1  provider discovery and selection
  Providers/*.psm1       one module per group of identifiers
```

### Adding a module

Drop a `.psm1` into `src/Providers/` exporting a single
`Get-SpooferProviderDefinition` that returns a descriptor with `Name`, `Title`,
`Tier`, `Description`, `Targets`, and the `GetState` and `Invoke` scriptblocks.
It is picked up automatically and validated at load time. For registry values,
`New-SpooferRegistryTarget` plus `Invoke-SpooferRegistryTarget` handles the
backup, the dry-run path and the output for you - `src/Providers/01-MachineGuid.psm1`
is about as small as a provider gets.

Anything that is not a registry value needs a restore handler: call
`Register-SpooferRestoreHandler` with the entry type and a scriptblock that
undoes it. `09-NetworkAdapter.psm1` and `11-VolumeSerial.psm1` are the worked
examples.

## Scope

This is for machines you own or administer. Changing these values will log you
out of software licensed to this machine, and services that expect a stable
device identity may treat the result as a new or suspicious device. That is the
point of the tool, and it is also the reason every change is backed up first.
