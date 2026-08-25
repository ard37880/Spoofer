<#
.SYNOPSIS
    P/Invoke helpers that the pure-PowerShell layers cannot express: enabling
    token privileges (needed to take ownership of protected registry keys) and
    locked, sector-aligned access to a volume's boot sector.
.NOTES
    The type is compiled once per session. On a non-Windows host compilation is
    skipped so the rest of the toolkit still imports for testing.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:NativeReady = $false

$script:Source = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Spoofer
{
    public static class Native
    {
        // ---- token privileges -------------------------------------------------

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            public LUID_AND_ATTRIBUTES Privilege;
        }

        private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
        private const uint TOKEN_ADJUST_PRIVILEGES = 0x00000020;
        private const uint TOKEN_QUERY = 0x00000008;

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(
            IntPtr tokenHandle, bool disableAll, ref TOKEN_PRIVILEGES newState,
            uint bufferLength, IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        /// <summary>Enables a privilege already present in the process token, e.g. SeTakeOwnershipPrivilege.</summary>
        public static void EnablePrivilege(string privilegeName)
        {
            IntPtr token;
            if (!OpenProcessToken(Process.CurrentProcessHandle(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed.");

            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, privilegeName, out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed for " + privilegeName + ".");

                TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
                privileges.PrivilegeCount = 1;
                privileges.Privilege.Luid = luid;
                privileges.Privilege.Attributes = SE_PRIVILEGE_ENABLED;

                if (!AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges failed.");

                // AdjustTokenPrivileges reports success even when it silently drops
                // a privilege the token does not hold, so the last error is checked.
                int error = Marshal.GetLastWin32Error();
                if (error == 1300) // ERROR_NOT_ALL_ASSIGNED
                    throw new InvalidOperationException("The privilege " + privilegeName + " is not held by this process.");
            }
            finally
            {
                CloseHandle(token);
            }
        }

        private static class Process
        {
            [DllImport("kernel32.dll")]
            private static extern IntPtr GetCurrentProcess();
            public static IntPtr CurrentProcessHandle() { return GetCurrentProcess(); }
        }

        // ---- raw volume access ------------------------------------------------

        private const uint GENERIC_READ  = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ  = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;

        private const uint FSCTL_LOCK_VOLUME     = 0x00090018;
        private const uint FSCTL_UNLOCK_VOLUME   = 0x0009001C;
        private const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFileW(
            string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
            uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle device, uint controlCode, IntPtr inBuffer, uint inBufferSize,
            IntPtr outBuffer, uint outBufferSize, out uint bytesReturned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(
            SafeFileHandle handle, byte[] buffer, uint bytesToRead, out uint bytesRead, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(
            SafeFileHandle handle, byte[] buffer, uint bytesToWrite, out uint bytesWritten, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(
            SafeFileHandle handle, long distance, IntPtr newPointer, uint moveMethod);

        private static SafeFileHandle OpenVolume(string volumePath, bool writable)
        {
            // Direct volume I/O must be sector aligned. Every call here reads or
            // writes exactly one sector at offset zero, which satisfies that, so
            // FILE_FLAG_NO_BUFFERING (and its buffer-address alignment rules) is
            // deliberately not used.
            uint access = writable ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ;
            uint flags = writable ? FILE_FLAG_WRITE_THROUGH : 0u;

            SafeFileHandle handle = CreateFileW(
                volumePath, access, FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);

            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open " + volumePath + ".");

            return handle;
        }

        private static bool Control(SafeFileHandle handle, uint code)
        {
            uint returned;
            return DeviceIoControl(handle, code, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero);
        }

        private static void Rewind(SafeFileHandle handle)
        {
            if (!SetFilePointerEx(handle, 0, IntPtr.Zero, 0 /* FILE_BEGIN */))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetFilePointerEx failed.");
        }

        /// <summary>Reads the first sector of a volume, e.g. ReadBootSector(@"\\.\D:", 512).</summary>
        public static byte[] ReadBootSector(string volumePath, int sectorSize)
        {
            using (SafeFileHandle handle = OpenVolume(volumePath, false))
            {
                byte[] buffer = new byte[sectorSize];
                uint read;
                Rewind(handle);
                if (!ReadFile(handle, buffer, (uint)sectorSize, out read, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadFile failed on " + volumePath + ".");
                if (read != sectorSize)
                    throw new IOException("Short read from " + volumePath + ": " + read + " of " + sectorSize + " bytes.");
                return buffer;
            }
        }

        /// <summary>
        /// Writes the first sector of a volume. The volume is locked first; when
        /// allowDismount is set and the lock fails because handles are open, the
        /// volume is dismounted instead so Windows re-reads the sector on next access.
        /// </summary>
        public static void WriteBootSector(string volumePath, byte[] sector, bool allowDismount)
        {
            using (SafeFileHandle handle = OpenVolume(volumePath, true))
            {
                bool locked = Control(handle, FSCTL_LOCK_VOLUME);
                if (!locked)
                {
                    if (!allowDismount)
                        throw new IOException("Could not lock " + volumePath + "; files on it are still open.");
                    if (!Control(handle, FSCTL_DISMOUNT_VOLUME))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not lock or dismount " + volumePath + ".");
                }

                try
                {
                    uint written;
                    Rewind(handle);
                    if (!WriteFile(handle, sector, (uint)sector.Length, out written, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteFile failed on " + volumePath + ".");
                    if (written != sector.Length)
                        throw new IOException("Short write to " + volumePath + ": " + written + " of " + sector.Length + " bytes.");
                }
                finally
                {
                    // Closing the handle would release the lock anyway; unlocking
                    // explicitly remounts the volume without waiting for the close.
                    if (locked) Control(handle, FSCTL_UNLOCK_VOLUME);
                }
            }
        }
    }
}
'@

function Initialize-SpooferNative {
    <#
    .SYNOPSIS
        Compiles the interop type. Safe to call repeatedly.
    .OUTPUTS
        $true when the native helpers are usable in this session.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:NativeReady) { return $true }

    if (-not (Test-SpooferOnWindows)) {
        Write-SpooferLog -Level Debug -Message 'Native helpers skipped: not running on Windows.'
        return $false
    }

    if ('Spoofer.Native' -as [type]) {
        $script:NativeReady = $true
        return $true
    }

    try {
        Add-Type -TypeDefinition $script:Source -Language CSharp -ErrorAction Stop
        $script:NativeReady = $true
        Write-SpooferLog -Level Debug -Message 'Native interop compiled.'
    } catch {
        Write-SpooferLog -Level Warn -Message "Native interop unavailable: $($_.Exception.Message)"
        $script:NativeReady = $false
    }

    return $script:NativeReady
}

function Test-SpooferNativeReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:NativeReady
}

function Enable-SpooferPrivilege {
    <#
    .SYNOPSIS
        Enables a privilege the process already holds but that is disabled by default.
    .DESCRIPTION
        Taking ownership of a TrustedInstaller-owned registry key needs
        SeTakeOwnershipPrivilege, which is present but disabled in an elevated
        token until it is explicitly switched on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege', 'SeSecurityPrivilege')]
        [string]$Privilege
    )

    if (-not (Initialize-SpooferNative)) { return $false }

    try {
        [Spoofer.Native]::EnablePrivilege($Privilege)
        Write-SpooferLog -Level Debug -Message "Enabled $Privilege."
        return $true
    } catch {
        Write-SpooferLog -Level Debug -Message "Could not enable ${Privilege}: $($_.Exception.Message)"
        return $false
    }
}

function Read-SpooferBootSector {
    <#
    .SYNOPSIS
        Reads the first sector of a volume, e.g. -DriveLetter D.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,

        [ValidateSet(512, 1024, 2048, 4096)]
        [int]$SectorSize = 512
    )

    if (-not (Initialize-SpooferNative)) {
        throw 'Native interop is unavailable, so raw volume access is not possible.'
    }

    $path = '\\.\{0}:' -f $DriveLetter.ToUpperInvariant()
    return ,([Spoofer.Native]::ReadBootSector($path, $SectorSize))
}

function Write-SpooferBootSector {
    <#
    .SYNOPSIS
        Writes the first sector of a volume back, locking or dismounting it first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [byte[]]$Sector,

        [switch]$AllowDismount
    )

    if (-not (Initialize-SpooferNative)) {
        throw 'Native interop is unavailable, so raw volume access is not possible.'
    }

    $path = '\\.\{0}:' -f $DriveLetter.ToUpperInvariant()
    [Spoofer.Native]::WriteBootSector($path, $Sector, [bool]$AllowDismount)
}

Export-ModuleMember -Function @(
    'Initialize-SpooferNative'
    'Test-SpooferNativeReady'
    'Enable-SpooferPrivilege'
    'Read-SpooferBootSector'
    'Write-SpooferBootSector'
)
