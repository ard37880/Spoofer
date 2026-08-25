<#
.SYNOPSIS
    Volume serial numbers, the XXXX-XXXX value "vol" prints.
.DESCRIPTION
    The serial lives in the volume boot record, so changing it means writing that
    record back with a few bytes altered. Every filesystem here is handled in
    full rather than approximately:

      NTFS   64-bit serial at 0x48, mirrored into the backup boot sector that
             sits in the last sector of the partition.
      FAT32  32-bit serial at 0x43.
      FAT16  32-bit serial at 0x27.
      exFAT  32-bit serial at 0x64 in both the main and backup boot regions,
             each of which is followed by a checksum over eleven sectors that
             has to be recomputed or the volume stops mounting.

    Every sector this provider touches is saved to the backup session first, so a
    restore rewrites the exact bytes that were there.
.NOTES
    The system volume is attempted like any other. Windows will normally refuse
    to lock the volume it is running from, in which case the failure is reported
    with the offline procedure that does work.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Native.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1') -DisableNameChecking

# exFAT keeps twelve sectors of boot region, then an identical backup region.
$script:ExFatRegionSectors = 12
$script:ExFatChecksumSector = 11
$script:ExFatBackupSector = 12

function Get-SectorText {
    <#
    .SYNOPSIS
        Reads an ASCII field out of a boot sector.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Sector,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Length
    )

    if ($Sector.Length -lt ($Offset + $Length)) { return '' }
    return [System.Text.Encoding]::ASCII.GetString($Sector, $Offset, $Length)
}

function Get-VolumeSerialLayout {
    <#
    .SYNOPSIS
        Locates the serial number field inside a boot sector.
    .OUTPUTS
        FileSystem, Offset, Length, and Region - how much of the volume has to be
        read and written to change the serial safely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Sector
    )

    $oem = Get-SectorText -Sector $Sector -Offset 3 -Length 8

    if ($oem -eq 'NTFS    ') {
        # NTFS keeps a 64-bit serial; Windows displays its low 32 bits.
        return [pscustomobject]@{ FileSystem = 'NTFS'; Offset = 0x48; Length = 8; Region = 'NtfsWithBackup' }
    }

    if ($oem -eq 'EXFAT   ') {
        return [pscustomobject]@{ FileSystem = 'exFAT'; Offset = 0x64; Length = 4; Region = 'ExFatBootRegion' }
    }

    if ((Get-SectorText -Sector $Sector -Offset 0x52 -Length 8) -eq 'FAT32   ') {
        return [pscustomobject]@{ FileSystem = 'FAT32'; Offset = 0x43; Length = 4; Region = 'SingleSector' }
    }

    if ((Get-SectorText -Sector $Sector -Offset 0x36 -Length 3) -eq 'FAT') {
        return [pscustomobject]@{
            FileSystem = (Get-SectorText -Sector $Sector -Offset 0x36 -Length 8).Trim()
            Offset     = 0x27
            Length     = 4
            Region     = 'SingleSector'
        }
    }

    return $null
}

function Get-ExFatBootChecksum {
    <#
    .SYNOPSIS
        The exFAT boot region checksum, over the first eleven sectors of a region.
    .DESCRIPTION
        Defined by the exFAT specification: a rotate-right-then-add over every
        byte of sectors 0 to 10, skipping the three bytes that are expected to
        change while the volume is mounted - VolumeFlags at 106 and 107, and
        PercentInUse at 112. Sector 11 is then filled with the result repeated.
    .PARAMETER Region
        The region's bytes, starting at its main boot sector.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][byte[]]$Region,
        [Parameter(Mandatory)][int]$SectorSize
    )

    $count    = 11 * $SectorSize
    $checksum = [uint64]0

    for ($i = 0; $i -lt $count; $i++) {
        if ($i -eq 106 -or $i -eq 107 -or $i -eq 112) { continue }

        # The spec writes this as a rotate-right by one followed by an add. The
        # arithmetic is done in 64 bits and masked back to 32 so the carry out of
        # bit 31 is discarded rather than sign-extending a signed shift.
        # 0x80000000 written as a hex literal is parsed as a negative Int32 and
        # will not cast; the decimal form is unambiguous.
        $carry    = if (($checksum -band 1) -ne 0) { [uint64]2147483648 } else { [uint64]0 }
        $checksum = ($carry + ($checksum -shr 1) + [uint64]$Region[$i]) -band 0xFFFFFFFF
    }

    return [uint32]$checksum
}

