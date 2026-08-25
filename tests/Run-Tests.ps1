#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Spoofer test suite.
.DESCRIPTION
    Covers the parts that can be exercised without touching the live machine:
    identifier generation, backup/restore bookkeeping, registry payload
    encoding, path parsing, boot-record parsing and the provider catalogue.

    Backups are redirected to a temporary directory through SPOOFER_ROOT, so the
    suite never reads or writes the real store. Everything here runs on Linux
    and macOS too, which is what makes it usable in CI.
.EXAMPLE
    .\tests\Run-Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root      = Split-Path -Path $PSScriptRoot -Parent
$sourceDir = Join-Path $root 'src'

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -Force -DisableNameChecking

# Redirect the data root before anything reads it.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('spoofer-tests-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
$originalRoot = $env:SPOOFER_ROOT
$env:SPOOFER_ROOT = $sandbox

Get-Module |
    Where-Object { $_.Path -and $_.Path.StartsWith($sourceDir, [System.StringComparison]::OrdinalIgnoreCase) } |
    Remove-Module -Force

foreach ($name in @('Common', 'Native', 'BackupStore', 'RegistryHelper', 'ProviderCommon', 'ProviderRegistry')) {
    Import-Module (Join-Path $sourceDir "$name.psm1") -DisableNameChecking
}

Reset-TestRun

