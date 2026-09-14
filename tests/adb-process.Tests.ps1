$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/adb-process.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-adb-' + [guid]::NewGuid().ToString('N'))
$unrelatedDirectory = Join-Path $directory 'unrelated'
$null = New-Item -ItemType Directory -Path $unrelatedDirectory -Force
$unrelatedProcess = $null
$cancellation = New-Object Threading.CancellationTokenSource

# Fail when the adapter violates process ownership or result semantics.
function Assert-Adb {
    param($Condition, $Message)

    if (-not $Condition) {
        throw $Message
    }
}

try {
    $fakeProgram = @'
using System;
using System.IO;
using System.Threading;
public static class AdbAdapterFixture {
    public static int Main(string[] arguments) {
        if (arguments.Length != 0 && arguments[0] == "quick") {
            Console.WriteLine("output"); Console.Error.WriteLine("diagnostic"); return 7;
        }
        File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"pid.txt"),System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(10000); return 0;
    }
}
'@
    Add-Type -TypeDefinition $fakeProgram -OutputAssembly (Join-Path $directory 'adb.exe') -OutputType ConsoleApplication
    Copy-Item (Join-Path $directory 'adb.exe') $unrelatedDirectory
    $unrelatedProcess = Start-Process -FilePath (Join-Path $unrelatedDirectory 'adb.exe') -WindowStyle Hidden -PassThru
    $result = Invoke-AdbCommand -RootDirectory $directory -Arguments @('quick')
    Assert-Adb ($result.ExitCode -eq 7 -and $result.Output.Trim() -eq 'output' -and $result.Error.Trim() -eq 'diagnostic') 'Adapter lost exit code or output streams.'
    $timedOut = $false

    try {
        Invoke-AdbCommand -RootDirectory $directory -Arguments @('devices') -TimeoutMilliseconds 300
    } catch [TimeoutException] {
        $timedOut = $true
    }

    Assert-Adb $timedOut 'Adapter did not distinguish timeout.'
    $ownedId = [int](Get-Content (Join-Path $directory 'pid.txt'))
    Assert-Adb ($null -eq (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Timed-out child was not reaped.'
    Assert-Adb (-not $unrelatedProcess.HasExited) 'Timeout stopped an unrelated ADB process.'
    Remove-Item -LiteralPath (Join-Path $directory 'pid.txt')
    $cancellation.Cancel()
    $cancelled = $false

    try {
        Invoke-AdbCommand -RootDirectory $directory -Arguments @('devices') -Cancellation $cancellation
    } catch [OperationCanceledException] {
        $cancelled = $true
    }

    Assert-Adb ($cancelled -and -not (Test-Path (Join-Path $directory 'pid.txt'))) 'Pre-cancelled operation spawned a process.'
    $invalidRejected = $false

    try {
        Invoke-AdbCommand -RootDirectory $directory -Arguments @('devices;invalid')
    } catch {
        $invalidRejected = $true
    }

    Assert-Adb ($invalidRejected -and -not (Test-Path (Join-Path $directory 'pid.txt'))) 'Invalid argument spawned a process.'
    Write-Output 'PASS: streams/exit status, timeout cleanup, unrelated process survival, pre-cancellation and argument rejection.'
} finally {
    $cancellation.Dispose()

    if ($null -ne $unrelatedProcess) {

        if (-not $unrelatedProcess.HasExited) {
            $unrelatedProcess.Kill()
            $unrelatedProcess.WaitForExit()
        }

        $unrelatedProcess.Dispose()
    }

    $resolvedDirectory = (Resolve-Path $directory).ProviderPath

    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
