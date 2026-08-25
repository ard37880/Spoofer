<#
.SYNOPSIS
    Volume serial numbers, the XXXX-XXXX value "vol" prints.
.DESCRIPTION
    The serial lives in the volume boot record, so changing it means writing
    that one sector back with four or eight bytes altered. The whole original
    sector is saved to the backup session before anything is written, and a
    restore puts that exact sector back.

    The system volume is never touched: its boot record cannot be locked while
    Windows is running on it. exFAT is skipped as well, because its boot region
    carries a checksum over eleven sectors that a naive write would invalidate.
.NOTES
    Risky tier - not selected unless you ask for it.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Native.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1') -DisableNameChecking

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
        FileSystem, Offset and Length, or $null when the filesystem is one this
        provider will not write to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Sector
    )

    if ((Get-SectorText -Sector $Sector -Offset 3 -Length 8) -eq 'NTFS    ') {
        # NTFS keeps a 64-bit serial; Windows displays its low 32 bits.
        return [pscustomobject]@{ FileSystem = 'NTFS'; Offset = 0x48; Length = 8 }
    }

    if ((Get-SectorText -Sector $Sector -Offset 3 -Length 8) -eq 'EXFAT   ') {
        return $null
    }

    if ((Get-SectorText -Sector $Sector -Offset 0x52 -Length 8) -eq 'FAT32   ') {
        return [pscustomobject]@{ FileSystem = 'FAT32'; Offset = 0x43; Length = 4 }
    }

    if ((Get-SectorText -Sector $Sector -Offset 0x36 -Length 3) -eq 'FAT') {
        return [pscustomobject]@{ FileSystem = (Get-SectorText -Sector $Sector -Offset 0x36 -Length 8).Trim(); Offset = 0x27; Length = 4 }
    }

    return $null
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
        Fixed, lettered volumes other than the one Windows is running from.
    #>
    [CmdletBinding()]
    param()

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
        if ($volume.DriveType -ne 'Fixed') { continue }

        $letter = ([string]$volume.DriveLetter).ToUpperInvariant()

        [pscustomobject]@{
            DriveLetter = $letter
            Label       = [string]$volume.FileSystemLabel
            FileSystem  = [string]$volume.FileSystem
            IsSystem    = ($letter -eq $systemLetter)
            SectorSize  = (Get-SpooferVolumeSectorSize -DriveLetter $letter)
        }
    }
}

