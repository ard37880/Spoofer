<#
.SYNOPSIS
    Registry read/write with automatic backup, plus the restore handlers that
    put registry values and key permissions back the way they were.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Native.psm1')      -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'BackupStore.psm1') -DisableNameChecking

$script:HiveMap = @{
    'HKLM'               = 'LocalMachine'
    'HKEY_LOCAL_MACHINE' = 'LocalMachine'
    'HKCU'               = 'CurrentUser'
    'HKEY_CURRENT_USER'  = 'CurrentUser'
    'HKCR'               = 'ClassesRoot'
    'HKEY_CLASSES_ROOT'  = 'ClassesRoot'
    'HKU'                = 'Users'
    'HKEY_USERS'         = 'Users'
}

#region Path handling

function Split-SpooferRegistryPath {
    <#
    .SYNOPSIS
        Splits 'HKLM:\SOFTWARE\Foo' into a .NET hive object and a sub-key path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalised = $Path -replace '^Registry::', ''
    $parts      = $normalised -split '[:\\]', 2

    $prefix = $parts[0].ToUpperInvariant()
    if (-not $script:HiveMap.ContainsKey($prefix)) {
        throw "Unsupported registry hive in path '$Path'."
    }

    $subKey = ''
    if ($parts.Count -gt 1) { $subKey = $parts[1].TrimStart('\') }

    $hiveName = $script:HiveMap[$prefix]

    $hiveKey = switch ($hiveName) {
        'LocalMachine' { [Microsoft.Win32.Registry]::LocalMachine }
        'CurrentUser'  { [Microsoft.Win32.Registry]::CurrentUser }
        'ClassesRoot'  { [Microsoft.Win32.Registry]::ClassesRoot }
        'Users'        { [Microsoft.Win32.Registry]::Users }
    }

    $longName = switch ($hiveName) {
        'LocalMachine' { 'HKEY_LOCAL_MACHINE' }
        'CurrentUser'  { 'HKEY_CURRENT_USER' }
        'ClassesRoot'  { 'HKEY_CLASSES_ROOT' }
        'Users'        { 'HKEY_USERS' }
    }

    $providerPath = if ($subKey) { 'Registry::{0}\{1}' -f $longName, $subKey } else { "Registry::$longName" }

    return [pscustomobject]@{
        HiveName     = $hiveName
        HiveKey      = $hiveKey
        SubKey       = $subKey
        ProviderPath = $providerPath
    }
}

function Resolve-SpooferRegistryPath {
    <#
    .SYNOPSIS
        Normalises a registry path to the Registry:: provider form.
    .DESCRIPTION
        HKLM: and HKCU: exist as PSDrives by default but HKCR: and HKU: do not,
        so every provider cmdlet call goes through this form instead.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -like 'Registry::*') { return $Path }
    return (Split-SpooferRegistryPath -Path $Path).ProviderPath
}

function Test-SpooferRegistryKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    return (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $Path) -ErrorAction SilentlyContinue)
}

#endregion

#region Reading

function Get-SpooferRegistryValue {
    <#
    .SYNOPSIS
        Reads a single value, reporting its type and whether it exists at all.
    .OUTPUTS
        Path, Name, KeyExists, Exists, Value, ValueKind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $result = [pscustomobject]@{
        Path      = $Path
        Name      = $Name
        KeyExists = $false
        Exists    = $false
        Value     = $null
        ValueKind = 'Unknown'
    }

    if (-not (Test-SpooferRegistryKey -Path $Path)) { return $result }
    $result.KeyExists = $true

    try {
        $key = Get-Item -LiteralPath (Resolve-SpooferRegistryPath -Path $Path) -ErrorAction Stop
        if ($key.GetValueNames() -notcontains $Name) { return $result }

        $result.Exists    = $true
        $result.ValueKind = [string]$key.GetValueKind($Name)
        # DoNotExpandEnvironmentNames keeps %SystemRoot% style values verbatim so
        # a restore writes back exactly what was there.
        $result.Value     = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } catch {
        Write-SpooferLog -Level Debug -Message "Read failed for ${Path}\${Name}: $($_.Exception.Message)"
    }

    return $result
}

function Get-SpooferRegistryValueSet {
    <#
    .SYNOPSIS
        Reads several values from one key, for status displays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    foreach ($n in $Name) { Get-SpooferRegistryValue -Path $Path -Name $n }
}

#endregion

#region Payload encoding

