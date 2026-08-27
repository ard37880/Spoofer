<#
.SYNOPSIS
    Disk-level identifiers: the GPT disk GUID and the MBR disk signature.
.DESCRIPTION
    These are the identifiers written in the partition table, not the serial
    number burned into the drive's firmware - that one is not writable from user
    mode at all.

    Changing the identifier of the disk Windows boots from is handled rather
    than avoided, and that applies to GPT and MBR alike. The BCD device element
    carries the disk identity, so either one leaves the boot entries pointing at
    a disk that no longer answers to that name. The store is exported to the
    backup first, the identifier is changed, and bcdboot then rewrites the boot
    entries against the new one. If any part of that fails the identifier is put
    straight back and the store re-imported, so the disk never sits in a state
    where the boot entries disagree with it.
.NOTES
    A reboot is the only real test of a repaired boot configuration.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1') -DisableNameChecking

function Get-SpooferDisk {
    <#
    .SYNOPSIS
        Disks carrying a rewritable identifier, with the flags needed to decide
        how much care each one needs.
    #>
    [CmdletBinding()]
    param()

    try {
        $disks = @(Get-Disk -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Warn -Message "Get-Disk is unavailable: $($_.Exception.Message)"
        return @()
    }

    foreach ($disk in $disks) {
        if ($disk.PartitionStyle -eq 'RAW') { continue }

        $isBootCritical = ([bool]$disk.IsBoot -or [bool]$disk.IsSystem)

        [pscustomobject]@{
            Number         = [int]$disk.Number
            FriendlyName   = [string]$disk.FriendlyName
            SerialNumber   = [string]$disk.SerialNumber
            PartitionStyle = [string]$disk.PartitionStyle
            Guid           = [string]$disk.Guid
            Signature      = $disk.Signature
            IsBootCritical = $isBootCritical
            # Any boot disk needs the boot configuration repaired afterwards,
            # GPT included. The BCD device element carries the disk identity
            # alongside the partition, so changing a GPT disk GUID leaves the
            # boot entries pointing at a disk that no longer answers to that
            # name and the machine stops at 0xc000000e. An earlier version of
            # this module assumed only MBR signatures mattered and made a test
            # machine unbootable.
            NeedsBcdRepair = [bool]$isBootCritical
            IsReadOnly     = [bool]$disk.IsReadOnly
        }
    }
}

function Set-SpooferDiskIdentity {
    <#
    .SYNOPSIS
        Applies a new GPT GUID or MBR signature to one disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][ValidateSet('GPT', 'MBR')][string]$PartitionStyle,
        [Parameter(Mandatory)][object]$Value
    )

    if ($PartitionStyle -eq 'GPT') {
        Set-Disk -Number $Number -Guid ([string]$Value) -ErrorAction Stop
    } else {
        Set-Disk -Number $Number -Signature ([uint32]$Value) -ErrorAction Stop
    }
}

function Export-SpooferBcdStore {
    <#
    .SYNOPSIS
        Exports the boot configuration data store to a file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $result = Invoke-SpooferProcess -FilePath 'bcdedit.exe' -ArgumentList @('/export', ('"{0}"' -f $Path))
    if (-not $result.Success) {
        throw ("bcdedit /export failed ({0}): {1}" -f $result.ExitCode, ($result.Error + $result.Output).Trim())
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'bcdedit /export reported success but wrote no file.'
    }

    return $Path
}

function Import-SpooferBcdStore {
    <#
    .SYNOPSIS
        Restores a previously exported boot configuration data store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "The exported boot configuration store is missing from '$Path'."
    }

    $result = Invoke-SpooferProcess -FilePath 'bcdedit.exe' -ArgumentList @('/import', ('"{0}"' -f $Path))
    if (-not $result.Success) {
        throw ("bcdedit /import failed ({0}): {1}" -f $result.ExitCode, ($result.Error + $result.Output).Trim())
    }
}

