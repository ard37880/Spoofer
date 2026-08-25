<#
.SYNOPSIS
    Durable backup sessions: every value Spoofer changes is recorded here first,
    and Restore-SpooferBackupSession replays those records to undo the change.
.DESCRIPTION
    The store is deliberately dumb. It persists JSON-safe entries and dispatches
    each one, on restore, to a handler registered by the module that knows how to
    put that kind of value back (registry, hostname, NIC, disk, volume). That
    keeps the store free of any dependency on the providers themselves.

    Layout on disk:

        %ProgramData%\Spoofer\backups\<session-id>\manifest.json
        %ProgramData%\Spoofer\backups\<session-id>\files\*        (raw blobs)
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:SchemaVersion    = 1
$script:RestoreHandlers  = @{}

#region Restore handler registry

function Register-SpooferRestoreHandler {
    <#
    .SYNOPSIS
        Registers the scriptblock that knows how to undo one entry type.
    .PARAMETER Handler
        Receives the entry as its only argument. Should throw on failure and
        may return a string describing what it did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [scriptblock]$Handler
    )

    $script:RestoreHandlers[$Type] = $Handler
    Write-SpooferLog -Level Debug -Message "Restore handler registered for entry type '$Type'."
}

function Get-SpooferRestoreHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Type
    )

    if ($script:RestoreHandlers.ContainsKey($Type)) {
        return $script:RestoreHandlers[$Type]
    }
    return $null
}

function Get-SpooferRegisteredRestoreType {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @($script:RestoreHandlers.Keys | Sort-Object)
}

#endregion

#region Session lifecycle

function Get-SpooferBackupRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path (Get-SpooferRoot) 'backups')
}

function New-SpooferBackupSession {
    <#
    .SYNOPSIS
        Starts a new backup session. Nothing is written until Save- is called.
    #>
    [CmdletBinding()]
    param(
        [string]$Note = '',

        [AllowNull()]
        [Nullable[int]]$Seed,

        [string[]]$Modules = @()
    )

    Initialize-SpooferRoot | Out-Null

    $created = [DateTime]::UtcNow
    $id      = '{0}-{1}' -f $created.ToString('yyyyMMdd-HHmmss'), (New-SpooferHexString -Length 6)
    $path    = Join-Path (Get-SpooferBackupRoot) $id

    $session = [pscustomobject]@{
        Schema      = $script:SchemaVersion
        Id          = $id
        Path        = $path
        CreatedUtc  = $created.ToString('o')
        Hostname    = [System.Environment]::MachineName
        User        = [System.Environment]::UserName
        Note        = $Note
        Seed        = $Seed
        Modules     = [string[]]$Modules
        Restored    = $false
        RestoredUtc = $null
        Entries     = (New-Object System.Collections.ArrayList)
    }

    Write-SpooferLog -Level Debug -Message "Backup session $id created (not yet persisted)."
    return $session
}

function Add-SpooferBackupEntry {
    <#
    .SYNOPSIS
        Records one original value in the session.
    .PARAMETER Type
        Entry type; must have a restore handler registered by restore time.
    .PARAMETER Label
        Human-readable name shown in listings and restore output.
    .PARAMETER Data
        Type-specific payload. Must contain only JSON-safe values: strings,
        numbers, booleans, nulls, and arrays of those. Binary data belongs in a
        base64 string or a sidecar file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [hashtable]$Data,

        [string]$Module = ''
    )

    $entry = [ordered]@{
        Type      = $Type
        Label     = $Label
        Module    = $Module
        StampUtc  = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($key in $Data.Keys) { $entry[$key] = $Data[$key] }

    [void]$Session.Entries.Add([pscustomobject]$entry)
    Write-SpooferLog -Level Debug -Message "Backup entry added: [$Type] $Label"

    return $Session.Entries[$Session.Entries.Count - 1]
}

function New-SpooferBackupFilePath {
    <#
    .SYNOPSIS
        Reserves a path inside the session for a raw blob (e.g. a boot sector).
    .OUTPUTS
        The absolute path. The caller writes the file; the relative name is what
        belongs in the entry payload so the session stays relocatable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $dir = Join-Path $Session.Path 'files'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir $Name)
}

