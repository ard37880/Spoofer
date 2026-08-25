<#
.SYNOPSIS
    The DigitalProductId blobs, the binary form of the installed product key.
.NOTES
    Risky tier, and the riskiest thing here. These are what the activation stack
    and the "installed key" readers parse. Changing them means Windows can report
    a different or invalid key, and re-activation may be needed. The length and
    the leading length field are preserved so the blobs stay structurally valid
    rather than obviously corrupt.

    Both values are backed up byte for byte, so a restore returns the original
    key exactly.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking

$script:CurrentVersion = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

function New-SpoofedProductIdBlob {
    <#
    .SYNOPSIS
        Randomises a DigitalProductId blob while keeping its shape.
    .DESCRIPTION
        The first four bytes are a little-endian length field covering the whole
        blob. Preserving it - and the overall size - keeps anything that parses
        the structure working on the new value instead of failing on a
        length mismatch, which would be a louder signal than the original.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [byte[]]$Current
    )

    if ($null -eq $Current -or $Current.Length -lt 8) { return $Current }

    $updated = New-Object byte[] $Current.Length
    [System.Array]::Copy($Current, $updated, $Current.Length)

    $random = Get-SpooferRandomByte -Count ($Current.Length - 4)
    [System.Array]::Copy($random, 0, $updated, 4, $random.Length)

    # Rewrite the length field from the real length rather than copying it, so a
    # blob that was already inconsistent comes out correct.
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$Current.Length), 0, $updated, 0, 4)

    return ,$updated
}

function Get-DigitalProductIdTarget {
    $targets = New-Object System.Collections.ArrayList

    foreach ($name in @('DigitalProductId', 'DigitalProductId4')) {
        $path = $script:CurrentVersion
        $valueName = $name

        [void]$targets.Add(
            (New-SpooferRegistryTarget -Path $path -Name $valueName -Kind 'Binary' `
                -Label $valueName -TakeOwnership `
                -Note 'activation may need to be re-run' `
                -Generator ({
                    $current = (Get-SpooferRegistryValue -Path $path -Name $valueName).Value
                    New-SpoofedProductIdBlob -Current ([byte[]]$current)
                }.GetNewClosure()))
        )
    }

    return @($targets)
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'digitalproductid'
        Title          = 'Digital product id'
        Tier           = 'Risky'
        RequiresReboot = $false
        Description    = 'Randomises the DigitalProductId and DigitalProductId4 blobs, keeping their length and length field intact. This is the binary form of the installed product key: Windows may report a different key afterwards and want re-activating.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DigitalProductId'
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DigitalProductId4'
        )

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-DigitalProductIdTarget)
        }

        Invoke = {
            param($Session, $Context)
            Write-SpooferLog -Level Warn -Message 'Changing the digital product id can put Windows into an unactivated state until it is re-activated. Restoring this backup puts the original key back.'
            Invoke-SpooferRegistryTarget -Target (Get-DigitalProductIdTarget) -Context $Context -Session $Session -Module 'digitalproductid'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
