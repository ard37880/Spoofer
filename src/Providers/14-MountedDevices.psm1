<#
.SYNOPSIS
    Volume GUIDs, the \\?\Volume{...} names Windows knows each volume by.
.DESCRIPTION
    HKLM\SYSTEM\MountedDevices holds two kinds of value. Names like
    \DosDevices\C: map a drive letter to a volume, and names like
    \??\Volume{guid} give that same volume its stable GUID. The GUID is in the
    value name rather than the data, so changing it means writing the data under
    a new name and removing the old one.

    Only the Volume entries are touched, and the system volume's is skipped
    outright. The DosDevices entries are matched on their data, so leaving them
    alone keeps drive letters where they are while the GUIDs underneath change.
.NOTES
    Software that recorded a path as \\?\Volume{...} rather than as a drive
    letter will not find it afterwards. That is rare outside backup and imaging
    tools, but it is the reason this sits in the Advanced tier.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1')    -DisableNameChecking

$script:MountedDevices = 'HKLM:\SYSTEM\MountedDevices'

function Get-SpooferMountedVolume {
    <#
    .SYNOPSIS
        The \??\Volume{guid} entries, with their data.
    #>
    [CmdletBinding()]
    param()

    $path = Resolve-SpooferRegistryPath -Path $script:MountedDevices
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return @() }

    # The system volume's entry is identified by matching its mapping data
    # against the \DosDevices entry for the system drive letter. Renaming it is
    # not worth the risk: the mount manager resolves the boot volume through
    # these names early in startup, and a machine that will not boot is a far
    # worse outcome than one identifier left alone.
    $systemData = $null
    if ($env:SystemDrive) {
        $systemName = '\DosDevices\{0}' -f $env:SystemDrive.ToUpperInvariant()
        if ($key.GetValueNames() -contains $systemName) {
            $systemData = [byte[]]$key.GetValue($systemName)
        }
    }

    foreach ($name in $key.GetValueNames()) {
        if ($name -notmatch '^\\\?\?\\Volume\{([0-9a-fA-F-]{36})\}$') { continue }

        $data = [byte[]]$key.GetValue($name)

        $isSystem = $false
        if ($null -ne $systemData -and $data.Length -eq $systemData.Length) {
            $isSystem = $true
            for ($i = 0; $i -lt $data.Length; $i++) {
                if ($data[$i] -ne $systemData[$i]) { $isSystem = $false; break }
            }
        }

        [pscustomobject]@{
            Name     = $name
            Guid     = $Matches[1]
            Data     = $data
            IsSystem = $isSystem
        }
    }
}

Register-SpooferRestoreHandler -Type 'MountedDevice' -Handler {
    param($Entry)

    $path = Resolve-SpooferRegistryPath -Path $Entry.Path
    $data = [System.Convert]::FromBase64String([string]$Entry.Data)

    # Put the original name back first, then drop the replacement, so the volume
    # is never left without an entry.
    New-ItemProperty -Path $path -Name $Entry.OriginalName -Value $data -PropertyType Binary -Force -ErrorAction Stop | Out-Null

    if ($Entry.NewName -and $Entry.NewName -ne $Entry.OriginalName) {
        Remove-ItemProperty -LiteralPath $path -Name $Entry.NewName -Force -ErrorAction SilentlyContinue
    }

    return "Volume GUID $($Entry.OriginalName) restored."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'volumeguid'
        Title          = 'Volume GUIDs'
        Tier           = 'Advanced'
        RequiresReboot = $true
        TouchesBoot    = $true
        Description    = 'Gives every volume a new \\?\Volume{...} GUID in HKLM\SYSTEM\MountedDevices, except the system volume, which the mount manager resolves the boot volume through. Drive letters are left alone, so C: stays C:. Takes effect after a restart.'
        Targets        = @('HKLM\SYSTEM\MountedDevices\\??\Volume{*}')

        GetState = {
            param($Context)

            $volumes = @(Get-SpooferMountedVolume)
            if ($volumes.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Volumes'; Value = 'none found'; Note = '' })
            }

            foreach ($volume in $volumes) {
                $note = '{0} bytes of mapping data' -f $volume.Data.Length
                if ($volume.IsSystem) { $note = 'system volume - always left alone' }

                [pscustomobject]@{
                    Item  = 'Volume GUID'
                    Value = '{{{0}}}' -f $volume.Guid
                    Note  = $note
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $volumes = @(Get-SpooferMountedVolume)
            if ($volumes.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No volume GUID entries found; nothing to change.'
                return @()
            }

            $path    = Resolve-SpooferRegistryPath -Path $script:MountedDevices
            $results = New-Object System.Collections.ArrayList

            foreach ($volume in $volumes) {
                if ($volume.IsSystem) {
                    Write-SpooferLog -Level Info -Message "Leaving the system volume's GUID alone; the mount manager resolves the boot volume through it."
                    continue
                }

                $newGuid = New-SpooferGuid -Format D
                $newName = '\??\Volume{{{0}}}' -f $newGuid
                $label   = 'Volume {{{0}}}' -f $volume.Guid

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue ('{{{0}}}' -f $volume.Guid) -NewValue ('{{{0}}}' -f $newGuid) -Simulated
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $volume.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                if ($Session) {
                    Add-SpooferBackupEntry -Session $Session -Type 'MountedDevice' -Module 'volumeguid' -Label $label -Data @{
                        Path         = $script:MountedDevices
                        OriginalName = $volume.Name
                        NewName      = $newName
                        Data         = [System.Convert]::ToBase64String($volume.Data)
                    } | Out-Null
                }

                try {
                    New-ItemProperty -Path $path -Name $newName -Value $volume.Data -PropertyType Binary -Force -ErrorAction Stop | Out-Null
                    Remove-ItemProperty -LiteralPath $path -Name $volume.Name -Force -ErrorAction Stop

                    Write-SpooferChange -Label $label -OldValue ('{{{0}}}' -f $volume.Guid) -NewValue ('{{{0}}}' -f $newGuid)
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $volume.Guid; NewValue = $newGuid
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } catch {
                    Write-SpooferLog -Level Error -Message "$($label): $($_.Exception.Message)"
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $volume.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
