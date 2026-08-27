#Requires -Version 5.1
<#
.SYNOPSIS
    Rewrites the hardware and installation identifiers of a Windows 10/11
    machine, and puts every one of them back on request.

.DESCRIPTION
    Spoofer changes the identifiers Windows exposes to software: the
    cryptography machine GUID, telemetry and update client ids, the hardware
    profile GUID, the cached SMBIOS description, the digital product id, the
    hostname, adapter MAC addresses, monitor EDID serials, disk and volume
    serials, and more.

    Every module runs by default, including the ones that can disturb licensing
    or the boot configuration. -Interactive gives you a checklist to tick instead,
    and -Exclude drops individual modules from a run.

    Nothing is changed without first being written to a backup session under
    %ProgramData%\Spoofer\backups. -Action Restore replays a session and returns
    the machine to exactly the state it was in.

    Run it on hardware you own or administer. Changing these values will log you
    out of software that licensed itself to this machine and can trip the fraud
    checks of services that expect a stable device identity.

.PARAMETER Action
    Status   Show the current value of every identifier (default).
    Spoof    Back up and then change the selected identifiers.
    Restore  Put the values from a backup session back.
    List     List stored backup sessions.
    Remove   Delete a stored backup session.
    Modules  Describe the available modules.

.PARAMETER Interactive
    Show a checklist of every module and pick which ones to run. Ticked entries
    can be toggled by number or by name before the run starts.

.PARAMETER Module
    Run only these modules, e.g. -Module machineguid,mac.

.PARAMETER Exclude
    Drop these modules from whatever the rest of the selection produced.

.PARAMETER Tier
    Select by tier instead of by name: Standard, Advanced or Risky.

.PARAMETER SafeOnly
    Shorthand for the Standard and Advanced tiers, leaving out the Risky ones.

.PARAMETER Seed
    Generate identifiers deterministically from this seed. The same seed always
    produces the same values, which is what you want when rebuilding a machine
    to a known identity.

.PARAMETER BackupId
    Backup session for -Action Restore or Remove. 'latest' (the default) means
    the newest session that has not been restored yet. A unique id prefix works.

.PARAMETER DryRun
    Show every change that would be made and write nothing.

.PARAMETER NoElevate
    Fail rather than prompting for elevation. Intended for unattended runs that
    are already elevated, and it stops an elevation loop if the prompt is declined.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\Spoofer.ps1 -Action Status

.EXAMPLE
    .\Spoofer.ps1 -Action Spoof -Interactive

.EXAMPLE
    .\Spoofer.ps1 -Action Spoof -DryRun

.EXAMPLE
    .\Spoofer.ps1 -Action Restore -BackupId latest

.NOTES
    Needs an elevated 64-bit PowerShell for Spoof and Restore. It will ask for
    elevation itself unless -NoElevate is given.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'Verify', 'Spoof', 'Restore', 'List', 'Remove', 'Modules')]
    [string]$Action = 'Menu',

    [switch]$Interactive,

    [string[]]$Module,

    [string[]]$Exclude,

    [ValidateSet('Standard', 'Advanced', 'Risky')]
    [string[]]$Tier,

    [switch]$SafeOnly,

    [AllowNull()]
    [Nullable[int]]$Seed,

    [string]$BackupId = 'latest',

    [string]$Note = '',

    [switch]$DryRun,

    [switch]$Force,

    [switch]$Yes,

    [switch]$NoElevate,

    [switch]$IncludeVirtualAdapters,

    [switch]$IncludeRemovableVolumes,

    [switch]$SkipDomainRename,

    [switch]$NoVolumeDismount,

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

foreach ($name in @('Common', 'Native', 'BackupStore', 'RegistryHelper', 'ProviderCommon', 'ProviderRegistry', 'Verify')) {
    Import-Module (Join-Path $modulePath "$name.psm1") -DisableNameChecking
}

#region Elevation

function Test-SpooferActionNeedsAdmin {
    <#
    .SYNOPSIS
        True when an action should run elevated.
    .DESCRIPTION
        Everything except Modules, which prints static descriptions and reads
        nothing. Status is included because disks, volumes and monitor EDID are
        unreadable without administrator rights, and half a status report is
        worse than none.
    #>
    param([string]$Name)
    return ($Name -ne 'Modules')
}

