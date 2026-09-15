$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/diagnostics-runtime.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-diagnostic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$cancellation = New-Object Threading.CancellationTokenSource

try {
    $program = @'
using System;
public static class DiagnosticFixture {
    public static void Main(string[] arguments) {
        Console.WriteLine(String.Join("|", arguments));
        Console.Error.WriteLine("diagnostic output");
        if (Array.IndexOf(arguments, "--version") >= 0) System.Threading.Thread.Sleep(5000);
    }
}
'@
    Add-Type -TypeDefinition $program -OutputAssembly (Join-Path $directory 'scrcpy.exe') -OutputType ConsoleApplication
    $result = Invoke-ScrcpyDiagnostic -RootDirectory $directory -Name 'help'

    if ($result.ExitCode -ne 0 -or -not $result.Text.Contains('--help|--pause-on-exit=false') -or -not $result.Text.Contains('diagnostic output')) {
        throw 'Help failed without a phone or lost native output.'
    }

    foreach ($action in @('record', 'bogus', 'list-encoders')) {
        $rejected = $false

        try {
            Invoke-ScrcpyDiagnostic -RootDirectory $directory -Name $action
        } catch {
            $rejected = $true
        }

        if (-not $rejected) {
            throw "Unsafe/unavailable diagnostic accepted: $action"
        }
    }

    $timedOut = $false

    try {
        Invoke-ScrcpyDiagnostic -RootDirectory $directory -Name 'version' -TimeoutMilliseconds 100
    } catch [TimeoutException] {
        $timedOut = $true
    }

    if (-not $timedOut) {
        throw 'Diagnostic process ignored deadline.'
    }

    $cancellation.Cancel()
    $cancelled = $false

    try {
        Invoke-ScrcpyDiagnostic -RootDirectory $directory -Name 'help' -Cancellation $cancellation
    } catch [OperationCanceledException] {
        $cancelled = $true
    }

    if (-not $cancelled) {
        throw 'Diagnostic ignored cancellation.'
    }

    Write-Output 'PASS: informational allowlist, phone-free help, missing device, native output, deadline and cancellation.'
} finally {
    $cancellation.Dispose()
    $resolved = (Resolve-Path -LiteralPath $directory).ProviderPath

    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected diagnostic fixture path.'
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}
