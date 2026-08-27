<#
.SYNOPSIS
    Network profile GUIDs, and the record of every network this machine has joined.
.DESCRIPTION
    Windows keeps a profile for each network it has ever connected to, under
    NetworkList\Profiles, named by GUID. Alongside each one is a signature entry
    holding the network's gateway MAC and SSID, pointing back at the profile by
    that GUID.

    Two things make this worth covering. The GUIDs are stable per-machine
    identifiers in their own right, and the profile names are a history of every
    Wi-Fi network and every office and home LAN the machine has been on, which
    says more about where a machine has been than most of the hardware ids do.

    Renaming a profile means copying its key to a new GUID and updating the
    signature that references it, because the registry has no rename.
.NOTES
    Windows creates a fresh profile the next time it sees a network, so the
    machine keeps working; it simply no longer carries the old record.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1')    -DisableNameChecking

$script:NetworkList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList'

function Get-SpooferNetworkProfile {
    <#
    .SYNOPSIS
        Each stored profile with its name and the signatures pointing at it.
    #>
    [CmdletBinding()]
    param()

    $profilesPath = '{0}\Profiles' -f $script:NetworkList
    $resolved     = Resolve-SpooferRegistryPath -Path $profilesPath
    if (-not (Test-Path -LiteralPath $resolved)) { return @() }

    # Signatures are indexed by their own hash, so the link back to a profile is
    # the ProfileGuid value inside them. Both branches have to be searched.
    $signatures = @()
    foreach ($branch in @('Managed', 'Unmanaged')) {
        $branchPath = '{0}\Signatures\{1}' -f $script:NetworkList, $branch
        $branchResolved = Resolve-SpooferRegistryPath -Path $branchPath
        if (-not (Test-Path -LiteralPath $branchResolved)) { continue }

        foreach ($entry in (Get-ChildItem -LiteralPath $branchResolved -ErrorAction SilentlyContinue)) {
            $path = '{0}\{1}' -f $branchPath, $entry.PSChildName
            $signatures += [pscustomobject]@{
                Path        = $path
                ProfileGuid = [string](Get-SpooferRegistryValue -Path $path -Name 'ProfileGuid').Value
            }
        }
    }

    foreach ($child in (Get-ChildItem -LiteralPath $resolved -ErrorAction SilentlyContinue)) {
        if ($child.PSChildName -notmatch '^\{[0-9a-fA-F-]{36}\}$') { continue }

        $path = '{0}\{1}' -f $profilesPath, $child.PSChildName

        [pscustomobject]@{
            Guid        = $child.PSChildName
            Path        = $path
            ProfileName = [string](Get-SpooferRegistryValue -Path $path -Name 'ProfileName').Value
            Signatures  = @($signatures | Where-Object { $_.ProfileGuid -eq $child.PSChildName })
        }
    }
}

Register-SpooferRestoreHandler -Type 'NetworkProfile' -Handler {
    param($Entry)

    $originalPath = '{0}\{1}' -f $Entry.ProfilesPath, $Entry.OriginalGuid
    $newPath      = '{0}\{1}' -f $Entry.ProfilesPath, $Entry.NewGuid

    if (-not (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $originalPath))) {
        Copy-SpooferRegistryKey -Source $newPath -Destination $originalPath
    }
    Remove-SpooferRegistryKey -Path $newPath

    foreach ($signature in @($Entry.Signatures)) {
        if (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $signature)) {
            New-ItemProperty -Path (Resolve-SpooferRegistryPath -Path $signature) `
                -Name 'ProfileGuid' -Value $Entry.OriginalGuid -PropertyType String -Force -ErrorAction Stop | Out-Null
        }
    }

    return "Network profile $($Entry.OriginalGuid) restored."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'networkprofile'
        Title          = 'Network profile GUIDs'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Gives every stored network profile a new GUID and repoints the signature that references it. The profile list is a record of every network the machine has joined, and the GUIDs are stable per-machine identifiers.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\{*}'
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\*\*\ProfileGuid'
        )

        GetState = {
            param($Context)

            $profiles = @(Get-SpooferNetworkProfile)
            if ($profiles.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Network profiles'; Value = 'none found'; Note = '' })
            }

            foreach ($networkProfile in $profiles) {
                [pscustomobject]@{
                    Item  = $(if ($networkProfile.ProfileName) { $networkProfile.ProfileName } else { 'unnamed profile' })
                    Value = $networkProfile.Guid
                    Note  = '{0} signature(s)' -f $networkProfile.Signatures.Count
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $profiles = @(Get-SpooferNetworkProfile)
            if ($profiles.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No network profiles found; nothing to change.'
                return @()
            }

            $profilesPath = '{0}\Profiles' -f $script:NetworkList
            $results = New-Object System.Collections.ArrayList

            foreach ($networkProfile in $profiles) {
                $newGuid = '{{{0}}}' -f (New-SpooferGuid -Format D)
                $label   = 'Profile {0}' -f $(if ($networkProfile.ProfileName) { $networkProfile.ProfileName } else { $networkProfile.Guid })

                if ($Context.DryRun) {
                    Write-SpooferChange -Label $label -OldValue $networkProfile.Guid -NewValue $newGuid -Simulated
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $networkProfile.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                    })
                    continue
                }

                if ($Session) {
                    Add-SpooferBackupEntry -Session $Session -Type 'NetworkProfile' -Module 'networkprofile' -Label $label -Data @{
                        ProfilesPath = $profilesPath
                        OriginalGuid = $networkProfile.Guid
                        NewGuid      = $newGuid
                        Signatures   = @($networkProfile.Signatures | ForEach-Object { $_.Path })
                    } | Out-Null
                }

                try {
                    $source      = '{0}\{1}' -f $profilesPath, $networkProfile.Guid
                    $destination = '{0}\{1}' -f $profilesPath, $newGuid

                    Copy-SpooferRegistryKey -Source $source -Destination $destination
                    Remove-SpooferRegistryKey -Path $source

                    # A signature left pointing at the old GUID would orphan the
                    # profile and Windows would rebuild it from scratch.
                    foreach ($signature in $networkProfile.Signatures) {
                        New-ItemProperty -Path (Resolve-SpooferRegistryPath -Path $signature.Path) `
                            -Name 'ProfileGuid' -Value $newGuid -PropertyType String -Force -ErrorAction Stop | Out-Null
                    }

                    Write-SpooferChange -Label $label -OldValue $networkProfile.Guid -NewValue $newGuid
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $networkProfile.Guid; NewValue = $newGuid
                        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                    })
                } catch {
                    Write-SpooferLog -Level Error -Message "$($label): $($_.Exception.Message)"
                    [void]$results.Add([pscustomobject]@{
                        Label = $label; OldValue = $networkProfile.Guid; NewValue = $newGuid
                        Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                    })
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
