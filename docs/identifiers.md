# Identifier map

Every value Spoofer touches, where it lives, and what reads it. Grouped by
module; run `.\Spoofer.ps1 -Action Modules` for the same list from the tool
itself.

## machineguid - Standard

| Value | Location |
|---|---|
| MachineGuid | `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` |

Generated once at install. The single most widely read machine identifier on
Windows: analytics SDKs, licensing libraries and telemetry all reach for it
first. Format is a bare lower-case GUID with dashes.

## machineid - Standard

| Value | Location |
|---|---|
| SQMClient MachineId | `HKLM\SOFTWARE\Microsoft\SQMClient\MachineId` |
| Windows Media UniqueID | `HKLM\SOFTWARE\Microsoft\Windows Media\WMSDK\General\UniqueID` |
| Terminal Services ClientHWID | `HKLM\SOFTWARE\Microsoft\MSLicensing\HardwareID\ClientHWID` |

Secondary machine ids that predate `MachineGuid` and are still read by older
software. Written braced and upper-case, matching how Windows writes them - a
lower-case value here is itself distinctive. Any of these that is absent on a
given system is left absent.

## hwprofile - Standard

| Value | Location |
|---|---|
| HwProfileGuid | `HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\<nnnn>\HwProfileGuid` |

Created the first time Windows enumerates the machine's devices. Every profile
key is enumerated, so a machine with more than one is handled in full.

## windowsinstall - Standard

| Value | Location | Type |
|---|---|---|
| BuildGUID | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\BuildGUID` | REG_SZ |
| InstallDate | `...\CurrentVersion\InstallDate` | REG_DWORD, Unix seconds |
| InstallTime | `...\CurrentVersion\InstallTime` | REG_QWORD, FILETIME |

The install timestamp is a strong signal on its own: a machine that claims to
have been installed this morning is unusual. A date between one month and roughly
two and a half years ago is generated, and both values are derived from the same
moment so they stay consistent - an inconsistent pair is louder than either value.

## telemetry - Standard

| Value | Location |
|---|---|
| SusClientId | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\SusClientId` |
| SusClientIDValidation | `...\WindowsUpdate\SusClientIDValidation` |
| Advertising Id | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Id` |

Windows Update regenerates its client id pair on the next scan, and the
advertising id is per-user rather than machine-wide. See `limitations.md`.

## smbios - Advanced

All under `HKLM\SYSTEM\CurrentControlSet\Control\SystemInformation`:

`SystemManufacturer`, `SystemProductName`, `SystemFamily`, `SystemSKU`,
`SystemVersion`, `BIOSVendor`, `BIOSVersion`, `BIOSReleaseDate`,
`ComputerHardwareId`, `ComputerHardwareIds`

Windows' cache of the SMBIOS/DMI strings, and what most user-mode fingerprinting
reads for "what machine is this". Values are drawn from one coherent vendor
profile - a Dell board does not get an ASUS BIOS - because a mismatched set is a
stronger signal than the original values were.

The key is often owned by TrustedInstaller. Ownership is taken when a write is
denied, and the original security descriptor is backed up and restored.

This is the cache only: `Win32_BIOS` and `Win32_ComputerSystemProduct` read the
firmware tables directly and are unaffected.

## computername - Advanced, restart required

| Value | Location |
|---|---|
| ComputerName | `HKLM\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName` |
| ActiveComputerName | `HKLM\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName` |
| Hostname | `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Hostname` |
| NV Hostname | `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname` |

All four have to agree. Windows reads `ActiveComputerName` until the next boot,
which is why a restart is needed for the change to take everywhere. Names are
generated in the Windows OOBE shape, `DESKTOP-A7K2M9Q`.

Skipped on domain-joined machines unless `-Force` is given.

## mac - Advanced

| Value | Location |
|---|---|
| NetworkAddress | `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\<nnnn>\NetworkAddress` |

Adapters are matched to their class key by interface GUID rather than by index,
which can shift between boots. Addresses are generated unicast and locally
administered - the multicast bit clear, the locally administered bit set - so they
can never collide with a real vendor OUI.

Each adapter is restarted so the driver re-reads the value, then the address is
read back: if the driver ignored the override, you are told.

Virtual adapters are excluded by default; `-IncludeVirtualAdapters` includes them.

## diskid - Advanced

| Partition style | Value |
|---|---|
| GPT | Disk GUID (`Set-Disk -Guid`) |
| MBR | Disk signature (`Set-Disk -Signature`), non-boot disks only |

Written in the partition table, not the drive firmware. MBR boot disks are
skipped: the boot configuration references the signature by value, so changing it
leaves the machine unbootable. GPT boot entries reference *partition* GUIDs, which
this does not touch, so a GPT disk GUID is safe to rewrite.

On restore the disk's recorded serial is checked first, so an identifier is never
written onto whatever now happens to hold that disk number.

## productid - Risky

| Value | Location |
|---|---|
| ProductId | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProductId` |
| Default ProductId | `...\CurrentVersion\DefaultProductKey\ProductId` |

Shown in System properties and read by some licensing checks. Both values are
written identically. This is not the product key: `DigitalProductId`, which
Windows activation uses, is deliberately left alone, so changing this does not
deactivate Windows. Third-party software that pinned a licence to it will see a
different machine.

## volumeserial - Risky

The serial number in each fixed volume's boot record - the `XXXX-XXXX` value
`vol` and `dir` print.

| Filesystem | Offset | Width |
|---|---|---|
| NTFS | `0x48` | 8 bytes (Windows displays the low 32 bits) |
| FAT32 | `0x43` | 4 bytes |
| FAT16/FAT12 | `0x27` | 4 bytes |
| exFAT | - | skipped; the boot region is checksummed across eleven sectors |

Changing it means writing that sector back, so the whole original sector is saved
to the backup session - both inline and as a file under `files\` - before
anything is written. The volume is locked first; `-AllowVolumeDismount` dismounts
it instead when files are open.

The system volume is always skipped: its boot record cannot be locked while
Windows is running from it.

On restore, the current sector's filesystem is checked against the backup before
writing, so a volume reformatted or re-lettered since the backup is refused
rather than overwritten.

> NTFS keeps a backup boot sector at the end of the volume carrying the same
> serial. It is only consulted when the primary is unreadable, so the two being
> out of step is harmless - but `chkdsk` may mention it.