try {

Describe-Group 'Identifier generation' {

    Test-Case 'New-SpooferGuid produces a parsable GUID' {
        Initialize-SpooferRandom -Seed $null
        $value = New-SpooferGuid
        $parsed = [guid]::Empty
        Assert-True ([guid]::TryParse($value, [ref]$parsed)) "'$value' is not a GUID"
    }

    Test-Case 'GUID formats are honoured' {
        Assert-Match '^\{[0-9a-f-]{36}\}$' (New-SpooferGuid -Format B) 'braced form'
        Assert-Match '^[0-9a-f]{32}$'      (New-SpooferGuid -Format N) 'compact form'
        Assert-Match '^\{[0-9A-F-]{36}\}$' (New-SpooferGuid -Format B -Upper) 'upper-case braced form'
    }

    Test-Case 'The same seed reproduces the same identifiers' {
        Initialize-SpooferRandom -Seed 1234
        $first = @(New-SpooferGuid; New-SpooferMacAddress; New-SpooferComputerName)

        Initialize-SpooferRandom -Seed 1234
        $second = @(New-SpooferGuid; New-SpooferMacAddress; New-SpooferComputerName)

        Assert-Equal ($first -join '|') ($second -join '|') 'a repeated seed must replay the same values'
    }

    Test-Case 'Different seeds produce different identifiers' {
        Initialize-SpooferRandom -Seed 1
        $a = New-SpooferGuid
        Initialize-SpooferRandom -Seed 2
        $b = New-SpooferGuid
        Assert-NotEqual $a $b
    }

    Test-Case 'Unseeded generation is not deterministic' {
        Initialize-SpooferRandom -Seed $null
        Assert-NotEqual (New-SpooferGuid) (New-SpooferGuid)
    }

    Test-Case 'MAC addresses are unicast and locally administered' {
        Initialize-SpooferRandom -Seed $null
        for ($i = 0; $i -lt 200; $i++) {
            $mac = New-SpooferMacAddress
            Assert-Match '^[0-9A-F]{12}$' $mac 'registry form has no separators'

            $first = [System.Convert]::ToByte($mac.Substring(0, 2), 16)
            Assert-Equal 0 ($first -band 0x01) 'the multicast bit must be clear'
            Assert-Equal 2 ($first -band 0x02) 'the locally administered bit must be set'
        }
    }

    Test-Case 'MAC separators are applied on request' {
        Assert-Match '^([0-9A-F]{2}-){5}[0-9A-F]{2}$' (New-SpooferMacAddress -Separator '-')
        Assert-Match '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' (New-SpooferMacAddress -Separator ':')
    }

    Test-Case 'Computer names match the Windows OOBE shape' {
        Assert-Match '^DESKTOP-[A-Z0-9]{7}$' (New-SpooferComputerName)
        Assert-Match '^LAPTOP-[A-Z0-9]{7}$'  (New-SpooferComputerName -Prefix 'LAPTOP')
    }

    Test-Case 'Hex strings honour the requested length' {
        foreach ($length in @(1, 2, 7, 16, 33)) {
            Assert-Equal $length (New-SpooferHexString -Length $length).Length
        }
    }

    Test-Case 'Serial alphabets exclude ambiguous glyphs' {
        for ($i = 0; $i -lt 50; $i++) {
            Assert-Match '^[2-9A-HJ-NP-Z]+$' (New-SpooferAlphanumeric -Length 12) 'no 0, 1, I or O'
        }
    }

    Test-Case 'Random integers stay inside the requested range' {
        for ($i = 0; $i -lt 500; $i++) {
            $value = Get-SpooferRandomInt -Minimum 10 -Maximum 20
            Assert-True ($value -ge 10 -and $value -lt 20) "$value is outside [10,20)"
        }
    }

    Test-Case 'Get-SpooferRandomInt rejects an empty range' {
        Assert-Throws { Get-SpooferRandomInt -Minimum 5 -Maximum 5 } -Pattern 'greater than'
    }

    Test-Case 'Volume serials render in the Windows XXXX-XXXX form' {
        Assert-Match '^[0-9A-F]{4}-[0-9A-F]{4}$' (New-SpooferVolumeSerial -AsString)
    }
}

Describe-Group 'Value formatting' {

    Test-Case 'A null value reads as not set' {
        Assert-Equal '<not set>' (ConvertTo-SpooferDisplayValue -Value $null)
    }

    Test-Case 'Byte arrays are summarised, not dumped' {
        $rendered = ConvertTo-SpooferDisplayValue -Value ([byte[]](1..40))
        Assert-Match '^0x[0-9a-f]+\.\.\. \(40 bytes\)$' $rendered
    }

    Test-Case 'Long strings are truncated to the requested width' {
        $rendered = ConvertTo-SpooferDisplayValue -Value ('x' * 200) -MaxLength 20
        Assert-Equal 20 $rendered.Length
        Assert-Match '\.\.\.$' $rendered
    }
}

Describe-Group 'Registry path parsing' {

    Test-Case 'Short and long hive names both resolve' {
        Assert-Equal 'LocalMachine' (Split-SpooferRegistryPath -Path 'HKLM:\SOFTWARE\Microsoft').HiveName
        Assert-Equal 'LocalMachine' (Split-SpooferRegistryPath -Path 'HKEY_LOCAL_MACHINE\SOFTWARE').HiveName
        Assert-Equal 'CurrentUser'  (Split-SpooferRegistryPath -Path 'HKCU:\SOFTWARE').HiveName
        Assert-Equal 'Users'        (Split-SpooferRegistryPath -Path 'HKU:\S-1-5-18').HiveName
    }

    Test-Case 'The sub-key survives parsing intact' {
        Assert-Equal 'SOFTWARE\Microsoft\Cryptography' (Split-SpooferRegistryPath -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography').SubKey
    }

    Test-Case 'Paths normalise to the Registry:: provider form' {
        Assert-Equal 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft' (Resolve-SpooferRegistryPath -Path 'HKLM:\SOFTWARE\Microsoft')
        Assert-Equal 'Registry::HKEY_USERS\S-1-5-18' (Resolve-SpooferRegistryPath -Path 'HKU:\S-1-5-18')
    }

    Test-Case 'An already-resolved path is left alone' {
        $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'
        Assert-Equal $path (Resolve-SpooferRegistryPath -Path $path)
    }

    Test-Case 'An unknown hive is rejected' {
        Assert-Throws { Split-SpooferRegistryPath -Path 'HKXX:\Nope' } -Pattern 'Unsupported registry hive'
    }
}

Describe-Group 'Registry payload encoding' {

    Test-Case 'Strings round-trip' {
        $payload = ConvertTo-SpooferRegistryPayload -ValueKind 'String' -Value 'hello world'
        Assert-Equal 'hello world' (ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject]$payload))
    }

    Test-Case 'Binary values round-trip through base64' {
        $original = [byte[]](0, 1, 2, 250, 255, 128)
        $payload  = ConvertTo-SpooferRegistryPayload -ValueKind 'Binary' -Value $original
        Assert-Equal 'Base64' $payload.Encoding

        $restored = ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject]$payload)
        Assert-Equal $original.Length $restored.Length
        for ($i = 0; $i -lt $original.Length; $i++) { Assert-Equal $original[$i] $restored[$i] }
    }

    Test-Case 'DWord and QWord keep their width' {
        Assert-Equal 42 (ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject](ConvertTo-SpooferRegistryPayload -ValueKind 'DWord' -Value 42)))

        $big = [int64]9000000000
        Assert-Equal $big (ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject](ConvertTo-SpooferRegistryPayload -ValueKind 'QWord' -Value $big)))
    }

    Test-Case 'MultiString round-trips as a string array' {
        $original = [string[]]@('one', 'two', 'three')
        $restored = ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject](ConvertTo-SpooferRegistryPayload -ValueKind 'MultiString' -Value $original))
        Assert-Equal 3 $restored.Count
        Assert-Equal 'two' $restored[1]
    }

    Test-Case 'A missing value encodes as null, not as an empty string' {
        $payload = ConvertTo-SpooferRegistryPayload -ValueKind 'String' -Value $null
        Assert-Equal 'Null' $payload.Encoding
        Assert-Equal $null (ConvertFrom-SpooferRegistryPayload -Payload ([pscustomobject]$payload))
    }
}