function ConvertTo-SpooferRegistryPayload {
    <#
    .SYNOPSIS
        Turns a registry value into JSON-safe backup data.
    .DESCRIPTION
        Byte arrays become base64 so the manifest survives a round trip through
        ConvertTo-Json/ConvertFrom-Json with the type intact.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ValueKind,

        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @{ ValueKind = $ValueKind; Encoding = 'Null'; Value = $null }
    }

    switch ($ValueKind) {
        'Binary' {
            return @{ ValueKind = $ValueKind; Encoding = 'Base64'; Value = [System.Convert]::ToBase64String([byte[]]$Value) }
        }
        'None' {
            return @{ ValueKind = $ValueKind; Encoding = 'Base64'; Value = [System.Convert]::ToBase64String([byte[]]$Value) }
        }
        'MultiString' {
            return @{ ValueKind = $ValueKind; Encoding = 'StringArray'; Value = @([string[]]$Value) }
        }
        'DWord' {
            return @{ ValueKind = $ValueKind; Encoding = 'Int32'; Value = [int]$Value }
        }
        'QWord' {
            return @{ ValueKind = $ValueKind; Encoding = 'Int64'; Value = [int64]$Value }
        }
        default {
            return @{ ValueKind = $ValueKind; Encoding = 'String'; Value = [string]$Value }
        }
    }
}

function ConvertFrom-SpooferRegistryPayload {
    <#
    .SYNOPSIS
        Rebuilds the original typed value from backup data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Payload
    )

    switch ($Payload.Encoding) {
        'Null'        { return $null }
        'Base64'      { return ,([System.Convert]::FromBase64String([string]$Payload.Value)) }
        'StringArray' { return ,([string[]]@($Payload.Value)) }
        'Int32'       { return [int]$Payload.Value }
        'Int64'       { return [int64]$Payload.Value }
        default       { return [string]$Payload.Value }
    }
}

#endregion

#region Permissions

