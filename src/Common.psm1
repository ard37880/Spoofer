<#
.SYNOPSIS
    Shared primitives for the Spoofer toolkit: environment probing, logging,
    and deterministic identifier generation.
.NOTES
    Targets Windows PowerShell 5.1 (shipped with Windows 10/11) and PowerShell 7+.
    Loads on non-Windows hosts so the pure helpers stay unit-testable.
#>

Set-StrictMode -Version Latest

$script:Rng        = $null
$script:RngSeeded  = $false
$script:LogFile    = $null
$script:LogMinimum = 'Info'

$script:LevelRank = @{
    Debug   = 0
    Info    = 1
    Success = 1
    Warn    = 2
    Error   = 3
}

#region Environment

function Test-SpooferOnWindows {
    <#
    .SYNOPSIS
        True when the current host is Windows.
    .DESCRIPTION
        $IsWindows only exists on PowerShell 6+. On Windows PowerShell 5.1 the
        variable is absent, which itself means we are on Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $var = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $true }
    return [bool]$var.Value
}

function Test-SpooferAdmin {
    <#
    .SYNOPSIS
        True when the process holds the local Administrators role.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-SpooferOnWindows)) { return $false }

    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-SpooferAdmin {
    <#
    .SYNOPSIS
        Throws unless the process is elevated.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-SpooferOnWindows)) {
        throw 'Spoofer only runs on Windows 10/11.'
    }
    if (-not (Test-SpooferAdmin)) {
        throw 'Administrator rights are required. Re-launch PowerShell with "Run as administrator".'
    }
}

function Test-SpooferProcess64Bit {
    <#
    .SYNOPSIS
        True when the hosting process is 64-bit.
    .DESCRIPTION
        A 32-bit PowerShell on 64-bit Windows is silently redirected into
        WOW6432Node for many HKLM\SOFTWARE reads and writes, which would leave
        the real identifiers untouched. Callers warn on $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [System.Environment]::Is64BitProcess
}

function Get-SpooferRoot {
    <#
    .SYNOPSIS
        Root directory for backups and logs.
    .DESCRIPTION
        Defaults to %ProgramData%\Spoofer. Set SPOOFER_ROOT to relocate it, which
        is how a portable install keeps everything on one removable drive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:SPOOFER_ROOT) { return $env:SPOOFER_ROOT }

    if ((Test-SpooferOnWindows) -and $env:ProgramData) {
        return (Join-Path $env:ProgramData 'Spoofer')
    }

    $home_ = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    return (Join-Path $home_ '.spoofer')
}

function Initialize-SpooferRoot {
    <#
    .SYNOPSIS
        Creates the root/backups/logs directories if missing and returns the root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Root = (Get-SpooferRoot)
    )

    foreach ($dir in @($Root, (Join-Path $Root 'backups'), (Join-Path $Root 'logs'))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    return $Root
}

function Get-SpooferOsInfo {
    <#
    .SYNOPSIS
        Caption/version/build of the running OS, best effort.
    #>
    [CmdletBinding()]
    param()

    $info = [ordered]@{
        Caption = 'Unknown'
        Version = 'Unknown'
        Build   = 'Unknown'
    }

    if (-not (Test-SpooferOnWindows)) {
        $info.Caption = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        return [pscustomobject]$info
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $info.Caption = $os.Caption
        $info.Version = $os.Version
        $info.Build   = $os.BuildNumber
    } catch {
        try {
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $info.Caption = (Get-ItemProperty -Path $key -Name 'ProductName' -ErrorAction Stop).ProductName
            $info.Build   = (Get-ItemProperty -Path $key -Name 'CurrentBuild' -ErrorAction Stop).CurrentBuild
        } catch {
            Write-SpooferLog -Level Debug -Message "Unable to read OS information: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$info
}

function Test-SpooferSupportedOs {
    <#
    .SYNOPSIS
        True when running on Windows 10 or Windows 11 (build 10240+).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-SpooferOnWindows)) { return $false }

    $build = 0
    if ([int]::TryParse([string](Get-SpooferOsInfo).Build, [ref]$build)) {
        return ($build -ge 10240)
    }
    return $false
}

#endregion

#region Logging

function Set-SpooferLogFile {
    <#
    .SYNOPSIS
        Directs subsequent log output to a transcript file as well as the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $script:LogFile = $Path
}

function Get-SpooferLogFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:LogFile
}

function Set-SpooferLogLevel {
    <#
    .SYNOPSIS
        Sets the minimum level rendered to the console. Debug enables verbose tracing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string]$Level
    )
    $script:LogMinimum = $Level
}

