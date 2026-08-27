<#
.SYNOPSIS
    Reading and rewriting GUID Partition Table structures.
.DESCRIPTION
    Each partition on a GPT disk carries a unique GUID, separate from the disk
    GUID that Set-Disk exposes. Nothing in Windows offers to change it, so it
    has to be done by editing the table directly.

    That means getting two checksums right. The partition entry array has a
    CRC32 stored in the header, and the header has a CRC32 of itself computed
    with that field zeroed. Both are checked at boot and by every tool that
    reads the disk; a stale one makes the table look corrupt.

    Everything here is pure computation over byte arrays. Reading and writing
    the disk belongs to the provider, which keeps this half testable without a
    disk to point it at.
#>

Set-StrictMode -Version Latest

$script:HeaderSignature = 'EFI PART'

# Field offsets within the 92-byte GPT header.
$script:HeaderCrcOffset        = 16
$script:HeaderSizeOffset       = 12
$script:CurrentLbaOffset       = 24
$script:BackupLbaOffset        = 32
$script:DiskGuidOffset         = 56
$script:ArrayLbaOffset         = 72
$script:EntryCountOffset       = 80
$script:EntrySizeOffset        = 84
$script:ArrayCrcOffset         = 88

# Within each partition entry.
$script:EntryTypeGuidOffset   = 0
$script:EntryUniqueGuidOffset = 16
$script:EntryFirstLbaOffset   = 32
$script:EntryNameOffset       = 56
$script:EntryNameLength       = 72

# Built on first use and kept for the life of the session.
$script:Crc32Table = $null

function Get-SpooferCrc32 {
    <#
    .SYNOPSIS
        CRC32 as GPT uses it: the reflected IEEE 802.3 polynomial.
    .DESCRIPTION
        The arithmetic runs in 64 bits and is masked back to 32 at every step.
        PowerShell parses an eight digit hex literal as a signed Int32, so
        0xFFFFFFFF is -1 and 0xEDB88320 is negative, and either one silently
        poisons the result. The constants are written in decimal for that reason.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [int]$Offset = 0,
        [Nullable[int]]$Length
    )

    $mask       = [uint64]4294967295   # 0xFFFFFFFF
    $polynomial = [uint64]3988292384   # 0xEDB88320

    if ($null -eq $Length) { $Length = $Bytes.Length - $Offset }
    if ($Length -le 0) { return [uint32](($mask -bxor $mask) -band $mask) }

    if ($null -eq $script:Crc32Table) {
        $table = New-Object 'uint32[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            $entry = [uint64]$i
            for ($bit = 0; $bit -lt 8; $bit++) {
                if (($entry -band 1) -ne 0) {
                    $entry = ((($entry -shr 1) -bxor $polynomial) -band $mask)
                } else {
                    $entry = (($entry -shr 1) -band $mask)
                }
            }
            $table[$i] = [uint32]$entry
        }
        $script:Crc32Table = $table
    }

    $crc = $mask
    for ($i = $Offset; $i -lt ($Offset + $Length); $i++) {
        $index = [int](($crc -bxor [uint64]$Bytes[$i]) -band 255)
        $crc = (([uint64]$script:Crc32Table[$index] -bxor ($crc -shr 8)) -band $mask)
    }

    return [uint32](($crc -bxor $mask) -band $mask)
}

function Test-SpooferGptHeader {
    <#
    .SYNOPSIS
        True when the bytes start with the GPT signature.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][byte[]]$Bytes,
        [int]$Offset = 0
    )

    if ($null -eq $Bytes -or $Bytes.Length -lt ($Offset + 92)) { return $false }
    return ([System.Text.Encoding]::ASCII.GetString($Bytes, $Offset, 8) -eq $script:HeaderSignature)
}

function Read-SpooferGptHeader {
    <#
    .SYNOPSIS
        Parses a GPT header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [int]$Offset = 0
    )

    if (-not (Test-SpooferGptHeader -Bytes $Bytes -Offset $Offset)) {
        throw 'The bytes given do not begin with a GPT header signature.'
    }

    return [pscustomobject]@{
        HeaderSize   = [System.BitConverter]::ToUInt32($Bytes, $Offset + $script:HeaderSizeOffset)
        HeaderCrc    = [System.BitConverter]::ToUInt32($Bytes, $Offset + $script:HeaderCrcOffset)
        CurrentLba   = [System.BitConverter]::ToInt64($Bytes,  $Offset + $script:CurrentLbaOffset)
        BackupLba    = [System.BitConverter]::ToInt64($Bytes,  $Offset + $script:BackupLbaOffset)
        # Cast to byte[]: a range slice yields Object[], which binds to the
        # Guid string constructor instead of the byte one.
        DiskGuid     = [System.Guid]::new([byte[]]($Bytes[($Offset + $script:DiskGuidOffset)..($Offset + $script:DiskGuidOffset + 15)]))
        ArrayLba     = [System.BitConverter]::ToInt64($Bytes,  $Offset + $script:ArrayLbaOffset)
        EntryCount   = [System.BitConverter]::ToUInt32($Bytes, $Offset + $script:EntryCountOffset)
        EntrySize    = [System.BitConverter]::ToUInt32($Bytes, $Offset + $script:EntrySizeOffset)
        ArrayCrc     = [System.BitConverter]::ToUInt32($Bytes, $Offset + $script:ArrayCrcOffset)
    }
}

