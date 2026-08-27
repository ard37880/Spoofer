<#
.SYNOPSIS
    Browser cookies and site storage, the identity a website actually tracks you by.
.DESCRIPTION
    Nothing a web page runs can read a machine GUID or a disk serial. The
    browser sandbox does not expose them. What a site does have is what it put
    on the machine itself: cookies, local and session storage, IndexedDB and
    service worker registrations. Those are the identifiers this module clears.

    Every file is copied into the backup session before it is removed, so a
    restore signs you back in to everything.

    What this does NOT change is the browser's fingerprint: the canvas and WebGL
    hashes, the installed font list, screen geometry, the AudioContext signature
    and the TLS handshake shape. Those are properties of the browser and the
    hardware it is running on, not files on disk, and clearing storage does not
    move them. See docs/limitations.md.
.NOTES
    A browser holds its databases open, so the browser has to be closed. This
    module reports which ones are running rather than corrupting a live profile.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.psm1')      -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'BackupStore.psm1') -DisableNameChecking

# Chromium keeps its per-profile state in a fixed layout, so one description
# covers Chrome, Edge, Brave, Vivaldi and Opera.
$script:ChromiumStores = @(
    'Network\Cookies'
    'Cookies'
    'Local Storage'
    'Session Storage'
    'IndexedDB'
    'Service Worker'
    'Local Extension Settings'
)

$script:FirefoxStores = @(
    'cookies.sqlite'
    'webappsstore.sqlite'
    'storage'
    'sessionstore.jsonlz4'
)

function Get-SpooferBrowser {
    <#
    .SYNOPSIS
        Installed browsers, their profile directories and whether they are running.
    #>
    [CmdletBinding()]
    param()

    $local   = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    if (-not $local -or -not $roaming) { return @() }

    $chromium = @(
        @{ Name = 'Chrome';   Process = 'chrome';   Root = Join-Path $local 'Google\Chrome\User Data' }
        @{ Name = 'Edge';     Process = 'msedge';   Root = Join-Path $local 'Microsoft\Edge\User Data' }
        @{ Name = 'Brave';    Process = 'brave';    Root = Join-Path $local 'BraveSoftware\Brave-Browser\User Data' }
        @{ Name = 'Vivaldi';  Process = 'vivaldi';  Root = Join-Path $local 'Vivaldi\User Data' }
        @{ Name = 'Opera';    Process = 'opera';    Root = Join-Path $roaming 'Opera Software\Opera Stable' }
    )

    foreach ($browser in $chromium) {
        if (-not (Test-Path -LiteralPath $browser.Root)) { continue }

        # Chromium calls the first profile Default and the rest "Profile N".
        # Opera puts its state straight in the root instead.
        $profiles = @(Get-ChildItem -LiteralPath $browser.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
        if ($profiles.Count -eq 0) { $profiles = @(Get-Item -LiteralPath $browser.Root) }

        foreach ($profileDir in $profiles) {
            [pscustomobject]@{
                Browser   = $browser.Name
                Process   = $browser.Process
                Profile   = $profileDir.Name
                Path      = $profileDir.FullName
                Stores    = $script:ChromiumStores
                IsRunning = [bool](Get-Process -Name $browser.Process -ErrorAction SilentlyContinue)
            }
        }
    }

    $firefoxRoot = Join-Path $roaming 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $firefoxRoot) {
        foreach ($profileDir in (Get-ChildItem -LiteralPath $firefoxRoot -Directory -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{
                Browser   = 'Firefox'
                Process   = 'firefox'
                Profile   = $profileDir.Name
                Path      = $profileDir.FullName
                Stores    = $script:FirefoxStores
                IsRunning = [bool](Get-Process -Name 'firefox' -ErrorAction SilentlyContinue)
            }
        }
    }
}

function Get-SpooferBrowserStore {
    <#
    .SYNOPSIS
        The storage paths that exist for one profile, with their sizes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$BrowserProfile
    )

    foreach ($store in $BrowserProfile.Stores) {
        $path = Join-Path $BrowserProfile.Path $store
        if (-not (Test-Path -LiteralPath $path)) { continue }

        $bytes = 0
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($item.PSIsContainer) {
                $bytes = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                if (-not $bytes) { $bytes = 0 }
            } else {
                $bytes = $item.Length
            }
        } catch {
            Write-SpooferLog -Level Debug -Message "Could not size ${path}: $($_.Exception.Message)"
        }

        [pscustomobject]@{
            Store       = $store
            Path        = $path
            IsContainer = (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).PSIsContainer
            Bytes       = [long]$bytes
        }
    }
}

