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
    separate backup entry, and a rename that fails part way through is undone
    on the spot: the keys that did move go back to the names they had before
    anything else is attempted. The class key is written last, so until every
    other reference is in place Windows still knows the adapter by its old GUID
    and an interrupted run leaves nothing half-applied.

    The GUID is also checked for collisions before it is used. A candidate that
    already names a key in any of the locations is thrown away and another is
    drawn, which is what stops a rename running into a key that is already
    there and stopping half-done.
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

function Test-SpooferInterfaceGuidAvailable {
    <#
    .SYNOPSIS
        True when no key in any of the interface locations already carries this GUID.
    .DESCRIPTION
        Every location is checked, not just the ones the adapter being renamed
        happens to use. A GUID that names a key belonging to some other adapter
        is not free, and finding that out half way through a rename is how an
        interface ends up with its references split across two names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Guid
    )

    foreach ($location in $script:InterfaceLocations) {
        $path = '{0}\{1}' -f $location.Parent, ($location.Format -f $Guid)
        if (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $path)) { return $false }
    }
    return $true
}

function New-SpooferFreeInterfaceGuid {
    <#
    .SYNOPSIS
        Draws an interface GUID that nothing in the registry is using yet.
    .OUTPUTS
        The GUID in brace form, or $null if every attempt collided.
    #>
    [CmdletBinding()]
    param(
        [int]$Attempts = 8
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $candidate = '{{{0}}}' -f (New-SpooferGuid -Format D)
        if (Test-SpooferInterfaceGuidAvailable -Guid $candidate) { return $candidate }
        Write-SpooferLog -Level Debug -Message "Interface GUID $candidate is already in use; drawing another."
    }
    return $null
}

function Complete-SpooferInterfaceRollback {
    <#
    .SYNOPSIS
        Undoes a partial rename and tidies the backup session after it.
    .DESCRIPTION
        Wraps Undo-SpooferInterfaceRename with the bookkeeping every caller
        needs: a step that went back has its backup entry dropped, or a later
        restore would try to undo a rename that is already undone. A step that
        would not go back keeps its entry, because that one still needs undoing.
    .OUTPUTS
        The reason string to report for the adapter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Completed,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Because,
        [pscustomobject]$Session
    )

    $rollback = Undo-SpooferInterfaceRename -Completed $Completed

    if ($Session) {
        foreach ($step in $rollback.Undone) {
            if ($step.Entry) { $Session.Entries.Remove($step.Entry) }
        }
    }

    if ($rollback.Stuck -eq 0) {
        Write-SpooferLog -Level Info -Message "$Label is back on its original GUID; the adapter is as it was."
        return '{0} (rolled back)' -f $Because
    }

    Write-SpooferLog -Level Error -Message "$Label could not be put back completely: $($rollback.Stuck) rename(s) are still on the new GUID. Restore this backup before restarting."
    return '{0} (rollback incomplete)' -f $Because
}

