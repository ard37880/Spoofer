#Requires -Version 5.1
<#
.SYNOPSIS
    Rewrites the hardware and installation identifiers of a Windows 10/11
    machine, and puts every one of them back on request.

.DESCRIPTION
    Spoofer changes the identifiers Windows exposes to software: the
    cryptography machine GUID, telemetry and update client ids, the hardware
    profile GUID, the cached SMBIOS description, the hostname, adapter MAC
    addresses, disk and volume serials, and more.

    Nothing is changed without first being written to a backup session under
    %ProgramData%\Spoofer\backups. -Action Restore replays a session and returns
    the machine to exactly the state it was in.

    Run it on hardware you own or administer. Changing these values will log
    you out of software that licensed itself to this machine and can trip the
    fraud checks of services that expect a stable device identity.

.PARAMETER Action
    Status   Show the current value of every identifier (default).
    Spoof    Back up and then change the selected identifiers.
    Restore  Put the values from a backup session back.
    List     List stored backup sessions.
    Remove   Delete a stored backup session.
    Modules  Describe the available modules.

.PARAMETER Module
    Module names to act on, e.g. -Module machineguid,mac. 'all' selects every
    module including the Risky tier. Defaults to the Standard and Advanced tiers.

.PARAMETER Tier
    Select by tier instead of by name: Standard, Advanced or Risky.

.PARAMETER IncludeRisky
    Add the Risky tier to the default selection.

.PARAMETER Seed
    Generate identifiers deterministically from this seed. The same seed always
    produces the same values, which is what you want when rebuilding a machine
    to a known identity.

.PARAMETER BackupId
    Backup session for -Action Restore or Remove. 'latest' (the default) means
    the newest session that has not been restored yet. A unique id prefix works.

.PARAMETER DryRun
    Show every change that would be made and write nothing.

.PARAMETER Force
    Proceed past guards that exist for a reason: renaming a domain-joined
    machine, replaying an already-restored backup.

.PARAMETER Yes
    Skip the confirmation prompt. Intended for unattended runs.

.EXAMPLE
    .\Spoofer.ps1 -Action Status

.EXAMPLE
    .\Spoofer.ps1 -Action Spoof -DryRun

.EXAMPLE
    .\Spoofer.ps1 -Action Spoof -Module machineguid,machineid,mac

.EXAMPLE
    .\Spoofer.ps1 -Action Restore -BackupId latest

.NOTES
    Requires an elevated 64-bit PowerShell session for -Action Spoof and Restore.
#>

[CmdletBinding()]
param(
    [ValidateSet('Status', 'Spoof', 'Restore', 'List', 'Remove', 'Modules')]
    [string]$Action = 'Status',

    [string[]]$Module,

    [ValidateSet('Standard', 'Advanced', 'Risky')]
    [string[]]$Tier,

    [switch]$IncludeRisky,

    [AllowNull()]
    [Nullable[int]]$Seed,

    [string]$BackupId = 'latest',

    [string]$Note = '',

    [switch]$DryRun,

    [switch]$Force,

    [switch]$Yes,

    [switch]$IncludeVirtualAdapters,

    [switch]$AllowVolumeDismount,

    [switch]$NoRestartPrompt,

    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src'

# Unload any modules left over from an earlier run in this session before
# re-importing them in dependency order. Import-Module -Force cannot be used for
# this: on a nested import it removes the instance its dependents are already
# bound to, leaving their exported functions unresolvable.
Get-Module |
    Where-Object { $_.Path -and $_.Path.StartsWith($modulePath, [System.StringComparison]::OrdinalIgnoreCase) } |
    Remove-Module -Force

foreach ($name in @('Common', 'Native', 'BackupStore', 'RegistryHelper', 'ProviderCommon', 'ProviderRegistry')) {
    Import-Module (Join-Path $modulePath "$name.psm1") -DisableNameChecking
}

#region Presentation

function Show-Header {
    Write-Host ''
    Write-Host '  Spoofer' -ForegroundColor White -NoNewline
    Write-Host '  -  Windows 10/11 hardware identifier tool' -ForegroundColor DarkGray
    Write-Host '  Every change is backed up first and can be reverted with -Action Restore.' -ForegroundColor DarkGray
}

function Show-Environment {
    $os = Get-SpooferOsInfo

    Write-Host ''
    Write-Host ('  Host      : {0}' -f [System.Environment]::MachineName) -ForegroundColor DarkGray
    Write-Host ('  OS        : {0} (build {1})' -f $os.Caption, $os.Build) -ForegroundColor DarkGray
    Write-Host ('  PowerShell: {0} ({1}-bit)' -f $PSVersionTable.PSVersion, $(if (Test-SpooferProcess64Bit) { 64 } else { 32 })) -ForegroundColor DarkGray
    Write-Host ('  Elevated  : {0}' -f $(if (Test-SpooferAdmin) { 'yes' } else { 'no' })) -ForegroundColor DarkGray
}

function Test-Environment {
    <#
    .SYNOPSIS
        Blocks on conditions that would make a run wrong rather than merely
        awkward, and warns about the rest.
    #>
    param(
        [switch]$RequireAdmin
    )

    if (-not (Test-SpooferOnWindows)) {
        throw 'Spoofer targets Windows 10 and 11. This host is not Windows.'
    }

    if (-not (Test-SpooferSupportedOs)) {
        Write-SpooferLog -Level Warn -Message 'This does not look like Windows 10 or 11. The identifier locations may differ.'
    }

    if (-not (Test-SpooferProcess64Bit) -and [System.Environment]::Is64BitOperatingSystem) {
        throw 'This is a 32-bit PowerShell on 64-bit Windows. Registry writes would be redirected into WOW6432Node and would not touch the real identifiers. Start the 64-bit PowerShell from C:\Windows\System32\WindowsPowerShell\v1.0.'
    }

    if ($RequireAdmin) { Assert-SpooferAdmin }
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Interactive yes/no gate, bypassed by -Yes.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Prompt = 'Continue?'
    )

    if ($Yes) { return $true }

    Write-Host ''
    Write-Host "  $Message" -ForegroundColor Yellow
    $answer = Read-Host "  $Prompt [y/N]"

    if ($answer -match '^(y|yes)$') { return $true }

    Write-SpooferLog -Level Info -Message 'Cancelled; nothing was changed.'
    return $false
}

