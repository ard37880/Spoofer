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

foreach ($name in @('Common', 'Native', 'BackupStore', 'RegistryHelper', 'ProviderCommon', 'ProviderRegistry', 'Verify', 'Gpt')) {
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

    Test-Case 'Values carrying provider note properties are stored plainly' {
        # Get-Content and friends return primitives wrapped in a PSObject with
        # PSPath, PSChildName and the rest attached. Windows PowerShell 5.1
        # serialises those note properties into the manifest, so the value comes
        # back as an object; PowerShell 7 does not, which is why this asserts on
        # the stored entry rather than on a JSON round trip.
        $decorated = 'original-value' |
            Add-Member -NotePropertyName 'PSPath'      -NotePropertyValue 'C:\somewhere\file.txt' -PassThru |
            Add-Member -NotePropertyName 'PSChildName' -NotePropertyValue 'file.txt' -PassThru |
            Add-Member -NotePropertyName 'ReadCount'   -NotePropertyValue 1 -PassThru

        Assert-True (@($decorated | Get-Member -MemberType NoteProperty).Count -gt 0) 'the fixture itself must be decorated'

        $session = New-SpooferBackupSession -Modules @('probe')
        $entry = Add-SpooferBackupEntry -Session $session -Type 'Stub' -Module 'probe' -Label 'decorated' -Data @{
            Value = $decorated
        }

        Assert-Equal 'original-value' $entry.Value
        Assert-Equal 0 (@($entry.Value | Get-Member -MemberType NoteProperty).Count) 'the decoration must not reach the manifest'
    }

    Test-Case 'Normalisation reaches inside arrays and nested maps' {
        $decorated = 'inner' | Add-Member -NotePropertyName 'PSPath' -NotePropertyValue 'C:\x' -PassThru

        $session = New-SpooferBackupSession -Modules @('probe')
        $entry = Add-SpooferBackupEntry -Session $session -Type 'Stub' -Module 'probe' -Label 'nested' -Data @{
            Items  = @($decorated, 'plain')
            Nested = @{ Deep = $decorated }
        }

        Assert-Equal 0 (@($entry.Items[0] | Get-Member -MemberType NoteProperty).Count)
        Assert-Equal 'inner' $entry.Items[0]
        Assert-Equal 'plain' $entry.Items[1]
        Assert-Equal 0 (@($entry.Nested.Deep | Get-Member -MemberType NoteProperty).Count)
        Assert-Equal 'inner' $entry.Nested.Deep
    }

    Test-Case 'Normalisation leaves ordinary values alone' {
        Assert-Equal $null   (ConvertTo-SpooferJsonSafeValue -Value $null)
        Assert-Equal 'text'  (ConvertTo-SpooferJsonSafeValue -Value 'text')
        Assert-Equal 42      (ConvertTo-SpooferJsonSafeValue -Value 42)
        Assert-Equal $true   (ConvertTo-SpooferJsonSafeValue -Value $true)

        # Byte arrays are enumerable but must not be taken apart.
        $bytes = ConvertTo-SpooferJsonSafeValue -Value ([byte[]](1, 2, 250))
        Assert-True ($bytes -is [byte[]]) "expected a byte[] but got $($bytes.GetType().Name)"
        Assert-Equal 3 $bytes.Length
        Assert-Equal 250 $bytes[2]
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

Describe-Group 'Array returns' {

    # PowerShell unrolls a single-element array as it leaves a function, so a
    # caller that does not wrap gets a bare object. Under StrictMode on Windows
    # PowerShell 5.1, .Count on that object throws, which is how a crash shipped
    # on the only platform this tool targets while every test passed on 7.x.
    # The rule is that the caller wraps, since that is what the rest of the code
    # already assumes.

    Test-Case 'A wrapped single-module selection counts as one' {
        $one = @(Get-SpooferProvider -Name @('machineguid'))
        Assert-True ($one -is [array]) "expected an array, got $($one.GetType().Name)"
        Assert-Equal 1 $one.Count
        Assert-Equal 'machineguid' $one[0].Name
    }

    Test-Case 'Wrapping does not nest an already-plural result' {
        $two = @(Get-SpooferProvider -Name @('machineguid', 'mac'))
        Assert-Equal 2 $two.Count
        Assert-True ($two[0] -isnot [array]) 'the elements must be providers, not arrays'
    }

    Test-Case 'A tier holding one module still counts as one' {
        foreach ($tier in @('Standard', 'Advanced', 'Risky')) {
            $byTier = @(Get-SpooferProvider -Tier @($tier))
            Assert-True ($byTier.Count -ge 1) "$tier tier came back empty"
            Assert-True ($byTier[0] -isnot [array]) "$tier tier nested its results"
        }
    }

    Test-Case 'A backup store holding one session counts as one' {
        $groupRoot = Join-Path $sandbox 'arrays'
        $outerRoot = $env:SPOOFER_ROOT
        $env:SPOOFER_ROOT = $groupRoot
        Initialize-SpooferRoot | Out-Null

        try {
            Assert-Equal 0 @(Get-SpooferBackupSession -IncludeRestored).Count

            $session = New-SpooferBackupSession -Modules @('mac')
            Add-SpooferBackupEntry -Session $session -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
            Save-SpooferBackupSession -Session $session | Out-Null

            Assert-Equal 1 @(Get-SpooferBackupSession -IncludeRestored).Count
            Assert-Equal $session.Id (Resolve-SpooferBackupSession -Id 'latest').Id 'one session must resolve to itself, not to a list'
        } finally {
            $env:SPOOFER_ROOT = $outerRoot
        }
    }

    Test-Case 'The provider selection call sites wrap their result' {
        # The precise regression. A broader sweep for this shape was tried and
        # dropped: it cannot see function boundaries, so unrelated locals that
        # happen to share a name collide and it reports work that is fine.
        $text = Get-Content -LiteralPath (Join-Path $root 'Spoofer.ps1')

        $assignments = @($text | Where-Object { $_ -match '^\s*\$providers\s*=' })
        Assert-True ($assignments.Count -ge 2) 'expected the status and spoof call sites'

        foreach ($line in $assignments) {
            Assert-Match '^\s*\$providers\s*=\s*@\(' $line `
                "unwrapped provider assignment, which unrolls to a bare object and breaks .Count on PowerShell 5.1: $($line.Trim())"
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

    Test-Case 'exFAT boot records are recognised at offset 0x64' {
        $sector = New-FakeSector -Signature 'EXFAT   ' -SignatureOffset 3 -SerialOffset 0x64
        $layout = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } $sector

        Assert-Equal 'exFAT' $layout.FileSystem
        Assert-Equal 0x64 $layout.Offset
        Assert-Equal 4 $layout.Length
        Assert-Equal 'ExFatBootRegion' $layout.Region 'exFAT needs the whole boot region rewritten, not one sector'
    }

    Test-Case 'Each filesystem declares how much has to be rewritten' {
        $ntfs = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } (New-FakeSector -Signature 'NTFS    ' -SignatureOffset 3 -SerialOffset 0x48)
        Assert-Equal 'NtfsWithBackup' $ntfs.Region 'NTFS mirrors its serial into the backup boot sector'

        $fat = & $volumeModule { param($s) Get-VolumeSerialLayout -Sector $s } (New-FakeSector -Signature 'FAT32   ' -SignatureOffset 0x52 -SerialOffset 0x43)
        Assert-Equal 'SingleSector' $fat.Region
    }

    Test-Case 'The NTFS backup boot sector is located from the volume itself' {
        $sector = New-FakeSector -Signature 'NTFS    ' -SignatureOffset 3 -SerialOffset 0x48
        [System.Array]::Copy([System.BitConverter]::GetBytes([int64]2048), 0, $sector, 0x28, 8)

        $offset = & $volumeModule { param($s) Get-NtfsBackupSectorOffset -Sector $s -SectorSize 512 } $sector
        Assert-Equal (2048 * 512) $offset

        # A zeroed sector count means "do not guess", not "offset zero".
        $blank = New-FakeSector -Signature 'NTFS    ' -SignatureOffset 3 -SerialOffset 0x48
        Assert-Equal -1 (& $volumeModule { param($s) Get-NtfsBackupSectorOffset -Sector $s -SectorSize 512 } $blank)
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

Describe-Group 'Module selection checklist' {

    # The picker lives in Spoofer.ps1, so its functions are lifted out of the
    # script's syntax tree and defined here. Running the script itself would
    # execute the whole command line instead.
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'Spoofer.ps1') -Raw
    $scriptAst  = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$null, [ref]$null)

    foreach ($definition in $scriptAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($definition.Name -in @('Show-ModuleChecklist', 'Select-SpooferModuleInteractive')) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    $catalogue    = @(Get-SpooferProvider)
    $script:Keys  = @()
    $script:KeyAt = 0

    # Stands in for the console prompt. Defined in this scope, so it shadows the
    # real cmdlet for the picker and disappears with the group.
    function Read-Host {
        param([string]$Prompt)
        $value = $script:Keys[$script:KeyAt]
        $script:KeyAt++
        return $value
    }

    function Invoke-Picker {
        param([string[]]$Keystrokes, [string[]]$PreSelected)

        $script:Keys  = $Keystrokes
        $script:KeyAt = 0

        $chosen = Select-SpooferModuleInteractive -Provider $catalogue -PreSelected $PreSelected 6>$null
        if ($null -eq $chosen) { return '<cancelled>' }
        return ((@($chosen) | ForEach-Object { $_.Name }) -join ',')
    }

    function Get-TierNames {
        param([string]$Tier)
        return ((@($catalogue | Where-Object { $_.Tier -eq $Tier }) | ForEach-Object { $_.Name }) -join ',')
    }

    $everything = ((@($catalogue) | ForEach-Object { $_.Name }) -join ',')

    Test-Case 'Pressing enter accepts what is already ticked' {
        Assert-Equal $everything (Invoke-Picker -Keystrokes @('') -PreSelected $null)
    }

    Test-Case 'A pre-selection is what starts ticked' {
        Assert-Equal 'machineguid,mac' (Invoke-Picker -Keystrokes @('') -PreSelected @('machineguid', 'mac'))
    }

    Test-Case 'q cancels without selecting anything' {
        Assert-Equal '<cancelled>' (Invoke-Picker -Keystrokes @('q') -PreSelected $null)
    }

    Test-Case 'Entries toggle by number' {
        Assert-Equal 'machineguid,hwprofile' (Invoke-Picker -Keystrokes @('n', '1 3', '') -PreSelected $null)
    }

    Test-Case 'Entries toggle by name' {
        Assert-Equal 'mac,volumeserial' (Invoke-Picker -Keystrokes @('n', 'mac volumeserial', '') -PreSelected $null)
    }

    Test-Case 'Numbers may be separated by commas' {
        Assert-Equal 'machineguid,machineid' (Invoke-Picker -Keystrokes @('n', '1,2', '') -PreSelected $null)
    }

    Test-Case 'Toggling twice returns an entry to where it started' {
        Assert-Equal $everything (Invoke-Picker -Keystrokes @('mac', 'mac', '') -PreSelected $null)
    }

    Test-Case 'The tier shortcuts select exactly that tier' {
        Assert-Equal (Get-TierNames -Tier 'Risky')    (Invoke-Picker -Keystrokes @('r', '') -PreSelected $null)
        Assert-Equal (Get-TierNames -Tier 'Standard') (Invoke-Picker -Keystrokes @('s', '') -PreSelected $null)
        Assert-Equal (Get-TierNames -Tier 'Advanced') (Invoke-Picker -Keystrokes @('d', '') -PreSelected $null)
    }

    Test-Case 'a ticks everything and n clears it' {
        Assert-Equal $everything (Invoke-Picker -Keystrokes @('n', 'a', '') -PreSelected @('mac'))
    }

    Test-Case 'i inverts the current selection' {
        Assert-Equal $everything (Invoke-Picker -Keystrokes @('n', 'i', '') -PreSelected $null)

        $withoutFirst = ((@($catalogue | Where-Object { $_.Name -ne 'machineguid' }) | ForEach-Object { $_.Name }) -join ',')
        Assert-Equal $withoutFirst (Invoke-Picker -Keystrokes @('n', 'machineguid', 'i', '') -PreSelected $null)
    }

    Test-Case 'An empty selection re-prompts rather than running nothing' {
        Assert-Equal 'machineguid' (Invoke-Picker -Keystrokes @('n', '', '1', '') -PreSelected $null)
    }

    Test-Case 'Unknown names and out-of-range numbers are rejected, not obeyed' {
        Assert-Equal 'machineguid' (Invoke-Picker -Keystrokes @('n', 'nosuchmodule', '999', '0', '1', '') -PreSelected $null)
    }

    Test-Case 'Selection order follows the catalogue, not the order typed' {
        Assert-Equal 'machineguid,mac' (Invoke-Picker -Keystrokes @('n', 'mac machineguid', '') -PreSelected $null)
    }
}

Describe-Group 'GPT structures' {

    function New-FakeGpt {
        <#
            Builds a minimal but structurally valid GPT: one header sector and a
            partition array with two entries in use, checksums correct.
        #>
        param([int]$SectorSize = 512, [int]$EntryCount = 128, [int]$EntrySize = 128)

        $header = New-Object 'byte[]' $SectorSize
        [System.Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('EFI PART'), 0, $header, 0, 8)
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]92), 0, $header, 12, 4)   # header size
        [System.Array]::Copy([System.BitConverter]::GetBytes([int64]1), 0, $header, 24, 8)     # current LBA
        [System.Array]::Copy([System.BitConverter]::GetBytes([int64]40), 0, $header, 32, 8)    # backup LBA
        [System.Array]::Copy(([guid]'11111111-2222-3333-4444-555555555555').ToByteArray(), 0, $header, 56, 16)
        [System.Array]::Copy([System.BitConverter]::GetBytes([int64]2), 0, $header, 72, 8)     # array LBA
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$EntryCount), 0, $header, 80, 4)
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$EntrySize), 0, $header, 84, 4)

        $array = New-Object 'byte[]' ($EntryCount * $EntrySize)
        $basic = [guid]'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
        foreach ($pair in @(@(0, 'System'), @(1, 'Data'))) {
            $base = $pair[0] * $EntrySize
            [System.Array]::Copy($basic.ToByteArray(), 0, $array, $base, 16)
            [System.Array]::Copy([guid]::NewGuid().ToByteArray(), 0, $array, $base + 16, 16)
            [System.Array]::Copy([System.BitConverter]::GetBytes([int64](2048 + $pair[0] * 100000)), 0, $array, $base + 32, 8)
            [System.Array]::Copy([System.Text.Encoding]::Unicode.GetBytes($pair[1]), 0, $array, $base + 56, ([System.Text.Encoding]::Unicode.GetBytes($pair[1])).Length)
        }

        Update-SpooferGptChecksum -Header $header -HeaderOffset 0 -Array $array -ArrayLength $array.Length | Out-Null
        return [pscustomobject]@{ Header = $header; Array = $array; EntryCount = $EntryCount; EntrySize = $EntrySize }
    }

    Test-Case 'CRC32 matches the published reference vectors' {
        # The GPT checksums are worthless if this is wrong, and it is easy to get
        # wrong: PowerShell reads an eight digit hex literal as a signed Int32.
        # Decimal, not hex: 0xE8B7BE43 as a literal is a negative Int32 and will
        # not cast to UInt32, which is the very trap this function documents.
        $cases = @{
            '123456789'                                   = [uint32]3421780262
            'a'                                           = [uint32]3904355907
            'abc'                                         = [uint32]891568578
            'The quick brown fox jumps over the lazy dog' = [uint32]1095738169
        }

        foreach ($text in $cases.Keys) {
            $actual = Get-SpooferCrc32 -Bytes ([System.Text.Encoding]::ASCII.GetBytes($text))
            Assert-Equal $cases[$text] $actual "CRC32 of '$text'"
        }
    }

    Test-Case 'An empty run has a zero CRC' {
        Assert-Equal ([uint32]0) (Get-SpooferCrc32 -Bytes (New-Object 'byte[]' 0))
    }

    Test-Case 'A GPT header is recognised, and other bytes are not' {
        Assert-True (Test-SpooferGptHeader -Bytes (New-FakeGpt).Header)
        Assert-True (-not (Test-SpooferGptHeader -Bytes (New-Object 'byte[]' 512)))
        Assert-True (-not (Test-SpooferGptHeader -Bytes (New-Object 'byte[]' 8))) 'too short to hold a header'
        Assert-True (-not (Test-SpooferGptHeader -Bytes $null))
    }

    Test-Case 'Header fields parse back out' {
        $gpt    = New-FakeGpt
        $parsed = Read-SpooferGptHeader -Bytes $gpt.Header

        Assert-Equal 92 $parsed.HeaderSize
        Assert-Equal 1  $parsed.CurrentLba
        Assert-Equal 40 $parsed.BackupLba
        Assert-Equal 2  $parsed.ArrayLba
        Assert-Equal 128 $parsed.EntryCount
        Assert-Equal 128 $parsed.EntrySize
        Assert-Equal '11111111-2222-3333-4444-555555555555' $parsed.DiskGuid.ToString()
    }

    Test-Case 'Only entries in use are returned' {
        $gpt     = New-FakeGpt
        $entries = @(Read-SpooferGptEntry -Array $gpt.Array -EntryCount $gpt.EntryCount -EntrySize $gpt.EntrySize)

        Assert-Equal 2 $entries.Count 'the other 126 slots are empty'
        Assert-Equal 'System' $entries[0].Name
        Assert-Equal 'Data'   $entries[1].Name
        Assert-Equal 2048     $entries[0].FirstLba
        Assert-NotEqual $entries[0].UniqueGuid.ToString() $entries[1].UniqueGuid.ToString()
    }

    Test-Case 'A freshly built table verifies' {
        Assert-True (Test-SpooferGptChecksum -Header (New-FakeGpt).Header -HeaderOffset 0)
    }

    Test-Case 'Changing a partition GUID and recomputing keeps the table valid' {
        $gpt    = New-FakeGpt
        $before = @(Read-SpooferGptEntry -Array $gpt.Array -EntryCount $gpt.EntryCount -EntrySize $gpt.EntrySize)
        $newGuid = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

        Set-SpooferGptEntryGuid -Array $gpt.Array -EntryOffset $before[0].Offset -Guid $newGuid
        Update-SpooferGptChecksum -Header $gpt.Header -HeaderOffset 0 -Array $gpt.Array -ArrayLength $gpt.Array.Length | Out-Null

        $after = @(Read-SpooferGptEntry -Array $gpt.Array -EntryCount $gpt.EntryCount -EntrySize $gpt.EntrySize)
        Assert-Equal $newGuid.ToString() $after[0].UniqueGuid.ToString()
        Assert-Equal $before[1].UniqueGuid.ToString() $after[1].UniqueGuid.ToString() 'the other partition must be untouched'
        Assert-Equal $before[0].Name $after[0].Name 'the name must survive'
        Assert-True (Test-SpooferGptChecksum -Header $gpt.Header -HeaderOffset 0) 'the header checksum must be recomputed'

        $storedArrayCrc = [System.BitConverter]::ToUInt32($gpt.Header, 88)
        Assert-Equal (Get-SpooferCrc32 -Bytes $gpt.Array) $storedArrayCrc 'the array checksum must match the array'
    }

    Test-Case 'Editing the array without recomputing invalidates the table' {
        # The whole reason both checksums have to be rewritten.
        $gpt = New-FakeGpt
        $gpt.Array[16] = [byte](($gpt.Array[16] + 1) % 256)

        $storedArrayCrc = [System.BitConverter]::ToUInt32($gpt.Header, 88)
        Assert-NotEqual (Get-SpooferCrc32 -Bytes $gpt.Array) $storedArrayCrc
    }

    Test-Case 'A tampered header fails its own checksum' {
        $gpt = New-FakeGpt
        $gpt.Header[56] = [byte](($gpt.Header[56] + 1) % 256)
        Assert-True (-not (Test-SpooferGptChecksum -Header $gpt.Header -HeaderOffset 0))
    }

    Test-Case 'A header claiming an impossible size is refused' {
        $gpt = New-FakeGpt
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]99999), 0, $gpt.Header, 12, 4)

        Assert-True (-not (Test-SpooferGptChecksum -Header $gpt.Header -HeaderOffset 0))
        Assert-Throws { Update-SpooferGptChecksum -Header $gpt.Header -HeaderOffset 0 -Array $gpt.Array -ArrayLength $gpt.Array.Length } -Pattern 'does not fit'
    }
}

Describe-Group 'Generator scope' {

    # A generator built with GetNewClosure is rebound to a fresh dynamic module,
    # which does not carry the defining module's private functions. Calling one
    # from inside a closure fails at spoof time with "not recognized", which is
    # how digitalproductid shipped broken while every other check passed.

    Test-Case 'No closure generator calls a private module function' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $sourceDir 'Providers') -Filter '*.psm1' -File)

        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $ast  = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)

            # Every function this module defines but does not export is private,
            # so a closure cannot reach it.
            $defined = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })

            foreach ($block in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
                $following = $text.Substring($block.Extent.EndOffset, [math]::Min(20, $text.Length - $block.Extent.EndOffset))
                if ($following -notmatch '^\s*\.GetNewClosure\(\)') { continue }

                $called = @($block.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                    ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $_ })

                foreach ($name in $called) {
                    Assert-True ($defined -notcontains $name) `
                        "$($file.Name): a GetNewClosure generator calls '$name', which is private to the module and will not resolve inside the closure"
                }
            }
        }
    }
}

