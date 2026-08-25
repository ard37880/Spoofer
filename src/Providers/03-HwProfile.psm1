<#
.SYNOPSIS
    The hardware profile GUIDs under IDConfigDB.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking

$script:ProfileRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles'

function Get-HwProfileTarget {
    <#
    .SYNOPSIS
        Builds one target per hardware profile present on this machine.
    .DESCRIPTION
        Most systems have a single profile, 0001, but the key is enumerated so a
        machine with several is handled in full.
    #>
    $root = Resolve-SpooferRegistryPath -Path $script:ProfileRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $targets = New-Object System.Collections.ArrayList

    foreach ($child in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        if ($child.PSChildName -notmatch '^\d{4}$') { continue }

        $path = '{0}\{1}' -f $script:ProfileRoot, $child.PSChildName
        [void]$targets.Add(
            (New-SpooferRegistryTarget -Path $path -Name 'HwProfileGuid' `
                -Kind 'String' -Label ("HwProfileGuid (profile {0})" -f $child.PSChildName) `
                -Generator { New-SpooferGuid -Format B })
        )
    }

    return @($targets)
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'hwprofile'
        Title          = 'Hardware profile GUID'
        Tier           = 'Standard'
        RequiresReboot = $false
        Description    = 'Rewrites HwProfileGuid for every hardware profile under IDConfigDB. Windows creates this GUID the first time it enumerates the machine''s devices.'
        Targets        = @('HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\*\HwProfileGuid')

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-HwProfileTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-HwProfileTarget) -Context $Context -Session $Session -Module 'hwprofile'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
