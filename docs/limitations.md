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

Re-run `-Action Status` after a few days if it matters to you.

## Deliberately out of scope

Refusals built into the tool, not oversights:

- **The MBR signature of a boot disk.** The boot configuration data references it
  by value; changing it leaves the machine unbootable. GPT disk GUIDs do not have
  this problem, and are changed. `diskid` skips MBR boot disks and says so.
- **The system volume's serial.** Its boot record cannot be locked while Windows
  is running from it. `volumeserial` handles other fixed volumes only. Changing
  the system volume's serial needs a boot from other media.
- **exFAT volume serials.** The exFAT boot region carries a checksum over eleven
  sectors. Writing four bytes without recomputing it produces a volume Windows
  may refuse to mount. `volumeserial` skips exFAT rather than risk it.
- **`DigitalProductId` / `DigitalProductId4`.** Windows activation reads these.
  The `productid` module rewrites the `ProductId` *string*, which is what
  licensing checks tend to look at, and leaves activation alone.
- **Domain-joined renames.** Renaming a domain-joined machine breaks its computer
  account's trust with the domain. `computername` skips it unless you pass
  `-Force`, and you will need to re-join afterwards.

## Things that can go wrong

- **A NIC driver can ignore the MAC override.** Wireless adapters in particular
  often reject a locally administered address. The `mac` module reads the address
  back after restarting the adapter and tells you when the driver ignored it. The
  backup entry is kept either way so the value can still be cleaned up.
- **`SystemInformation` may be TrustedInstaller-owned.** The `smbios` module takes
  ownership and grants Administrators full control when a write is denied. The
  original security descriptor is backed up first and a restore hands the key
  back to its previous owner.
- **A locked volume.** `volumeserial` needs an exclusive lock on the volume. If
  anything has a file open on it, the write fails cleanly and nothing is changed.
  `-AllowVolumeDismount` dismounts the volume instead, which is safe but will make
  open handles fail.
- **Drive letters can move.** Changing a GPT disk GUID does not disturb the
  `MountedDevices` mappings, which key on partition GUIDs. Changing an MBR
  signature on a data disk can, so its letters may be reassigned on the next boot.

## What this is not

This changes reported identity. It is not an anti-cheat bypass, it does not hide
anything from a kernel driver reading hardware directly, and it does not defeat
fingerprinting that combines many signals - installed software, timing, network
behaviour, account history - rather than reading one ID.

If you need a genuinely clean machine identity, the reliable answer is different
hardware or a fresh virtual machine.