Describe-Group 'Verification checks' {

    Test-Case 'Every check is completely specified' {
        foreach ($check in (Get-SpooferCheck)) {
            Assert-True ($check.Group.Length -gt 0) 'a check needs a group'
            Assert-True ($check.Item.Length -gt 0)  'a check needs an item'
            Assert-True (@('Full', 'CacheOnly', 'None') -contains $check.Coverage) "unknown coverage '$($check.Coverage)' on $($check.Item)"
            Assert-True ($check.Reported -is [scriptblock]) "$($check.Item) must know how to read itself"
        }
    }

    Test-Case 'A CacheOnly check has something to compare against' {
        # The whole point of that classification is the second read. Without it
        # the row could never show a gap and would be quietly meaningless.
        foreach ($check in (Get-SpooferCheck | Where-Object { $_.Coverage -eq 'CacheOnly' })) {
            Assert-True ($check.Authoritative -is [scriptblock]) "$($check.Item) is CacheOnly but has no authoritative read"
        }
    }

    Test-Case 'Full and None checks name no second source' {
        foreach ($check in (Get-SpooferCheck | Where-Object { $_.Coverage -ne 'CacheOnly' })) {
            Assert-True ($null -eq $check.Authoritative) "$($check.Item) is $($check.Coverage) but declares an authoritative read"
        }
    }

    Test-Case 'The things that cannot be changed are all listed' {
        $items = @(Get-SpooferCheck | Where-Object { $_.Coverage -eq 'None' } | ForEach-Object { $_.Item })
        foreach ($expected in @('Motherboard UUID', 'CPU identifier', 'TPM', 'GPU')) {
            Assert-True ($items -contains $expected) "'$expected' should be reported as not covered"
        }
    }

    Test-Case 'Every covered check names the module responsible' {
        foreach ($check in (Get-SpooferCheck | Where-Object { $_.Coverage -ne 'None' })) {
            Assert-True ($check.Module.Length -gt 0) "$($check.Item) does not say which module covers it"
        }

        $known = @(Get-SpooferProviderName)
        foreach ($check in (Get-SpooferCheck | Where-Object { $_.Module })) {
            Assert-True ($known -contains $check.Module) "$($check.Item) names module '$($check.Module)', which does not exist"
        }
    }

    Test-Case 'A malformed coverage value is rejected at declaration' {
        Assert-Throws { New-SpooferCheck -Group 'g' -Item 'i' -Coverage 'Nonsense' -Reported {} }
    }

    Test-Case 'Reads that throw are reported, not fatal' {
        # Nearly every check calls a Windows-only cmdlet, so on any other
        # platform they all throw. Invoke-SpooferCheck has to survive that and
        # still return a row per check.
        $results = @(Invoke-SpooferCheck 6>$null)
        Assert-True ($results.Count -gt 0) 'checks should still produce rows'

        foreach ($row in $results) {
            Assert-True ($row.Reported.Length -gt 0) "$($row.Item) produced no reported value"
            Assert-True (@('Full', 'CacheOnly', 'None') -contains $row.Coverage)
        }
    }

    Test-Case 'Match is left undecided when there is nothing to compare' {
        foreach ($row in (Invoke-SpooferCheck 6>$null | Where-Object { $_.Coverage -ne 'CacheOnly' })) {
            Assert-Equal $null $row.Match "$($row.Item) should not claim a comparison it did not make"
        }
    }
}