Describe-Group 'Backup sessions' {

    Test-Case 'A session round-trips through the manifest' {
        $session = New-SpooferBackupSession -Note 'round trip' -Seed 99 -Modules @('machineguid')
        Add-SpooferBackupEntry -Session $session -Type 'Registry' -Module 'machineguid' -Label 'MachineGuid' -Data @{
            Path = 'HKLM:\SOFTWARE\Microsoft\Cryptography'; Name = 'MachineGuid'
            KeyExists = $true; Existed = $true; ValueKind = 'String'; Encoding = 'String'; Value = 'original-guid'
        } | Out-Null

        Save-SpooferBackupSession -Session $session | Out-Null
        $loaded = Read-SpooferBackupSession -Path $session.Path

        Assert-Equal $session.Id $loaded.Id
        Assert-Equal 'round trip' $loaded.Note
        Assert-Equal 99 $loaded.Seed
        Assert-Equal 1 $loaded.Entries.Count
        Assert-Equal 'original-guid' $loaded.Entries[0].Value
        Assert-Equal 'machineguid' $loaded.Entries[0].Module
    }

    Test-Case 'Binary payloads survive the JSON round trip' {
        $bytes   = [byte[]](5, 200, 0, 255, 17)
        $session = New-SpooferBackupSession -Modules @('telemetry')
        Add-SpooferBackupEntry -Session $session -Type 'Registry' -Module 'telemetry' -Label 'Validation' -Data `
            (ConvertTo-SpooferRegistryPayload -ValueKind 'Binary' -Value $bytes) | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        $loaded   = Read-SpooferBackupSession -Path $session.Path
        $restored = ConvertFrom-SpooferRegistryPayload -Payload $loaded.Entries[0]

        Assert-Equal $bytes.Length $restored.Length
        for ($i = 0; $i -lt $bytes.Length; $i++) { Assert-Equal $bytes[$i] $restored[$i] }
    }

    Test-Case 'An empty session writes nothing to disk' {
        $session = New-SpooferBackupSession
        Assert-Equal $null (Save-SpooferBackupSession -Session $session)
        Assert-True (-not (Test-Path -LiteralPath $session.Path)) 'no directory should be created'
    }

    Test-Case "'latest' resolves to the newest un-restored session" {
        $older = New-SpooferBackupSession -Note 'older'
        Add-SpooferBackupEntry -Session $older -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
        Save-SpooferBackupSession -Session $older | Out-Null

        # The id carries a whole-second timestamp, so the newer session is given
        # an explicitly later creation time rather than relying on clock skew.
        $newer = New-SpooferBackupSession -Note 'newer'
        $newer.CreatedUtc = ([datetime]$older.CreatedUtc).AddMinutes(1).ToString('o')
        Add-SpooferBackupEntry -Session $newer -Type 'Stub' -Label 'y' -Data @{ Value = 2 } | Out-Null
        Save-SpooferBackupSession -Session $newer | Out-Null

        Assert-Equal 'newer' (Resolve-SpooferBackupSession -Id 'latest').Note
    }

    Test-Case 'A session resolves by unique id prefix' {
        $session = New-SpooferBackupSession -Note 'prefix'
        Add-SpooferBackupEntry -Session $session -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        Assert-Equal $session.Id (Resolve-SpooferBackupSession -Id $session.Id.Substring(0, 20)).Id
    }

    Test-Case 'An unknown id is reported, not guessed at' {
        Assert-Throws { Resolve-SpooferBackupSession -Id 'nope-not-here' } -Pattern 'No backup found'
    }
}

Describe-Group 'Restore' {

    Test-Case 'Entries are replayed newest first' {
        $order = New-Object System.Collections.ArrayList
        Register-SpooferRestoreHandler -Type 'OrderProbe' -Handler { param($Entry) [void]$order.Add($Entry.Label); 'ok' }.GetNewClosure()

        $session = New-SpooferBackupSession -Modules @('probe')
        foreach ($label in @('first', 'second', 'third')) {
            Add-SpooferBackupEntry -Session $session -Type 'OrderProbe' -Module 'probe' -Label $label -Data @{ Value = 1 } | Out-Null
        }
        Save-SpooferBackupSession -Session $session | Out-Null

        Restore-SpooferBackupSession -Session $session | Out-Null
        Assert-Equal 'third|second|first' ($order -join '|') 'restore must unwind last-in-first-out'
    }

    Test-Case 'A successful restore marks the session and takes it out of latest' {
        Register-SpooferRestoreHandler -Type 'AlwaysOk' -Handler { param($Entry) 'done' }

        $session = New-SpooferBackupSession -Note 'to restore' -Modules @('probe')
        Add-SpooferBackupEntry -Session $session -Type 'AlwaysOk' -Module 'probe' -Label 'value' -Data @{ Value = 1 } | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        $summary = Restore-SpooferBackupSession -Session $session
        Assert-Equal 1 $summary.Restored
        Assert-Equal 0 $summary.Failed

        $reloaded = Read-SpooferBackupSession -Path $session.Path
        Assert-True $reloaded.Restored 'the manifest should record the restore'
        Assert-NotEqual $session.Id (Resolve-SpooferBackupSession -Id 'latest').Id
    }

    Test-Case 'A restored session is not replayed without -Force' {
        Register-SpooferRestoreHandler -Type 'AlwaysOk2' -Handler { param($Entry) 'done' }

        $session = New-SpooferBackupSession -Modules @('probe')
        Add-SpooferBackupEntry -Session $session -Type 'AlwaysOk2' -Module 'probe' -Label 'value' -Data @{ Value = 1 } | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null
        Restore-SpooferBackupSession -Session $session | Out-Null

        Assert-Throws { Restore-SpooferBackupSession -Session $session } -Pattern 'already restored'
        $again = Restore-SpooferBackupSession -Session $session -Force
        Assert-Equal 1 $again.Restored
    }

    Test-Case 'One failing entry does not stop the others' {
        Register-SpooferRestoreHandler -Type 'SometimesFails' -Handler {
            param($Entry)
            if ($Entry.Label -eq 'bad') { throw 'deliberate failure' }
            'ok'
        }

        $session = New-SpooferBackupSession -Modules @('probe')
        foreach ($label in @('good1', 'bad', 'good2')) {
            Add-SpooferBackupEntry -Session $session -Type 'SometimesFails' -Module 'probe' -Label $label -Data @{ Value = 1 } | Out-Null
        }
        Save-SpooferBackupSession -Session $session | Out-Null

        $summary = Restore-SpooferBackupSession -Session $session
        Assert-Equal 2 $summary.Restored 'the healthy entries still restore'
        Assert-Equal 1 $summary.Failed

        $reloaded = Read-SpooferBackupSession -Path $session.Path
        Assert-True (-not $reloaded.Restored) 'a partial restore must stay replayable'
    }

    Test-Case 'An entry type with no handler fails loudly' {
        $session = New-SpooferBackupSession -Modules @('probe')
        Add-SpooferBackupEntry -Session $session -Type 'NoSuchHandler' -Module 'probe' -Label 'orphan' -Data @{ Value = 1 } | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        $summary = Restore-SpooferBackupSession -Session $session
        Assert-Equal 1 $summary.Failed
        Assert-Match 'No restore handler' $summary.Results[0].Message
    }

    Test-Case 'Restore can be limited to selected modules' {
        Register-SpooferRestoreHandler -Type 'Selective' -Handler { param($Entry) 'ok' }

        $session = New-SpooferBackupSession -Modules @('alpha', 'beta')
        Add-SpooferBackupEntry -Session $session -Type 'Selective' -Module 'alpha' -Label 'a' -Data @{ Value = 1 } | Out-Null
        Add-SpooferBackupEntry -Session $session -Type 'Selective' -Module 'beta'  -Label 'b' -Data @{ Value = 2 } | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        $summary = Restore-SpooferBackupSession -Session $session -Module @('alpha')
        Assert-Equal 1 $summary.Total 'only the selected module is replayed'
        Assert-Equal 'a' $summary.Results[0].Label

        $reloaded = Read-SpooferBackupSession -Path $session.Path
        Assert-True (-not $reloaded.Restored) 'a partial restore must not close the session'
    }

    Test-Case 'The registry restore handler is registered' {
        Assert-True ($null -ne (Get-SpooferRestoreHandler -Type 'Registry'))
        Assert-True ($null -ne (Get-SpooferRestoreHandler -Type 'RegistryAcl'))
    }
}

Describe-Group 'Provider catalogue' {

    Test-Case 'Every provider module loads' {
        $providers = @(Import-SpooferProvider -Force)
        Assert-True ($providers.Count -ge 10) "expected at least 10 providers, found $($providers.Count)"
    }

    Test-Case 'The catalogue contains descriptors and nothing else' {
        # Guards against a helper leaking its return value into the catalogue,
        # which shows up as a plausible-looking but oversized provider list.
        $providers = @(Import-SpooferProvider -Force)
        foreach ($provider in $providers) {
            Assert-True ($provider -is [pscustomobject]) "found a $($provider.GetType().Name) in the catalogue"
            Assert-True ($provider.PSObject.Properties.Name -contains 'Name') 'every entry must be a descriptor'
        }
        Assert-Equal (@(Get-SpooferProviderName)).Count $providers.Count
    }

    Test-Case 'Provider names are unique' {
        $names = @(Get-SpooferProviderName)
        Assert-Equal $names.Count (@($names | Sort-Object -Unique).Count)
    }

    Test-Case 'Every provider declares a complete descriptor' {
        foreach ($provider in (Get-SpooferProvider)) {
            Assert-True (Confirm-SpooferProviderDefinition -Definition $provider -Source $provider.Name)
            Assert-True ($provider.Description.Length -gt 40) "$($provider.Name) needs a real description"
            Assert-True (@($provider.Targets).Count -ge 1) "$($provider.Name) must declare its targets"
            Assert-Match '^[a-z]+$' $provider.Name 'module names are lower-case words'
        }
    }

    Test-Case 'The expected modules are present' {
        $names = @(Get-SpooferProviderName)
        foreach ($expected in @('machineguid', 'machineid', 'hwprofile', 'windowsinstall', 'telemetry', 'smbios', 'productid', 'computername', 'mac', 'diskid', 'volumeserial')) {
            Assert-True ($names -contains $expected) "module '$expected' is missing"
        }
    }

    Test-Case 'Selecting by name returns exactly those modules' {
        $selected = @(Get-SpooferProvider -Name @('machineguid', 'mac'))
        Assert-Equal 2 $selected.Count
        Assert-Equal 'machineguid' $selected[0].Name
        Assert-Equal 'mac' $selected[1].Name
    }

    Test-Case "'all' selects every module" {
        Assert-Equal (@(Get-SpooferProvider).Count) (@(Get-SpooferProvider -Name @('all')).Count)
    }

    Test-Case 'Selecting by tier filters correctly' {
        foreach ($provider in (Get-SpooferProvider -Tier @('Risky'))) {
            Assert-Equal 'Risky' $provider.Tier
        }
        Assert-True (@(Get-SpooferProvider -Tier @('Risky')).Count -ge 1)
    }

    Test-Case 'The default tier selection leaves out Risky modules' {
        $default = @(Get-SpooferProvider -Tier @('Standard', 'Advanced'))
        foreach ($provider in $default) { Assert-NotEqual 'Risky' $provider.Tier }
        Assert-True ($default.Count -lt @(Get-SpooferProvider).Count) 'something must be held back'
    }

    Test-Case 'An unknown module name is rejected with the list of real ones' {
        Assert-Throws { Get-SpooferProvider -Name @('not-a-module') } -Pattern 'Unknown module'
    }

    Test-Case 'A malformed descriptor is rejected' {
        Assert-Throws { Confirm-SpooferProviderDefinition -Definition ([pscustomobject]@{ Name = 'x' }) } -Pattern 'missing the required'
        Assert-Throws {
            Confirm-SpooferProviderDefinition -Definition ([pscustomobject]@{
                Name = 'x'; Title = 'x'; Tier = 'Nonsense'; Description = 'x'; GetState = {}; Invoke = {}
            })
        } -Pattern 'unknown tier'
    }

    Test-Case 'Modules that need a restart say so' {
        Assert-True (Get-SpooferProvider -Name @('computername'))[0].RequiresReboot
        Assert-True (-not (Get-SpooferProvider -Name @('machineguid'))[0].RequiresReboot)
    }
}

Describe-Group 'Provider command resolution' {

    # Provider scriptblocks run in their own module's session state, and a module
    # only gets the functions its own Import-Module calls bring in - imports are
    # not transitive. A missing one fails at spoof time, on Windows, halfway
    # through a run. This resolves it statically instead.
    #
    # Deliberately not done with Get-Command: command lookup inside a module
    # falls back to the global session state, where this suite has already
    # imported everything, so every name would resolve whether the provider
    # imported it or not.
    Test-Case 'Every provider imports the modules exporting the commands it calls' {
        $exporters = @{}
        foreach ($module in (Get-ChildItem -LiteralPath $sourceDir -Filter '*.psm1' -File)) {
            $loaded = Get-Module -Name $module.BaseName
            Assert-True ($null -ne $loaded) "$($module.BaseName) is not loaded"
            foreach ($command in $loaded.ExportedCommands.Keys) { $exporters[$command] = $module.BaseName }
        }

        $providerFiles = @(Get-ChildItem -LiteralPath (Join-Path $sourceDir 'Providers') -Filter '*.psm1' -File)
        Assert-True ($providerFiles.Count -ge 10) 'expected the provider modules to be found'

        foreach ($file in $providerFiles) {
            $tokens = $null; $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert-Equal 0 @($parseErrors).Count "$($file.Name) does not parse"

            $defined = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })

            $called = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -and $_ -like '*Spoofer*' -and $defined -notcontains $_ } |
                Sort-Object -Unique)

            # Every '<name>.psm1' literal in the file is one of its imports.
            $imported = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                ForEach-Object { $_.Value } |
                Where-Object { $_ -like '*.psm1' } |
                ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })

            foreach ($command in $called) {
                Assert-True $exporters.ContainsKey($command) "$($file.Name) calls '$command', which no module under src exports"

                $needed = $exporters[$command]
                Assert-True ($imported -contains $needed) `
                    "$($file.Name) calls '$command' but does not import $needed.psm1"
            }
        }
    }
}

