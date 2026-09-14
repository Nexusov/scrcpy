$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/launch-runtime.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-native-adapter-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$previousReconnectEnvironment = $env:SCRCPY_RECONNECT_SERIAL
$native = $null

try {
    $fakeProgram = @'
using System;
public static class NativeAdapterFixture {
    public static void Main(string[] arguments) {
        Console.WriteLine("reconnect=" + Environment.GetEnvironmentVariable("SCRCPY_RECONNECT_SERIAL"));
        Console.WriteLine("adb=" + Environment.GetEnvironmentVariable("ADB"));
        Console.WriteLine("arguments=" + String.Join("|", arguments));
        Console.Error.WriteLine("fixture diagnostic");
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

        if ((Get-Content (Join-Path $directory 'last-run-errors.log') -Raw).Trim() -ne 'fixture diagnostic') {
            throw 'Native error stream was not drained.'
        }
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
