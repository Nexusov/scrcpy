$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/launch-runtime.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-native-adapter-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$previousReconnectEnvironment = $env:SCRCPY_RECONNECT_SERIAL
$native = $null

try {
    $fakeProgram = @'
using System;
using System.Threading;
public static class NativeAdapterFixture {
    public static void Main(string[] arguments) {
        Console.WriteLine("reconnect=" + Environment.GetEnvironmentVariable("SCRCPY_RECONNECT_SERIAL"));
        Console.WriteLine("adb=" + Environment.GetEnvironmentVariable("ADB"));
        Console.WriteLine("arguments=" + String.Join("|", arguments));
        Console.Error.WriteLine("fixture diagnostic");
        if (Array.IndexOf(arguments, "--window-title=wait-for-stop") >= 0) {
            using (var stop = EventWaitHandle.OpenExisting(Environment.GetEnvironmentVariable("SCRCPY_STOP_EVENT"))) {
                if (!stop.WaitOne(3000)) { Environment.Exit(4); }
                Console.WriteLine("graceful-stop-complete");
            }
        }
        if (Array.IndexOf(arguments, "--window-title=ignore-stop") >= 0) {
            Thread.Sleep(10000);
        }
    }
}
'@
    Add-Type -TypeDefinition $fakeProgram -OutputAssembly (Join-Path $directory 'scrcpy.exe') -OutputType ConsoleApplication
    $env:SCRCPY_RECONNECT_SERIAL = 'parent sentinel'

    foreach ($mode in @('usb', 'auto')) {
        $logPath = Join-Path $directory 'last-run.log'
        Set-Content $logPath 'fixture'
        $configuration = [pscustomobject]@{ UsbSerial = 'phone-A'; WirelessService = ''; ConnectionMode = $mode }
        $target = @{ Serial = 'phone-A'; WirelessTarget = '192.168.1.2:40000' }
        $native = New-LaunchNativeProcess -RootDirectory $directory -Configuration $configuration -Target $target

        if (-not $native.Process.WaitForExit(3000)) {
            throw 'Native fixture did not exit.'
        }

        Close-LaunchNativeResources -Native $native
        $native = $null
        $log = Get-Content $logPath -Raw
        $expectedReconnect = 'reconnect=' + [Environment]::NewLine

        if ($mode -eq 'auto') {
            $expectedReconnect = 'reconnect=' + $target.WirelessTarget
        }

        if (-not $log.Contains($expectedReconnect) -or -not $log.Contains('adb=' + (Join-Path $directory 'adb.exe'))) {
            throw 'Native child environment did not match selected mode.'
        }

        if ($env:SCRCPY_RECONNECT_SERIAL -ne 'parent sentinel') {
            throw 'Native adapter changed the parent process environment.'
        }

        if (-not $log.Contains('--window-title=Phone-Seamless') -or -not $log.Contains('--pause-on-exit=false')) {
            throw 'Default launcher title or noninteractive exit policy was lost.'
        }

        if ((Get-Content (Join-Path $directory 'last-run-errors.log') -Raw).Trim() -ne 'fixture diagnostic') {
            throw 'Native error stream was not drained.'
        }
    }

    # Pass user values as individual native arguments, including Windows quoting edge cases.
    $settings = @{
        Reconnect = $false
        Options = @{ 'window-title' = 'A "quoted" title'; 'record' = 'C:\Videos\my clip.mkv'; 'max-fps' = '60'; 'no-window' = $true }
    }
    Set-Content $logPath 'fixture'
    $native = New-LaunchNativeProcess -RootDirectory $directory -Configuration $configuration -Target $target -Settings $settings
    $null = $native.Process.WaitForExit(3000)

    if ($native.ExpectsWindow) {
        throw 'A no-window session incorrectly requires a native window.'
    }

    Close-LaunchNativeResources -Native $native
    $native = $null
    $log = Get-Content $logPath -Raw

    if ($log.Contains('--window-title=Phone-Seamless')) {
        throw 'Custom title received a duplicate launcher default.'
    }

    foreach ($argument in @('--window-title=A "quoted" title', '--record=C:\Videos\my clip.mkv', '--max-fps=60', '--no-window')) {

        if (-not $log.Contains($argument)) {
            throw "Native argument did not round-trip: $argument"
        }
    }

    if (-not $log.Contains('reconnect=' + [Environment]::NewLine)) {
        throw 'Disabling reconnection left the native reconnect environment set.'
    }

    # An owned stop request lets the child drain and finalize before its resources close.
    Set-Content $logPath 'fixture'
    $settings = @{ Reconnect = $true; Options = @{ 'window-title' = 'wait-for-stop' } }
    $native = New-LaunchNativeProcess -RootDirectory $directory -Configuration $configuration -Target $target -Settings $settings
    $stopEvent = $native.StopEvent
    Close-LaunchNativeResources -Native $native
    $native = $null
    $log = Get-Content $logPath -Raw

    if (-not $log.Contains('graceful-stop-complete')) {
        throw 'Shutdown killed the child without waiting for graceful finalization.'
    }

    $disposed = $false

    try {
        $null = $stopEvent.Set()
    } catch [ObjectDisposedException] {
        $disposed = $true
    }

    if (-not $disposed) {
        throw 'Shutdown leaked the owned stop event.'
    }

    # A broken child cannot block launcher cleanup indefinitely; its forced stop is explicit in logs.
    $settings.Options['window-title'] = 'ignore-stop'
    $native = New-LaunchNativeProcess -RootDirectory $directory -Configuration $configuration -Target $target -Settings $settings
    $native.ShutdownTimeoutMilliseconds = 100
    Close-LaunchNativeResources -Native $native
    $native = $null

    if (-not (Get-Content (Join-Path $directory 'last-run-errors.log') -Raw).Contains('An active recording may be incomplete.')) {
        throw 'Forced shutdown did not report the recording finalization risk.'
    }

    Remove-Item -LiteralPath (Join-Path $directory 'scrcpy.exe')
    $failed = $false

    try {
        New-LaunchNativeProcess -RootDirectory $directory -Configuration $configuration -Target $target
    } catch {
        $failed = $true
    }

    if (-not $failed) {
        throw 'Missing native executable was silently accepted.'
    }

    $exclusiveFile = [IO.File]::Open((Join-Path $directory 'last-run.log'), 'Open', 'ReadWrite', 'None')
    $exclusiveFile.Dispose()
    Write-Output 'PASS: native process-local environment, mode flags, asynchronous logs and failed-start handle cleanup.'
} finally {

    if ($null -ne $native) {
        Close-LaunchNativeResources -Native $native
    }

    $env:SCRCPY_RECONNECT_SERIAL = $previousReconnectEnvironment
    $resolvedDirectory = (Resolve-Path $directory).ProviderPath

    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
