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
.\Spoofer.ps1 -Action Spoof                      # change everything
.\Spoofer.ps1 -Action Spoof -Interactive         # tick what to change
.\Spoofer.ps1 -Action Restore -BackupId latest   # change them back
```

Every module runs by default, the ones that can disturb licensing or the boot
configuration included. `-Interactive` gives you a checklist instead.

## Requirements

- Windows 10 or 11 (build 10240 or later)
- Windows PowerShell 5.1, which ships with both, or PowerShell 7+
- A **64-bit** shell for `Spoof` and `Restore`

Those two actions need administrator rights, and the script asks Windows for
them itself: run it from an ordinary prompt and it reopens elevated after the
UAC prompt. `-NoElevate` turns that off for unattended runs that are already
elevated.

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

# Pick from a checklist, then run.
.\Spoofer.ps1 -Action Spoof -Interactive

# Or change everything.
.\Spoofer.ps1 -Action Spoof
```

`Spoofer.cmd` is there if you would rather double-click; it forwards its
arguments and bypasses the execution policy for that one process only.

### Choosing what to change

`-Interactive` prints a checklist you can toggle before anything happens:

```
   #      Module            Tier      What it is
   1. [x] machineguid       Standard  Cryptography MachineGuid
   2. [x] machineid         Standard  Secondary machine identifiers
   ...
  12. [x] digitalproductid  Risky     Digital product id
  13. [x] edid              Advanced  Monitor EDID serials

   13 of 13 selected

   Toggle : numbers or names, e.g. "1 4 7" or "mac volumeserial"
   a all   n none   s standard   d advanced   r risky   i invert
   Enter to run the ticked modules, q to cancel
```

The same choices are available non-interactively: `-Module` to name them,
`-Exclude` to drop some, `-Tier` to pick a tier, and `-SafeOnly` for everything
except the Risky tier.

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
| `diskid` | Advanced | GPT disk GUID, or the MBR signature - boot disks included, with the boot configuration rewritten to match |
| `edid` | Advanced | The serial in each cached monitor EDID, checksum recomputed |
| `productid` | Risky | The Windows `ProductId` string |
| `digitalproductid` | Risky | The `DigitalProductId` blobs - the binary form of the installed product key |
| `volumeserial` | Risky | The `XXXX-XXXX` serial in every volume's boot record, NTFS backup sectors and exFAT checksums included |

Tiers describe blast radius, not effectiveness:

- **Standard** - reversible registry values, no restart, nothing else depends on them.
- **Advanced** - touches devices or the partition table, or needs a restart.
- **Risky** - can disturb software licensing or activation, or writes raw disk
  sectors.

All three run by default. `-SafeOnly` leaves out the Risky tier; `-Interactive`
lets you tick individual modules.

## Usage

```
.\Spoofer.ps1 [-Action <Status|Spoof|Restore|List|Remove|Modules>]
              [-Interactive]
              [-Module <names>] [-Exclude <names>]
              [-Tier <Standard|Advanced|Risky>] [-SafeOnly]
              [-Seed <int>] [-BackupId <id|latest>] [-Note <text>]
              [-DryRun] [-Force] [-Yes] [-NoElevate]
              [-IncludeVirtualAdapters] [-IncludeRemovableVolumes]
              [-SkipDomainRename] [-NoVolumeDismount]
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
# Tick what to change from a checklist.
.\Spoofer.ps1 -Action Spoof -Interactive

# Just the machine IDs and the MAC addresses.
.\Spoofer.ps1 -Action Spoof -Module machineguid,machineid,mac

# Everything except the two that touch activation.
.\Spoofer.ps1 -Action Spoof -Exclude productid,digitalproductid

# Everything except the Risky tier, without prompting.
.\Spoofer.ps1 -Action Spoof -SafeOnly -Yes

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
their own. `docs/limitations.md` is the honest account: read it before assuming a
value stayed changed. `docs/identifiers.md` maps every value the tool touches to
where it lives and what reads it.

In short: this changes what Windows *reports*. It does not reflash firmware, and
it does not touch anything a kernel driver reads directly from hardware.

Two things are worth knowing before a full run:

- **The MBR boot disk.** Its signature is referenced by the boot configuration.
  `diskid` exports the boot store, changes the signature, and rewrites the boot
  entries with `bcdboot`; if any of that fails, the signature goes straight back
  and the store is re-imported. A restart is still the only real proof.
- **The system volume's serial.** Windows will not let the volume it is running
  from be locked, so the write is attempted and reported honestly rather than
  skipped silently. Boot from Windows PE and run the same command there and it
  works, because `C:` is not the system volume in that environment.

## Development

```powershell
.\tests\Run-Tests.ps1
```

The suite has no dependencies - it ships its own harness - so it runs on a fresh
Windows box with no module installs, and on Linux and macOS for CI. It covers
identifier generation, the backup/restore engine, registry payload encoding, path
parsing, boot-record parsing, the provider catalogue, and a full spoof/restore
cycle against a synthetic provider.

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
tests/                   test harness and suite
docs/                    identifier map and limitations
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