function Save-SpooferBackupSession {
    <#
    .SYNOPSIS
        Writes (or rewrites) the session manifest atomically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session
    )

    if ($Session.Entries.Count -eq 0) {
        Write-SpooferLog -Level Debug -Message "Session $($Session.Id) has no entries; nothing written."
        return $null
    }

    if (-not (Test-Path -LiteralPath $Session.Path)) {
        New-Item -ItemType Directory -Path $Session.Path -Force | Out-Null
    }

    $manifest = [ordered]@{
        schema      = $Session.Schema
        id          = $Session.Id
        createdUtc  = $Session.CreatedUtc
        hostname    = $Session.Hostname
        user        = $Session.User
        note        = $Session.Note
        seed        = $Session.Seed
        modules     = @($Session.Modules)
        restored    = $Session.Restored
        restoredUtc = $Session.RestoredUtc
        entries     = @($Session.Entries)
    }

    $file = Join-Path $Session.Path 'manifest.json'
    $temp = '{0}.tmp' -f $file

    $json = $manifest | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $temp -Value $json -Encoding UTF8 -Force

    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Move-Item -LiteralPath $temp -Destination $file -Force

    Write-SpooferLog -Level Debug -Message "Manifest saved: $file ($($Session.Entries.Count) entries)."
    return $file
}

function Read-SpooferBackupSession {
    <#
    .SYNOPSIS
        Loads one session from a manifest path or a session directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $manifestPath = $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $manifestPath = Join-Path $Path 'manifest.json'
    }

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "No backup manifest found at '$manifestPath'."
    }

    $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        throw "Backup manifest '$manifestPath' is not valid JSON: $($_.Exception.Message)"
    }

    if ($data.schema -gt $script:SchemaVersion) {
        throw ("Backup '{0}' uses manifest schema {1}; this build understands up to {2}." -f `
                $data.id, $data.schema, $script:SchemaVersion)
    }

    $entries = New-Object System.Collections.ArrayList
    if ($null -ne $data.entries) {
        foreach ($entry in @($data.entries)) { [void]$entries.Add($entry) }
    }

    return [pscustomobject]@{
        Schema      = $data.schema
        Id          = $data.id
        Path        = (Split-Path -Path $manifestPath -Parent)
        CreatedUtc  = $data.createdUtc
        Hostname    = $data.hostname
        User        = $data.user
        Note        = $data.note
        Seed        = $data.seed
        Modules     = @($data.modules)
        Restored    = [bool]$data.restored
        RestoredUtc = $data.restoredUtc
        Entries     = $entries
    }
}

function Get-SpooferBackupSession {
    <#
    .SYNOPSIS
        Every stored session, newest first.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeRestored
    )

    $root = Get-SpooferBackupRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $sessions = foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $manifest = Join-Path $dir.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        try {
            Read-SpooferBackupSession -Path $manifest
        } catch {
            Write-SpooferLog -Level Warn -Message "Skipping unreadable backup '$($dir.Name)': $($_.Exception.Message)"
        }
    }

    $result = @($sessions)
    if (-not $IncludeRestored) {
        $result = @($result | Where-Object { -not $_.Restored })
    }

    # Sorted on the parsed timestamp: manifests written by different versions
    # may render the same instant with 'Z' or with a numeric offset, and those
    # two forms do not sort correctly against each other as strings.
    return @($result | Sort-Object -Property @{ Expression = {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($_.CreatedUtc, [ref]$parsed)) { $parsed } else { [datetime]::MinValue }
    } } -Descending)
}

function Resolve-SpooferBackupSession {
    <#
    .SYNOPSIS
        Finds a session by id, by unique id prefix, or by the alias 'latest'.
    .DESCRIPTION
        'latest' means the newest session that has not been restored yet, which
        is what you want when undoing the spoof you just ran. Pass an explicit id
        to reach an already-restored session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    if ($Id -eq 'latest') {
        $candidate = @(Get-SpooferBackupSession) | Select-Object -First 1
        if (-not $candidate) {
            throw 'No un-restored backups found. Use -Action List to see every backup, including restored ones.'
        }
        return $candidate
    }

    $all     = @(Get-SpooferBackupSession -IncludeRestored)
    $exact   = @($all | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $partial = @($all | Where-Object { $_.Id -like "$Id*" })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) {
        throw ("Backup id '{0}' is ambiguous; it matches {1} backups: {2}" -f `
                $Id, $partial.Count, (($partial | ForEach-Object { $_.Id }) -join ', '))
    }

    throw "No backup found with id '$Id'."
}