function Write-SpooferLog {
    <#
    .SYNOPSIS
        Writes a levelled, timestamped line to the console and the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('Debug', 'Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info',

        [switch]$NoConsole
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = '[{0}] [{1,-7}] {2}' -f $stamp, $Level.ToUpperInvariant(), $Message

    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # A broken log file must never abort a spoof or restore in progress.
        }
    }

    if ($NoConsole) { return }
    if ($script:LevelRank[$Level] -lt $script:LevelRank[$script:LogMinimum]) { return }

    $prefix, $colour = switch ($Level) {
        'Debug'   { '  .', 'DarkGray' }
        'Info'    { '  -', 'Gray' }
        'Success' { '  +', 'Green' }
        'Warn'    { '  !', 'Yellow' }
        'Error'   { '  x', 'Red' }
    }

    Write-Host ('{0} {1}' -f $prefix, $Message) -ForegroundColor $colour
}

function Write-SpooferBanner {
    <#
    .SYNOPSIS
        Prints a section heading.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Write-Host ''
    Write-Host ('== {0} ' -f $Text).PadRight(74, '=') -ForegroundColor Cyan
    if ($script:LogFile) {
        Write-SpooferLog -Message ('=== {0} ===' -f $Text) -Level Info -NoConsole
    }
}

#endregion

#region Randomness

function Initialize-SpooferRandom {
    <#
    .SYNOPSIS
        Selects the random source used by the New-Spoofer* generators.
    .PARAMETER Seed
        When supplied, generation becomes deterministic: the same seed always
        produces the same identifiers, which makes a spoof reproducible across
        machines and makes the generators testable.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Nullable[int]]$Seed
    )

    if ($null -ne $Seed) {
        $script:Rng       = New-Object System.Random -ArgumentList $Seed
        $script:RngSeeded = $true
        Write-SpooferLog -Level Debug -Message "Deterministic generation enabled (seed $Seed)."
    } else {
        $script:Rng       = $null
        $script:RngSeeded = $false
    }
}

function Test-SpooferRandomSeeded {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:RngSeeded
}

function Get-SpooferRandomByte {
    <#
    .SYNOPSIS
        Returns Count random bytes from the active source.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 4096)]
        [int]$Count
    )

    $bytes = New-Object byte[] $Count

    if ($script:RngSeeded) {
        $script:Rng.NextBytes($bytes)
    } else {
        $provider = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $provider.GetBytes($bytes) } finally { $provider.Dispose() }
    }

    return ,$bytes
}

function Get-SpooferRandomInt {
    <#
    .SYNOPSIS
        Uniform integer in [Minimum, Maximum).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($Maximum -le $Minimum) {
        throw "Maximum ($Maximum) must be greater than Minimum ($Minimum)."
    }

    $range = [uint32]($Maximum - $Minimum)
    $bytes = Get-SpooferRandomByte -Count 4
    $value = [System.BitConverter]::ToUInt32($bytes, 0)

    return [int]($Minimum + ($value % $range))
}

function Get-SpooferRandomItem {
    <#
    .SYNOPSIS
        Picks one element from an array using the active random source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$InputArray
    )

    if ($InputArray.Count -eq 0) { throw 'InputArray is empty.' }
    return $InputArray[(Get-SpooferRandomInt -Minimum 0 -Maximum $InputArray.Count)]
}

function New-SpooferGuid {
    <#
    .SYNOPSIS
        A random GUID from the active source.
    .PARAMETER Format
        Any .NET GUID format string: D (default, 8-4-4-4-12), B (braced),
        N (no dashes), P (parenthesised).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('D', 'B', 'N', 'P')]
        [string]$Format = 'D',

        [switch]$Upper
    )

    $guid  = [System.Guid]::new((Get-SpooferRandomByte -Count 16))
    $value = $guid.ToString($Format)

    if ($Upper) { return $value.ToUpperInvariant() }
    return $value
}

function New-SpooferHexString {
    <#
    .SYNOPSIS
        A random hexadecimal string of the requested character length.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 512)]
        [int]$Length,

        [switch]$Upper
    )

    $bytes = Get-SpooferRandomByte -Count ([math]::Ceiling($Length / 2.0))
    $hex   = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    $value = $hex.Substring(0, $Length)

    if ($Upper) { return $value.ToUpperInvariant() }
    return $value
}

function New-SpooferAlphanumeric {
    <#
    .SYNOPSIS
        A random uppercase alphanumeric string, e.g. for a serial number.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 256)]
        [int]$Length
    )

    # Ambiguous glyphs (I/O/0/1) are excluded the way vendor serials usually do.
    $alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
    $chars    = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $Length; $i++) {
        [void]$chars.Append($alphabet[(Get-SpooferRandomInt -Minimum 0 -Maximum $alphabet.Length)])
    }

    return $chars.ToString()
}

