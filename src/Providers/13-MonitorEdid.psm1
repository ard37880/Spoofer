<#
.SYNOPSIS
    The cached monitor EDID blobs, which carry a per-display serial number.
.DESCRIPTION
    Windows caches each display's EDID under its device instance key. The blob
    holds a 32-bit serial at bytes 12-15, often a printed serial string in one of
    the descriptor blocks, and a checksum byte that has to be recomputed or the
    blob is rejected as corrupt.
.NOTES
    Windows rebuilds this cache from the display itself when the monitor is
    re-detected - a driver update, a cable swap, a different port.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RegistryHelper.psm1') -DisableNameChecking

$script:DisplayEnumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'

# Block 0 is 128 bytes: a fixed header, then four 18-byte descriptors, then the
# checksum byte.
$script:EdidBlockSize        = 128
$script:EdidSerialOffset     = 12
$script:EdidDescriptorOffset = 54
$script:EdidDescriptorSize   = 18
$script:EdidDescriptorCount  = 4
$script:EdidSerialTag        = 0xFF

function Test-EdidBlob {
    <#
    .SYNOPSIS
        True when the bytes start with the fixed EDID 1.x header.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][byte[]]$Edid
    )

    if ($null -eq $Edid -or $Edid.Length -lt $script:EdidBlockSize) { return $false }

    $header = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($i = 0; $i -lt $header.Count; $i++) {
        if ($Edid[$i] -ne $header[$i]) { return $false }
    }
    return $true
}

function Get-EdidChecksum {
    <#
    .SYNOPSIS
        The checksum byte for one 128-byte EDID block.
    .DESCRIPTION
        Every byte of the block, the checksum included, must sum to zero modulo
        256 - so the checksum is the two's complement of the sum of the rest.
    #>
    [CmdletBinding()]
    [OutputType([byte])]
    param(
        [Parameter(Mandatory)][byte[]]$Edid,
        [int]$BlockOffset = 0
    )

    $sum = 0
    for ($i = 0; $i -lt ($script:EdidBlockSize - 1); $i++) {
        $sum = ($sum + $Edid[$BlockOffset + $i]) -band 0xFF
    }

    return [byte]((256 - $sum) -band 0xFF)
}

function Test-EdidChecksum {
    <#
    .SYNOPSIS
        True when a block's stored checksum is already correct.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]]$Edid,
        [int]$BlockOffset = 0
    )

    $sum = 0
    for ($i = 0; $i -lt $script:EdidBlockSize; $i++) {
        $sum = ($sum + $Edid[$BlockOffset + $i]) -band 0xFF
    }
    return ($sum -eq 0)
}

function Get-EdidSerialNumber {
    <#
    .SYNOPSIS
        The 32-bit serial from bytes 12-15.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][byte[]]$Edid
    )
    return [System.BitConverter]::ToUInt32($Edid, $script:EdidSerialOffset)
}

function Set-EdidDescriptorSerial {
    <#
    .SYNOPSIS
        Replaces the text of any display-serial descriptor block.
    .DESCRIPTION
        A descriptor is a serial string when its first three bytes are zero and
        its tag byte is 0xFF. The text runs to thirteen bytes, terminated by
        0x0A and padded with spaces when shorter - leaving the old printed
        serial in place would undo the point of changing the numeric one.
    .OUTPUTS
        The number of descriptors rewritten.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][byte[]]$Edid,
        [Parameter(Mandatory)][string]$Text
    )

    $written = 0

    for ($index = 0; $index -lt $script:EdidDescriptorCount; $index++) {
        $offset = $script:EdidDescriptorOffset + ($index * $script:EdidDescriptorSize)
        if (($offset + $script:EdidDescriptorSize) -gt $Edid.Length) { break }

        if ($Edid[$offset] -ne 0 -or $Edid[$offset + 1] -ne 0 -or $Edid[$offset + 2] -ne 0) { continue }
        if ($Edid[$offset + 3] -ne $script:EdidSerialTag) { continue }

        $payload = New-Object byte[] 13
        for ($i = 0; $i -lt 13; $i++) { $payload[$i] = [byte]0x20 }

        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
        $take  = [math]::Min($bytes.Length, 12)
        [System.Array]::Copy($bytes, 0, $payload, 0, $take)
        $payload[$take] = [byte]0x0A

        [System.Array]::Copy($payload, 0, $Edid, $offset + 5, 13)
        $written++
    }

    return $written
}

