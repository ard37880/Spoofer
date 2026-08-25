<#
.SYNOPSIS
    A minimal test harness.
.DESCRIPTION
    Deliberately dependency-free: the suite has to run on a freshly installed
    Windows 10/11 box with stock Windows PowerShell 5.1 and no internet access,
    which rules out installing Pester first.
#>

Set-StrictMode -Version Latest

$script:Results = New-Object System.Collections.ArrayList
$script:Group   = '<none>'

function Reset-TestRun {
    $script:Results = New-Object System.Collections.ArrayList
    $script:Group   = '<none>'
}

function Describe-Group {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $script:Group = $Name
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    & $Body
}

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    try {
        & $Body
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:Group; Name = $Name; Passed = $true; Message = '' })
        Write-Host '    PASS ' -ForegroundColor Green -NoNewline
        Write-Host $Name -ForegroundColor Gray
    } catch {
        [void]$script:Results.Add([pscustomobject]@{ Group = $script:Group; Name = $Name; Passed = $false; Message = $_.Exception.Message })
        Write-Host '    FAIL ' -ForegroundColor Red -NoNewline
        Write-Host $Name -ForegroundColor Gray
        Write-Host ('         {0}' -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Condition,
        [string]$Because = 'expected the condition to be true'
    )
    if (-not $Condition) { throw $Because }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Expected,
        [Parameter(Mandatory)][AllowNull()][object]$Actual,
        [string]$Because = ''
    )

    $same = if ($null -eq $Expected -and $null -eq $Actual) { $true } else { $Expected -eq $Actual }
    if (-not $same) {
        $detail = "expected '$Expected' but got '$Actual'"
        if ($Because) { $detail = "$Because ($detail)" }
        throw $detail
    }
}

function Assert-NotEqual {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$NotExpected,
        [Parameter(Mandatory)][AllowNull()][object]$Actual,
        [string]$Because = ''
    )
    if ($NotExpected -eq $Actual) {
        $detail = "expected a value other than '$NotExpected'"
        if ($Because) { $detail = "$Because ($detail)" }
        throw $detail
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][AllowNull()][string]$Actual,
        [string]$Because = ''
    )
    if ($Actual -notmatch $Pattern) {
        $detail = "'$Actual' does not match /$Pattern/"
        if ($Because) { $detail = "$Because ($detail)" }
        throw $detail
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Pattern = '',
        [string]$Because = 'expected the scriptblock to throw'
    )

    try {
        & $Body
    } catch {
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "threw, but the message '$($_.Exception.Message)' does not match /$Pattern/"
        }
        return
    }
    throw $Because
}

function Get-TestResult {
    return @($script:Results)
}

function Write-TestSummary {
    $all    = @($script:Results)
    $failed = @($all | Where-Object { -not $_.Passed })

    Write-Host ''
    Write-Host ('  {0} tests, {1} passed, {2} failed' -f $all.Count, ($all.Count - $failed.Count), $failed.Count) `
        -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })

    foreach ($failure in $failed) {
        Write-Host ('    {0} / {1}: {2}' -f $failure.Group, $failure.Name, $failure.Message) -ForegroundColor Red
    }
    Write-Host ''

    return $failed.Count
}

Export-ModuleMember -Function @(
    'Reset-TestRun', 'Describe-Group', 'Test-Case',
    'Assert-True', 'Assert-Equal', 'Assert-NotEqual', 'Assert-Match', 'Assert-Throws',
    'Get-TestResult', 'Write-TestSummary'
)