function Get-SelectedProvider {
    <#
    .SYNOPSIS
        Resolves the -Module / -Tier / -IncludeRisky combination to a provider list.
    #>
    if ($Module -and $Module.Count) {
        return @(Get-SpooferProvider -Name $Module)
    }

    if ($Tier -and $Tier.Count) {
        return @(Get-SpooferProvider -Tier $Tier)
    }

    $tiers = @('Standard', 'Advanced')
    if ($IncludeRisky) { $tiers += 'Risky' }
    return @(Get-SpooferProvider -Tier $tiers)
}

function New-RunContext {
    New-SpooferContext -DryRun:$DryRun -Force:$Force -Options @{
        IncludeVirtualAdapters = [bool]$IncludeVirtualAdapters
        AllowVolumeDismount    = [bool]$AllowVolumeDismount
    }
}

function Show-RebootNotice {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Provider
    )

    $needsReboot = @($Provider | Where-Object { $_.RequiresReboot })
    if ($needsReboot.Count -eq 0) { return }

    Write-Host ''
    Write-SpooferLog -Level Warn -Message ('A restart is needed before these take full effect: {0}' -f (($needsReboot | ForEach-Object { $_.Name }) -join ', '))

    if ($NoRestartPrompt -or $Yes -or $DryRun) { return }

    if (Confirm-Action -Message 'Restart now?' -Prompt 'Restart') {
        Write-SpooferLog -Level Info -Message 'Restarting.'
        Restart-Computer -Force
    }
}

#endregion

#region Actions

function Invoke-StatusAction {
    Test-Environment

    if (-not (Test-SpooferAdmin)) {
        Write-SpooferLog -Level Warn -Message 'Not elevated. Values that need administrator rights to read will show as unavailable.'
    }

    foreach ($provider in (Get-SelectedProvider)) {
        Write-SpooferBanner -Text ('{0}  [{1}]' -f $provider.Title, $provider.Tier)

        try {
            $rows = @(& $provider.GetState (New-RunContext))
        } catch {
            Write-SpooferLog -Level Error -Message "Could not read $($provider.Name): $($_.Exception.Message)"
            continue
        }

        if ($rows.Count -eq 0) {
            Write-SpooferLog -Level Info -Message 'Nothing on this system matches this module.'
            continue
        }

        foreach ($row in $rows) {
            Write-Host ('    {0,-40} ' -f $row.Item) -ForegroundColor Gray -NoNewline
            Write-Host (ConvertTo-SpooferDisplayValue -Value $row.Value) -ForegroundColor White -NoNewline
            if ($row.Note) {
                Write-Host ('  ({0})' -f $row.Note) -ForegroundColor DarkGray
            } else {
                Write-Host ''
            }
        }
    }

    Write-Host ''
}