function New-SpoofedEdid {
    <#
    .SYNOPSIS
        Returns a copy of an EDID blob with a new serial and a valid checksum.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [byte[]]$Current
    )

    if (-not (Test-EdidBlob -Edid $Current)) { return $Current }

    $updated = New-Object byte[] $Current.Length
    [System.Array]::Copy($Current, $updated, $Current.Length)

    [System.Array]::Copy((Get-SpooferRandomByte -Count 4), 0, $updated, $script:EdidSerialOffset, 4)
    Set-EdidDescriptorSerial -Edid $updated -Text (New-SpooferAlphanumeric -Length 10) | Out-Null

    # Only block 0 is modified, so only block 0's checksum is recomputed;
    # extension blocks keep the checksums they arrived with.
    $updated[$script:EdidBlockSize - 1] = Get-EdidChecksum -Edid $updated -BlockOffset 0

    return ,$updated
}

function Get-SpooferEdidTarget {
    <#
    .SYNOPSIS
        One target per cached display EDID found under the DISPLAY enum key.
    #>
    [CmdletBinding()]
    param()

    $root = Resolve-SpooferRegistryPath -Path $script:DisplayEnumRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $targets = New-Object System.Collections.ArrayList

    foreach ($monitor in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        foreach ($instance in (Get-ChildItem -LiteralPath $monitor.PSPath -ErrorAction SilentlyContinue)) {

            $path = '{0}\{1}\{2}\Device Parameters' -f $script:DisplayEnumRoot, $monitor.PSChildName, $instance.PSChildName
            $current = Get-SpooferRegistryValue -Path $path -Name 'EDID'
            if (-not $current.Exists) { continue }
            if (-not (Test-EdidBlob -Edid ([byte[]]$current.Value))) { continue }

            $label = 'EDID {0} ({1})' -f $monitor.PSChildName, $instance.PSChildName
            $targetPath = $path

            [void]$targets.Add(
                (New-SpooferRegistryTarget -Path $targetPath -Name 'EDID' -Kind 'Binary' `
                    -Label $label -TakeOwnership `
                    -Generator ({
                        $value = (Get-SpooferRegistryValue -Path $targetPath -Name 'EDID').Value
                        New-SpoofedEdid -Current ([byte[]]$value)
                    }.GetNewClosure()))
            )
        }
    }

    return @($targets)
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'edid'
        Title          = 'Monitor EDID serials'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Rewrites the serial number in each cached display EDID - the numeric serial at bytes 12-15 and any printed serial descriptor - then recomputes the block checksum so the blob stays valid.'
        Targets        = @('HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\*\*\Device Parameters\EDID')

        GetState = {
            param($Context)

            $targets = @(Get-SpooferEdidTarget)
            if ($targets.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Displays'; Value = 'no cached EDID found'; Note = '' })
            }

            foreach ($target in $targets) {
                $value = (Get-SpooferRegistryValue -Path $target.Path -Name 'EDID').Value
                $edid  = [byte[]]$value

                $note = if (Test-EdidChecksum -Edid $edid -BlockOffset 0) { 'checksum valid' } else { 'checksum already invalid' }

                [pscustomobject]@{
                    Item  = $target.Label
                    Value = ('0x{0:X8}' -f (Get-EdidSerialNumber -Edid $edid))
                    Note  = $note
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $targets = @(Get-SpooferEdidTarget)
            if ($targets.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No cached display EDID found; nothing to change.'
                return @()
            }

            Invoke-SpooferRegistryTarget -Target $targets -Context $Context -Session $Session -Module 'edid'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