function New-SpooferMacAddress {
    <#
    .SYNOPSIS
        A random MAC address that is unicast and locally administered.
    .DESCRIPTION
        Bit 0 of the first octet is cleared (unicast) and bit 1 is set
        (locally administered), so the address can never collide with a real
        vendor OUI. Windows expects the registry override with no separators.
    .PARAMETER Separator
        '' for the registry form (AABBCCDDEEFF), '-' or ':' for display.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('', '-', ':')]
        [string]$Separator = ''
    )

    $bytes = Get-SpooferRandomByte -Count 6
    $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)

    $parts = $bytes | ForEach-Object { $_.ToString('X2') }
    return ($parts -join $Separator)
}

function New-SpooferComputerName {
    <#
    .SYNOPSIS
        A hostname in the Windows OOBE style, e.g. DESKTOP-A7K2M9Q.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('DESKTOP', 'LAPTOP', 'PC', 'WIN')]
        [string]$Prefix = 'DESKTOP'
    )

    return ('{0}-{1}' -f $Prefix, (New-SpooferAlphanumeric -Length 7))
}

function New-SpooferVolumeSerial {
    <#
    .SYNOPSIS
        A random 32-bit NTFS/FAT volume serial number.
    .PARAMETER AsString
        Returns the XXXX-XXXX display form instead of the raw UInt32.
    #>
    [CmdletBinding()]
    param(
        [switch]$AsString
    )

    $bytes = Get-SpooferRandomByte -Count 4
    $value = [System.BitConverter]::ToUInt32($bytes, 0)

    if ($AsString) {
        $hex = $value.ToString('X8')
        return ('{0}-{1}' -f $hex.Substring(0, 4), $hex.Substring(4, 4))
    }
    return $value
}

#endregion

#region Provider context

function New-SpooferContext {
    <#
    .SYNOPSIS
        Builds the context object handed to every provider scriptblock.
    #>
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$Force,
        [hashtable]$Options = @{}
    )

    return [pscustomobject]@{
        DryRun  = [bool]$DryRun
        Force   = [bool]$Force
        Options = $Options
    }
}

function Get-SpooferOption {
    <#
    .SYNOPSIS
        Reads one entry from the context's option bag with a default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $Context.Options) { return $Default }
    if ($Context.Options.ContainsKey($Name)) { return $Context.Options[$Name] }
    return $Default
}

#endregion

#region Formatting

function ConvertTo-SpooferDisplayValue {
    <#
    .SYNOPSIS
        Renders a registry/CIM value for the console, shortening byte arrays.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$MaxLength = 60
    )

    if ($null -eq $Value) { return '<not set>' }

    if ($Value -is [byte[]]) {
        $hex = ($Value | Select-Object -First 16 | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($Value.Length -gt 16) { $hex += '...' }
        return ('0x{0} ({1} bytes)' -f $hex, $Value.Length)
    }

    if ($Value -is [System.Array]) {
        $Value = ($Value -join '; ')
    }

    $text = [string]$Value
    if ($text.Length -gt $MaxLength) {
        return $text.Substring(0, $MaxLength - 3) + '...'
    }
    return $text
}

function Write-SpooferChange {
    <#
    .SYNOPSIS
        Prints an "old -> new" line for a single identifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$OldValue,
        [AllowNull()][object]$NewValue,
        [switch]$Simulated
    )

    $old = ConvertTo-SpooferDisplayValue -Value $OldValue
    $new = ConvertTo-SpooferDisplayValue -Value $NewValue
    $tag = if ($Simulated) { '[dry-run] ' } else { '' }

    Write-Host ('    {0}{1,-34} ' -f $tag, $Label) -ForegroundColor Gray -NoNewline
    Write-Host $old -ForegroundColor DarkYellow -NoNewline
    Write-Host ' -> ' -ForegroundColor DarkGray -NoNewline
    Write-Host $new -ForegroundColor Green

    Write-SpooferLog -Level Info -NoConsole -Message ('{0}{1}: {2} -> {3}' -f $tag, $Label, $old, $new)
}

#endregion

Export-ModuleMember -Function @(
    'Test-SpooferOnWindows'
    'Test-SpooferAdmin'
    'Assert-SpooferAdmin'
    'Test-SpooferProcess64Bit'
    'Get-SpooferRoot'
    'Initialize-SpooferRoot'
    'Get-SpooferOsInfo'
    'Test-SpooferSupportedOs'
    'Set-SpooferLogFile'
    'Get-SpooferLogFile'
    'Set-SpooferLogLevel'
    'Write-SpooferLog'
    'Write-SpooferBanner'
    'Initialize-SpooferRandom'
    'Test-SpooferRandomSeeded'
    'Get-SpooferRandomByte'
    'Get-SpooferRandomInt'
    'Get-SpooferRandomItem'
    'New-SpooferGuid'
    'New-SpooferHexString'
    'New-SpooferAlphanumeric'
    'New-SpooferMacAddress'
    'New-SpooferComputerName'
    'New-SpooferVolumeSerial'
    'New-SpooferContext'
    'Get-SpooferOption'
    'ConvertTo-SpooferDisplayValue'
    'Write-SpooferChange'
)