function Set-ExFatBootChecksum {
    <#
    .SYNOPSIS
        Recomputes a region's checksum and writes it across its checksum sector.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Region,
        [Parameter(Mandatory)][int]$SectorSize,
        [int]$RegionOffset = 0
    )

    $slice = New-Object byte[] (11 * $SectorSize)
    [System.Array]::Copy($Region, $RegionOffset, $slice, 0, $slice.Length)

    $checksum = Get-ExFatBootChecksum -Region $slice -SectorSize $SectorSize
    $bytes    = [System.BitConverter]::GetBytes($checksum)
    $start    = $RegionOffset + ($script:ExFatChecksumSector * $SectorSize)

    for ($offset = 0; $offset -lt $SectorSize; $offset += 4) {
        [System.Array]::Copy($bytes, 0, $Region, $start + $offset, 4)
    }
}

function Format-VolumeSerial {
    <#
    .SYNOPSIS
        Renders the serial the way Windows shows it, as XXXX-XXXX.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Sector,
        [Parameter(Mandatory)][int]$Offset
    )

    if ($Sector.Length -lt ($Offset + 4)) { return '<unreadable>' }
    $hex = ([System.BitConverter]::ToUInt32($Sector, $Offset)).ToString('X8')
    return ('{0}-{1}' -f $hex.Substring(0, 4), $hex.Substring(4, 4))
}

function Get-NtfsBackupSectorOffset {
    <#
    .SYNOPSIS
        Byte offset of the NTFS backup boot sector.
    .DESCRIPTION
        NTFS records its own sector count at 0x28, excluding the backup boot
        sector that follows it. Deriving the offset from the volume itself is
        safer than asking Windows for the partition size, which can include
        alignment padding the filesystem does not use.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][byte[]]$Sector,
        [Parameter(Mandatory)][int]$SectorSize
    )

    if ($Sector.Length -lt 0x30) { return -1 }

    $totalSectors = [System.BitConverter]::ToInt64($Sector, 0x28)
    if ($totalSectors -le 0) { return -1 }

    return ([long]$totalSectors * [long]$SectorSize)
}

function Get-SpooferVolumeSectorSize {
    <#
    .SYNOPSIS
        Logical sector size of the disk behind a drive letter, defaulting to 512.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter
    )

    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk      = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        if ($disk.LogicalSectorSize -gt 0) { return [int]$disk.LogicalSectorSize }
    } catch {
        Write-SpooferLog -Level Debug -Message "Could not determine sector size for ${DriveLetter}: $($_.Exception.Message)"
    }
    return 512
}

function Get-SpooferSpoofableVolume {
    <#
    .SYNOPSIS
        Every fixed, lettered volume, including the system volume.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeRemovable
    )

    $systemLetter = ''
    if ($env:SystemDrive) { $systemLetter = $env:SystemDrive.TrimEnd(':').ToUpperInvariant() }

    try {
        $volumes = @(Get-Volume -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Warn -Message "Get-Volume is unavailable: $($_.Exception.Message)"
        return @()
    }

    foreach ($volume in $volumes) {
        if (-not $volume.DriveLetter) { continue }
        if ($volume.DriveType -ne 'Fixed' -and -not $IncludeRemovable) { continue }

        $letter = ([string]$volume.DriveLetter).ToUpperInvariant()

        [pscustomobject]@{
            DriveLetter = $letter
            Label       = [string]$volume.FileSystemLabel
            FileSystem  = [string]$volume.FileSystem
            DriveType   = [string]$volume.DriveType
            IsSystem    = ($letter -eq $systemLetter)
            SectorSize  = (Get-SpooferVolumeSectorSize -DriveLetter $letter)
        }
    }
}

