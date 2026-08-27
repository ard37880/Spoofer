<#
.SYNOPSIS
    Compares what Windows reports against what the hardware actually says.
.DESCRIPTION
    Most of what this tool rewrites is a cache. Windows read a value from
    firmware once, wrote it into the registry, and hands the registry copy to
    anything that asks nicely. Rewriting that copy changes what ordinary
    software sees and nothing else: the firmware is still sitting there, and a
    caller that goes to it directly gets the original.

    This module runs both reads and puts them side by side, so the gap is
    something you can measure rather than something you have to take on trust.
    Each check declares its coverage:

      Full       the value exists only where this tool writes it, so what is
                 reported is all there is
      CacheOnly  the cache was rewritten but an authoritative read still
                 returns the real value
      None       not touched at all, listed so it is not a surprise
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RegistryHelper.psm1') -DisableNameChecking

$script:ValidCoverage = @('Full', 'CacheOnly', 'None')

function New-SpooferCheck {
    <#
    .SYNOPSIS
        Describes one comparison.
    .PARAMETER Reported
        Reads the value ordinary software sees.
    .PARAMETER Authoritative
        Reads the same thing from the source Windows originally got it from.
        Omitted when there is no lower layer to consult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('Full', 'CacheOnly', 'None')][string]$Coverage,
        [Parameter(Mandatory)][scriptblock]$Reported,
        [scriptblock]$Authoritative,
        [string]$Module = '',
        [string]$Note = ''
    )

    return [pscustomobject]@{
        Group         = $Group
        Item          = $Item
        Coverage      = $Coverage
        Module        = $Module
        Note          = $Note
        Reported      = $Reported
        Authoritative = $Authoritative
    }
}

