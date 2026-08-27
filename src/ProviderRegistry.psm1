<#
.SYNOPSIS
    Discovers the provider modules under src\Providers and exposes them as a
    single ordered catalogue.
.DESCRIPTION
    A provider is one module that owns one group of related identifiers. Each
    provider module exports a single Get-SpooferProviderDefinition function
    returning one or more descriptors:

        Name           short selector used on the command line
        Title          heading shown in output
        Tier           Standard | Advanced | Risky
        RequiresReboot $true when the change only takes full effect after a restart
        Description    one or two sentences of what it touches
        Targets        the concrete registry paths / devices involved
        GetState       { param($Context) } -> rows of Item / Value / Note
        Invoke         { param($Session, $Context) } -> change results

    Because every provider exports the same function name, definitions are pulled
    through each module's own session state rather than the caller's, which keeps
    the last-imported module from shadowing the rest.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:Providers   = $null
$script:ProviderDir = Join-Path $PSScriptRoot 'Providers'

$script:ValidTiers = @('Standard', 'Advanced', 'Risky')

function Import-SpooferProvider {
    <#
    .SYNOPSIS
        Loads every provider module and caches the resulting catalogue.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if ($script:Providers -and -not $Force) { return $script:Providers }

    if (-not (Test-Path -LiteralPath $script:ProviderDir)) {
        throw "Provider directory not found: $script:ProviderDir"
    }

    $catalogue = New-Object System.Collections.ArrayList

    $files = Get-ChildItem -LiteralPath $script:ProviderDir -Filter '*.psm1' -File |
        Where-Object { $_.Name -notlike '_*' } |
        Sort-Object Name

    foreach ($file in $files) {
        try {
            $module = Import-Module -Name $file.FullName -Force -PassThru -DisableNameChecking -ErrorAction Stop
            $definitions = & $module { Get-SpooferProviderDefinition }

            foreach ($definition in @($definitions)) {
                # Piped to Out-Null: the validator returns $true, which would
                # otherwise land in this function's output stream alongside the
                # catalogue itself.
                Confirm-SpooferProviderDefinition -Definition $definition -Source $file.Name | Out-Null
                Add-SpooferProviderDefault -Definition $definition
                [void]$catalogue.Add($definition)
            }
            Write-SpooferLog -Level Debug -Message "Loaded provider module $($file.Name)."
        } catch {
            Write-SpooferLog -Level Error -Message "Provider module $($file.Name) failed to load: $($_.Exception.Message)"
            throw
        }
    }

    $names = @($catalogue | ForEach-Object { $_.Name })
    $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count) {
        throw "Duplicate provider names: $($dupes -join ', ')"
    }

    $script:Providers = @($catalogue)
    return $script:Providers
}

function Add-SpooferProviderDefault {
    <#
    .SYNOPSIS
        Fills in the optional descriptor properties.
    .DESCRIPTION
        StrictMode turns a missing property into an error, so without this every
        consumer would have to test for these before reading them. Defaulting
        them once at load time keeps that out of the checklist and the status
        table, and means a new provider only declares what is true of it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Definition
    )

    $defaults = @{
        RequiresReboot = $false
        TouchesBoot    = $false
        Targets        = @()
    }

    foreach ($name in $defaults.Keys) {
        if ($Definition.PSObject.Properties.Name -contains $name) { continue }
        Add-Member -InputObject $Definition -MemberType NoteProperty -Name $name -Value $defaults[$name]
    }
}

function Confirm-SpooferProviderDefinition {
    <#
    .SYNOPSIS
        Validates one descriptor so a malformed provider fails loudly at load
        time rather than halfway through a spoof.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Definition,

        [string]$Source = '<unknown>'
    )

    if ($null -eq $Definition) {
        throw "$Source returned a null provider definition."
    }

    foreach ($property in @('Name', 'Title', 'Tier', 'Description', 'GetState', 'Invoke')) {
        if (-not ($Definition.PSObject.Properties.Name -contains $property)) {
            throw "$Source is missing the required provider property '$property'."
        }
    }

    if ([string]::IsNullOrWhiteSpace($Definition.Name)) {
        throw "$Source declares a provider with an empty Name."
    }

    if ($script:ValidTiers -notcontains $Definition.Tier) {
        throw "$Source declares provider '$($Definition.Name)' with unknown tier '$($Definition.Tier)'."
    }

    foreach ($property in @('GetState', 'Invoke')) {
        if ($Definition.$property -isnot [scriptblock]) {
            throw "$Source declares provider '$($Definition.Name)' whose $property is not a scriptblock."
        }
    }

    return $true
}

function Get-SpooferProvider {
    <#
    .SYNOPSIS
        Returns the provider catalogue, optionally filtered.
    .PARAMETER Name
        Explicit provider names. 'all' selects every provider including the
        Risky tier. Names are matched case-insensitively.
    .PARAMETER Tier
        Tier filter used when no explicit names are given.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Name,

        [ValidateSet('Standard', 'Advanced', 'Risky')]
        [string[]]$Tier
    )

    $providers = Import-SpooferProvider

    if ($Name -and $Name.Count) {
        if ($Name -contains 'all') { return $providers }

        $selected = New-Object System.Collections.ArrayList
        foreach ($requested in $Name) {
            $match = @($providers | Where-Object { $_.Name -eq $requested })
            if ($match.Count -eq 0) {
                throw ("Unknown module '{0}'. Available modules: {1}" -f `
                        $requested, (($providers | ForEach-Object { $_.Name }) -join ', '))
            }
            if ($selected -notcontains $match[0]) { [void]$selected.Add($match[0]) }
        }
        return @($selected)
    }

    if ($Tier -and $Tier.Count) {
        return @($providers | Where-Object { $Tier -contains $_.Tier })
    }

    return $providers
}

function Get-SpooferProviderName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @((Import-SpooferProvider) | ForEach-Object { $_.Name })
}

Export-ModuleMember -Function @(
    'Import-SpooferProvider'
    'Confirm-SpooferProviderDefinition'
    'Add-SpooferProviderDefault'
    'Get-SpooferProvider'
    'Get-SpooferProviderName'
)
