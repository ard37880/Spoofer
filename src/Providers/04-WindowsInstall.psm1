<#
.SYNOPSIS
    Per-installation identifiers: the build GUID and the OS install timestamp.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

$script:CurrentVersion = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

function Get-WindowsInstallTarget {
    <#
    .DESCRIPTION
        InstallDate (seconds since the Unix epoch) and InstallTime (a FILETIME)
        describe the same moment, so both are derived from one generated date.
        Leaving them inconsistent would be a stronger signal than either value.
    #>

    # Somewhere between one month and roughly two and a half years ago, which is
    # an unremarkable age for a Windows 10/11 installation.
    $ageDays     = Get-SpooferRandomInt -Minimum 30 -Maximum 900
    $installDate = (Get-Date).ToUniversalTime().AddDays(-$ageDays).AddSeconds(-(Get-SpooferRandomInt -Minimum 0 -Maximum 86400))

    $epoch       = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    $unixSeconds = [int][math]::Floor(($installDate - $epoch).TotalSeconds)
    $fileTime    = $installDate.ToFileTimeUtc()

    @(
        New-SpooferRegistryTarget -Path $script:CurrentVersion -Name 'BuildGUID' `
            -Kind 'String' -Label 'Windows BuildGUID' `
            -Generator { New-SpooferGuid -Format D }

        New-SpooferRegistryTarget -Path $script:CurrentVersion -Name 'InstallDate' `
            -Kind 'DWord' -Label 'Windows InstallDate' `
            -Note ('will read as {0:yyyy-MM-dd}' -f $installDate) `
            -Generator ({ $unixSeconds }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:CurrentVersion -Name 'InstallTime' `
            -Kind 'QWord' -Label 'Windows InstallTime' `
            -Generator ({ $fileTime }.GetNewClosure())
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'windowsinstall'
        Title          = 'Windows installation identity'
        Tier           = 'Standard'
        RequiresReboot = $false
        Description    = 'Rewrites BuildGUID and the install timestamp under Windows NT\CurrentVersion. The two timestamp values are generated from the same moment so they stay consistent with each other.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\BuildGUID'
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\InstallDate'
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\InstallTime'
        )

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-WindowsInstallTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-WindowsInstallTarget) -Context $Context -Session $Session -Module 'windowsinstall'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