Register-SpooferRestoreHandler -Type 'BrowserStore' -Handler {
    param($Entry)

    $source = Join-Path $Entry.SessionPath $Entry.Archive
    if (-not (Test-Path -LiteralPath $source)) {
        throw "The saved copy of $($Entry.Store) is missing from the backup."
    }

    if (Test-Path -LiteralPath $Entry.Path) {
        Remove-Item -LiteralPath $Entry.Path -Recurse -Force -ErrorAction SilentlyContinue
    }

    $parent = Split-Path -Path $Entry.Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $source -Destination $Entry.Path -Recurse -Force -ErrorAction Stop
    return "$($Entry.Browser) $($Entry.Store) restored."
}

function Get-SpooferProviderDefinition {
    [pscustomobject]@{
        Name           = 'browser'
        Title          = 'Browser cookies and site storage'
        Tier           = 'Risky'
        RequiresReboot = $false
        Description    = 'Clears cookies, local and session storage, IndexedDB and service workers for every installed browser profile. This is what a website actually tracks you by. Everything is copied into the backup first, so a restore signs you back in.'
        Targets        = @(
            'Chrome, Edge, Brave, Vivaldi and Opera profiles under LOCALAPPDATA'
            'Firefox profiles under APPDATA'
        )

        GetState = {
            param($Context)

            $profiles = @(Get-SpooferBrowser)
            if ($profiles.Count -eq 0) {
                return @([pscustomobject]@{ Item = 'Browsers'; Value = 'none found'; Note = '' })
            }

            foreach ($browserProfile in $profiles) {
                $stores = @(Get-SpooferBrowserStore -BrowserProfile $browserProfile)
                $total  = ($stores | Measure-Object -Property Bytes -Sum).Sum
                if (-not $total) { $total = 0 }

                $note = '{0} stores' -f $stores.Count
                if ($browserProfile.IsRunning) { $note += ', running - close it before clearing' }

                [pscustomobject]@{
                    Item  = '{0} [{1}]' -f $browserProfile.Browser, $browserProfile.Profile
                    Value = '{0:N1} MB' -f ($total / 1MB)
                    Note  = $note
                }
            }
        }

        Invoke = {
            param($Session, $Context)

            $profiles = @(Get-SpooferBrowser)
            if ($profiles.Count -eq 0) {
                Write-SpooferLog -Level Warn -Message 'No browser profiles found; nothing to clear.'
                return @()
            }

            $running = @($profiles | Where-Object { $_.IsRunning } | ForEach-Object { $_.Browser } | Sort-Object -Unique)
            if ($running.Count -and -not $Context.DryRun) {
                Write-SpooferLog -Level Error -Message ('These browsers are running: {0}. Close them and run again; clearing a live profile corrupts it.' -f ($running -join ', '))
                return @()
            }

            $results = New-Object System.Collections.ArrayList

            foreach ($browserProfile in $profiles) {
                foreach ($store in (Get-SpooferBrowserStore -BrowserProfile $browserProfile)) {

                    $label = '{0} {1} {2}' -f $browserProfile.Browser, $browserProfile.Profile, $store.Store
                    $size  = '{0:N1} MB' -f ($store.Bytes / 1MB)

                    if ($Context.DryRun) {
                        Write-SpooferChange -Label $label -OldValue $size -NewValue 'cleared' -Simulated
                        [void]$results.Add([pscustomobject]@{
                            Label = $label; OldValue = $size; NewValue = 'cleared'
                            Changed = $false; Simulated = $true; Skipped = $false; Reason = ''
                        })
                        continue
                    }

                    try {
                        if ($Session) {
                            $safeName = ('{0}-{1}-{2}' -f $browserProfile.Browser, $browserProfile.Profile, $store.Store) -replace '[^A-Za-z0-9._-]', '_'
                            $target   = New-SpooferBackupFilePath -Session $Session -Name $safeName

                            Copy-Item -LiteralPath $store.Path -Destination $target -Recurse -Force -ErrorAction Stop

                            Add-SpooferBackupEntry -Session $Session -Type 'BrowserStore' -Module 'browser' -Label $label -Data @{
                                Browser     = $browserProfile.Browser
                                Store       = $store.Store
                                Path        = $store.Path
                                SessionPath = $Session.Path
                                Archive     = ('files\{0}' -f $safeName)
                            } | Out-Null
                        }

                        Remove-Item -LiteralPath $store.Path -Recurse -Force -ErrorAction Stop

                        Write-SpooferChange -Label $label -OldValue $size -NewValue 'cleared'
                        [void]$results.Add([pscustomobject]@{
                            Label = $label; OldValue = $size; NewValue = 'cleared'
                            Changed = $true; Simulated = $false; Skipped = $false; Reason = ''
                        })
                    } catch {
                        Write-SpooferLog -Level Error -Message "$($label): $($_.Exception.Message)"
                        [void]$results.Add([pscustomobject]@{
                            Label = $label; OldValue = $size; NewValue = 'cleared'
                            Changed = $false; Simulated = $false; Skipped = $true; Reason = $_.Exception.Message
                        })
                    }
                }
            }

            return @($results)
        }
    }
}

Export-ModuleMember -Function 'Get-SpooferProviderDefinition'
