<#
.SYNOPSIS
    The Cryptography MachineGuid: the single most widely read machine
    identifier on Windows.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

function Get-MachineGuidTarget {
    @(
        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' `
            -Kind 'String' -Label 'Cryptography MachineGuid' `
            -Generator { New-SpooferGuid -Format D }
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'machineguid'
        Title          = 'Cryptography MachineGuid'
        Tier           = 'Standard'
        RequiresReboot = $false
        Description    = 'Rewrites HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid, the GUID Windows generates at install time and the value most applications treat as "the machine ID".'
        Targets        = @('HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid')

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-MachineGuidTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-MachineGuidTarget) -Context $Context -Session $Session -Module 'machineguid'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