function Invoke-SpooferRelaunchElevated {
    <#
    .SYNOPSIS
        Relaunches this script elevated with the same arguments.
    .DESCRIPTION
        The child is started with -NoExit so its output stays on screen in the
        new window, and with -NoElevate so a declined or ineffective prompt
        produces an error rather than another elevation attempt.
    .OUTPUTS
        $true when a child was started and this process should stop.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$BoundParameters
    )

    $host_ = (Get-Process -Id $PID).Path
    if (-not $host_) { $host_ = 'powershell.exe' }

    $arguments = New-Object System.Collections.ArrayList
    foreach ($item in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))) {
        [void]$arguments.Add($item)
    }

    foreach ($entry in $BoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'NoElevate') { continue }

        $value = $entry.Value

        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { [void]$arguments.Add('-{0}' -f $entry.Key) }
            continue
        }

        [void]$arguments.Add('-{0}' -f $entry.Key)
        if ($value -is [System.Array]) {
            [void]$arguments.Add('"{0}"' -f (@($value) -join ','))
        } else {
            [void]$arguments.Add('"{0}"' -f $value)
        }
    }

    [void]$arguments.Add('-NoElevate')

    Write-SpooferLog -Level Info -Message 'Asking Windows for administrator rights; approve the prompt to continue in the new window.'

    try {
        Start-Process -FilePath $host_ -ArgumentList @($arguments) -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-SpooferLog -Level Error -Message "Elevation was declined or failed: $($_.Exception.Message)"
        return $false
    }
}

#endregion

#region Presentation

function Show-Header {
    Write-Host ''
    Write-Host '  Spoofer' -ForegroundColor White -NoNewline
    Write-Host '  -  Windows 10/11 hardware identifier tool' -ForegroundColor DarkGray
    Write-Host '  Every change is backed up first and can be reverted with -Action Restore.' -ForegroundColor DarkGray
}

function Get-SpooferBuild {
    <#
    .SYNOPSIS
        A string identifying the code that is actually running.
    .DESCRIPTION
        An old copy looks exactly like a current one from the inside, and a ZIP
        download has no git metadata to tell them apart. The VERSION file
        travels with the ZIP, so it answers the question either way; the commit
        is added on top when the checkout has one.
    #>
    $build = '<unknown>'

    # Nothing here is allowed to stop a run. A banner that throws would be a
    # worse bug than the one it exists to diagnose.
    try {
        $here = $PSScriptRoot
        if ([string]::IsNullOrEmpty($here)) { $here = (Get-Location).Path }

        $versionFile = Join-Path $here 'VERSION'
        if (Test-Path -LiteralPath $versionFile) {
            $build = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        }

        if (Test-Path -LiteralPath (Join-Path $here '.git')) {
            $sha = & git -C $here rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $sha) { $build = '{0} ({1})' -f $build, ([string]$sha).Trim() }
        }
    } catch {
        # No git on PATH, or an unreadable directory. Whatever was worked out
        # before the failure is still more useful than nothing.
    }

    return $build
}