function Get-VolumeSerialPlan {
    <#
    .SYNOPSIS
        Works out every byte range that has to change for one volume, and what
        the serial will read as afterwards.
    .OUTPUTS
        Layout, the current serial, and a list of writes as
        { ByteOffset, Original, Updated }. Returns $null when the boot record is
        not one this provider understands.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][int]$SectorSize,
        [byte[]]$NewSerialBytes
    )

    $first  = Read-SpooferVolumeSector -DriveLetter $DriveLetter -ByteOffset 0 -Length $SectorSize -SectorSize $SectorSize
    $layout = Get-VolumeSerialLayout -Sector $first
    if ($null -eq $layout) { return $null }

    if (-not $PSBoundParameters.ContainsKey('NewSerialBytes') -or $null -eq $NewSerialBytes) {
        $NewSerialBytes = Get-SpooferRandomByte -Count $layout.Length
    }

    $writes  = New-Object System.Collections.ArrayList
    $current = Format-VolumeSerial -Sector $first -Offset $layout.Offset
    $updatedSerial = $current

    switch ($layout.Region) {

        'ExFatBootRegion' {
            # Both boot regions are read as one run so their checksums can be
            # recomputed from exactly the bytes that will be on disk.
            $length   = 2 * $script:ExFatRegionSectors * $SectorSize
            $original = Read-SpooferVolumeSector -DriveLetter $DriveLetter -ByteOffset 0 -Length $length -SectorSize $SectorSize

            $updated = New-Object byte[] $original.Length
            [System.Array]::Copy($original, $updated, $original.Length)

            $backupBase = $script:ExFatBackupSector * $SectorSize
            [System.Array]::Copy($NewSerialBytes, 0, $updated, $layout.Offset, $layout.Length)
            [System.Array]::Copy($NewSerialBytes, 0, $updated, $backupBase + $layout.Offset, $layout.Length)

            Set-ExFatBootChecksum -Region $updated -SectorSize $SectorSize -RegionOffset 0
            Set-ExFatBootChecksum -Region $updated -SectorSize $SectorSize -RegionOffset $backupBase

            $updatedSerial = Format-VolumeSerial -Sector $updated -Offset $layout.Offset
            [void]$writes.Add([pscustomobject]@{ ByteOffset = [long]0; Original = $original; Updated = $updated })
        }

        'NtfsWithBackup' {
            $updated = New-Object byte[] $first.Length
            [System.Array]::Copy($first, $updated, $first.Length)
            [System.Array]::Copy($NewSerialBytes, 0, $updated, $layout.Offset, $layout.Length)

            $updatedSerial = Format-VolumeSerial -Sector $updated -Offset $layout.Offset
            [void]$writes.Add([pscustomobject]@{ ByteOffset = [long]0; Original = $first; Updated = $updated })

            # The backup boot sector carries the same serial. Windows only reads
            # it when the primary is unreadable, but leaving the two out of step
            # is exactly the kind of inconsistency chkdsk reports.
            $backupOffset = Get-NtfsBackupSectorOffset -Sector $first -SectorSize $SectorSize
            if ($backupOffset -gt 0) {
                try {
                    $backup = Read-SpooferVolumeSector -DriveLetter $DriveLetter -ByteOffset $backupOffset -Length $SectorSize -SectorSize $SectorSize
                    if ((Get-SectorText -Sector $backup -Offset 3 -Length 8) -eq 'NTFS    ') {
                        $backupUpdated = New-Object byte[] $backup.Length
                        [System.Array]::Copy($backup, $backupUpdated, $backup.Length)
                        [System.Array]::Copy($NewSerialBytes, 0, $backupUpdated, $layout.Offset, $layout.Length)
                        [void]$writes.Add([pscustomobject]@{ ByteOffset = $backupOffset; Original = $backup; Updated = $backupUpdated })
                    } else {
                        Write-SpooferLog -Level Debug -Message "${DriveLetter}: backup boot sector does not carry an NTFS signature; leaving it alone."
                    }
                } catch {
                    Write-SpooferLog -Level Debug -Message "${DriveLetter}: backup boot sector unreadable: $($_.Exception.Message)"
                }
            }
        }

        default {
            $updated = New-Object byte[] $first.Length
            [System.Array]::Copy($first, $updated, $first.Length)
            [System.Array]::Copy($NewSerialBytes, 0, $updated, $layout.Offset, $layout.Length)

            $updatedSerial = Format-VolumeSerial -Sector $updated -Offset $layout.Offset
            [void]$writes.Add([pscustomobject]@{ ByteOffset = [long]0; Original = $first; Updated = $updated })
        }
    }

    return [pscustomobject]@{
        Layout    = $layout
        OldSerial = $current
        NewSerial = $updatedSerial
        Writes    = @($writes)
    }
}