function Remove-SpooferBackupSession {
    <#
    .SYNOPSIS
        Permanently deletes a stored session.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    $session = Resolve-SpooferBackupSession -Id $Id

    if (-not $session.Restored) {
        Write-SpooferLog -Level Warn -Message "Backup $($session.Id) has not been restored; deleting it discards the only record of the original values."
    }

    if ($PSCmdlet.ShouldProcess($session.Id, 'Delete backup')) {
        Remove-Item -LiteralPath $session.Path -Recurse -Force
        Write-SpooferLog -Level Success -Message "Backup $($session.Id) deleted."
        return $true
    }
    return $false
}

#endregion

#region Restore

function Restore-SpooferBackupSession {
    <#
    .SYNOPSIS
        Replays a session's entries to put every original value back.
    .DESCRIPTION
        Entries unwind last-in-first-out. One failing entry never stops the
        others: each result is collected and reported, so a partial restore is
        visible instead of silent. The manifest is only marked restored when
        every entry succeeded, which keeps a partially restored backup
        reachable from 'latest'.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [string[]]$Module,

        [switch]$Force
    )

    if ($Session.Restored -and -not $Force) {
        throw ("Backup {0} was already restored on {1}. Re-run with -Force to replay it." -f `
                $Session.Id, $Session.RestoredUtc)
    }

    $entries = @($Session.Entries)
    [array]::Reverse($entries)

    if ($PSBoundParameters.ContainsKey('Module') -and $Module) {
        $entries = @($entries | Where-Object { $Module -contains $_.Module })
        Write-SpooferLog -Level Info -Message "Restoring only these modules: $($Module -join ', ')"
    }

    $results = New-Object System.Collections.ArrayList

    foreach ($entry in $entries) {
        $handler = Get-SpooferRestoreHandler -Type $entry.Type

        if ($null -eq $handler) {
            [void]$results.Add([pscustomobject]@{
                Label   = $entry.Label
                Type    = $entry.Type
                Status  = 'Failed'
                Message = "No restore handler is registered for entry type '$($entry.Type)'."
            })
            Write-SpooferLog -Level Error -Message "Cannot restore '$($entry.Label)': unknown entry type '$($entry.Type)'."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($entry.Label, 'Restore original value')) {
            [void]$results.Add([pscustomobject]@{
                Label   = $entry.Label
                Type    = $entry.Type
                Status  = 'Skipped'
                Message = 'Dry run.'
            })
            continue
        }

        try {
            $message = & $handler $entry
            [void]$results.Add([pscustomobject]@{
                Label   = $entry.Label
                Type    = $entry.Type
                Status  = 'Restored'
                Message = ([string]$message)
            })
            Write-SpooferLog -Level Success -Message "Restored $($entry.Label)"
        } catch {
            [void]$results.Add([pscustomobject]@{
                Label   = $entry.Label
                Type    = $entry.Type
                Status  = 'Failed'
                Message = $_.Exception.Message
            })
            Write-SpooferLog -Level Error -Message "Failed to restore $($entry.Label): $($_.Exception.Message)"
        }
    }

    $failed  = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    if ($failed -eq 0 -and $skipped -eq 0 -and -not $PSBoundParameters.ContainsKey('Module')) {
        $Session.Restored    = $true
        $Session.RestoredUtc = [DateTime]::UtcNow.ToString('o')
        Save-SpooferBackupSession -Session $Session | Out-Null
    }

    return [pscustomobject]@{
        SessionId = $Session.Id
        Total     = $results.Count
        Restored  = @($results | Where-Object { $_.Status -eq 'Restored' }).Count
        Failed    = $failed
        Skipped   = $skipped
        Results   = @($results)
    }
}

#endregion

Export-ModuleMember -Function @(
    'Register-SpooferRestoreHandler'
    'Get-SpooferRestoreHandler'
    'Get-SpooferRegisteredRestoreType'
    'Get-SpooferBackupRoot'
    'New-SpooferBackupSession'
    'Add-SpooferBackupEntry'
    'New-SpooferBackupFilePath'
    'Save-SpooferBackupSession'
    'Read-SpooferBackupSession'
    'Get-SpooferBackupSession'
    'Resolve-SpooferBackupSession'
    'Remove-SpooferBackupSession'
    'Restore-SpooferBackupSession'
)
