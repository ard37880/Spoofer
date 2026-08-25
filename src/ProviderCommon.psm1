<#
.SYNOPSIS
    Helpers shared by the registry-backed providers so each one only has to
    declare which values it owns and how to generate a replacement.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RegistryHelper.psm1') -DisableNameChecking

function New-SpooferRegistryTarget {
    <#
    .SYNOPSIS
        Describes one registry value a provider owns.
    .PARAMETER Generator
        Scriptblock returning the replacement value. Called once per spoof.
    .PARAMETER CreateIfMissing
        Write the value even when it is absent on this machine. Off by default:
        inventing an identifier Windows never had is itself a fingerprint.
    .PARAMETER TakeOwnership
        Take ownership of the key if the write is denied. The original security
        descriptor is backed up first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Generator,

        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Kind = 'String',

        [string]$Label,
        [string]$Note = '',

        [switch]$CreateIfMissing,
        [switch]$TakeOwnership
    )

    if (-not $PSBoundParameters.ContainsKey('Label')) { $Label = $Name }

    return [pscustomobject]@{
        Path            = $Path
        Name            = $Name
        Kind            = $Kind
        Generator       = $Generator
        Label           = $Label
        Note            = $Note
        CreateIfMissing = [bool]$CreateIfMissing
        TakeOwnership   = [bool]$TakeOwnership
    }
}

function Get-SpooferRegistryTargetState {
    <#
    .SYNOPSIS
        Reads the current value of each target for the status display.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Target
    )

    foreach ($item in $Target) {
        $current = Get-SpooferRegistryValue -Path $item.Path -Name $item.Name

        $note = $item.Note
        if (-not $current.KeyExists) {
            $note = 'key not present on this system'
        } elseif (-not $current.Exists) {
            $note = 'value not present on this system'
        }

        [pscustomobject]@{
            Item  = $item.Label
            Value = $current.Value
            Note  = $note
        }
    }
}

function Invoke-SpooferRegistryTarget {
    <#
    .SYNOPSIS
        Backs up and rewrites every target, honouring the context's dry-run flag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Target,

        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [pscustomobject]$Session,

        [string]$Module = ''
    )

    foreach ($item in $Target) {
        $newValue = & $item.Generator

        $splat = @{
            Path   = $item.Path
            Name   = $item.Name
            Value  = $newValue
            Kind   = $item.Kind
            Label  = $item.Label
            Module = $Module
        }
        if ($Session)              { $splat['Session']         = $Session }
        if ($Context.DryRun)       { $splat['DryRun']          = $true }
        if ($item.CreateIfMissing) { $splat['CreateIfMissing']  = $true }
        if ($item.TakeOwnership)   { $splat['TakeOwnership']    = $true }

        try {
            Set-SpooferRegistryValue @splat
        } catch {
            Write-SpooferLog -Level Error -Message "$($item.Label): $($_.Exception.Message)"
            [pscustomobject]@{
                Label = $item.Label; Path = $item.Path; Name = $item.Name
                OldValue = $null; NewValue = $newValue
                Changed = $false; Simulated = $Context.DryRun; Skipped = $true
                Reason = $_.Exception.Message
            }
        }
    }
}

Export-ModuleMember -Function @(
    'New-SpooferRegistryTarget'
    'Get-SpooferRegistryTargetState'
    'Invoke-SpooferRegistryTarget'
)
