$ErrorActionPreference = 'Stop'
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\launcher\instance.ps1'))
. $modulePath
$instanceName = 'scrcpy-test-' + [guid]::NewGuid().ToString('N')
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) $instanceName
$null = New-Item -ItemType Directory -Path $testDirectory
$primary = $null

# Exercise the public lock contract from a separate process and desktop-safe namespace.
function Invoke-InstanceTestChild {
    param([string]$ExpectedPrimary)
    $outputPath = Join-Path $testDirectory 'result.txt'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $testDirectory 'child.ps1') + '" -ModulePath "' + $modulePath + '" -InstanceName "' + $instanceName + '" -OutputPath "' + $outputPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)

    try {
        $errors = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Instance test child timed out.'
        }

        if ($process.ExitCode -ne 0) {
            throw $errors.GetAwaiter().GetResult()
        }

        if (([IO.File]::ReadAllText($outputPath)).Trim() -ne $ExpectedPrimary) {
            throw 'Unexpected primary-instance ownership.'
        }
    } finally {
        $process.Dispose()
    }
}

try {
    @'
param($ModulePath, $InstanceName, $OutputPath)
$ErrorActionPreference = 'Stop'
. $ModulePath
$instance = Enter-LauncherInstance -InstanceName $InstanceName
try {
    [IO.File]::WriteAllText($OutputPath, [string]$instance.IsPrimary)
} finally {
    Exit-LauncherInstance -Instance $instance
}
'@ | Set-Content -LiteralPath (Join-Path $testDirectory 'child.ps1') -Encoding UTF8
    $primary = Enter-LauncherInstance -InstanceName $instanceName

    if (-not $primary.IsPrimary) {
        throw 'Unique test namespace was already owned.'
    }

    Invoke-InstanceTestChild -ExpectedPrimary 'False'

    if (-not $primary.Signal.WaitOne(5000)) {
        throw 'Repeated launch failed to signal activation.'
    }

    Exit-LauncherInstance -Instance $primary
    $primary = $null
    Invoke-InstanceTestChild -ExpectedPrimary 'True'
    Write-Output 'PASS: independent-process instance exclusion, activation and ownership release.'
} finally {

    if ($null -ne $primary) {
        Exit-LauncherInstance -Instance $primary
    }

    $resolvedPath = (Resolve-Path -LiteralPath $testDirectory).ProviderPath

    if ((Split-Path -Parent $resolvedPath) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected instance fixture cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}