function Undo-SpooferInterfaceRename {
    <#
    .SYNOPSIS
        Puts the renames that did complete back on their original names.
    .DESCRIPTION
        Walks the completed steps in reverse, copying each key back to the name
        it had and deleting the new one. The class key is never involved: it is
        written last during a rename, so a failure can only happen while Windows
        still knows the adapter by its old GUID.

        A step that cannot be put back is counted rather than thrown, because
        stopping at the first stuck key would strand the rest.
    .OUTPUTS
        An object carrying the steps that were undone and a count of those that
        were not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Completed
    )

    $undone = New-Object System.Collections.ArrayList
    $stuck  = 0

    for ($i = $Completed.Count - 1; $i -ge 0; $i--) {
        $step = $Completed[$i]
        try {
            # Copied back before the new one is deleted, so the key is never
            # absent from both names.
            if (-not (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $step.Original))) {
                Copy-SpooferRegistryKey -Source $step.New -Destination $step.Original
            }
            Remove-SpooferRegistryKey -Path $step.New
            [void]$undone.Add($step)
            Write-SpooferLog -Level Info -Message "Rolled back $($step.Purpose)."
        } catch {
            $stuck++
            Write-SpooferLog -Level Error -Message "Could not roll back $($step.Purpose): $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Undone = @($undone)
        Stuck  = $stuck
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
                $label   = 'Interface {0}' -f $interface.Name
                $newGuid = New-SpooferFreeInterfaceGuid

                if (-not $newGuid) {
                    $reason = 'every candidate GUID was already in use'
                    Write-SpooferLog -Level Error -Message "$($label): $reason; leaving it alone."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $null
                        Changed = $false; Simulated = [bool]$Context.DryRun; Skipped = $true; Reason = $reason
                    })
                    continue
                }

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

                $completed = New-Object System.Collections.ArrayList
                $failed    = $null

                foreach ($reference in $interface.References) {
                    $newName     = $reference.Format -f $newGuid
                    $source      = '{0}\{1}' -f $reference.Parent, $reference.Name
                    $destination = '{0}\{1}' -f $reference.Parent, $newName
                    $entry       = $null

                    try {
                        if ($Session) {
                            # Recorded before the rename, so a failure part way
                            # through still leaves every completed step undoable
                            # even if the rollback below cannot finish either.
                            $entry = Add-SpooferBackupEntry -Session $Session -Type 'RegistryKeyRename' -Module 'interfaceguid' `
                                -Label ('{0} ({1})' -f $label, $reference.Purpose) -Data @{
                                    Parent       = $reference.Parent
                                    OriginalName = $reference.Name
                                    NewName      = $newName
                                }
                        }

                        Copy-SpooferRegistryKey -Source $source -Destination $destination
                        Remove-SpooferRegistryKey -Path $source

                        [void]$completed.Add([pscustomobject]@{
                            Purpose  = $reference.Purpose
                            Original = $source
                            New      = $destination
                            Entry    = $entry
                        })
                    } catch {
                        $failed = '{0}: {1}' -f $reference.Purpose, $_.Exception.Message
                        Write-SpooferLog -Level Error -Message "$($label) $($reference.Purpose): $($_.Exception.Message)"

                        # The copy may have got part way before it threw. If the
                        # new key is there at all it has to be cleaned up, so it
                        # counts as a step to undo. If it is not, nothing moved
                        # and the entry would only describe a rename that never
                        # happened.
                        if (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $destination)) {
                            [void]$completed.Add([pscustomobject]@{
                                Purpose  = $reference.Purpose
                                Original = $source
                                New      = $destination
                                Entry    = $entry
                            })
                        } elseif ($Session -and $entry) {
                            $Session.Entries.Remove($entry)
                        }

                        break
                    }
                }

                if ($failed) {
                    Write-SpooferLog -Level Warn -Message "Stopped after $($completed.Count) of $($interface.References.Count) references; putting them back."
                    $reason = Complete-SpooferInterfaceRollback -Completed @($completed) -Label $label -Because $failed -Session $Session

                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $reason
                    })
                    continue
                }

                # The class key goes last. While it still holds the old GUID the
                # adapter is unchanged as far as Windows is concerned, so this
                # write is what actually commits the rename.
                $written = $null
                try {
                    $written = Set-SpooferRegistryValue -Path $interface.ClassKey -Name 'NetCfgInstanceId' `
                        -Value $newGuid -Kind 'String' -Label ('{0} NetCfgInstanceId' -f $label) `
                        -Module 'interfaceguid' -Session $Session
                } catch {
                    Write-SpooferLog -Level Error -Message "$($label): the class key write failed ($($_.Exception.Message)); putting the renames back."
                    $reason = Complete-SpooferInterfaceRollback -Completed @($completed) -Label $label `
                        -Because $_.Exception.Message -Session $Session

                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $reason
                    })
                    continue
                }

                if ($written.Changed) {
                    Write-SpooferLog -Level Success -Message "$label rewritten in $($completed.Count) place(s) plus the class key."
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                    continue
                }

                # The renames all worked and the class key did not. That is the
                # worst state to leave an adapter in: Windows still looks for
                # its settings under the old GUID and they are no longer there.
                # Undo the renames rather than report a failure and walk away.
                Write-SpooferLog -Level Error -Message "$($label): the class key was not written ($($written.Reason)); putting the renames back."
                $reason = Complete-SpooferInterfaceRollback -Completed @($completed) -Label $label `
                    -Because $written.Reason -Session $Session

                [void]$results.Add([pscustomobject]@{
                    Label = $label; OldValue = $interface.Guid; NewValue = $newGuid
                    Changed = $false; Simulated = $false; Skipped = $true; Reason = $reason
                })
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