Register-SpooferRestoreHandler -Type 'VolumeSerial' -Handler {
    param($Entry)

    # Refuse to write one filesystem's boot record over another: a reformat or a
    # drive-letter reassignment since the backup would otherwise destroy the volume.
    $current = Read-SpooferVolumeSector -DriveLetter $Entry.DriveLetter -ByteOffset 0 `
        -Length $Entry.SectorSize -SectorSize $Entry.SectorSize
    $layout  = Get-VolumeSerialLayout -Sector $current

    if ($null -eq $layout -or $layout.FileSystem -ne $Entry.FileSystem) {
        $now = if ($layout) { $layout.FileSystem } else { 'an unrecognised filesystem' }
        throw ("$($Entry.DriveLetter): now holds {0}, not the {1} volume that was backed up. Refusing to overwrite its boot record." -f $now, $Entry.FileSystem)
    }

    $restored = 0
    foreach ($write in @($Entry.Writes)) {
        $bytes = $null

        if ($write.File) {
            $path = Join-Path $Entry.SessionPath $write.File
            if (Test-Path -LiteralPath $path) { $bytes = [System.IO.File]::ReadAllBytes($path) }
        }
        if ($null -eq $bytes -and $write.Base64) {
            $bytes = [System.Convert]::FromBase64String([string]$write.Base64)
        }
        if ($null -eq $bytes) {
            throw "The saved sectors at offset $($write.ByteOffset) for $($Entry.DriveLetter): are missing from the backup."
        }

        Write-SpooferVolumeSector -DriveLetter $Entry.DriveLetter -ByteOffset ([long]$write.ByteOffset) `
            -Data $bytes -SectorSize $Entry.SectorSize -AllowDismount
        $restored++
    }

    return "Boot record of $($Entry.DriveLetter): restored ($($Entry.FileSystem), $restored write(s))."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'volumeserial'
        Title          = 'Volume serial numbers'
        Tier           = 'Risky'
        RequiresReboot = $false
        Description    = 'Rewrites the serial number in every fixed volume''s boot record, including NTFS backup boot sectors and both exFAT boot regions with their checksums recomputed. Every sector touched is saved before any write.'
        Targets        = @('Volume boot record of every fixed, lettered volume, the system volume included')

        GetState = {
            param($Context)

            $volumes = @(Get-SpooferSpoofableVolume -IncludeRemovable:([bool](Get-SpooferOption -Context $Context -Name 'IncludeRemovableVolumes' -Default $false)))
            if ($volumes.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Volumes'; Value = 'none found'; Note = '' })
            }

            foreach ($volume in $volumes) {
                $item = '{0}: [{1}]' -f $volume.DriveLetter, $(if ($volume.Label) { $volume.Label } else { $volume.FileSystem })

                try {
                    $sector = Read-SpooferVolumeSector -DriveLetter $volume.DriveLetter -ByteOffset 0 `
                        -Length $volume.SectorSize -SectorSize $volume.SectorSize
                    $layout = Get-VolumeSerialLayout -Sector $sector

                    if ($null -eq $layout) {
                        [pscustomobject]@{ Item = $item; Value = '<unrecognised>'; Note = "$($volume.FileSystem) boot record not understood" }
                    } else {
                        $note = $layout.FileSystem
                        if ($volume.IsSystem) { $note += ', system volume' }
                        [pscustomobject]@{ Item = $item; Value = (Format-VolumeSerial -Sector $sector -Offset $layout.Offset); Note = $note }
                    }
                } catch {
                    [pscustomobject]@{ Item = $item; Value = '<unreadable>'; Note = $_.Exception.Message }
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $volumes = @(Get-SpooferSpoofableVolume -IncludeRemovable:([bool](Get-SpooferOption -Context $Context -Name 'IncludeRemovableVolumes' -Default $false)))
            if ($volumes.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No lettered volumes found.'
                return @()
            }

            # Dismounting is the default here: without it the write fails on any
            # volume with an open handle, which in practice is most of them.
            $allowDismount = [bool](Get-SpooferOption -Context $Context -Name 'AllowVolumeDismount' -Default $true)
            $results = New-Object System.Collections.ArrayList

            foreach ($volume in $volumes) {
                $label = 'Volume {0}: serial' -f $volume.DriveLetter

                try {
                    $plan = Get-VolumeSerialPlan -DriveLetter $volume.DriveLetter -SectorSize $volume.SectorSize
                } catch {
                    Write-SpooferLog -Level Error -Message "$($volume.DriveLetter): could not read the boot record: $($_.Exception.Message)"
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $null; NewValue = $null
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                    continue
                }

                if ($null -eq $plan) {
                    Write-SpooferLog -Level Warn -Message "$($volume.DriveLetter): boot record is not one this provider understands ($($volume.FileSystem)); leaving it untouched."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $null; NewValue = $null
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = 'Unrecognised boot record'
                    })
                    continue
                }

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $plan.OldSerial -NewValue $plan.NewSerial -Simulated
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $plan.OldSerial; NewValue = $plan.NewSerial
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                if ($Session) {
                    $writeRecords = New-Object System.Collections.ArrayList
                    $index = 0

                    foreach ($write in $plan.Writes) {
                        $fileName = 'volume-{0}-{1}.bin' -f $volume.DriveLetter, $index
                        $filePath = New-SpooferBackupFilePath -Session $Session -Name $fileName
                        [System.IO.File]::WriteAllBytes($filePath, $write.Original)

                        [void]$writeRecords.Add([ordered]@{
                            ByteOffset = [long]$write.ByteOffset
                            File       = ('files\{0}' -f $fileName)
                            Base64     = [System.Convert]::ToBase64String($write.Original)
                        })
                        $index++
                    }

                    Add-SpooferBackupEntry -Session $Session -Type 'VolumeSerial' -Module 'volumeserial' -Label $label -Data @{
                        DriveLetter = $volume.DriveLetter
                        FileSystem  = $plan.Layout.FileSystem
                        SectorSize  = $volume.SectorSize
                        SessionPath = $Session.Path
                        Serial      = $plan.OldSerial
                        Writes      = @($writeRecords)
                    } | Out-Null
                }

                try {
                    foreach ($write in $plan.Writes) {
                        Write-SpooferVolumeSector -DriveLetter $volume.DriveLetter -ByteOffset $write.ByteOffset `
                            -Data $write.Updated -SectorSize $volume.SectorSize -AllowDismount:$allowDismount
                    }

                    Write-SpooferChange -Label $label -OldValue $plan.OldSerial -NewValue $plan.NewSerial
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $plan.OldSerial; NewValue = $plan.NewSerial
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } catch {
                    Write-SpooferLog -Level Error -Message "$($volume.DriveLetter): $($_.Exception.Message)"

                    if ($volume.IsSystem) {
                        Write-SpooferLog -Level Info -Message "Windows will not let the volume it is running from be locked. Boot from Windows PE or another installation, where $($volume.DriveLetter): is not the system volume, and run the same command there."
                    } else {
                        Write-SpooferLog -Level Info -Message "Close anything holding $($volume.DriveLetter): open and retry."
                    }

                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $plan.OldSerial; NewValue = $plan.NewSerial
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