Describe-Group 'Provider context' {

    Test-Case 'Options are read back with their defaults' {
        $context = New-SpooferContext -DryRun -Options @{ AllowVolumeDismount = $true }
        Assert-True $context.DryRun
        Assert-True (-not $context.Force)
        Assert-Equal $true  (Get-SpooferOption -Context $context -Name 'AllowVolumeDismount' -Default $false)
        Assert-Equal $false (Get-SpooferOption -Context $context -Name 'IncludeVirtualAdapters' -Default $false)
    }
}

Describe-Group 'Boot record parsing' {

    $volumeModule = Import-Module (Join-Path $sourceDir 'Providers/11-VolumeSerial.psm1') -Force -PassThru -DisableNameChecking

    function New-FakeSector {
        param(
            [string]$Signature,
            [int]$SignatureOffset,
            [int]$SerialOffset,
            [uint32]$Serial = 0x12345678
        )

        $sector = [byte[]]::new(512)
        $bytes  = [System.Text.Encoding]::ASCII.GetBytes($Signature)
        [System.Array]::Copy($bytes, 0, $sector, $SignatureOffset, $bytes.Length)
        [System.Array]::Copy([System.BitConverter]::GetBytes($Serial), 0, $sector, $SerialOffset, 4)
        return $sector
    }

    Test-Case 'NTFS boot records are recognised at offset 0x48' {
        $sector = New-FakeSector -Signature 'NTFS    ' -SignatureOffset 3 -SerialOffset 0x48
        $layout = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } $sector

        Assert-Equal 'NTFS' $layout.FileSystem
        Assert-Equal 0x48 $layout.Offset
        Assert-Equal 8 $layout.Length
    }

    Test-Case 'FAT32 boot records are recognised at offset 0x43' {
        $sector = New-FakeSector -Signature 'FAT32   ' -SignatureOffset 0x52 -SerialOffset 0x43
        $layout = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } $sector

        Assert-Equal 'FAT32' $layout.FileSystem
        Assert-Equal 0x43 $layout.Offset
        Assert-Equal 4 $layout.Length
    }

    Test-Case 'FAT16 boot records are recognised at offset 0x27' {
        $sector = New-FakeSector -Signature 'FAT16   ' -SignatureOffset 0x36 -SerialOffset 0x27
        $layout = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } $sector

        Assert-Equal 'FAT16' $layout.FileSystem
        Assert-Equal 0x27 $layout.Offset
    }

    Test-Case 'exFAT is refused rather than written to blindly' {
        $sector = New-FakeSector -Signature 'EXFAT   ' -SignatureOffset 3 -SerialOffset 0x64
        Assert-Equal $null (& $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } $sector)
    }

    Test-Case 'An unrecognised boot record yields no layout' {
        Assert-Equal $null (& $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } ([byte[]]::new(512)))
    }

    Test-Case 'Serials render the way Windows shows them' {
        $sector = New-FakeSector -Signature 'NTFS    ' -SignatureOffset 3 -SerialOffset 0x48 -Serial ([uint32]0xDEADBEEFL)
        $text   = & $volumeModule { param($s) Format-VolumeSerial -Sector $s -Offset 0x48 } $sector
        Assert-Equal 'DEAD-BEEF' $text
    }

    Test-Case 'A truncated sector is reported, not misread' {
        $text = & $volumeModule { param($s) Format-VolumeSerial -Sector $s -Offset 0x48 } ([byte[]]::new(16))
        Assert-Equal '<unreadable>' $text
    }
}

