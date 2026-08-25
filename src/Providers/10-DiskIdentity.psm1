<#
.SYNOPSIS
    Disk-level identifiers: the GPT disk GUID and the MBR disk signature.
.NOTES
    These are the identifiers written in the partition table, not the serial
    number burned into the drive's firmware - that one is not writable from
    user mode at all. See docs/limitations.md.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1') -DisableNameChecking

function Get-SpooferDisk {
    <#
    .SYNOPSIS
        Disks that carry a rewritable identifier, with the flags needed to
        decide whether touching them is safe.
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

        # An MBR signature is referenced by the boot configuration data, so
        # changing it on the disk Windows boots from leaves the machine
        # unbootable. GPT boot entries reference partition GUIDs instead, which
        # this provider never touches, so the disk GUID is safe to rewrite.
        $isBootCritical = ([bool]$disk.IsBoot -or [bool]$disk.IsSystem)
        $bootUnsafe     = ($disk.PartitionStyle -eq 'MBR' -and $isBootCritical)

        [pscustomobject]@{
            Number         = [int]$disk.Number
            FriendlyName   = [string]$disk.FriendlyName
            SerialNumber   = [string]$disk.SerialNumber
            PartitionStyle = [string]$disk.PartitionStyle
            Guid           = [string]$disk.Guid
            Signature      = $disk.Signature
            IsBootCritical = $isBootCritical
            BootUnsafe     = $bootUnsafe
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
    return "Disk $($Entry.Number) MBR signature restored."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'diskid'
        Title          = 'Disk GUID / MBR signature'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Rewrites the GPT disk GUID, or the MBR disk signature on non-boot disks. The MBR signature of a boot disk is skipped because the boot configuration references it.'
        Targets        = @('Partition table of every initialised disk')

        GetState = {
            param($Context)

            $disks = @(Get-SpooferDisk)
            if ($disks.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Disks'; Value = 'none found'; Note = '' })
            }

            foreach ($disk in $disks) {
                $value = if ($disk.PartitionStyle -eq 'GPT') { $disk.Guid } else { '0x{0:X8}' -f $disk.Signature }

                $note = $disk.PartitionStyle
                if ($disk.BootUnsafe)         { $note += ', boot disk - skipped' }
                elseif ($disk.IsBootCritical) { $note += ', boot disk' }
                if ($disk.IsReadOnly)         { $note += ', read-only' }

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
                    Write-SpooferLog -Level Warn -Message "Skipping disk $($disk.Number): it is read-only."
                    continue
                }

                if ($disk.BootUnsafe) {
                    Write-SpooferLog -Level Warn -Message "Skipping disk $($disk.Number): changing an MBR boot disk's signature would break the boot configuration."
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
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
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
                    Write-SpooferChange -Label $label -OldValue $oldValue -NewValue $newValue
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } catch {
                    Write-SpooferLog -Level Error -Message "Disk $($disk.Number): $($_.Exception.Message)"
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldValue; NewValue = $newValue
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
