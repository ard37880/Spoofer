<#
.SYNOPSIS
    The machine's NetBIOS/DNS hostname.
.NOTES
    The hostname lives in four places that must agree. Windows reads
    ActiveComputerName until the next boot, which is why this provider is
    marked as requiring a restart.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

function Test-DomainJoined {
    <#
    .SYNOPSIS
        True when the machine is joined to an Active Directory domain.
    #>
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return [bool]$system.PartOfDomain
    } catch {
        Write-SpooferLog -Level Debug -Message "Domain membership check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-ComputerNameTarget {
    param(
        [string]$NewName = (New-SpooferComputerName)
    )

    @(
        New-SpooferRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName' `
            -Kind 'String' -Label 'ComputerName (next boot)' `
            -Generator ({ $NewName }.GetNewClosure())

        New-SpooferRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName' `
            -Kind 'String' -Label 'ActiveComputerName (current)' `
            -Generator ({ $NewName }.GetNewClosure())

        New-SpooferRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'Hostname' `
            -Kind 'String' -Label 'TCP/IP Hostname' `
            -Generator ({ $NewName }.GetNewClosure())

        New-SpooferRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'NV Hostname' `
            -Kind 'String' -Label 'TCP/IP NV Hostname' `
            -Generator ({ $NewName }.GetNewClosure())
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'computername'
        Title          = 'Computer name'
        Tier           = 'Advanced'
        RequiresReboot = $true
        Description    = 'Rewrites the hostname in all four locations Windows keeps it. Domain-joined machines are renamed too, which breaks the computer account''s trust until the machine is re-joined - pass -SkipDomainRename to leave a domain-joined machine alone.'
        Targets        = @(
            'HKLM\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
            'HKLM\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
            'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Hostname'
            'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname'
        )

        GetState = {
            param($Context)

            $rows = @(Get-SpooferRegistryTargetState -Target (Get-ComputerNameTarget))
            if (Test-DomainJoined) {
                $rows += [pscustomobject]@{
                    Item  = 'Domain membership'
                    Value = 'joined'
                    Note  = 'renaming will require re-joining the domain'
                }
            }
            $rows
        }

        Invoke = {
            param($Session, $Context)

            if (Test-DomainJoined) {
                if (Get-SpooferOption -Context $Context -Name 'SkipDomainRename' -Default $false) {
                    Write-SpooferLog -Level Warn -Message 'This machine is domain-joined and -SkipDomainRename was given; leaving the hostname alone.'
                    return @()
                }

                Write-SpooferLog -Level Warn -Message 'This machine is domain-joined. Renaming it breaks the computer account''s trust with the domain: after the restart, re-join it (or restore this backup) before expecting domain sign-in to work.'
            }

            $newName = New-SpooferComputerName
            Write-SpooferLog -Level Info -Message "New hostname: $newName (takes effect after a restart)."

            Invoke-SpooferRegistryTarget -Target (Get-ComputerNameTarget -NewName $newName) `
                -Context $Context -Session $Session -Module 'computername'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