Describe-Group 'Environment probes' {

    Test-Case 'Windows detection agrees with the host' {
        $expected = if ($PSVersionTable.PSVersion.Major -ge 6) { [bool]$IsWindows } else { $true }
        Assert-Equal $expected (Test-SpooferOnWindows)
    }

    Test-Case 'SPOOFER_ROOT redirects the data root' {
        Assert-Equal $sandbox (Get-SpooferRoot)
        Assert-Equal (Join-Path $sandbox 'backups') (Get-SpooferBackupRoot)
    }

    Test-Case 'Initialising the root creates the backup and log directories' {
        Initialize-SpooferRoot | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $sandbox 'backups'))
        Assert-True (Test-Path -LiteralPath (Join-Path $sandbox 'logs'))
    }
}

Describe-Group 'End-to-end spoof and restore' {

    # A synthetic provider backed by a text file stands in for the registry, so
    # the whole cycle - generate, back up, write, then restore - is exercised on
    # any platform rather than only on a live Windows box.
    #
    # This group gets its own backup root: it asserts on what 'latest' resolves
    # to, which the stub sessions left behind by earlier groups would otherwise
    # answer.
    $groupRoot = Join-Path $sandbox 'e2e'
    $outerRoot = $env:SPOOFER_ROOT
    $env:SPOOFER_ROOT = $groupRoot
    Initialize-SpooferRoot | Out-Null

    $stateFile = Join-Path $groupRoot 'fake-identifier.txt'

    Register-SpooferRestoreHandler -Type 'FileValue' -Handler {
        param($Entry)
        if ($Entry.Existed) {
            Set-Content -LiteralPath $Entry.Path -Value $Entry.Value -Encoding UTF8
            return 'restored'
        }
        Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue
        return 'removed'
    }

    function Invoke-FakeSpoof {
        param($Session, $Context, $Path)

        $existed = Test-Path -LiteralPath $Path
        $old     = if ($existed) { Get-Content -LiteralPath $Path -Raw } else { $null }
        $new     = New-SpooferGuid

        if ($Context.DryRun) {
            return [pscustomobject]@{ Label = 'fake'; OldValue = $old; NewValue = $new; Changed = $false; Simulated = $true; Skipped = $false }
        }

        Add-SpooferBackupEntry -Session $Session -Type 'FileValue' -Module 'fake' -Label 'fake identifier' -Data @{
            Path = $Path; Existed = $existed; Value = $old
        } | Out-Null

        Set-Content -LiteralPath $Path -Value $new -Encoding UTF8
        return [pscustomobject]@{ Label = 'fake'; OldValue = $old; NewValue = $new; Changed = $true; Simulated = $false; Skipped = $false }
    }

    Test-Case 'A dry run changes nothing and writes no backup' {
        Set-Content -LiteralPath $stateFile -Value 'original' -Encoding UTF8

        $session = New-SpooferBackupSession -Modules @('fake')
        $result  = Invoke-FakeSpoof -Session $session -Context (New-SpooferContext -DryRun) -Path $stateFile

        Assert-True $result.Simulated
        Assert-Equal 'original' (Get-Content -LiteralPath $stateFile -Raw).Trim()
        Assert-Equal 0 $session.Entries.Count
        Assert-Equal $null (Save-SpooferBackupSession -Session $session)
    }

    Test-Case 'A spoof changes the value and a restore puts the original back' {
        Set-Content -LiteralPath $stateFile -Value 'original-value' -Encoding UTF8

        $session = New-SpooferBackupSession -Note 'e2e' -Modules @('fake')
        $result  = Invoke-FakeSpoof -Session $session -Context (New-SpooferContext) -Path $stateFile
        Save-SpooferBackupSession -Session $session | Out-Null

        Assert-True $result.Changed
        Assert-NotEqual 'original-value' (Get-Content -LiteralPath $stateFile -Raw).Trim()

        # Reloaded from disk, so the restore runs against the persisted manifest
        # rather than the in-memory session the spoof happened to leave behind.
        $reloaded = Read-SpooferBackupSession -Path $session.Path
        $summary  = Restore-SpooferBackupSession -Session $reloaded

        Assert-Equal 1 $summary.Restored
        Assert-Equal 0 $summary.Failed
        Assert-Equal 'original-value' (Get-Content -LiteralPath $stateFile -Raw).Trim()
    }

    Test-Case 'Restoring a value that did not exist removes it again' {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue

        $session = New-SpooferBackupSession -Modules @('fake')
        Invoke-FakeSpoof -Session $session -Context (New-SpooferContext) -Path $stateFile | Out-Null
        Save-SpooferBackupSession -Session $session | Out-Null

        Assert-True (Test-Path -LiteralPath $stateFile) 'the spoof should have created it'

        Restore-SpooferBackupSession -Session (Read-SpooferBackupSession -Path $session.Path) | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'the restore should have removed it again'
    }

    Test-Case 'Several spoofs stack and unwind one backup at a time' {
        Set-Content -LiteralPath $stateFile -Value 'v0' -Encoding UTF8

        $first = New-SpooferBackupSession -Note 'first' -Modules @('fake')
        Invoke-FakeSpoof -Session $first -Context (New-SpooferContext) -Path $stateFile | Out-Null
        Save-SpooferBackupSession -Session $first | Out-Null
        $afterFirst = (Get-Content -LiteralPath $stateFile -Raw).Trim()

        $second = New-SpooferBackupSession -Note 'second' -Modules @('fake')
        $second.CreatedUtc = ([datetime]::UtcNow).AddMinutes(1).ToString('o')
        Invoke-FakeSpoof -Session $second -Context (New-SpooferContext) -Path $stateFile | Out-Null
        Save-SpooferBackupSession -Session $second | Out-Null

        # 'latest' is the newest un-restored backup, so undoing twice walks back
        # through the stack in order instead of jumping to the original value.
        Restore-SpooferBackupSession -Session (Resolve-SpooferBackupSession -Id 'latest') | Out-Null
        Assert-Equal $afterFirst (Get-Content -LiteralPath $stateFile -Raw).Trim()

        Restore-SpooferBackupSession -Session (Resolve-SpooferBackupSession -Id 'latest') | Out-Null
        Assert-Equal 'v0' (Get-Content -LiteralPath $stateFile -Raw).Trim()
    }

    $env:SPOOFER_ROOT = $outerRoot
}

} finally {
    if ($originalRoot) { $env:SPOOFER_ROOT = $originalRoot } else { Remove-Item Env:\SPOOFER_ROOT -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

$failures = Write-TestSummary
exit $failures
