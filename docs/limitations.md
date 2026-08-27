# Limitations

What Spoofer changes is what Windows *reports*. That covers most of what
software actually reads, but not all of it, and a few values do not stay changed.
This page is the honest account.

## Not changeable from user mode

These are read below the layer any script can reach. Spoofer does not attempt
them, and a tool that claims to change them from PowerShell is not doing what it
says.

| Identifier | Where it really lives | Why not |
|---|---|---|
| Drive serial number | Drive firmware | Reported over ATA/NVMe by the drive itself. Changing it means a vendor firmware tool, and on most drives it is not writable at all. |
| SMBIOS / DMI tables | Motherboard firmware | `Win32_BIOS`, `Win32_BaseBoard` and `Win32_ComputerSystemProduct` read the firmware tables directly. The `smbios` module rewrites the registry *cache* of these strings, which is what most user-mode fingerprinting reads - but not those WMI classes. Changing the real values means a BIOS/DMI editor, or a VM's config file. |
| Machine UUID | SMBIOS type 1 | Same as above: `Win32_ComputerSystemProduct.UUID` comes from firmware. |
| CPU ID and features | The CPU | `CPUID` is a processor instruction. Nothing in software intercepts it. |
| GPU device and vendor IDs | PCI configuration space | Read from the bus. The driver reports what the card says. |
| Monitor EDID | The display's own EEPROM | Windows caches it, but anything reading it properly asks the display. |
| TPM endorsement key | The TPM | The whole point of the part. |
| NIC burned-in address | The adapter's EEPROM | The `mac` module makes the driver *report* a different address, which is what the network and nearly all software see. The burned-in address is untouched and can still be queried through some driver interfaces. |

## Values that regenerate on their own

Changed successfully, then quietly restored by Windows:

- **`SusClientId`** - Windows Update regenerates this pair on its next scan.
  Treat the `telemetry` module's update ids as short-lived.
- **Advertising id** - resets when the user toggles ad personalisation, and it is
  per-user, not machine-wide.
- **`ComputerHardwareIds`** - Windows recomputes these from the SMBIOS fields
  when the hardware configuration changes. The `smbios` module writes a coherent
  set, but a driver or hardware change can prompt a recalculation from the real
  firmware values.
- **Monitor EDID** - the `edid` module rewrites Windows' cached copy. Windows
  rebuilds that cache from the display itself whenever the monitor is
  re-detected: a driver update, a cable swap, a different port.

Re-run `-Action Status` after a few days if it matters to you.

## Handled rather than avoided

Four things a hardware ID tool usually declines to touch. All of them run by
default here, each with the work that makes it safe:

- **The identifier of a boot disk, GPT and MBR alike.** The BCD device element
  carries the disk identity, so changing either one leaves the boot entries
  pointing at a disk that no longer answers to that name and the machine stops
  at `0xc000000e`. `diskid` exports the boot store into the backup with
  `bcdedit /export`, changes the identifier, and rewrites the boot entries with
  `bcdboot`. If the export fails the disk is left alone; if the repair fails the
  identifier is put straight back and the store re-imported. On a total failure
  the exact recovery commands are printed. **A restart is the only real proof
  that a repaired boot configuration works - keep the backup until the machine
  has booted once.**
- **exFAT volume serials.** The exFAT boot region carries a checksum over eleven
  sectors, which is why most tools skip it. `volumeserial` writes the serial into
  both the main and backup boot regions and recomputes both checksums, so the
  volume still mounts. The checksum is cross-checked against the specification
  formula in the test suite.
- **The NTFS backup boot sector.** NTFS keeps a second copy of its boot record in
  the last sector of the partition, carrying the same serial. Its position is
  derived from the sector count NTFS records at offset 0x28 rather than guessed
  from the partition size, and it is updated alongside the primary so the two
  never disagree.
- **Domain-joined renames.** `computername` renames a domain-joined machine like
  any other. This breaks the computer account's trust with the domain: re-join
  it after the restart, or restore the backup. `-SkipDomainRename` leaves a
  domain-joined machine alone.

## Still not possible from a running Windows

- **The system volume's serial.** Windows will not grant an exclusive lock on the
  volume it is running from, and it cannot be dismounted either. `volumeserial`
  attempts it like any other volume and reports the refusal rather than skipping
  it silently.

  It does work offline. Boot from Windows PE or another Windows installation,
  where that volume is no longer the system volume, and run the same command:

  ```powershell
  .\Spoofer.ps1 -Action Spoof -Module volumeserial
  ```

