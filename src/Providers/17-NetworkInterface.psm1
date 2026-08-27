<#
.SYNOPSIS
    Network interface GUIDs, the per-adapter identity Windows uses everywhere.
.DESCRIPTION
    Every adapter has a GUID that Windows scatters across the registry. It is a
    stable per-machine identifier, it survives a MAC change, and unlike the
    burned-in address it really is writable.

    The catch is that it appears in several places at once and they all have to
    agree. The adapter's class key holds it as NetCfgInstanceId; TCP/IP, TCP/IPv6
    and NetBT each keep a settings key named after it; Control\Network holds the
    connection's friendly name under it; and NetworkSetup2 keeps its own copy.
    Miss one and the adapter comes back with no working TCP/IP binding.

    So the module works from a table of every location it knows about, renames
    the ones that are present, and reports what it touched. Every rename is a
    separate backup entry, so a partial failure can still be unwound.
.NOTES
    Risky tier and a restart is required. This is the module most likely to cost
    you networking if it goes wrong, which is exactly why every step is recorded
    individually rather than as one all-or-nothing change.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1')    -DisableNameChecking

$script:NetClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

# Every parent key that holds a per-interface sub-key, with the shape of the
# name. NetBT prefixes the GUID; the rest use it verbatim.
$script:InterfaceLocations = @(
    @{ Parent = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces';  Format = '{0}';        Purpose = 'TCP/IP settings' }
    @{ Parent = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces'; Format = '{0}';        Purpose = 'TCP/IPv6 settings' }
    @{ Parent = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces';  Format = 'Tcpip_{0}';  Purpose = 'NetBIOS over TCP/IP' }
    @{ Parent = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}'; Format = '{0}'; Purpose = 'connection name' }
    @{ Parent = 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkSetup2\Interfaces';      Format = '{0}';        Purpose = 'network setup' }
)

function Get-SpooferNetworkInterface {
    <#
    .SYNOPSIS
        Adapters with their interface GUID and every place that GUID appears.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeVirtual
    )

    $classRoot = Resolve-SpooferRegistryPath -Path $script:NetClassRoot
    if (-not (Test-Path -LiteralPath $classRoot)) {
        Write-SpooferLog -Level Warn -Message "Network adapter class key not found."
        return @()
    }

    $physical = @{}
    try {
        foreach ($adapter in (Get-NetAdapter -ErrorAction Stop)) {
            $physical[[string]$adapter.InterfaceGuid] = $adapter
        }
    } catch {
        Write-SpooferLog -Level Debug -Message "Get-NetAdapter unavailable: $($_.Exception.Message)"
    }

    foreach ($child in (Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue)) {
        if ($child.PSChildName -notmatch '^\d{4}$') { continue }

        $classKey = '{0}\{1}' -f $script:NetClassRoot, $child.PSChildName
        $guid     = [string](Get-SpooferRegistryValue -Path $classKey -Name 'NetCfgInstanceId').Value
        if (-not $guid -or $guid -notmatch '^\{[0-9a-fA-F-]{36}\}$') { continue }

        $adapter = $null
        if ($physical.ContainsKey($guid)) { $adapter = $physical[$guid] }

        # Without -IncludeVirtual, only adapters Windows calls hardware are
        # touched. Renaming the GUID of a VPN or Hyper-V adapter tends to break
        # the software that created it.
        if (-not $IncludeVirtual) {
            if ($null -eq $adapter) { continue }
            if (-not $adapter.HardwareInterface) { continue }
        }

        $present = New-Object System.Collections.ArrayList
        foreach ($location in $script:InterfaceLocations) {
            $name = $location.Format -f $guid
            $path = '{0}\{1}' -f $location.Parent, $name
            if (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $path)) {
                [void]$present.Add([pscustomobject]@{
                    Parent  = $location.Parent
                    Name    = $name
                    Format  = $location.Format
                    Purpose = $location.Purpose
                })
            }
        }

        [pscustomobject]@{
            Guid         = $guid
            ClassKey     = $classKey
            Name         = $(if ($adapter) { [string]$adapter.Name } else { 'index ' + $child.PSChildName })
            Description  = $(if ($adapter) { [string]$adapter.InterfaceDescription } else { '' })
            IsPhysical   = ($null -ne $adapter -and $adapter.HardwareInterface)
            References   = @($present)
        }
    }
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'interfaceguid'
        Title          = 'Network interface GUIDs'
        Tier           = 'Risky'
        RequiresReboot = $true
        Description    = 'Gives each adapter a new interface GUID and renames every registry key that references it: TCP/IP, TCP/IPv6, NetBT, the connection name and NetworkSetup2. A stable per-machine identifier that survives a MAC change. Needs a restart, and a missed reference costs the adapter its TCP/IP binding.'
        Targets        = @(
            'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-...}\*\NetCfgInstanceId'
            'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{*}'
            'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\{*}'
            'HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{*}'
            'HKLM\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-...}\{*}'
            'HKLM\SYSTEM\CurrentControlSet\Control\NetworkSetup2\Interfaces\{*}'
        )

        GetState = {
            param($Context)

            $includeVirtual = [bool](Get-SpooferOption -Context $Context -Name 'IncludeVirtualAdapters' -Default $false)
            $interfaces = @(Get-SpooferNetworkInterface -IncludeVirtual:$includeVirtual)

            if ($interfaces.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Interfaces'; Value = 'none found'; Note = '' })
            }

            foreach ($interface in $interfaces) {
                [pscustomobject]@{
                    Item  = '{0}' -f $interface.Name
                    Value = $interface.Guid
                    Note  = '{0} reference(s): {1}' -f $interface.References.Count, ((@($interface.References | ForEach-Object { $_.Purpose })) -join ', ')
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $includeVirtual = [bool](Get-SpooferOption -Context $Context -Name 'IncludeVirtualAdapters' -Default $false)
            $interfaces = @(Get-SpooferNetworkInterface -IncludeVirtual:$includeVirtual)

            if ($interfaces.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No network interfaces found; nothing to change.'
                return @()
            }

            Write-SpooferLog -Level Warn -Message 'Interface GUIDs are referenced in several places at once. If this leaves an adapter without networking, restore this backup and restart.'

            $results = New-Object System.Collections.ArrayList

            foreach ($interface in $interfaces) {
                $newGuid = '{{{0}}}' -f (New-SpooferGuid -Format D)
                $label   = 'Interface {0}' -f $interface.Name

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $interface.Guid -NewValue $newGuid -Simulated
                    foreach ($reference in $interface.References) {
                        Write-SpooferLog -Level Info -Message "  would rename $($reference.Parent)\$($reference.Name)"
                    }
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                $renamed = 0
                $failed  = $null

                foreach ($reference in $interface.References) {
                    $newName     = $reference.Format -f $newGuid
                    $source      = '{0}\{1}' -f $reference.Parent, $reference.Name
                    $destination = '{0}\{1}' -f $reference.Parent, $newName

                    try {
                        if ($Session) {
                            # Recorded before the rename, so a failure part way
                            # through still leaves every completed step undoable.
                            Add-SpooferBackupEntry -Session $Session -Type 'RegistryKeyRename' -Module 'interfaceguid' `
                                -Label ('{0} ({1})' -f $label, $reference.Purpose) -Data @{
                                    Parent       = $reference.Parent
                                    OriginalName = $reference.Name
                                    NewName      = $newName
                                } | Out-Null
                        }

                        Copy-SpooferRegistryKey -Source $source -Destination $destination
                        Remove-SpooferRegistryKey -Path $source
                        $renamed++
                    } catch {
                        $failed = '{0}: {1}' -f $reference.Purpose, $_.Exception.Message
                        Write-SpooferLog -Level Error -Message "$($label) $($reference.Purpose): $($_.Exception.Message)"
                        break
                    }
                }

                if ($failed) {
                    Write-SpooferLog -Level Error -Message "Stopped after $renamed of $($interface.References.Count) references. The class key was left on the old GUID, so restore this backup before rebooting."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $failed
                    })
                    continue
                }

                # The class key goes last. While it still holds the old GUID the
                # adapter is unchanged as far as Windows is concerned, so this
                # write is what actually commits the rename.
                $written = Set-SpooferRegistryValue -Path $interface.ClassKey -Name 'NetCfgInstanceId' `
                    -Value $newGuid -Kind 'String' -Label ('{0} NetCfgInstanceId' -f $label) `
                    -Module 'interfaceguid' -Session $Session

                if ($written.Changed) {
                    Write-SpooferLog -Level Success -Message "$label rewritten in $renamed place(s) plus the class key."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } else {
                    [void]$results.Add($written)
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