function Invoke-SpoofAction {
    Test-Environment -RequireAdmin:(-not $DryRun)

    $providers = Get-SelectedProvider
    if ($providers.Count -eq 0) {
        throw 'No modules selected.'
    }

    Initialize-SpooferRandom -Seed $Seed

    Write-Host ''
    Write-Host '  Modules selected:' -ForegroundColor White
    foreach ($provider in $providers) {
        Write-Host ('    {0,-16} {1,-10} {2}' -f $provider.Name, $provider.Tier, $provider.Title) -ForegroundColor Gray
    }

    $risky = @($providers | Where-Object { $_.Tier -eq 'Risky' })
    if ($risky.Count -and -not $DryRun) {
        Write-SpooferLog -Level Warn -Message ('Risky-tier modules are included: {0}. Review them before continuing.' -f (($risky | ForEach-Object { $_.Name }) -join ', '))
    }

    if (-not $DryRun) {
        $message = 'This will change {0} groups of identifiers on {1}. Software licensed to this machine will stop recognising it.' -f `
            $providers.Count, [System.Environment]::MachineName
        if (-not (Confirm-Action -Message $message)) { return }
    }

    $session = $null
    if (-not $DryRun) {
        $session = New-SpooferBackupSession -Note $Note -Seed $Seed -Modules @($providers | ForEach-Object { $_.Name })
        Write-SpooferLog -Level Info -Message "Backup session: $($session.Id)"
    }

    $context   = New-RunContext
    $changed   = 0
    $skipped   = 0
    $failed    = @()

    foreach ($provider in $providers) {
        Write-SpooferBanner -Text ('{0}  [{1}]' -f $provider.Title, $provider.Tier)

        try {
            $results = @(& $provider.Invoke $session $context)
        } catch {
            Write-SpooferLog -Level Error -Message "$($provider.Name) failed: $($_.Exception.Message)"
            $failed += $provider.Name

            # A provider that threw may still have written some values, so the
            # partial session is saved rather than discarded.
            if ($session) { Save-SpooferBackupSession -Session $session | Out-Null }
            continue
        }

        foreach ($result in $results) {
            if ($result.Changed)      { $changed++ }
            elseif ($result.Skipped)  { $skipped++ }
        }

        if ($session) { Save-SpooferBackupSession -Session $session | Out-Null }
    }

    Write-SpooferBanner -Text 'Summary'

    if ($DryRun) {
        Write-SpooferLog -Level Info -Message 'Dry run: nothing was written.'
        return
    }

    Write-SpooferLog -Level Success -Message "$changed identifiers changed."
    if ($skipped) { Write-SpooferLog -Level Info -Message "$skipped were skipped (not present on this system, or blocked)." }
    if ($failed.Count) { Write-SpooferLog -Level Error -Message ('These modules failed: {0}' -f ($failed -join ', ')) }

    if ($session -and $session.Entries.Count) {
        $manifest = Save-SpooferBackupSession -Session $session
        Write-Host ''
        Write-SpooferLog -Level Info -Message "Backup written to $manifest"
        Write-Host ''
        Write-Host ('  Undo everything with:  .\Spoofer.ps1 -Action Restore -BackupId {0}' -f $session.Id) -ForegroundColor Cyan
    } else {
        Write-SpooferLog -Level Warn -Message 'Nothing was changed, so no backup was written.'
    }

    Show-RebootNotice -Provider $providers
}

function Invoke-RestoreAction {
    Test-Environment -RequireAdmin

    $session = Resolve-SpooferBackupSession -Id $BackupId

    Write-Host ''
    Write-Host ('  Backup   : {0}' -f $session.Id) -ForegroundColor White
    Write-Host ('  Taken    : {0} on {1}' -f $session.CreatedUtc, $session.Hostname) -ForegroundColor DarkGray
    Write-Host ('  Modules  : {0}' -f (@($session.Modules) -join ', ')) -ForegroundColor DarkGray
    Write-Host ('  Entries  : {0}' -f $session.Entries.Count) -ForegroundColor DarkGray
    if ($session.Note)     { Write-Host ('  Note     : {0}' -f $session.Note) -ForegroundColor DarkGray }
    if ($session.Restored) { Write-SpooferLog -Level Warn -Message "This backup was already restored on $($session.RestoredUtc)." }

    if ($session.Hostname -ne [System.Environment]::MachineName) {
        Write-SpooferLog -Level Warn -Message "This backup was taken on '$($session.Hostname)' but this machine is '$([System.Environment]::MachineName)'. That is expected if the hostname itself was spoofed."
    }

    if (-not $DryRun) {
        if (-not (Confirm-Action -Message ('Restore {0} original values?' -f $session.Entries.Count))) { return }
    }

    $splat = @{ Session = $session }
    if ($Force)  { $splat['Force']  = $true }
    if ($Module) { $splat['Module'] = $Module }
    if ($DryRun) { $splat['WhatIf'] = $true }

    $summary = Restore-SpooferBackupSession @splat

    Write-SpooferBanner -Text 'Summary'
    Write-SpooferLog -Level Success -Message "$($summary.Restored) of $($summary.Total) entries restored."
    if ($summary.Skipped) { Write-SpooferLog -Level Info  -Message "$($summary.Skipped) skipped." }

    if ($summary.Failed) {
        Write-SpooferLog -Level Error -Message "$($summary.Failed) failed:"
        foreach ($failure in @($summary.Results | Where-Object { $_.Status -eq 'Failed' })) {
            Write-Host ('    {0}: {1}' -f $failure.Label, $failure.Message) -ForegroundColor Red
        }
        Write-SpooferLog -Level Info -Message "The backup is still marked un-restored, so you can fix the cause and run the same command again."
    }

    if (-not $DryRun -and $summary.Restored -gt 0) {
        $moduleNames = @(@($session.Modules) | Where-Object { $_ })

        if ($moduleNames.Count) {
            try {
                Show-RebootNotice -Provider @(Get-SpooferProvider -Name $moduleNames)
            } catch {
                # A backup can name a module this build no longer ships; that is
                # not a reason to fail a restore that already succeeded.
                Write-SpooferLog -Level Debug -Message "Could not resolve the backup's modules for the restart notice: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-ListAction {
    $sessions = @(Get-SpooferBackupSession -IncludeRestored)

    if ($sessions.Count -eq 0) {
        Write-Host ''
        Write-SpooferLog -Level Info -Message "No backups yet. They are stored under $(Get-SpooferBackupRoot)."
        return
    }

    Write-Host ''
    $sessions |
        Select-Object `
            @{ Name = 'Id';       Expression = { $_.Id } },
            @{ Name = 'Taken';    Expression = { ([datetime]$_.CreatedUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } },
            @{ Name = 'Host';     Expression = { $_.Hostname } },
            @{ Name = 'Entries';  Expression = { $_.Entries.Count } },
            @{ Name = 'Restored'; Expression = { if ($_.Restored) { 'yes' } else { 'no' } } },
            @{ Name = 'Modules';  Expression = { (@($_.Modules) -join ',') } } |
        Format-Table -AutoSize |
        Out-Host

    Write-Host ('  Backups are stored under {0}' -f (Get-SpooferBackupRoot)) -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-RemoveAction {
    $session = Resolve-SpooferBackupSession -Id $BackupId

    $message = "Delete backup $($session.Id)?"
    if (-not $session.Restored) {
        $message = "Backup $($session.Id) has NOT been restored. Deleting it throws away the only record of the original values. Delete anyway?"
    }

    if (-not (Confirm-Action -Message $message -Prompt 'Delete')) { return }

    Remove-SpooferBackupSession -Id $session.Id -Confirm:$false | Out-Null
}

function Invoke-ModulesAction {
    Write-Host ''
    foreach ($provider in (Get-SpooferProvider)) {
        Write-Host ('  {0}' -f $provider.Name) -ForegroundColor White -NoNewline
        Write-Host ('  [{0}]{1}' -f $provider.Tier, $(if ($provider.RequiresReboot) { ' [restart required]' } else { '' })) -ForegroundColor DarkGray

        Write-Host ('      {0}' -f $provider.Description) -ForegroundColor Gray
        foreach ($target in @($provider.Targets)) {
            Write-Host ('        - {0}' -f $target) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    Write-Host '  Default selection is the Standard and Advanced tiers.' -ForegroundColor DarkGray
    Write-Host '  Add -IncludeRisky, or name a module directly, to reach the Risky tier.' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

try {
    Initialize-SpooferRoot | Out-Null
    $logDirectory = Join-Path (Get-SpooferRoot) 'logs'
    Set-SpooferLogFile -Path (Join-Path $logDirectory ('spoofer-{0:yyyyMMdd}.log' -f (Get-Date)))
    Set-SpooferLogLevel -Level $LogLevel
} catch {
    Write-Warning "Could not initialise the Spoofer data directory: $($_.Exception.Message)"
}

Show-Header

if ($Action -in @('Status', 'Spoof')) { Show-Environment }

Write-SpooferLog -Level Debug -NoConsole -Message ("Invoked: -Action {0} -Module '{1}' -DryRun:{2} -Force:{3}" -f $Action, ($Module -join ','), $DryRun, $Force)

try {
    switch ($Action) {
        'Status'  { Invoke-StatusAction }
        'Spoof'   { Invoke-SpoofAction }
        'Restore' { Invoke-RestoreAction }
        'List'    { Invoke-ListAction }
        'Remove'  { Invoke-RemoveAction }
        'Modules' { Invoke-ModulesAction }
    }
} catch {
    Write-Host ''
    Write-SpooferLog -Level Error -Message $_.Exception.Message
    Write-SpooferLog -Level Debug -NoConsole -Message ($_.ScriptStackTrace)
    exit 1
}