function Repair-SpooferBootConfiguration {
    <#
    .SYNOPSIS
        Rewrites the boot entries so they reference the disk's new signature.
    .DESCRIPTION
        bcdboot with no /s picks the system partition itself, which matters
        because on a BIOS system that partition often has no drive letter. The
        result is verified by enumerating the default entry: bcdboot reporting
        success while leaving an unreadable store would otherwise go unnoticed
        until the machine failed to boot.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $firmware = if ($env:firmware_type) { $env:firmware_type } else { 'Legacy' }
    $format   = if ($firmware -eq 'UEFI') { 'UEFI' } else { 'BIOS' }

    $result = Invoke-SpooferProcess -FilePath 'bcdboot.exe' -ArgumentList @(('"{0}"' -f $env:SystemRoot), '/f', $format)

    if (-not $result.Success) {
        Write-SpooferLog -Level Error -Message ("bcdboot failed ({0}): {1}" -f $result.ExitCode, ($result.Error + $result.Output).Trim())
        return $false
    }

    $verify = Invoke-SpooferProcess -FilePath 'bcdedit.exe' -ArgumentList @('/enum', '{default}')
    if (-not $verify.Success) {
        Write-SpooferLog -Level Error -Message 'bcdboot reported success but the boot store could not be read back.'
        return $false
    }

    Write-SpooferLog -Level Success -Message "Boot configuration rewritten for $format firmware."
    return $true
}

