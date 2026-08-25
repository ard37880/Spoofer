<#
.SYNOPSIS
    Identifiers used for telemetry, Windows Update, and ad personalisation.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

function Get-TelemetryTarget {
    @(
        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -Name 'SusClientId' `
            -Kind 'String' -Label 'Windows Update SusClientId' `
            -Generator { New-SpooferGuid -Format D }

        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -Name 'SusClientIDValidation' `
            -Kind 'Binary' -Label 'Windows Update SusClientIDValidation' `
            -Note 'Windows Update regenerates this pair on its next scan' `
            -Generator { Get-SpooferRandomByte -Count 32 }

        New-SpooferRegistryTarget -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Id' `
            -Kind 'String' -Label 'Advertising Id (current user)' `
            -Note 'per-user, not machine-wide' `
            -Generator { New-SpooferGuid -Format D -Upper }
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'telemetry'
        Title          = 'Telemetry and Windows Update identifiers'
        Tier           = 'Standard'
        RequiresReboot = $false
        Description    = 'Rewrites the Windows Update client id and the current user''s advertising id. Windows regenerates the update client id on its next scan, so treat this one as short-lived.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\SusClientId'
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\SusClientIDValidation'
            'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Id'
        )

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-TelemetryTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-TelemetryTarget) -Context $Context -Session $Session -Module 'telemetry'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