function Show-Environment {
    $os = Get-SpooferOsInfo

    Write-Host ''
    Write-Host ('  Build     : {0}' -f (Get-SpooferBuild)) -ForegroundColor DarkGray
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

    if ($RequireAdmin) {
        Assert-SpooferAdmin
        Enable-SpooferPrivilegeSet | Out-Null
    }
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

#endregion

#region Module selection

function Show-ModuleChecklist {
    <#
    .SYNOPSIS
        Draws the checklist and its key.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Provider,
        [Parameter(Mandatory)][hashtable]$Selected
    )

    Write-Host ''
    Write-Host '  Pick what to change' -ForegroundColor White
    Write-Host '  ------------------------------------------------------------------------' -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Provider.Count; $i++) {
        $item = $Provider[$i]
        $tick = if ($Selected[$item.Name]) { 'x' } else { ' ' }

        $colour = switch ($item.Tier) {
            'Risky'    { 'Red' }
            'Advanced' { 'Yellow' }
            default    { 'Gray' }
        }

        Write-Host ('   {0,2}. [{1}] ' -f ($i + 1), $tick) -ForegroundColor $(if ($Selected[$item.Name]) { 'Green' } else { 'DarkGray' }) -NoNewline
        Write-Host ('{0,-18}' -f $item.Name) -ForegroundColor White -NoNewline
        Write-Host ('{0,-10}' -f $item.Tier) -ForegroundColor $colour -NoNewline
        # The tier says how disruptive a module is, not whether it can stop the
        # machine starting. Those are different questions, and the second one is
        # the one worth seeing before pressing ENTER. The title is only padded
        # out to the marker column when there is a marker to line up.
        $title = if ($item.TouchesBoot -or $item.RequiresReboot) { '{0,-42}' -f $item.Title } else { $item.Title }
        Write-Host $title -ForegroundColor DarkGray -NoNewline

        if ($item.TouchesBoot)    { Write-Host ' boot'    -ForegroundColor Red    -NoNewline }
        if ($item.RequiresReboot) { Write-Host ' restart' -ForegroundColor Yellow -NoNewline }
        Write-Host ''
    }

    $count = @($Selected.Keys | Where-Object { $Selected[$_] }).Count

    Write-Host '  ------------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ('   {0} of {1} selected' -f $count, $Provider.Count) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   Change the selection : numbers or names, e.g. "1 4 7" or "mac volumeserial"' -ForegroundColor DarkGray
    Write-Host '                          a all   n none   s standard   d advanced   r risky   i invert' -ForegroundColor DarkGray
    Write-Host '                          b untick everything marked boot' -ForegroundColor DarkGray
    Write-Host '   Cancel               : q' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   boot' -ForegroundColor Red -NoNewline
    Write-Host ' rewrites something the machine needs to start. Backed up and repaired,' -ForegroundColor DarkGray
    Write-Host '        but a restart is the only real proof it worked.' -ForegroundColor DarkGray
    Write-Host ''

    if ($count -gt 0) {
        Write-Host '   >>> ' -ForegroundColor Green -NoNewline
        Write-Host 'Happy with the list? Press ENTER on its own to run it.' -ForegroundColor White
    } else {
        Write-Host '   >>> ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Nothing is ticked. Tick something, or press q to cancel.' -ForegroundColor White
    }
}

function Select-SpooferModuleInteractive {
    <#
    .SYNOPSIS
        Runs the checklist and returns the chosen providers.
    .OUTPUTS
        The selected provider descriptors, or $null when cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Provider,
        [string[]]$PreSelected
    )

    $selected = @{}
    foreach ($item in $Provider) {
        $selected[$item.Name] = ($null -eq $PreSelected) -or ($PreSelected -contains $item.Name)
    }

    while ($true) {
        Show-ModuleChecklist -Provider $Provider -Selected $selected

        $selectedCount = @($Provider | Where-Object { $selected[$_.Name] }).Count
        $prompt = if ($selectedCount -gt 0) {
            '   [ENTER = run {0} module(s)]' -f $selectedCount
        } else {
            '   [nothing ticked]'
        }

        $answer = Read-Host $prompt
        if ($null -eq $answer) { return $null }
        $input_ = $answer.Trim()

        if ($input_ -eq '') {
            $chosen = @($Provider | Where-Object { $selected[$_.Name] })
            if ($chosen.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'Nothing is ticked. Tick at least one module, or press q to cancel.'
                continue
            }
            return $chosen
        }

        # Written as if/elseif rather than a switch: 'continue' inside a switch
        # leaves the switch and falls through to the code after it, which would
        # then try to read the same word as a module name.
        if ($input_ -match '^(q|quit|cancel)$') { return $null }

        if ($input_ -match '^(a|all)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = $true }
            continue
        }
        if ($input_ -match '^(n|none)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = $false }
            continue
        }
        if ($input_ -match '^(i|invert)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = -not $selected[$item.Name] }
            continue
        }
        if ($input_ -match '^(s|standard)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = ($item.Tier -eq 'Standard') }
            continue
        }
        if ($input_ -match '^(d|advanced)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = ($item.Tier -eq 'Advanced') }
            continue
        }
        if ($input_ -match '^(r|risky)$') {
            foreach ($item in $Provider) { $selected[$item.Name] = ($item.Tier -eq 'Risky') }
            continue
        }
        if ($input_ -match '^(b|boot)$') {
            foreach ($item in $Provider) {
                if ($item.TouchesBoot) { $selected[$item.Name] = $false }
            }
            continue
        }

        # Anything else is a list of numbers and/or module names to toggle.
        foreach ($token in ($input_ -split '[\s,]+' | Where-Object { $_ })) {
            $index = 0
            if ([int]::TryParse($token, [ref]$index)) {
                if ($index -ge 1 -and $index -le $Provider.Count) {
                    $name = $Provider[$index - 1].Name
                    $selected[$name] = -not $selected[$name]
                } else {
                    Write-SpooferLog -Level Warn -Message "There is no module number $index."
                }
                continue
            }

            $match = @($Provider | Where-Object { $_.Name -eq $token.ToLowerInvariant() })
            if ($match.Count -eq 1) {
                $selected[$match[0].Name] = -not $selected[$match[0].Name]
            } else {
                Write-SpooferLog -Level Warn -Message "'$token' is not a module number or name."
            }
        }
    }
}