Describe-Group 'Menu' {

    # Same approach as the checklist group: the menu lives in Spoofer.ps1, so its
    # functions are lifted out of the syntax tree rather than by running the script.
    $menuText = Get-Content -LiteralPath (Join-Path $root 'Spoofer.ps1') -Raw
    $menuAst  = [System.Management.Automation.Language.Parser]::ParseInput($menuText, [ref]$null, [ref]$null)

    foreach ($definition in $menuAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($definition.Name -in @('Read-SpooferMenuChoice', 'Format-SpooferBackupLine', 'Select-SpooferBackupInteractive')) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    $script:Typed  = @()
    $script:TypedAt = 0

    function Read-Host {
        param([string]$Prompt)
        if ($script:TypedAt -ge $script:Typed.Count) { return $null }
        $value = $script:Typed[$script:TypedAt]
        $script:TypedAt++
        return $value
    }

    function Set-Typed {
        param([string[]]$Keys)
        $script:Typed   = $Keys
        $script:TypedAt = 0
    }

    Test-Case 'A valid choice is returned as declared' {
        Set-Typed -Keys @('3')
        Assert-Equal '3' (Read-SpooferMenuChoice -Key @('0', '1', '2', '3') 6>$null)
    }

    Test-Case 'Surrounding whitespace is ignored' {
        Set-Typed -Keys @('  2  ')
        Assert-Equal '2' (Read-SpooferMenuChoice -Key @('1', '2') 6>$null)
    }

    Test-Case 'An invalid choice re-prompts instead of being accepted' {
        Set-Typed -Keys @('9', 'banana', '', '1')
        Assert-Equal '1' (Read-SpooferMenuChoice -Key @('0', '1') 6>$null)
        Assert-Equal 4 $script:TypedAt 'every bad answer should have been read and rejected'
    }

    Test-Case 'A closed input stream ends the prompt rather than looping forever' {
        # Read-Host returns nothing in a non-interactive host. Without this the
        # menu would spin on an unreadable stream.
        Set-Typed -Keys @()
        Assert-Equal $null (Read-SpooferMenuChoice -Key @('0', '1') 6>$null)
    }

    Test-Case 'A backup renders with its id, age, size and state' {
        $session = New-SpooferBackupSession -Note 'a note' -Modules @('mac')
        Add-SpooferBackupEntry -Session $session -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null

        $line = Format-SpooferBackupLine -Session $session
        Assert-Match ([regex]::Escape($session.Id)) $line
        Assert-Match '1 entries' $line
        Assert-Match 'not yet restored' $line
        Assert-Match 'a note' $line
    }

    Test-Case 'A restored backup says so' {
        $session = New-SpooferBackupSession -Modules @('mac')
        Add-SpooferBackupEntry -Session $session -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
        $session.Restored = $true

        Assert-Match 'already restored' (Format-SpooferBackupLine -Session $session)
    }

    Test-Case 'An unparsable timestamp does not break the line' {
        $session = New-SpooferBackupSession -Modules @('mac')
        Add-SpooferBackupEntry -Session $session -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
        $session.CreatedUtc = 'not a date'

        Assert-Match ([regex]::Escape($session.Id)) (Format-SpooferBackupLine -Session $session 6>$null)
    }

    Test-Case 'The backup picker returns the chosen session' {
        $groupRoot = Join-Path $sandbox 'menu'
        $outerRoot = $env:SPOOFER_ROOT
        $env:SPOOFER_ROOT = $groupRoot
        Initialize-SpooferRoot | Out-Null

        try {
            $first = New-SpooferBackupSession -Note 'first' -Modules @('mac')
            Add-SpooferBackupEntry -Session $first -Type 'Stub' -Label 'x' -Data @{ Value = 1 } | Out-Null
            Save-SpooferBackupSession -Session $first | Out-Null

            $second = New-SpooferBackupSession -Note 'second' -Modules @('mac')
            $second.CreatedUtc = ([datetime]::UtcNow).AddMinutes(5).ToString('o')
            Add-SpooferBackupEntry -Session $second -Type 'Stub' -Label 'y' -Data @{ Value = 2 } | Out-Null
            Save-SpooferBackupSession -Session $second | Out-Null

            # Newest first, so entry 1 is the one created later.
            Set-Typed -Keys @('1')
            Assert-Equal $second.Id (Select-SpooferBackupInteractive -Title 'pick' 6>$null).Id

            Set-Typed -Keys @('2')
            Assert-Equal $first.Id (Select-SpooferBackupInteractive -Title 'pick' 6>$null).Id

            Set-Typed -Keys @('0')
            Assert-Equal $null (Select-SpooferBackupInteractive -Title 'pick' 6>$null)

            Set-Typed -Keys @('7', '1')
            Assert-Equal $second.Id (Select-SpooferBackupInteractive -Title 'pick' 6>$null).Id
        } finally {
            $env:SPOOFER_ROOT = $outerRoot
        }
    }

    Test-Case 'The backup picker copes with there being none' {
        $emptyRoot = Join-Path $sandbox 'menu-empty'
        $outerRoot = $env:SPOOFER_ROOT
        $env:SPOOFER_ROOT = $emptyRoot
        Initialize-SpooferRoot | Out-Null

        try {
            Set-Typed -Keys @()
            Assert-Equal $null (Select-SpooferBackupInteractive -Title 'pick' 6>$null)
        } finally {
            $env:SPOOFER_ROOT = $outerRoot
        }
    }
}

Describe-Group 'exFAT boot region' {

    $exfatModule = Import-Module (Join-Path $sourceDir 'Providers/11-VolumeSerial.psm1') -Force -PassThru -DisableNameChecking

    function Get-ReferenceExFatChecksum {
        # The specification formula, evaluated in arbitrary precision so it can
        # disagree with the module if the module's 32-bit arithmetic is wrong.
        param([byte[]]$Region, [int]$SectorSize)

        $modulus = [System.Numerics.BigInteger]::Pow(2, 32)
        $value   = [System.Numerics.BigInteger]0

        for ($i = 0; $i -lt 11 * $SectorSize; $i++) {
            if ($i -eq 106 -or $i -eq 107 -or $i -eq 112) { continue }
            $high  = if (($value % 2) -eq 1) { [System.Numerics.BigInteger]2147483648 } else { [System.Numerics.BigInteger]0 }
            $value = ($high + [System.Numerics.BigInteger]::Divide($value, 2) + $Region[$i]) % $modulus
        }
        return [uint32]$value
    }

    Test-Case 'The checksum matches an independent implementation' {
        foreach ($sectorSize in @(512, 4096)) {
            Initialize-SpooferRandom -Seed $sectorSize
            $region = Get-SpooferRandomByte -Count (12 * $sectorSize)

            $actual   = & $exfatModule { param($r, $s) Get-ExFatBootChecksum -Region $r -SectorSize $s } $region $sectorSize
            $expected = Get-ReferenceExFatChecksum -Region $region -SectorSize $sectorSize

            Assert-Equal $expected $actual "sector size $sectorSize"
        }
    }

    Test-Case 'The three volatile bytes are excluded' {
        Initialize-SpooferRandom -Seed 11
        $a = Get-SpooferRandomByte -Count (12 * 512)
        $b = New-Object byte[] $a.Length
        [System.Array]::Copy($a, $b, $a.Length)

        # VolumeFlags and PercentInUse change while the volume is mounted, so the
        # checksum has to be blind to them or it would go stale on its own.
        $b[106] = [byte](($a[106] + 1) % 256)
        $b[107] = [byte](($a[107] + 7) % 256)
        $b[112] = [byte](($a[112] + 9) % 256)

        $first  = & $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $a
        $second = & $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $b
        Assert-Equal $first $second
    }

    Test-Case 'Any other byte does change the checksum' {
        Initialize-SpooferRandom -Seed 12
        $a = Get-SpooferRandomByte -Count (12 * 512)
        $b = New-Object byte[] $a.Length
        [System.Array]::Copy($a, $b, $a.Length)
        $b[0x64] = [byte](($a[0x64] + 1) % 256)

        Assert-NotEqual `
            (& $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $a) `
            (& $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $b)
    }

    Test-Case 'The checksum sector is filled with the repeated value' {
        Initialize-SpooferRandom -Seed 13
        $region = Get-SpooferRandomByte -Count (12 * 512)

        & $exfatModule { param($r) Set-ExFatBootChecksum -Region $r -SectorSize 512 -RegionOffset 0 } $region

        $expected = & $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $region
        for ($offset = 11 * 512; $offset -lt 12 * 512; $offset += 4) {
            Assert-Equal $expected ([System.BitConverter]::ToUInt32($region, $offset)) "checksum copy at $offset"
        }
    }

    Test-Case 'A backup region is checksummed independently of the main one' {
        Initialize-SpooferRandom -Seed 14
        $both = Get-SpooferRandomByte -Count (24 * 512)

        & $exfatModule { param($r) Set-ExFatBootChecksum -Region $r -SectorSize 512 -RegionOffset 0 } $both
        & $exfatModule { param($r) Set-ExFatBootChecksum -Region $r -SectorSize 512 -RegionOffset (12 * 512) } $both

        $mainSlice = New-Object byte[] (11 * 512)
        [System.Array]::Copy($both, 0, $mainSlice, 0, $mainSlice.Length)
        $backupSlice = New-Object byte[] (11 * 512)
        [System.Array]::Copy($both, 12 * 512, $backupSlice, 0, $backupSlice.Length)

        Assert-Equal (& $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $mainSlice) `
                     ([System.BitConverter]::ToUInt32($both, 11 * 512))
        Assert-Equal (& $exfatModule { param($r) Get-ExFatBootChecksum -Region $r -SectorSize 512 } $backupSlice) `
                     ([System.BitConverter]::ToUInt32($both, 23 * 512))
    }
}

Describe-Group 'Monitor EDID' {

    $edidModule = Import-Module (Join-Path $sourceDir 'Providers/13-MonitorEdid.psm1') -Force -PassThru -DisableNameChecking

    function New-FakeEdid {
        param([switch]$WithSerialDescriptor)

        $edid = New-Object byte[] 128
        foreach ($pair in @(@(0, 0x00), @(1, 0xFF), @(2, 0xFF), @(3, 0xFF), @(4, 0xFF), @(5, 0xFF), @(6, 0xFF), @(7, 0x00))) {
            $edid[$pair[0]] = [byte]$pair[1]
        }
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]0x11223344), 0, $edid, 12, 4)

        if ($WithSerialDescriptor) {
            # Descriptor 1: zero flag bytes plus tag 0xFF marks a printed serial.
            $offset = 54 + 18
            $edid[$offset] = 0; $edid[$offset + 1] = 0; $edid[$offset + 2] = 0
            $edid[$offset + 3] = 0xFF
            $edid[$offset + 4] = 0
            $text = [System.Text.Encoding]::ASCII.GetBytes('OLDSERIAL123')
            [System.Array]::Copy($text, 0, $edid, $offset + 5, $text.Length)
        }

        $sum = 0
        for ($i = 0; $i -lt 127; $i++) { $sum = ($sum + $edid[$i]) -band 0xFF }
        $edid[127] = [byte]((256 - $sum) -band 0xFF)

        return $edid
    }

    Test-Case 'The EDID header is required' {
        Assert-True (& $edidModule { param($e) Test-EdidBlob -Edid $e } (New-FakeEdid))
        Assert-True (-not (& $edidModule { param($e) Test-EdidBlob -Edid $e } ([byte[]]::new(128))))
        Assert-True (-not (& $edidModule { param($e) Test-EdidBlob -Edid $e } ([byte[]]::new(16)))) 'too short to be an EDID'
        Assert-True (-not (& $edidModule { param($e) Test-EdidBlob -Edid $e } $null))
    }

    Test-Case 'A well-formed block validates, a tampered one does not' {
        $edid = New-FakeEdid
        Assert-True (& $edidModule { param($e) Test-EdidChecksum -Edid $e -BlockOffset 0 } $edid)

        $edid[20] = [byte](($edid[20] + 1) % 256)
        Assert-True (-not (& $edidModule { param($e) Test-EdidChecksum -Edid $e -BlockOffset 0 } $edid))
    }

    Test-Case 'Spoofing changes the serial and leaves the checksum valid' {
        Initialize-SpooferRandom -Seed 21
        $original = New-FakeEdid
        $updated  = & $edidModule { param($e) New-SpoofedEdid -Current $e } $original

        Assert-Equal 128 $updated.Length
        Assert-NotEqual (& $edidModule { param($e) Get-EdidSerialNumber -Edid $e } $original) `
                        (& $edidModule { param($e) Get-EdidSerialNumber -Edid $e } $updated)
        Assert-True (& $edidModule { param($e) Test-EdidChecksum -Edid $e -BlockOffset 0 } $updated) `
            'a block whose checksum does not add up is treated as corrupt'
    }

    Test-Case 'The original blob is not modified in place' {
        Initialize-SpooferRandom -Seed 22
        $original = New-FakeEdid
        $before   = & $edidModule { param($e) Get-EdidSerialNumber -Edid $e } $original

        & $edidModule { param($e) New-SpoofedEdid -Current $e } $original | Out-Null

        Assert-Equal $before (& $edidModule { param($e) Get-EdidSerialNumber -Edid $e } $original)
    }

    Test-Case 'A printed serial descriptor is rewritten too' {
        Initialize-SpooferRandom -Seed 23
        $original = New-FakeEdid -WithSerialDescriptor
        $updated  = & $edidModule { param($e) New-SpoofedEdid -Current $e } $original

        $text = [System.Text.Encoding]::ASCII.GetString($updated, 54 + 18 + 5, 13)
        Assert-True ($text -notmatch 'OLDSERIAL') "the printed serial survived as '$text'"
        Assert-Match "`n|`r|^[A-Z0-9]+" $text.Trim() 'the replacement should be printable'
        Assert-True (& $edidModule { param($e) Test-EdidChecksum -Edid $e -BlockOffset 0 } $updated)
    }

    Test-Case 'Descriptors that are not serials are left alone' {
        Initialize-SpooferRandom -Seed 24
        $original = New-FakeEdid
        # Descriptor 2 carries tag 0xFC (display name), which must not be touched.
        $offset = 54 + 36
        $original[$offset + 3] = 0xFC
        $name = [System.Text.Encoding]::ASCII.GetBytes('MONITOR NAME')
        [System.Array]::Copy($name, 0, $original, $offset + 5, $name.Length)

        $updated = & $edidModule { param($e) New-SpoofedEdid -Current $e } $original
        Assert-Equal 'MONITOR NAME' ([System.Text.Encoding]::ASCII.GetString($updated, $offset + 5, 12))
    }

    Test-Case 'Something that is not an EDID is returned untouched' {
        $notEdid = [byte[]]::new(128)
        $result  = & $edidModule { param($e) New-SpoofedEdid -Current $e } $notEdid
        Assert-Equal 128 $result.Length
        for ($i = 0; $i -lt 128; $i++) { Assert-Equal 0 $result[$i] }
    }
}

