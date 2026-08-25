<#
.SYNOPSIS
    The cached SMBIOS/DMI strings under Control\SystemInformation.
.NOTES
    These registry values are what most user-mode fingerprinting reads for
    "what machine is this". They are a cache: Win32_BIOS and
    Win32_ComputerSystemProduct go to the firmware tables directly and are not
    affected, and neither is anything that reads SMBIOS itself. See docs/limitations.md.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

$script:SystemInformation = 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation'

# Coherent vendor profiles. Mixing a Dell board into an ASUS BIOS would be a
# louder signal than the original values, so manufacturer, model and BIOS vendor
# always travel together.
$script:Profiles = @(
    @{ Manufacturer = 'Dell Inc.';                        Product = 'OptiPlex 7090';            Family = 'OptiPlex';       BiosVendor = 'Dell Inc.';                  BiosVersion = '1.{0}.{1}' }
    @{ Manufacturer = 'Dell Inc.';                        Product = 'Latitude 5420';            Family = 'Latitude';       BiosVendor = 'Dell Inc.';                  BiosVersion = '1.{0}.{1}' }
    @{ Manufacturer = 'HP';                               Product = 'HP EliteDesk 800 G6';      Family = 'HP EliteDesk';   BiosVendor = 'AMI';                        BiosVersion = 'S0{0}Ver02.{1}' }
    @{ Manufacturer = 'LENOVO';                           Product = '20XW004RUS';               Family = 'ThinkPad T14';   BiosVendor = 'LENOVO';                     BiosVersion = 'N32ET{0}W ({1})' }
    @{ Manufacturer = 'ASUSTeK COMPUTER INC.';            Product = 'ROG STRIX B550-F GAMING';  Family = 'To be filled by O.E.M.'; BiosVendor = 'American Megatrends Inc.'; BiosVersion = '2{0}{1}' }
    @{ Manufacturer = 'Micro-Star International Co., Ltd.'; Product = 'MS-7C56';               Family = 'To be filled by O.E.M.'; BiosVendor = 'American Megatrends Inc.'; BiosVersion = '1.{0}{1}' }
    @{ Manufacturer = 'Gigabyte Technology Co., Ltd.';    Product = 'B550 AORUS ELITE';         Family = 'To be filled by O.E.M.'; BiosVendor = 'American Megatrends Inc.'; BiosVersion = 'F{0}{1}' }
    @{ Manufacturer = 'Acer';                             Product = 'Aspire TC-1660';           Family = 'Aspire';         BiosVendor = 'Insyde Corp.';               BiosVersion = 'R01-A{0}.{1}' }
)

function Get-SmbiosTarget {
    $vendorProfile = Get-SpooferRandomItem -InputArray $script:Profiles
    $biosVersion = $vendorProfile.BiosVersion -f (Get-SpooferRandomInt -Minimum 10 -Maximum 99), (Get-SpooferRandomInt -Minimum 10 -Maximum 99)

    $releaseDate = (Get-Date).AddDays(-(Get-SpooferRandomInt -Minimum 90 -Maximum 1500)).ToString('MM/dd/yyyy')
    $sku         = New-SpooferAlphanumeric -Length 4
    $version     = New-SpooferAlphanumeric -Length 6

    $manufacturer = $vendorProfile.Manufacturer
    $product      = $vendorProfile.Product
    $family       = $vendorProfile.Family

    @(
        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'SystemManufacturer' `
            -Kind 'String' -Label 'System manufacturer' -TakeOwnership `
            -Generator ({ $manufacturer }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'SystemProductName' `
            -Kind 'String' -Label 'System product name' -TakeOwnership `
            -Generator ({ $product }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'SystemFamily' `
            -Kind 'String' -Label 'System family' -TakeOwnership `
            -Generator ({ $family }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'SystemSKU' `
            -Kind 'String' -Label 'System SKU' -TakeOwnership `
            -Generator ({ $sku }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'SystemVersion' `
            -Kind 'String' -Label 'System version' -TakeOwnership `
            -Generator ({ $version }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'BIOSVendor' `
            -Kind 'String' -Label 'BIOS vendor' -TakeOwnership `
            -Generator ({ $vendorProfile.BiosVendor }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'BIOSVersion' `
            -Kind 'String' -Label 'BIOS version' -TakeOwnership `
            -Generator ({ $biosVersion }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'BIOSReleaseDate' `
            -Kind 'String' -Label 'BIOS release date' -TakeOwnership `
            -Generator ({ $releaseDate }.GetNewClosure())

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'ComputerHardwareId' `
            -Kind 'String' -Label 'Computer hardware id' -TakeOwnership `
            -Generator { New-SpooferGuid -Format B }

        New-SpooferRegistryTarget -Path $script:SystemInformation -Name 'ComputerHardwareIds' `
            -Kind 'MultiString' -Label 'Computer hardware ids' -TakeOwnership `
            -Note 'Windows derives these from the SMBIOS fields above' `
            -Generator { [string[]]@(1..4 | ForEach-Object { New-SpooferGuid -Format B }) }
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'smbios'
        Title          = 'SMBIOS/DMI system description'
        Tier           = 'Advanced'
        RequiresReboot = $false
        Description    = 'Rewrites the cached SMBIOS strings (manufacturer, model, family, SKU, BIOS vendor/version/date and the derived hardware ids) with a coherent set from one vendor profile. This is the registry cache only; WMI classes that read the firmware tables directly are unchanged.'
        Targets        = @('HKLM\SYSTEM\CurrentControlSet\Control\SystemInformation\*')

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-SmbiosTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-SmbiosTarget) -Context $Context -Session $Session -Module 'smbios'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