function Get-SelectedProvider {
    <#
    .SYNOPSIS
        Resolves -Interactive / -Module / -Tier / -SafeOnly / -Exclude to a list.
    .DESCRIPTION
        With none of them given the answer is every module, Risky tier included.
    #>
    param(
        [switch]$AllowInteractive
    )

    $all = @(Get-SpooferProvider)

    if ($Module -and $Module.Count) {
        $chosen = @(Get-SpooferProvider -Name $Module)
    } elseif ($Tier -and $Tier.Count) {
        $chosen = @(Get-SpooferProvider -Tier $Tier)
    } elseif ($SafeOnly) {
        $chosen = @(Get-SpooferProvider -Tier @('Standard', 'Advanced'))
    } else {
        $chosen = $all
    }

    if ($Interactive -and $AllowInteractive) {
        $chosen = Select-SpooferModuleInteractive -Provider $all -PreSelected @($chosen | ForEach-Object { $_.Name })
        if ($null -eq $chosen) {
            Write-SpooferLog -Level Info -Message 'Cancelled; nothing was changed.'
            return @()
        }
    }

    if ($Exclude -and $Exclude.Count) {
        $unknown = @($Exclude | Where-Object { $name = $_; -not (@($all | Where-Object { $_.Name -eq $name })) })
        if ($unknown.Count) {
            throw ("Unknown module in -Exclude: {0}. Available modules: {1}" -f `
                    ($unknown -join ', '), (($all | ForEach-Object { $_.Name }) -join ', '))
        }
        $chosen = @($chosen | Where-Object { $Exclude -notcontains $_.Name })
    }

    return @($chosen)
}

function New-RunContext {
    New-SpooferContext -DryRun:$DryRun -Force:$Force -Options @{
        IncludeVirtualAdapters  = [bool]$IncludeVirtualAdapters
        IncludeRemovableVolumes = [bool]$IncludeRemovableVolumes
        SkipDomainRename        = [bool]$SkipDomainRename
        AllowVolumeDismount     = (-not $NoVolumeDismount)
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

#region Menu

function Read-SpooferMenuChoice {
    <#
    .SYNOPSIS
        Prompts until the answer is one of the offered keys.
    .PARAMETER Key
        Accepted answers, matched case-insensitively.
    .OUTPUTS
        The matching key in the case it was declared, or $null if the input
        stream ended (which is how a non-interactive host answers a prompt).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Key,

        [string]$Prompt = '  Choose'
    )

    while ($true) {
        $answer = Read-Host $Prompt

        if ($null -eq $answer) { return $null }

        $answer = $answer.Trim()
        $match = @($Key | Where-Object { $_ -eq $answer })
        if ($match.Count -eq 1) { return $match[0] }

        Write-Host ('  "{0}" is not one of the options.' -f $answer) -ForegroundColor Yellow
    }
}

function Wait-SpooferAcknowledge {
    <#
    .SYNOPSIS
        Holds the screen so output is readable before the menu redraws.
    #>
    Write-Host ''
    Read-Host '  Press Enter to return to the menu' | Out-Null
}

function Show-SpooferMainMenu {
    <#
    .SYNOPSIS
        Draws the main menu.
    #>
    Write-Host ''
    Write-Host '  ====================================================================' -ForegroundColor DarkGray
    Write-Host '   What would you like to do?' -ForegroundColor White
    Write-Host '  ====================================================================' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Show current identifiers' -ForegroundColor White
    Write-Host '        What this machine currently reports. Changes nothing.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   2.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Check what is actually hidden' -ForegroundColor White
    Write-Host '        Compares what Windows reports against what the hardware says.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   3.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Preview a change' -ForegroundColor White
    Write-Host '        Shows exactly what would change. Still writes nothing.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   4.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Change identifiers' -ForegroundColor White
    Write-Host '        Pick which ones from a checklist, then apply. Backed up first.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   5.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Undo a change' -ForegroundColor White
    Write-Host '        Put the original values back from a backup.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   6.' -ForegroundColor Cyan -NoNewline
    Write-Host '  List backups' -ForegroundColor White
    Write-Host ''
    Write-Host '   7.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Explain the modules' -ForegroundColor White
    Write-Host ''
    Write-Host '   8.' -ForegroundColor Cyan -NoNewline
    Write-Host '  Delete a backup' -ForegroundColor White
    Write-Host ''
    Write-Host '   0.' -ForegroundColor DarkGray -NoNewline
    Write-Host '  Exit' -ForegroundColor Gray
    Write-Host ''
}

function Format-SpooferBackupLine {
    <#
    .SYNOPSIS
        One backup rendered for the picker.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session
    )

    $taken = $Session.CreatedUtc
    try   { $taken = ([datetime]$Session.CreatedUtc).ToLocalTime().ToString('dd MMM HH:mm') }
    catch { Write-SpooferLog -Level Debug -Message "Unparsable timestamp on $($Session.Id)." }

    $state = if ($Session.Restored) { 'already restored' } else { 'not yet restored' }
    $note  = if ($Session.Note) { "  {0}" -f $Session.Note } else { '' }

    return ('{0}   {1}   {2} entries   {3}{4}' -f $Session.Id, $taken, $Session.Entries.Count, $state, $note)
}

function Select-SpooferBackupInteractive {
    <#
    .SYNOPSIS
        Numbered picker over the stored backups.
    .OUTPUTS
        The chosen session, or $null when there is nothing to pick or the user
        backs out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $sessions = @(Get-SpooferBackupSession -IncludeRestored)

    if ($sessions.Count -eq 0) {
        Write-Host ''
        Write-SpooferLog -Level Info -Message 'There are no backups yet.'
        return $null
    }

    Write-Host ''
    Write-Host ("  {0}" -f $Title) -ForegroundColor White
    Write-Host '  --------------------------------------------------------------------' -ForegroundColor DarkGray

    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $colour = if ($sessions[$i].Restored) { 'DarkGray' } else { 'White' }
        Write-Host ('  {0,2}. ' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host (Format-SpooferBackupLine -Session $sessions[$i]) -ForegroundColor $colour
    }

    Write-Host '   0. Back' -ForegroundColor DarkGray
    Write-Host ''

    $keys   = @('0') + @(1..$sessions.Count | ForEach-Object { [string]$_ })
    $choice = Read-SpooferMenuChoice -Key $keys

    if ($null -eq $choice -or $choice -eq '0') { return $null }
    return $sessions[[int]$choice - 1]
}

function Invoke-MenuAction {
    <#
    .SYNOPSIS
        The interactive menu, so nothing has to be typed as a command.
    .DESCRIPTION
        Each branch reuses the same functions the command line calls, so the two
        routes cannot drift apart. Script-scoped parameters are set before each
        call because those functions read them directly.
    #>
    [CmdletBinding()]
    param()

    Test-Environment

    while ($true) {
        Show-SpooferMainMenu

        $choice = Read-SpooferMenuChoice -Key @('0', '1', '2', '3', '4', '5', '6', '7', '8')
        if ($null -eq $choice -or $choice -eq '0') {
            Write-Host ''
            Write-SpooferLog -Level Info -Message 'Done.'
            return
        }

        try {
            switch ($choice) {

                '1' {
                    $script:Interactive = $false
                    $script:DryRun      = $false
                    Invoke-StatusAction
                    Wait-SpooferAcknowledge
                }

                '2' {
                    Invoke-VerifyAction
                    Wait-SpooferAcknowledge
                }

                '3' {
                    # A preview still picks its modules, so the checklist runs first.
                    $script:Interactive = $true
                    $script:DryRun      = $true
                    Invoke-SpoofAction
                    $script:DryRun = $false
                    Wait-SpooferAcknowledge
                }

                '4' {
                    $script:Interactive = $true
                    $script:DryRun      = $false
                    Invoke-SpoofAction
                    Wait-SpooferAcknowledge
                }

                '5' {
                    $session = Select-SpooferBackupInteractive -Title 'Which backup would you like to undo?'
                    if ($session) {
                        $script:BackupId = $session.Id
                        $script:Force    = $true    # an explicitly chosen backup may be replayed
                        Invoke-RestoreAction
                        $script:Force = $false
                        Wait-SpooferAcknowledge
                    }
                }

                '6' {
                    Invoke-ListAction
                    Wait-SpooferAcknowledge
                }

                '7' {
                    Invoke-ModulesAction
                    Wait-SpooferAcknowledge
                }

                '8' {
                    $session = Select-SpooferBackupInteractive -Title 'Which backup would you like to delete?'
                    if ($session) {
                        $script:BackupId = $session.Id
                        Invoke-RemoveAction
                        Wait-SpooferAcknowledge
                    }
                }
            }
        } catch {
            Write-Host ''
            Write-SpooferLog -Level Error -Message $_.Exception.Message
            Write-SpooferLog -Level Debug -NoConsole -Message ($_.ScriptStackTrace)
            Wait-SpooferAcknowledge
        }
    }
}

#endregion

#region Actions

function Invoke-StatusAction {
    Test-Environment

    if (-not (Test-SpooferAdmin)) {
        Write-SpooferLog -Level Warn -Message 'Not elevated. Values that need administrator rights to read will show as unavailable.'
    } else {
        Enable-SpooferPrivilegeSet | Out-Null
    }

    $providers = @(Get-SelectedProvider -AllowInteractive)
    if ($providers.Count -eq 0) { return }

    foreach ($provider in $providers) {
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

function Invoke-VerifyAction {
    <#
    .SYNOPSIS
        Prints what Windows reports beside what the hardware says.
    #>
    Test-Environment

    $results = @(Invoke-SpooferCheck)
    $lastGroup = ''

    foreach ($row in $results) {
        if ($row.Group -ne $lastGroup) {
            Write-SpooferBanner -Text $row.Group
            $lastGroup = $row.Group
        }

        Write-Host ('    {0,-34} ' -f $row.Item) -ForegroundColor Gray -NoNewline
        Write-Host ('{0,-40}' -f (ConvertTo-SpooferDisplayValue -Value $row.Reported -MaxLength 38)) -ForegroundColor White -NoNewline

        switch ($row.Coverage) {
            'Full' {
                Write-Host 'covered' -ForegroundColor Green
            }
            'CacheOnly' {
                if ($row.Match -eq $false) {
                    Write-Host 'cache only' -ForegroundColor Yellow
                    Write-Host ('    {0,-34} ' -f '') -NoNewline
                    Write-Host ('{0,-40}' -f (ConvertTo-SpooferDisplayValue -Value $row.Authoritative -MaxLength 38)) -ForegroundColor DarkYellow -NoNewline
                    Write-Host 'what the hardware says' -ForegroundColor DarkYellow
                } else {
                    Write-Host 'cache only, unchanged' -ForegroundColor DarkGray
                }
            }
            'None' {
                Write-Host 'not covered' -ForegroundColor Red
            }
        }
    }

    $full      = @($results | Where-Object { $_.Coverage -eq 'Full' }).Count
    $leaking   = @($results | Where-Object { $_.Coverage -eq 'CacheOnly' -and $_.Match -eq $false }).Count
    $uncovered = @($results | Where-Object { $_.Coverage -eq 'None' }).Count

    Write-SpooferBanner -Text 'Summary'
    Write-Host ('    {0,-12} {1} values this tool fully controls' -f 'covered', $full) -ForegroundColor Green
    Write-Host ('    {0,-12} {1} values where the cache and the hardware now disagree' -f 'cache only', $leaking) -ForegroundColor Yellow
    Write-Host ('    {0,-12} {1} values read straight from hardware, never touched' -f 'not covered', $uncovered) -ForegroundColor Red
    Write-Host ''
    Write-Host '    A caller that goes to the firmware or the driver instead of the' -ForegroundColor DarkGray
    Write-Host '    registry sees the second and third groups as they really are.' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-SpoofAction {
    Test-Environment -RequireAdmin:(-not $DryRun)

    $providers = @(Get-SelectedProvider -AllowInteractive)
    if ($providers.Count -eq 0) { return }

    Initialize-SpooferRandom -Seed $Seed

    Write-Host ''
    Write-Host '  Modules selected:' -ForegroundColor White
    foreach ($provider in $providers) {
        $colour = switch ($provider.Tier) { 'Risky' { 'Red' } 'Advanced' { 'Yellow' } default { 'Gray' } }
        Write-Host ('    {0,-18}' -f $provider.Name) -ForegroundColor White -NoNewline
        Write-Host ('{0,-10}' -f $provider.Tier) -ForegroundColor $colour -NoNewline
        Write-Host $provider.Title -ForegroundColor DarkGray
    }

    $risky = @($providers | Where-Object { $_.Tier -eq 'Risky' })
    if ($risky.Count -and -not $DryRun) {
        Write-Host ''
        Write-SpooferLog -Level Warn -Message ('Risky-tier modules are included: {0}.' -f (($risky | ForEach-Object { $_.Name }) -join ', '))
        Write-SpooferLog -Level Warn -Message 'These can put Windows into an unactivated state and write raw disk sectors.'
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

    $context = New-RunContext
    $changed = 0
    $skipped = 0
    $failed  = @()

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
            if ($result.Changed)     { $changed++ }
            elseif ($result.Skipped) { $skipped++ }
        }

        if ($session) { Save-SpooferBackupSession -Session $session | Out-Null }
    }

    Write-SpooferBanner -Text 'Summary'

    if ($DryRun) {
        Write-SpooferLog -Level Info -Message 'Dry run: nothing was written.'
        return
    }

    Write-SpooferLog -Level Success -Message "$changed identifiers changed."
    if ($skipped) { Write-SpooferLog -Level Info -Message "$skipped were skipped (not present on this system, or the write was refused - see the messages above)." }
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
    if ($summary.Skipped) { Write-SpooferLog -Level Info -Message "$($summary.Skipped) skipped." }

    if ($summary.Failed) {
        Write-SpooferLog -Level Error -Message "$($summary.Failed) failed:"
        foreach ($failure in @($summary.Results | Where-Object { $_.Status -eq 'Failed' })) {
            Write-Host ('    {0}: {1}' -f $failure.Label, $failure.Message) -ForegroundColor Red
        }
        Write-SpooferLog -Level Info -Message 'The backup is still marked un-restored, so you can fix the cause and run the same command again.'
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
        $colour = switch ($provider.Tier) { 'Risky' { 'Red' } 'Advanced' { 'Yellow' } default { 'Gray' } }

        Write-Host ('  {0}' -f $provider.Name) -ForegroundColor White -NoNewline
        Write-Host ('  [{0}]' -f $provider.Tier) -ForegroundColor $colour -NoNewline
        Write-Host $(if ($provider.RequiresReboot) { ' [restart required]' } else { '' }) -ForegroundColor DarkGray

        Write-Host ('      {0}' -f $provider.Description) -ForegroundColor Gray
        foreach ($target in @($provider.Targets)) {
            Write-Host ('        - {0}' -f $target) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    Write-Host '  Every module runs by default. Narrow a run with -Interactive, -Module,' -ForegroundColor DarkGray
    Write-Host '  -Exclude, -Tier, or -SafeOnly (which leaves out the Risky tier).' -ForegroundColor DarkGray
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

if ($Action -in @('Menu', 'Status', 'Verify', 'Spoof')) { Show-Environment }

Write-SpooferLog -Level Debug -NoConsole -Message ("Invoked: -Action {0} -Module '{1}' -DryRun:{2} -Force:{3}" -f $Action, ($Module -join ','), $DryRun, $Force)

# Ask for elevation before doing anything, so the work happens in one place
# rather than half here and half in an elevated child.
if ((Test-SpooferActionNeedsAdmin -Name $Action) -and
    (Test-SpooferOnWindows) -and -not (Test-SpooferAdmin) -and -not $NoElevate) {

    if (Invoke-SpooferRelaunchElevated -BoundParameters $PSBoundParameters) { return }

    Write-Host ''
    Write-SpooferLog -Level Error -Message 'Administrator rights are needed. Approve the prompt, or start PowerShell with Run as administrator.'
    exit 1
}

try {
    switch ($Action) {
        'Menu'    { Invoke-MenuAction }
        'Status'  { Invoke-StatusAction }
        'Verify'  { Invoke-VerifyAction }
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