Describe-Group 'Digital product id' {

    $productModule = Import-Module (Join-Path $sourceDir 'Providers/12-DigitalProductId.psm1') -Force -PassThru -DisableNameChecking

    function New-FakeProductId {
        param([int]$Length = 164)
        $blob = New-Object byte[] $Length
        [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$Length), 0, $blob, 0, 4)
        for ($i = 4; $i -lt $Length; $i++) { $blob[$i] = [byte]($i % 256) }
        return $blob
    }

    Test-Case 'The length and its length field are preserved' {
        Initialize-SpooferRandom -Seed 31
        foreach ($length in @(164, 1272)) {
            $original = New-FakeProductId -Length $length
            $updated  = & $productModule { param($b) New-SpoofedProductIdBlob -Current $b } $original

            Assert-Equal $length $updated.Length
            Assert-Equal ([uint32]$length) ([System.BitConverter]::ToUInt32($updated, 0)) 'the leading length field must still describe the blob'
        }
    }

    Test-Case 'The body is actually randomised' {
        Initialize-SpooferRandom -Seed 32
        $original = New-FakeProductId
        $updated  = & $productModule { param($b) New-SpoofedProductIdBlob -Current $b } $original

        $differences = 0
        for ($i = 4; $i -lt $original.Length; $i++) {
            if ($original[$i] -ne $updated[$i]) { $differences++ }
        }
        Assert-True ($differences -gt ($original.Length / 2)) "only $differences bytes changed"
    }

    Test-Case 'The original blob is not modified in place' {
        Initialize-SpooferRandom -Seed 33
        $original = New-FakeProductId
        & $productModule { param($b) New-SpoofedProductIdBlob -Current $b } $original | Out-Null
        Assert-Equal 8 $original[8] 'the source array must be left as it was'
    }

    Test-Case 'A missing or truncated blob is passed straight through' {
        Assert-Equal $null (& $productModule { param($b) New-SpoofedProductIdBlob -Current $b } $null)

        $short = [byte[]](1, 2, 3, 4)
        $result = & $productModule { param($b) New-SpoofedProductIdBlob -Current $b } $short
        Assert-Equal 4 $result.Length
    }
}