function Get-SpooferCheck {
    <#
    .SYNOPSIS
        The full set of comparisons.
    #>
    [CmdletBinding()]
    param()

    $systemInformation = 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation'

    @(
        # ---- values that live only where this tool writes them ----

        New-SpooferCheck -Group 'Windows identifiers' -Item 'Cryptography MachineGuid' -Coverage 'Full' -Module 'machineguid' -Reported {
            (Get-SpooferRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid').Value
        }

        New-SpooferCheck -Group 'Windows identifiers' -Item 'SQMClient MachineId' -Coverage 'Full' -Module 'machineid' -Reported {
            (Get-SpooferRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient' -Name 'MachineId').Value
        }

        New-SpooferCheck -Group 'Windows identifiers' -Item 'Windows ProductId' -Coverage 'Full' -Module 'productid' -Reported {
            (Get-SpooferRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductId').Value
        }

        New-SpooferCheck -Group 'Windows identifiers' -Item 'Computer name' -Coverage 'Full' -Module 'computername' -Reported {
            [System.Environment]::MachineName
        }

        # ---- caches with firmware behind them ----

        New-SpooferCheck -Group 'System description' -Item 'Manufacturer' -Coverage 'CacheOnly' -Module 'smbios' `
            -Note 'firmware read via Win32_ComputerSystem' -Reported {
                (Get-SpooferRegistryValue -Path $systemInformation -Name 'SystemManufacturer').Value
            } -Authoritative {
                (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
            }

        New-SpooferCheck -Group 'System description' -Item 'Model' -Coverage 'CacheOnly' -Module 'smbios' -Reported {
            (Get-SpooferRegistryValue -Path $systemInformation -Name 'SystemProductName').Value
        } -Authoritative {
            (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
        }

        New-SpooferCheck -Group 'System description' -Item 'BIOS vendor' -Coverage 'CacheOnly' -Module 'smbios' -Reported {
            (Get-SpooferRegistryValue -Path $systemInformation -Name 'BIOSVendor').Value
        } -Authoritative {
            (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).Manufacturer
        }

        New-SpooferCheck -Group 'System description' -Item 'BIOS version' -Coverage 'CacheOnly' -Module 'smbios' -Reported {
            (Get-SpooferRegistryValue -Path $systemInformation -Name 'BIOSVersion').Value
        } -Authoritative {
            (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion
        }

        # ---- not touched at all ----

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'Motherboard UUID' -Coverage 'None' `
            -Note 'SMBIOS type 1, in flash' -Reported {
                (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
            }

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'BIOS serial number' -Coverage 'None' -Reported {
            (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
        }

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'Baseboard serial number' -Coverage 'None' -Reported {
            (Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).SerialNumber
        }

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'CPU identifier' -Coverage 'None' `
            -Note 'the CPUID instruction; nothing sits between it and the silicon' -Reported {
                (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) | ForEach-Object { $_.ProcessorId }) -join ', '
            }

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'GPU' -Coverage 'None' `
            -Note 'PCI configuration space' -Reported {
                (@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) | ForEach-Object { $_.PNPDeviceID }) -join ', '
            }

        New-SpooferCheck -Group 'Firmware and hardware' -Item 'TPM' -Coverage 'None' `
            -Note 'the endorsement key is burned in at manufacture' -Reported {
                $tpm = Get-Tpm -ErrorAction Stop
                if ($tpm.TpmPresent) { 'present, ' + $(if ($tpm.TpmReady) { 'ready' } else { 'not ready' }) } else { 'not present' }
            }
    )
}

function Get-SpooferAdapterCheck {
    <#
    .SYNOPSIS
        Current versus burned-in MAC, one row per adapter.
    .DESCRIPTION
        Split out from the static table because the rows depend on how many
        adapters the machine has. This is the clearest demonstration of the
        difference the whole module exists to show: the registry override sets
        the current address and cannot touch the permanent one.
    #>
    [CmdletBinding()]
    param()

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Debug -Message "Get-NetAdapter unavailable: $($_.Exception.Message)"
        return @()
    }

    foreach ($adapter in $adapters) {
        $current   = [string]$adapter.MacAddress
        $permanent = [string]$adapter.PermanentAddress
        $currentAddress = $current
        $permanentAddress = $permanent

        [pscustomobject]@{
            Group         = 'Network adapters'
            Item          = $adapter.Name
            Coverage      = 'CacheOnly'
            Module        = 'mac'
            Note          = 'permanent address read through NDIS'
            Reported      = { $currentAddress }.GetNewClosure()
            Authoritative = { $permanentAddress }.GetNewClosure()
        }
    }
}

function Get-SpooferVolumeCheck {
    <#
    .SYNOPSIS
        Volume serials as Windows reports them.
    .DESCRIPTION
        Win32_LogicalDisk reads the serial out of the boot record, which is what
        the volumeserial module rewrites, so this confirms a write landed rather
        than exposing a gap.
    #>
    [CmdletBinding()]
    param()

    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Debug -Message "Win32_LogicalDisk unavailable: $($_.Exception.Message)"
        return @()
    }

    foreach ($disk in $disks) {
        $serial = [string]$disk.VolumeSerialNumber
        $value  = $serial

        [pscustomobject]@{
            Group         = 'Volumes'
            Item          = '{0} serial' -f $disk.DeviceID
            Coverage      = 'Full'
            Module        = 'volumeserial'
            Note          = 'read back from the boot record'
            Reported      = { $value }.GetNewClosure()
            Authoritative = $null
        }
    }
}

function Get-SpooferDiskCheck {
    <#
    .SYNOPSIS
        Disk identifiers, separating the partition table from the drive firmware.
    #>
    [CmdletBinding()]
    param()

    try {
        $disks = @(Get-Disk -ErrorAction Stop)
    } catch {
        Write-SpooferLog -Level Debug -Message "Get-Disk unavailable: $($_.Exception.Message)"
        return @()
    }

    foreach ($disk in $disks) {
        $identifier = if ($disk.PartitionStyle -eq 'GPT') { [string]$disk.Guid } else { '0x{0:X8}' -f $disk.Signature }
        $style      = [string]$disk.PartitionStyle
        $serial     = ([string]$disk.SerialNumber).Trim()
        $number     = [int]$disk.Number

        [pscustomobject]@{
            Group         = 'Disks'
            Item          = 'Disk {0} {1} identifier' -f $number, $style
            Coverage      = 'Full'
            Module        = 'diskid'
            Note          = 'written in the partition table'
            Reported      = { $identifier }.GetNewClosure()
            Authoritative = $null
        }

        [pscustomobject]@{
            Group         = 'Disks'
            Item          = 'Disk {0} firmware serial' -f $number
            Coverage      = 'None'
            Module        = ''
            Note          = 'reported by the drive itself'
            Reported      = { $serial }.GetNewClosure()
            Authoritative = $null
        }
    }
}

function Invoke-SpooferCheck {
    <#
    .SYNOPSIS
        Runs every check and returns the results.
    .OUTPUTS
        Group, Item, Coverage, Module, Note, Reported, Authoritative, Match.
        Match is $true when both reads agree, $false when they disagree, and
        $null when there was nothing to compare against.
    #>
    [CmdletBinding()]
    param()

    $checks = @(Get-SpooferCheck) + @(Get-SpooferAdapterCheck) + @(Get-SpooferDiskCheck) + @(Get-SpooferVolumeCheck)

    foreach ($check in $checks) {
        $reported = '<unreadable>'
        try {
            $value = & $check.Reported
            if ($null -ne $value -and "$value".Trim()) { $reported = "$value".Trim() } else { $reported = '<not set>' }
        } catch {
            Write-SpooferLog -Level Debug -Message "$($check.Item): $($_.Exception.Message)"
        }

        $authoritative = $null
        if ($check.Authoritative) {
            $authoritative = '<unreadable>'
            try {
                $value = & $check.Authoritative
                if ($null -ne $value -and "$value".Trim()) { $authoritative = "$value".Trim() } else { $authoritative = '<not set>' }
            } catch {
                Write-SpooferLog -Level Debug -Message "$($check.Item) (authoritative): $($_.Exception.Message)"
            }
        }

        $match = $null
        if ($null -ne $authoritative -and $reported -ne '<unreadable>' -and $authoritative -ne '<unreadable>') {
            # Separators differ between the two MAC reads, so compare on the
            # characters that carry the value rather than on formatting.
            $match = ($reported -replace '[:\-\s]', '').ToUpperInvariant() -eq
                     ($authoritative -replace '[:\-\s]', '').ToUpperInvariant()
        }

        [pscustomobject]@{
            Group         = $check.Group
            Item          = $check.Item
            Coverage      = $check.Coverage
            Module        = $check.Module
            Note          = $check.Note
            Reported      = $reported
            Authoritative = $authoritative
            Match         = $match
        }
    }
}

Export-ModuleMember -Function @(
    'New-SpooferCheck'
    'Get-SpooferCheck'
    'Get-SpooferAdapterCheck'
    'Get-SpooferDiskCheck'
    'Get-SpooferVolumeCheck'
    'Invoke-SpooferCheck'
)
