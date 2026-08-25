<#
.SYNOPSIS
    MAC addresses of the physical network adapters.
.DESCRIPTION
    Windows lets a NIC driver present an administratively assigned address by
    way of the NetworkAddress value on the adapter's class key. The burned-in
    address in the NIC's own EEPROM is untouched; the driver simply reports the
    override instead, and deleting the value returns the adapter to its real
    address. Not every driver honours it - the spoof verifies the result and
    says so when the driver ignored the override.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1')    -DisableNameChecking

# The device class GUID for network adapters, stable since Windows 2000.
$script:NetClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function Get-SpooferNetAdapter {
    <#
    .SYNOPSIS
        Physical adapters paired with the class registry key that configures them.
    .PARAMETER IncludeVirtual
        Also return virtual adapters (Hyper-V switches, VPN and loopback
        adapters). Off by default: they have no burned-in address to hide and
        rewriting them tends to break the software that created them.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeVirtual
    )

    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Warn -Message "Get-NetAdapter is unavailable: $($_.Exception.Message)"
        return @()
    }

    if (-not $IncludeVirtual) {
        $adapters = @($adapters | Where-Object { $_.HardwareInterface })
    }

    $classRoot = Resolve-SpooferRegistryPath -Path $script:NetClassRoot
    if (-not (Test-Path -LiteralPath $classRoot)) {
        Write-SpooferLog -Level Warn -Message "Network adapter class key not found at $script:NetClassRoot."
        return @()
    }

    # Index the class sub-keys by NetCfgInstanceId so each adapter is matched by
    # its interface GUID rather than by an index that can shift between boots.
    $byInstanceId = @{}
    foreach ($child in (Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
        if ($child.PSChildName -notmatch '^\d{4}$') { continue }

        $keyPath    = '{0}\{1}' -f $script:NetClassRoot, $child.PSChildName
        $instanceId = (Get-SpooferRegistryValue -Path $keyPath -Name 'NetCfgInstanceId').Value
        if ($instanceId) { $byInstanceId[[string]$instanceId] = $keyPath }
    }

    foreach ($adapter in $adapters) {
        $guid = [string]$adapter.InterfaceGuid
        if (-not $byInstanceId.ContainsKey($guid)) {
            Write-SpooferLog -Level Debug -Message "No class key found for adapter '$($adapter.Name)' ($guid)."
            continue
        }

        [pscustomobject]@{
            Name        = $adapter.Name
            Description = $adapter.InterfaceDescription
            Status      = [string]$adapter.Status
            MacAddress  = [string]$adapter.MacAddress
            InstanceId  = $guid
            KeyPath     = $byInstanceId[$guid]
            Override    = (Get-SpooferRegistryValue -Path $byInstanceId[$guid] -Name 'NetworkAddress').Value
        }
    }
}

function Restart-SpooferNetAdapter {
    <#
    .SYNOPSIS
        Bounces an adapter so the driver re-reads its NetworkAddress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        Restart-NetAdapter -Name $Name -ErrorAction Stop
        return $true
    } catch {
        Write-SpooferLog -Level Debug -Message "Restart-NetAdapter failed for '$Name', falling back to disable/enable: $($_.Exception.Message)"
    }

    try {
        Disable-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop
        Enable-NetAdapter  -Name $Name -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        Write-SpooferLog -Level Warn -Message "Could not restart adapter '$Name': $($_.Exception.Message). Disable and re-enable it by hand, or reboot, for the change to take effect."
        return $false
    }
}

Register-SpooferRestoreHandler -Type 'NetAdapterRestart' -Handler {
    param($Entry)

    if (Restart-SpooferNetAdapter -Name $Entry.AdapterName) {
        return "Restarted adapter '$($Entry.AdapterName)'."
    }
    return "Adapter '$($Entry.AdapterName)' could not be restarted; reboot to finish the restore."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'mac'
        Title          = 'Network adapter MAC addresses'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Assigns each physical adapter a random locally administered MAC address via the driver''s NetworkAddress override, then restarts the adapter. The burned-in address is not modified.'
        Targets        = @('HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\*\NetworkAddress')

        GetState = {
            param($Context)

            $includeVirtual = [bool](Get-SpooferOption -Context $Context -Name 'IncludeVirtualAdapters' -Default $false)
            $adapters = @(Get-SpooferNetAdapter -IncludeVirtual:$includeVirtual)

            if ($adapters.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Adapters'; Value = 'none found'; Note = '' })
            }

            foreach ($adapter in $adapters) {
                $note = if ($adapter.Override) { "overridden (real address hidden), $($adapter.Status)" } else { $adapter.Status }
                [pscustomobject]@{
                    Item  = '{0} [{1}]' -f $adapter.Name, $adapter.Description
                    Value = $adapter.MacAddress
                    Note  = $note
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $includeVirtual = [bool](Get-SpooferOption -Context $Context -Name 'IncludeVirtualAdapters' -Default $false)
            $adapters = @(Get-SpooferNetAdapter -IncludeVirtual:$includeVirtual)

            if ($adapters.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No matching network adapters found; nothing to change.'
                return @()
            }

            $results = New-Object System.Collections.ArrayList

            foreach ($adapter in $adapters) {
                $newMac = New-SpooferMacAddress
                $label  = 'MAC {0}' -f $adapter.Name

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $adapter.MacAddress -NewValue $newMac -Simulated
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $adapter.MacAddress; NewValue = $newMac
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                # Queued before the registry write so that a restore, which
                # replays entries in reverse, puts the original address back
                # first and only then bounces the adapter.
                if ($Session) {
                    Add-SpooferBackupEntry -Session $Session -Type 'NetAdapterRestart' -Module 'mac' `
                        -Label ("Restart adapter {0}" -f $adapter.Name) `
                        -Data @{ AdapterName = $adapter.Name; InstanceId = $adapter.InstanceId } | Out-Null
                }

                $written = Set-SpooferRegistryValue -Path $adapter.KeyPath -Name 'NetworkAddress' `
                    -Value $newMac -Kind 'String' -Label $label -Module 'mac' `
                    -Session $Session -CreateIfMissing

                [void]$results.Add($written)

                if ($written.Changed) {
                    Restart-SpooferNetAdapter -Name $adapter.Name | Out-Null

                    $observed = (Get-NetAdapter -Name $adapter.Name -ErrorAction SilentlyContinue).MacAddress
                    if ($observed) {
                        $normalisedObserved = ($observed -replace '[:-]', '').ToUpperInvariant()
                        if ($normalisedObserved -ne $newMac.ToUpperInvariant()) {
                            Write-SpooferLog -Level Warn -Message "Adapter '$($adapter.Name)' still reports $observed. This driver ignores the NetworkAddress override; the backup entry is kept so the value can still be cleaned up."
                        } else {
                            Write-SpooferLog -Level Success -Message "Adapter '$($adapter.Name)' now reports $observed."
                        }
                    }
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