function Read-SpooferGptEntry {
    <#
    .SYNOPSIS
        The partition entries that are in use.
    .DESCRIPTION
        An entry whose type GUID is all zeroes is an unused slot. GPT tables are
        normally 128 entries long with only a handful filled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Array,
        [Parameter(Mandatory)][int]$EntryCount,
        [Parameter(Mandatory)][int]$EntrySize
    )

    $empty = New-Object 'byte[]' 16

    for ($i = 0; $i -lt $EntryCount; $i++) {
        $base = $i * $EntrySize
        if (($base + $EntrySize) -gt $Array.Length) { break }

        $typeGuid = $Array[($base + $script:EntryTypeGuidOffset)..($base + $script:EntryTypeGuidOffset + 15)]
        $inUse = $false
        for ($b = 0; $b -lt 16; $b++) { if ($typeGuid[$b] -ne $empty[$b]) { $inUse = $true; break } }
        if (-not $inUse) { continue }

        $name = [System.Text.Encoding]::Unicode.GetString($Array, $base + $script:EntryNameOffset, $script:EntryNameLength).TrimEnd([char]0)

        [pscustomobject]@{
            Index      = $i
            Offset     = $base
            TypeGuid   = [System.Guid]::new([byte[]]$typeGuid)
            UniqueGuid = [System.Guid]::new([byte[]]($Array[($base + $script:EntryUniqueGuidOffset)..($base + $script:EntryUniqueGuidOffset + 15)]))
            FirstLba   = [System.BitConverter]::ToInt64($Array, $base + $script:EntryFirstLbaOffset)
            Name       = $name
        }
    }
}

function Set-SpooferGptEntryGuid {
    <#
    .SYNOPSIS
        Writes a new unique GUID into one partition entry, in place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Array,
        [Parameter(Mandatory)][int]$EntryOffset,
        [Parameter(Mandatory)][guid]$Guid
    )

    [System.Array]::Copy($Guid.ToByteArray(), 0, $Array, $EntryOffset + $script:EntryUniqueGuidOffset, 16)
}

function Update-SpooferGptChecksum {
    <#
    .SYNOPSIS
        Recomputes both checksums after the entry array has changed.
    .DESCRIPTION
        Order matters. The array CRC goes into the header, so it has to be
        written before the header CRC is computed over it. The header CRC is
        computed with its own field zeroed, which is what the specification
        requires and what every reader assumes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Header,
        [Parameter(Mandatory)][int]$HeaderOffset,
        [Parameter(Mandatory)][byte[]]$Array,
        [Parameter(Mandatory)][int]$ArrayLength
    )

    $arrayCrc = Get-SpooferCrc32 -Bytes $Array -Offset 0 -Length $ArrayLength
    [System.Array]::Copy([System.BitConverter]::GetBytes($arrayCrc), 0, $Header, $HeaderOffset + $script:ArrayCrcOffset, 4)

    $headerSize = [int][System.BitConverter]::ToUInt32($Header, $HeaderOffset + $script:HeaderSizeOffset)
    if ($headerSize -lt 92 -or ($HeaderOffset + $headerSize) -gt $Header.Length) {
        throw "GPT header claims a size of $headerSize bytes, which does not fit the data read."
    }

    for ($i = 0; $i -lt 4; $i++) { $Header[$HeaderOffset + $script:HeaderCrcOffset + $i] = 0 }

    $headerCrc = Get-SpooferCrc32 -Bytes $Header -Offset $HeaderOffset -Length $headerSize
    [System.Array]::Copy([System.BitConverter]::GetBytes($headerCrc), 0, $Header, $HeaderOffset + $script:HeaderCrcOffset, 4)

    return [pscustomobject]@{ ArrayCrc = $arrayCrc; HeaderCrc = $headerCrc }
}

function Test-SpooferGptChecksum {
    <#
    .SYNOPSIS
        True when a header's own CRC matches its contents.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]]$Header,
        [int]$HeaderOffset = 0
    )

    if (-not (Test-SpooferGptHeader -Bytes $Header -Offset $HeaderOffset)) { return $false }

    $headerSize = [int][System.BitConverter]::ToUInt32($Header, $HeaderOffset + $script:HeaderSizeOffset)
    if ($headerSize -lt 92 -or ($HeaderOffset + $headerSize) -gt $Header.Length) { return $false }

    $stored = [System.BitConverter]::ToUInt32($Header, $HeaderOffset + $script:HeaderCrcOffset)

    $copy = New-Object 'byte[]' $Header.Length
    [System.Array]::Copy($Header, $copy, $Header.Length)
    for ($i = 0; $i -lt 4; $i++) { $copy[$HeaderOffset + $script:HeaderCrcOffset + $i] = 0 }

    return ((Get-SpooferCrc32 -Bytes $copy -Offset $HeaderOffset -Length $headerSize) -eq $stored)
}

Export-ModuleMember -Function @(
    'Get-SpooferCrc32'
    'Test-SpooferGptHeader'
    'Read-SpooferGptHeader'
    'Read-SpooferGptEntry'
    'Set-SpooferGptEntryGuid'
    'Update-SpooferGptChecksum'
    'Test-SpooferGptChecksum'
)