function Grant-SpooferRegistryAccess {
    <#
    .SYNOPSIS
        Takes ownership of a key and grants Administrators full control.
    .DESCRIPTION
        A few identifier keys (parts of Control\SystemInformation, for example)
        are owned by TrustedInstaller and deny writes even to an elevated shell.
        The original security descriptor is recorded in the backup session first,
        so a restore hands the key back to its previous owner.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [pscustomobject]$Session,

        [string]$Module = ''
    )

    Enable-SpooferPrivilege -Privilege SeTakeOwnershipPrivilege | Out-Null
    Enable-SpooferPrivilege -Privilege SeRestorePrivilege       | Out-Null

    $parts  = Split-SpooferRegistryPath -Path $Path
    $admins = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

    $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
                [System.Security.AccessControl.AccessControlSections]::Group -bor
                [System.Security.AccessControl.AccessControlSections]::Access

    $key = $parts.HiveKey.OpenSubKey(
        $parts.SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::ReadPermissions)

    if ($null -eq $key) { throw "Registry key '$Path' does not exist." }

    try {
        $originalSddl = $key.GetAccessControl($sections).Sddl
    } finally {
        $key.Close()
    }

    if ($Session) {
        Add-SpooferBackupEntry -Session $Session -Type 'RegistryAcl' -Module $Module `
            -Label ("ACL {0}" -f $Path) `
            -Data @{ Path = $Path; Sddl = $originalSddl } | Out-Null
    }

    # Ownership must change before the DACL can be rewritten.
    $key = $parts.HiveKey.OpenSubKey(
        $parts.SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    try {
        $security = New-Object System.Security.AccessControl.RegistrySecurity
        $security.SetOwner($admins)
        $key.SetAccessControl($security)
    } finally {
        $key.Close()
    }

    $key = $parts.HiveKey.OpenSubKey(
        $parts.SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        ([System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
         [System.Security.AccessControl.RegistryRights]::ReadPermissions))
    try {
        $acl  = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        $key.SetAccessControl($acl)
    } finally {
        $key.Close()
    }

    Write-SpooferLog -Level Debug -Message "Took ownership of $Path."
}

#endregion

#region Writing

function Copy-SpooferRegistryKey {
    <#
    .SYNOPSIS
        Copies a registry key and everything under it to a new name.
    .DESCRIPTION
        The registry has no rename. Identifiers that live in a key *name* rather
        than in a value, such as a network profile GUID, are changed by copying
        the subtree to the new name and deleting the original.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $from = Resolve-SpooferRegistryPath -Path $Source
    $to   = Resolve-SpooferRegistryPath -Path $Destination

    if (-not (Test-Path -LiteralPath $from)) { throw "Registry key '$Source' does not exist." }
    if (Test-Path -LiteralPath $to)          { throw "Registry key '$Destination' already exists." }

    New-Item -Path $to -Force -ErrorAction Stop | Out-Null

    $key = Get-Item -LiteralPath $from -ErrorAction Stop
    foreach ($name in $key.GetValueNames()) {
        $kind = [string]$key.GetValueKind($name)
        if ($kind -eq 'Unknown' -or $kind -eq 'None') { $kind = 'Binary' }

        $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        New-ItemProperty -Path $to -Name $name -Value $value -PropertyType $kind -Force -ErrorAction Stop | Out-Null
    }

    foreach ($child in (Get-ChildItem -LiteralPath $from -ErrorAction SilentlyContinue)) {
        Copy-SpooferRegistryKey -Source ('{0}\{1}' -f $Source, $child.PSChildName) `
                                -Destination ('{0}\{1}' -f $Destination, $child.PSChildName)
    }
}

function Remove-SpooferRegistryKey {
    <#
    .SYNOPSIS
        Deletes a key and everything under it, if it is there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $resolved = Resolve-SpooferRegistryPath -Path $Path
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}

function Backup-SpooferRegistryValue {
    <#
    .SYNOPSIS
        Records a value's current state in the session without changing it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Module = '',

        [string]$Label
    )

    $current = Get-SpooferRegistryValue -Path $Path -Name $Name
    $payload = ConvertTo-SpooferRegistryPayload -ValueKind $current.ValueKind -Value $current.Value

    if (-not $PSBoundParameters.ContainsKey('Label')) {
        $Label = '{0}\{1}' -f $Path, $Name
    }

    $data = @{
        Path      = $Path
        Name      = $Name
        KeyExists = $current.KeyExists
        Existed   = $current.Exists
        ValueKind = $payload.ValueKind
        Encoding  = $payload.Encoding
        Value     = $payload.Value
    }

    Add-SpooferBackupEntry -Session $Session -Type 'Registry' -Module $Module -Label $Label -Data $data | Out-Null
    return $current
}

function Set-SpooferRegistryValue {
    <#
    .SYNOPSIS
        Backs up a registry value and then writes a new one.
    .PARAMETER Session
        Backup session. Omitting it writes without a way back, so callers in the
        spoof path always pass one.
    .PARAMETER DryRun
        Reports the change that would be made and writes nothing.
    .PARAMETER TakeOwnership
        On an access-denied write, take ownership of the key and retry once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Kind = 'String',

        [pscustomobject]$Session,

        [string]$Module = '',

        [string]$Label,

        [switch]$CreateIfMissing,

        [switch]$DryRun,

        [switch]$TakeOwnership
    )

    if (-not $PSBoundParameters.ContainsKey('Label')) {
        $Label = '{0}\{1}' -f (Split-Path -Path $Path -Leaf), $Name
    }

    $current = Get-SpooferRegistryValue -Path $Path -Name $Name

    if (-not $current.KeyExists -and -not $CreateIfMissing) {
        Write-SpooferLog -Level Debug -Message "Skipping ${Label}: key '$Path' is not present on this system."
        return [pscustomobject]@{
            Label = $Label; Path = $Path; Name = $Name
            OldValue = $null; NewValue = $Value
            Changed = $false; Simulated = [bool]$DryRun; Skipped = $true
            Reason = 'Key not present'
        }
    }

    if (-not $current.Exists -and -not $CreateIfMissing) {
        Write-SpooferLog -Level Debug -Message "Skipping ${Label}: value is not present on this system."
        return [pscustomobject]@{
            Label = $Label; Path = $Path; Name = $Name
            OldValue = $null; NewValue = $Value
            Changed = $false; Simulated = [bool]$DryRun; Skipped = $true
            Reason = 'Value not present'
        }
    }

    if ($DryRun) {
        Write-SpooferChange -Label $Label -OldValue $current.Value -NewValue $Value -Simulated
        return [pscustomobject]@{
            Label = $Label; Path = $Path; Name = $Name
            OldValue = $current.Value; NewValue = $Value
            Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
        }
    }

    if ($Session) {
        Backup-SpooferRegistryValue -Session $Session -Path $Path -Name $Name -Module $Module -Label $Label | Out-Null
    }

    $providerPath = Resolve-SpooferRegistryPath -Path $Path

    $write = {
        if (-not (Test-SpooferRegistryKey -Path $Path)) {
            New-Item -Path $providerPath -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $providerPath -Name $Name -Value $Value -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
    }

    try {
        & $write
    } catch [System.UnauthorizedAccessException] {
        if (-not $TakeOwnership) { throw }
        Write-SpooferLog -Level Warn -Message "Access denied writing $Label; taking ownership of the key."
        Grant-SpooferRegistryAccess -Path $Path -Session $Session -Module $Module
        & $write
    }

    Write-SpooferChange -Label $Label -OldValue $current.Value -NewValue $Value

    return [pscustomobject]@{
        Label = $Label; Path = $Path; Name = $Name
        OldValue = $current.Value; NewValue = $Value
        Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
    }
}

#endregion

#region Restore handlers

Register-SpooferRestoreHandler -Type 'Registry' -Handler {
    param($Entry)

    $providerPath = Resolve-SpooferRegistryPath -Path $Entry.Path

    if (-not $Entry.Existed) {
        # The value did not exist before the spoof, so removing it is the undo.
        if (Test-Path -LiteralPath $providerPath) {
            Remove-ItemProperty -LiteralPath $providerPath -Name $Entry.Name -Force -ErrorAction SilentlyContinue
        }
        if (-not $Entry.KeyExists -and (Test-Path -LiteralPath $providerPath)) {
            $key = Get-Item -LiteralPath $providerPath
            if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
                Remove-Item -LiteralPath $providerPath -Force -ErrorAction SilentlyContinue
            }
        }
        return "Removed $($Entry.Name) (it did not exist before)."
    }

    $value = ConvertFrom-SpooferRegistryPayload -Payload $Entry

    if (-not (Test-Path -LiteralPath $providerPath)) {
        New-Item -Path $providerPath -Force -ErrorAction Stop | Out-Null
    }

    $kind = $Entry.ValueKind
    if ($kind -eq 'Unknown' -or $kind -eq 'None') { $kind = 'Binary' }

    New-ItemProperty -Path $providerPath -Name $Entry.Name -Value $value `
        -PropertyType $kind -Force -ErrorAction Stop | Out-Null

    return "Restored $($Entry.Name)."
}

Register-SpooferRestoreHandler -Type 'RegistryKeyRename' -Handler {
    param($Entry)

    $originalPath = '{0}\{1}' -f $Entry.Parent, $Entry.OriginalName
    $newPath      = '{0}\{1}' -f $Entry.Parent, $Entry.NewName

    # Copy back before deleting, so the key is never absent from both names.
    if (-not (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $originalPath))) {
        if (-not (Test-Path -LiteralPath (Resolve-SpooferRegistryPath -Path $newPath))) {
            throw "Neither '$originalPath' nor '$newPath' is present; the key cannot be put back."
        }
        Copy-SpooferRegistryKey -Source $newPath -Destination $originalPath
    }

    if ($Entry.NewName -ne $Entry.OriginalName) {
        Remove-SpooferRegistryKey -Path $newPath
    }

    return "Renamed $($Entry.NewName) back to $($Entry.OriginalName)."
}

Register-SpooferRestoreHandler -Type 'RegistryAcl' -Handler {
    param($Entry)

    Enable-SpooferPrivilege -Privilege SeTakeOwnershipPrivilege | Out-Null
    Enable-SpooferPrivilege -Privilege SeRestorePrivilege       | Out-Null

    $parts = Split-SpooferRegistryPath -Path $Entry.Path
    $key   = $parts.HiveKey.OpenSubKey(
        $parts.SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership -bor
        [System.Security.AccessControl.RegistryRights]::ChangePermissions)

    if ($null -eq $key) { throw "Registry key '$($Entry.Path)' no longer exists." }

    try {
        $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
                    [System.Security.AccessControl.AccessControlSections]::Group -bor
                    [System.Security.AccessControl.AccessControlSections]::Access

        $security = New-Object System.Security.AccessControl.RegistrySecurity
        $security.SetSecurityDescriptorSddlForm($Entry.Sddl, $sections)
        $key.SetAccessControl($security)
    } finally {
        $key.Close()
    }

    return "Restored the original security descriptor on $($Entry.Path)."
}

#endregion

Export-ModuleMember -Function @(
    'Split-SpooferRegistryPath'
    'Resolve-SpooferRegistryPath'
    'Test-SpooferRegistryKey'
    'Get-SpooferRegistryValue'
    'Get-SpooferRegistryValueSet'
    'ConvertTo-SpooferRegistryPayload'
    'ConvertFrom-SpooferRegistryPayload'
    'Grant-SpooferRegistryAccess'
    'Copy-SpooferRegistryKey'
    'Remove-SpooferRegistryKey'
    'Backup-SpooferRegistryValue'
    'Set-SpooferRegistryValue'
)
