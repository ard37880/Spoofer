<#
.SYNOPSIS
    The Windows ProductId string.
.NOTES
    Risky tier. ProductId is shown in System properties and read by some
    licensing checks. It is not the product key and changing it does not
    deactivate Windows, but third-party software that pinned a licence to it
    will see a different machine and may need re-activating. DigitalProductId
    and DigitalProductId4, which Windows activation actually uses, are
    deliberately left untouched.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')         -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProviderCommon.psm1') -DisableNameChecking

function New-WindowsProductId {
    <#
    .SYNOPSIS
        A ProductId in the Windows 10/11 shape, e.g. 00330-80000-00000-AA123.
    #>
    $group1 = '{0:00000}' -f (Get-SpooferRandomInt -Minimum 0 -Maximum 100000)
    $group2 = '{0:00000}' -f (Get-SpooferRandomInt -Minimum 0 -Maximum 100000)
    $group3 = '{0:00000}' -f (Get-SpooferRandomInt -Minimum 0 -Maximum 100000)
    $group4 = '{0}{1:000}' -f (New-SpooferAlphanumeric -Length 2), (Get-SpooferRandomInt -Minimum 0 -Maximum 1000)

    return ('{0}-{1}-{2}-{3}' -f $group1, $group2, $group3, $group4)
}

function Get-ProductIdTarget {
    $productId = New-WindowsProductId

    @(
        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductId' `
            -Kind 'String' -Label 'Windows ProductId' `
            -Generator ({ $productId }.GetNewClosure())

        New-SpooferRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DefaultProductKey' -Name 'ProductId' `
            -Kind 'String' -Label 'Default ProductId' `
            -Note 'kept identical to the value above' `
            -Generator ({ $productId }.GetNewClosure())
    )
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'productid'
        Title          = 'Windows ProductId'
        Tier           = 'Risky'
        RequiresReboot = $false
        Description    = 'Rewrites the Windows ProductId string. Software that licensed itself against this value will treat the machine as new. Windows activation itself uses DigitalProductId, which is left alone.'
        Targets        = @(
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProductId'
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DefaultProductKey\ProductId'
        )

        GetState = {
            param($Context)
            Get-SpooferRegistryTargetState -Target (Get-ProductIdTarget)
        }

        Invoke = {
            param($Session, $Context)
            Invoke-SpooferRegistryTarget -Target (Get-ProductIdTarget) -Context $Context -Session $Session -Module 'productid'
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