- **`DigitalProductId` and activation.** `digitalproductid` rewrites the blobs
  and keeps their length and length field intact, but the contents no longer
  encode a valid key. Expect Windows to report a different or invalid key and to
  want re-activating. Restoring the backup puts the original key back byte for
  byte.

## Things that can go wrong

- **A NIC driver can ignore the MAC override.** Wireless adapters in particular
  often reject a locally administered address. The `mac` module reads the address
  back after restarting the adapter and tells you when the driver ignored it. The
  backup entry is kept either way so the value can still be cleaned up.
- **`SystemInformation` may be TrustedInstaller-owned.** The `smbios` module takes
  ownership and grants Administrators full control when a write is denied. The
  original security descriptor is backed up first and a restore hands the key
  back to its previous owner.
- **A locked volume.** `volumeserial` needs an exclusive lock on the volume, and
  dismounts it when it cannot get one - that is the default, because in practice
  most volumes have something open on them. `-NoVolumeDismount` makes it fail
  cleanly instead, changing nothing.
- **Drive letters can move.** Changing a GPT disk GUID does not disturb the
  `MountedDevices` mappings, which key on partition GUIDs. Changing an MBR
  signature on a data disk can, so its letters may be reassigned on the next boot.
- **The system volume's GUID.** `volumeguid` renames every `\??\Volume{...}`
  entry in `MountedDevices` except the one whose mapping data matches the
  `\DosDevices` entry for the system drive. The mount manager resolves the boot
  volume through that name early in startup, and one identifier left alone is a
  far better outcome than a machine that will not start.
- **Dismounting a busy volume.** `volumeserial` dismounts a volume it cannot lock,
  which is the only way to write to one with open handles. Anything holding a
  file on it will see that handle fail. `-NoVolumeDismount` makes it refuse
  rather than dismount.

## Known gaps

Not skips so much as work that is not done yet:

- **Extension blocks in EDID.** Only block 0 is rewritten and re-checksummed;
  CTA-861 extension blocks are left exactly as they were.
- **GPT partition GUIDs.** The parsing and checksum half is written and tested
  in `src/Gpt.psm1`: it reads a partition table, rewrites an entry's GUID, and
  recomputes both the entry-array CRC32 and the header CRC32 that every reader
  checks. What is not wired up is the disk half, because applying it means
  writing raw sectors to `\\.\PhysicalDriveN`, and a bad write there costs the
  whole disk rather than one value. It also needs the boot configuration and
  `MountedDevices` updated alongside it, both of which reference partition GUIDs
  on a UEFI system.
- **The machine SID.** Changing it breaks local accounts, profiles and any domain
  membership. Sysinternals withdrew NewSID over exactly this; the supported
  answer is sysprep on a fresh image, not an in-place edit.

## Browser fingerprinting

The `browser` module clears cookies, local and session storage, IndexedDB and
service workers. Those are the identifiers a site *stored on your machine*, and
clearing them genuinely resets that half.

It does not touch the browser's fingerprint, which is the other half and the
harder one:

- the canvas and WebGL hashes, which come from how your GPU and drivers
  rasterise a test image
- the WebGL renderer string, which names your graphics card
- the installed font list, enumerated by measuring text
- screen geometry, colour depth and device pixel ratio
- the AudioContext signature
- the TLS handshake shape (JA3), fixed before any HTTP is sent

None of those are files on disk, so no system tool moves them. They are
properties of the browser and the machine it runs on, and changing them is the
browser's job: Tor Browser, Firefox with `privacy.resistFingerprinting`, or
Brave's per-site randomisation.

Randomising badly is worse than not randomising. A machine presenting a fresh
unique canvas hash on every visit is itself a rare and memorable signal, which
is why Tor aims for every user looking identical rather than every user looking
different.

## What this is not

This changes reported identity. It is not an anti-cheat bypass, it does not hide
anything from a kernel driver reading hardware directly, and it does not defeat
fingerprinting that combines many signals - installed software, timing, network
behaviour, account history - rather than reading one ID.

If you need a genuinely clean machine identity, the reliable answer is different
hardware or a fresh virtual machine.