Register-SpooferRestoreHandler -Type 'VolumeSerial' -Handler {
    param($Entry)

    $sector = $null

    if ($Entry.SectorFile) {
        $path = Join-Path $Entry.SessionPath $Entry.SectorFile
        if (Test-Path -LiteralPath $path) {
            $sector = [System.IO.File]::ReadAllBytes($path)
        }
    }

    if ($null -eq $sector -and $Entry.SectorBase64) {
        $sector = [System.Convert]::FromBase64String([string]$Entry.SectorBase64)
    }

    if ($null -eq $sector) {
        throw "The saved boot sector for $($Entry.DriveLetter): is missing from the backup."
    }

    # Refuse to write a sector from one filesystem over another: a reformat or a
    # drive-letter reassignment since the backup would otherwise destroy the volume.
    $current = Read-SpooferBootSector -DriveLetter $Entry.DriveLetter -SectorSize $sector.Length
    $layout  = Get-VolumeSerialLayout -Sector $current

    if ($null -eq $layout -or $layout.FileSystem -ne $Entry.FileSystem) {
        $now = if ($layout) { $layout.FileSystem } else { 'an unrecognised filesystem' }
        throw ("$($Entry.DriveLetter): now holds {0}, not the {1} volume that was backed up. Refusing to overwrite its boot sector." -f $now, $Entry.FileSystem)
    }

    Write-SpooferBootSector -DriveLetter $Entry.DriveLetter -Sector $sector -AllowDismount
    return "Boot sector of $($Entry.DriveLetter): restored ($($Entry.FileSystem))."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'volumeserial'
        Title          = 'Volume serial numbers'
        Tier           = 'Risky'
        RequiresReboot = $false
        Description    = 'Rewrites the serial number in each fixed volume''s boot record. The system volume and exFAT volumes are always skipped. The complete original sector is saved before any write.'
        Targets        = @('Volume boot record of every fixed, lettered, non-system volume')

        GetState = {
            param($Context)

            $volumes = @(Get-SpooferSpoofableVolume)
            if ($volumes.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Volumes'; Value = 'none found'; Note = '' })
            }

            foreach ($volume in $volumes) {
                $item = '{0}: [{1}]' -f $volume.DriveLetter, $(if ($volume.Label) { $volume.Label } else { $volume.FileSystem })

                if ($volume.IsSystem) {
                    [pscustomobject]@{ Item = $item; Value = '<not read>'; Note = 'system volume - always skipped' }
                    continue
                }

                try {
                    $sector = Read-SpooferBootSector -DriveLetter $volume.DriveLetter -SectorSize $volume.SectorSize
                    $layout = Get-VolumeSerialLayout -Sector $sector
                    if ($null -eq $layout) {
                        [pscustomobject]@{ Item = $item; Value = '<unsupported>'; Note = "$($volume.FileSystem) boot records are not written by this tool" }
                    } else {
                        [pscustomobject]@{ Item = $item; Value = (Format-VolumeSerial -Sector $sector -Offset $layout.Offset); Note = $layout.FileSystem }
                    }
                } catch {
                    [pscustomobject]@{ Item = $item; Value = '<unreadable>'; Note = $_.Exception.Message }
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $volumes = @(Get-SpooferSpoofableVolume | Where-Object { -not $_.IsSystem })
            if ($volumes.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No eligible volumes found. The system volume is always skipped.'
                return @()
            }

            $allowDismount = [bool](Get-SpooferOption -Context $Context -Name 'AllowVolumeDismount' -Default $false)
            $results = New-Object System.Collections.ArrayList

            foreach ($volume in $volumes) {
                $label = 'Volume {0}: serial' -f $volume.DriveLetter

                try {
                    $sector = Read-SpooferBootSector -DriveLetter $volume.DriveLetter -SectorSize $volume.SectorSize
                } catch {
                    Write-SpooferLog -Level Warn -Message "Skipping $($volume.DriveLetter): $($_.Exception.Message)"
                    continue
                }

                $layout = Get-VolumeSerialLayout -Sector $sector
                if ($null -eq $layout) {
                    Write-SpooferLog -Level Warn -Message "Skipping $($volume.DriveLetter): $($volume.FileSystem) boot records are not written by this tool."
                    continue
                }

                $oldSerial = Format-VolumeSerial -Sector $sector -Offset $layout.Offset

                $updated = [byte[]]::new($sector.Length)
                [System.Array]::Copy($sector, $updated, $sector.Length)
                $newBytes = Get-SpooferRandomByte -Count $layout.Length
                [System.Array]::Copy($newBytes, 0, $updated, $layout.Offset, $layout.Length)

                $newSerial = Format-VolumeSerial -Sector $updated -Offset $layout.Offset

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $oldSerial -NewValue $newSerial -Simulated
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldSerial; NewValue = $newSerial
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                if ($Session) {
                    $fileName = 'volume-{0}-boot.bin' -f $volume.DriveLetter
                    $filePath = New-SpooferBackupFilePath -Session $Session -Name $fileName
                    [System.IO.File]::WriteAllBytes($filePath, $sector)

                    Add-SpooferBackupEntry -Session $Session -Type 'VolumeSerial' -Module 'volumeserial' -Label $label -Data @{
                        DriveLetter  = $volume.DriveLetter
                        FileSystem   = $layout.FileSystem
                        SectorSize   = $sector.Length
                        SectorFile   = ('files\{0}' -f $fileName)
                        SessionPath  = $Session.Path
                        SectorBase64 = [System.Convert]::ToBase64String($sector)
                        Serial       = $oldSerial
                    } | Out-Null
                }

                try {
                    Write-SpooferBootSector -DriveLetter $volume.DriveLetter -Sector $updated -AllowDismount:$allowDismount
                    Write-SpooferChange -Label $label -OldValue $oldSerial -NewValue $newSerial
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldSerial; NewValue = $newSerial
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } catch {
                    Write-SpooferLog -Level Error -Message "$($volume.DriveLetter): $($_.Exception.Message)"
                    Write-SpooferLog -Level Info  -Message "Close anything using $($volume.DriveLetter): and retry, or pass -AllowVolumeDismount to dismount it first."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $oldSerial; NewValue = $newSerial
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
