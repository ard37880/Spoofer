<#
.SYNOPSIS
    Secondary per-machine identifiers: the SQM/telemetry machine id, the Windows
    Media unique id, and the Terminal Services client hardware id.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

function Get-MachineIdTarget {
    @(
        # SQMClient stores the id braced and upper-case; matching the house style
        # matters because a lower-case value is itself distinctive.
        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient' -Name 'MachineId' `
            -Kind 'String' -Label 'SQMClient MachineId' `
            -Generator { New-SpooferGuid -Format B -Upper }

        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows Media\WMSDK\General' -Name 'UniqueID' `
            -Kind 'String' -Label 'Windows Media UniqueID' `
            -Generator { New-SpooferGuid -Format B -Upper }

        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\MSLicensing\HardwareID' -Name 'ClientHWID' `
            -Kind 'String' -Label 'Terminal Services ClientHWID' `
            -Generator { New-SpooferGuid -Format B -Upper } `
            -Note 'read by Remote Desktop licensing'
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'machineid'
        Title          = 'Secondary machine identifiers'
        Tier           = 'Standard'
        RequiresReboot = $false
        Description    = 'Rewrites the SQM/telemetry machine id, the Windows Media SDK unique id, and the Remote Desktop client hardware id. Values that are absent on this system are left alone.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\SQMClient\MachineId'
            'HKLM\SOFTWARE\Microsoft\Windows Media\WMSDK\General\UniqueID'
            'HKLM\SOFTWARE\Microsoft\MSLicensing\HardwareID\ClientHWID'
        )

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-MachineIdTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-MachineIdTarget) -Context $Context -Session $Session -Module 'machineid'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
