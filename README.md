# Spoofer

![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)

Change the hardware IDs Windows reports, then put them all back with one command.

- **17 modules** - machine GUIDs, SMBIOS cache, MAC, disk and volume IDs, monitor EDID, and more
- **Everything is backed up** before it changes, and one restore undoes the whole run
- **Preview first** - dry-run mode shows every change without writing anything
- **No install, no dependencies** - plain PowerShell

## Quick start

```powershell
git clone https://github.com/ard37880/Spoofer.git
cd Spoofer
.\Spoofer.cmd
```

It asks for admin rights, then shows a menu. That's it.

## Command line

```powershell
.\Spoofer.ps1 -Action Status                     # show current IDs
.\Spoofer.ps1 -Action Spoof -DryRun              # preview changes
.\Spoofer.ps1 -Action Spoof -Interactive         # pick what to change
.\Spoofer.ps1 -Action Spoof                      # change everything
.\Spoofer.ps1 -Action Restore -BackupId latest   # undo
```

Run `.\Spoofer.ps1 -Action Modules` to see every module and what it touches.

## Requirements

- Windows 10 or 11, 64-bit
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- Administrator rights (it asks for them)

Downloaded the ZIP instead of cloning? Run `Get-ChildItem -Recurse | Unblock-File` first.

## Good to know

- Modules marked **boot** in the checklist (`diskid`, `volumeguid`) touch what Windows needs to start. Press `b` in the checklist to skip them.
- Some IDs can't be changed from inside Windows, like firmware serials and the system drive's volume serial. Run `-Action Verify` to see what is actually hidden.
- Changing these IDs can sign you out of licensed software and may need Windows reactivated.

## Disclaimer

For machines you own or administer. Use at your own risk, and keep the backup until you've rebooted once.