Describe-Group 'Interface rename rollback' {

    # The provider is loaded on its own so its private rollback helpers can be
    # reached, and the registry calls inside them are replaced with a hashtable
    # standing in for the keys. That is enough to exercise the logic on a
    # machine that has no registry at all.
    $interfaceModule = Import-Module (Join-Path $sourceDir 'Providers/17-NetworkInterface.psm1') -Force -PassThru -DisableNameChecking

    $installFakes = {
        param($Keys, $FailOn)

        $script:FakeKeys   = $Keys
        $script:FakeFailOn = $FailOn

        function script:Resolve-SpooferRegistryPath { param([string]$Path) return $Path }

        function script:Test-Path {
            param([string]$Path, [string]$LiteralPath)
            $target = if ($LiteralPath) { $LiteralPath } else { $Path }
            return $script:FakeKeys.ContainsKey($target)
        }

        function script:Copy-SpooferRegistryKey {
            param([string]$Source, [string]$Destination)
            if ($Destination -eq $script:FakeFailOn) { throw "cannot create '$Destination'" }
            $script:FakeKeys[$Destination] = $script:FakeKeys[$Source]
        }

        function script:Remove-SpooferRegistryKey {
            param([string]$Path)
            if ($Path -eq $script:FakeFailOn) { throw "cannot remove '$Path'" }
            $script:FakeKeys.Remove($Path)
        }
    }

    Test-Case 'Every completed rename goes back to the name it had' {
        $keys = @{ 'P\new-a' = 'a'; 'P\new-b' = 'b' }
        & $interfaceModule $installFakes $keys $null

        $completed = @(
            [pscustomobject]@{ Purpose = 'TCP/IP settings';   Original = 'P\old-a'; New = 'P\new-a'; Entry = $null }
            [pscustomobject]@{ Purpose = 'TCP/IPv6 settings'; Original = 'P\old-b'; New = 'P\new-b'; Entry = $null }
        )

        $result = & $interfaceModule { param($c) Undo-SpooferInterfaceRename -Completed $c } $completed

        Assert-Equal 0 $result.Stuck
        Assert-Equal 2 @($result.Undone).Count
        Assert-True ($keys.ContainsKey('P\old-a') -and $keys.ContainsKey('P\old-b')) 'both keys should be back under their original names'
        Assert-True (-not $keys.ContainsKey('P\new-a') -and -not $keys.ContainsKey('P\new-b')) 'neither new name should still be there'
    }

    Test-Case 'A step that will not go back is counted rather than thrown' {
        $keys = @{ 'P\new-a' = 'a'; 'P\new-b' = 'b' }
        & $interfaceModule $installFakes $keys 'P\new-b'

        $completed = @(
            [pscustomobject]@{ Purpose = 'TCP/IP settings'; Original = 'P\old-a'; New = 'P\new-a'; Entry = $null }
            [pscustomobject]@{ Purpose = 'network setup';   Original = 'P\old-b'; New = 'P\new-b'; Entry = $null }
        )

        $result = & $interfaceModule { param($c) Undo-SpooferInterfaceRename -Completed $c } $completed

        # The stuck one must not stop the rest from being put back.
        Assert-Equal 1 $result.Stuck
        Assert-Equal 1 @($result.Undone).Count
        Assert-True ($keys.ContainsKey('P\old-a')) 'the step that could go back should have gone back'
    }

    Test-Case 'Only the renames that went back lose their backup entry' {
        $keys = @{ 'P\new-a' = 'a'; 'P\new-b' = 'b' }
        & $interfaceModule $installFakes $keys 'P\new-b'

        $session = [pscustomobject]@{ Entries = (New-Object System.Collections.ArrayList) }
        $entryA  = [pscustomobject]@{ Label = 'a' }
        $entryB  = [pscustomobject]@{ Label = 'b' }
        [void]$session.Entries.Add($entryA)
        [void]$session.Entries.Add($entryB)

        $completed = @(
            [pscustomobject]@{ Purpose = 'TCP/IP settings'; Original = 'P\old-a'; New = 'P\new-a'; Entry = $entryA }
            [pscustomobject]@{ Purpose = 'network setup';   Original = 'P\old-b'; New = 'P\new-b'; Entry = $entryB }
        )

        $reason = & $interfaceModule {
            param($c, $s)
            Complete-SpooferInterfaceRollback -Completed $c -Label 'Interface Test' -Because 'boom' -Session $s
        } $completed $session

        Assert-True ($reason -like '*rollback incomplete*') "expected the reason to report an incomplete rollback, got '$reason'"
        Assert-Equal 1 $session.Entries.Count
        Assert-True ([object]::ReferenceEquals($session.Entries[0], $entryB)) 'the entry left behind should be the one that is still on the new name'
    }

    Test-Case 'A clean rollback drops every entry and says so' {
        $keys = @{ 'P\new-a' = 'a' }
        & $interfaceModule $installFakes $keys $null

        $session = [pscustomobject]@{ Entries = (New-Object System.Collections.ArrayList) }
        $entryA  = [pscustomobject]@{ Label = 'a' }
        [void]$session.Entries.Add($entryA)

        $completed = @(
            [pscustomobject]@{ Purpose = 'TCP/IP settings'; Original = 'P\old-a'; New = 'P\new-a'; Entry = $entryA }
        )

        $reason = & $interfaceModule {
            param($c, $s)
            Complete-SpooferInterfaceRollback -Completed $c -Label 'Interface Test' -Because 'boom' -Session $s
        } $completed $session

        Assert-True ($reason -like '*rolled back*') "expected the reason to report a completed rollback, got '$reason'"
        Assert-True ($reason -notlike '*incomplete*') "a clean rollback should not be reported as incomplete, got '$reason'"
        Assert-Equal 0 $session.Entries.Count
    }

    Test-Case 'A GUID already naming a key is never handed out' {
        $keys = @{}
        & $interfaceModule $installFakes $keys $null

        $guid = & $interfaceModule { New-SpooferFreeInterfaceGuid }
        Assert-True ($guid -match '^\{[0-9a-fA-F-]{36}\}$') "expected a brace-form GUID, got '$guid'"

        # Every candidate now collides, which is the case that used to leave an
        # adapter with its references split across two names.
        & $interfaceModule { function script:Test-Path { param([string]$Path, [string]$LiteralPath) return $true } }

        $blocked = & $interfaceModule { New-SpooferFreeInterfaceGuid -Attempts 3 }
        Assert-Equal $null $blocked
    }

    Remove-Module -ModuleInfo $interfaceModule -Force
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