Register-SpooferRestoreHandler -Type 'DiskId' -Handler {
    param($Entry)

    $disk = @(Get-Disk -Number $Entry.Number -ErrorAction SilentlyContinue)
    if ($disk.Count -eq 0) {
        throw "Disk $($Entry.Number) is no longer present."
    }

    # Disk numbers are reassigned when hardware changes, so the recorded serial
    # is checked before writing an identifier onto whatever now holds that number.
    if ($Entry.SerialNumber -and ([string]$disk[0].SerialNumber).Trim() -ne ([string]$Entry.SerialNumber).Trim()) {
        throw ("Disk {0} is now '{1}' (serial {2}), not the disk that was backed up (serial {3}). Refusing to write to it." -f `
                $Entry.Number, $disk[0].FriendlyName, $disk[0].SerialNumber, $Entry.SerialNumber)
    }

    if ($Entry.PartitionStyle -eq 'GPT') {
        Set-Disk -Number $Entry.Number -Guid ([string]$Entry.Value) -ErrorAction Stop
        return "Disk $($Entry.Number) GPT GUID restored."
    }

    Set-Disk -Number $Entry.Number -Signature ([uint32]$Entry.Value) -ErrorAction Stop

    # The exported store is replayed by its own BcdStore entry, which was added
    # before this one and so is restored after it - by which point the signature
    # it refers to is back in place.
    return "Disk $($Entry.Number) MBR signature restored."
}

Register-SpooferRestoreHandler -Type 'BcdStore' -Handler {
    param($Entry)

    $path = Join-Path $Entry.SessionPath $Entry.File
    Import-SpooferBcdStore -Path $path
    return 'Boot configuration store re-imported.'
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'diskid'
        Title          = 'Disk GUID / MBR signature'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Rewrites the GPT disk GUID or the MBR disk signature on every disk. On an MBR boot disk the boot configuration is exported first and rewritten with bcdboot afterwards, and both are rolled back together if the repair fails.'
        Targets        = @('Partition table of every initialised disk', 'Boot configuration data store, on an MBR boot disk')

        GetState = {
            param($Context)

            $disks = @(Get-SpooferDisk)
            if ($disks.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Disks'; Value = 'none found'; Note = '' })
            }

            foreach ($disk in $disks) {
                $value = if ($disk.PartitionStyle -eq 'GPT') { $disk.Guid } else { '0x{0:X8}' -f $disk.Signature }

                $note = $disk.PartitionStyle
                if ($disk.NeedsBcdRepair) { $note += ', boot disk - boot config will be rewritten' }
                if ($disk.IsReadOnly)     { $note += ', read-only' }

                [pscustomobject]@{
                    Item  = 'Disk {0} [{1}]' -f $disk.Number, $disk.FriendlyName
                    Value = $value
                    Note  = $note
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $disks = @(Get-SpooferDisk)
            if ($disks.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No initialised disks found; nothing to change.'
                return @()
            }

            $results = New-Object System.Collections.ArrayList

            foreach ($disk in $disks) {
                $label = 'Disk {0} {1} id' -f $disk.Number, $disk.PartitionStyle

                if ($disk.IsReadOnly) {
                    Write-SpooferLog -Level Warn -Message "Skipping disk $($disk.Number): the disk is marked read-only, so nothing can be written to it."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $null; NewValue = $null
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = 'Disk is read-only'
                    })
                    continue
                }

                $oldValue = if ($disk.PartitionStyle -eq 'GPT') { $disk.Guid } else { $disk.Signature }
                $newValue = if ($disk.PartitionStyle -eq 'GPT') {
                    New-SpooferGuid -Format B
                } else {
                    [uint32]([System.BitConverter]::ToUInt32((Get-SpooferRandomByte -Count 4), 0))
                }

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $oldValue -NewValue $newValue -Simulated
                    if ($disk.NeedsBcdRepair) {
                        Write-SpooferLog -Level Info -Message "Disk $($disk.Number) is the boot disk; the boot configuration would be exported and rewritten with bcdboot."
                    }
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                $bcdExportPath = $null

                if ($disk.NeedsBcdRepair) {
                    Write-SpooferLog -Level Warn -Message "Disk $($disk.Number) is the boot disk. Exporting the boot configuration before touching its identifier."
                    try {
                        $fileName      = 'bcd-disk{0}.bcd' -f $disk.Number
                        $bcdExportPath = New-SpooferBackupFilePath -Session $Session -Name $fileName
                        Export-SpooferBcdStore -Path $bcdExportPath | Out-Null

                        if ($Session) {
                            # Added before the DiskId entry so that a restore,
                            # which replays in reverse, puts the signature back
                            # first and re-imports the store afterwards.
                            Add-SpooferBackupEntry -Session $Session -Type 'BcdStore' -Module 'diskid' `
                                -Label ('Boot configuration (disk {0})' -f $disk.Number) `
                                -Data @{ SessionPath = $Session.Path; File = ('files\{0}' -f $fileName) } | Out-Null
                        }
                    } catch {
                        Write-SpooferLog -Level Error -Message "Could not export the boot configuration: $($_.Exception.Message). Leaving disk $($disk.Number) alone rather than changing a signature that could not be backed out."
                        [void]$results.Add([pscustomobject]@{
                            Label = $label; OldValue = $oldValue; NewValue = $newValue
                            Changed = $false; Simulated = $false; Skipped = $true; Reason = 'Boot configuration export failed'
                        })
                        continue
                    }
                }

                if ($Session) {
                    Add-SpooferBackupEntry -Session $Session -Type 'DiskId' -Module 'diskid' -Label $label -Data @{
                        Number         = $disk.Number
                        PartitionStyle = $disk.PartitionStyle
                        SerialNumber   = $disk.SerialNumber
                        Value          = if ($disk.PartitionStyle -eq 'GPT') { [string]$oldValue } else { [int64]$oldValue }
                    } | Out-Null
                }

                try {
                    Set-SpooferDiskIdentity -Number $disk.Number -PartitionStyle $disk.PartitionStyle -Value $newValue
                } catch {
                    Write-SpooferLog -Level Error -Message "Disk $($disk.Number): $($_.Exception.Message)"
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                    continue
                }

                if ($disk.NeedsBcdRepair -and -not (Repair-SpooferBootConfiguration)) {
                    Write-SpooferLog -Level Error -Message "Boot configuration repair failed. Rolling disk $($disk.Number) back so the machine still boots."
                    try {
                        Set-SpooferDiskIdentity -Number $disk.Number -PartitionStyle $disk.PartitionStyle -Value $oldValue
                        if ($bcdExportPath) { Import-SpooferBcdStore -Path $bcdExportPath }
                        Write-SpooferLog -Level Success -Message "Disk $($disk.Number) and its boot configuration are back as they were."
                    } catch {
                        Write-SpooferLog -Level Error -Message "ROLLBACK FAILED for disk $($disk.Number): $($_.Exception.Message)"
                        Write-SpooferLog -Level Error -Message "Do not reboot. Put the signature back by hand with: Set-Disk -Number $($disk.Number) -Signature $oldValue"
                        if ($bcdExportPath) {
                            Write-SpooferLog -Level Error -Message "Then re-import the boot store with: bcdedit /import `"$bcdExportPath`""
                        }
                    }

                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = 'Boot configuration repair failed; change rolled back'
                    })
                    continue
                }

                Write-SpooferChange -Label $label -OldValue $oldValue -NewValue $newValue
                if ($disk.NeedsBcdRepair) {
                    Write-SpooferLog -Level Warn -Message 'The boot configuration was rewritten, but only a restart proves it. Keep this backup until the machine has booted once.'
                }

                [void]$results.Add([pscustomobject]@{
                    Label = $label; OldValue = $oldValue; NewValue = $newValue
                    Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                })
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
