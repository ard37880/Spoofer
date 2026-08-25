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

## edid - Advanced

| Value | Location |
|---|---|
| EDID | `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<monitor>\<instance>\Device Parameters\EDID` |

Windows' cached copy of each display's EDID. Three things change: the 32-bit
serial at bytes 12-15, the text of any descriptor block tagged 0xFF (the printed
serial - leaving it would undo the point of changing the numeric one), and the
block checksum at byte 127, which is recomputed so every byte of the block sums
to zero modulo 256. Descriptors carrying anything else, such as the display name
at tag 0xFC, are left alone, as are CTA-861 extension blocks.

Windows rebuilds this cache from the display when the monitor is re-detected.

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

## digitalproductid - Risky

| Value | Location | Type |
|---|---|---|
| DigitalProductId | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DigitalProductId` | REG_BINARY |
| DigitalProductId4 | `...\CurrentVersion\DigitalProductId4` | REG_BINARY |

The binary form of the installed product key, and what the activation stack and
the "installed key" readers parse. The blob length and the little-endian length
field in the first four bytes are preserved so the structure stays valid; the
rest is randomised, which means it no longer encodes a real key.

Expect Windows to report a different or invalid key and to want re-activating.
Both blobs are backed up byte for byte, so a restore returns the original key
exactly.

## volumeserial - Risky

The serial number in each fixed volume's boot record - the `XXXX-XXXX` value
`vol` and `dir` print.

| Filesystem | Offset | Width | What else is rewritten |
|---|---|---|---|
| NTFS | `0x48` | 8 bytes (Windows displays the low 32 bits) | The backup boot sector in the last sector of the partition |
| exFAT | `0x64` | 4 bytes | The backup boot region, and the checksum sector of both regions |
| FAT32 | `0x43` | 4 bytes | - |
| FAT16/FAT12 | `0x27` | 4 bytes | - |

Each filesystem needs a different amount of the volume rewritten, so the provider
works out the full set of byte ranges first and saves every one of them - inline
and as files under `files\` - before writing anything.

- **NTFS** keeps a second copy of its boot record in the last sector of the
  partition. Its position comes from the sector count NTFS records at offset
  0x28, read from the volume itself rather than inferred from the partition size,
  and it is updated alongside the primary so the two never disagree.
- **exFAT** follows each of its two boot regions with a checksum over the
  region's first eleven sectors, skipping the three bytes that change while the
  volume is mounted (VolumeFlags at 106 and 107, PercentInUse at 112). Both
  regions get the new serial and both checksums are recomputed; without that the
  volume stops mounting.

The volume is locked before any write, and dismounted if it cannot be locked -
`-NoVolumeDismount` makes it refuse instead. The system volume is attempted like
any other, but Windows will not let the volume it is running from be locked; see
`limitations.md` for the offline procedure that does work.

On restore, the current boot record's filesystem is checked against the backup
before writing, so a volume reformatted or re-lettered since the backup is
refused rather than overwritten.
