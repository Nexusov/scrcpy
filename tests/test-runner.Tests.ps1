$ErrorActionPreference = 'Stop'
$runnerPath = Join-Path $PSScriptRoot '../scripts/test.ps1'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-runner-' + [guid]::NewGuid().ToString('N'))
$suiteDirectory = Join-Path $directory 'suites'
$resultDirectory = Join-Path $directory 'results'
$null = New-Item -ItemType Directory -Path $suiteDirectory -Force

try {
    Set-Content -LiteralPath (Join-Path $suiteDirectory '00-isolated.Tests.ps1') -Value @'
if ($PSVersionTable.PSVersion.Major -ne 5 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Runner used the wrong PowerShell host or apartment.'
}
$global:FixtureLeak = $true
'@
    Set-Content -LiteralPath (Join-Path $suiteDirectory '01-throw.Tests.ps1') -Value "throw 'intentional fixture failure'"
    Set-Content -LiteralPath (Join-Path $suiteDirectory '02-exit.Tests.ps1') -Value 'exit 9'
    Set-Content -LiteralPath (Join-Path $suiteDirectory '03-timeout.Tests.ps1') -Value @'
$child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'child.pid') -Value $child.Id
Start-Sleep -Seconds 30
'@
    Set-Content -LiteralPath (Join-Path $suiteDirectory '04-isolated.Tests.ps1') -Value "if (`$global:FixtureLeak) { throw 'Suite state leaked.' }"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath -TestDirectory $suiteDirectory -ResultDirectory $resultDirectory -TimeoutSeconds 5

    if ($LASTEXITCODE -eq 0) {
        throw 'Runner reported success despite failing and timed-out fixtures.'
    }

    $results = Get-Content -LiteralPath (Join-Path $resultDirectory 'results.json') -Raw | ConvertFrom-Json
    $statuses = @($results | Select-Object -ExpandProperty Status) -join ','

    if ($statuses -ne 'PASS,FAIL,FAIL,TIMEOUT,PASS') {
        throw ('Unexpected runner result sequence: ' + $statuses + '. Output: ' + ($output -join '; '))
    }

    $childId = [int](Get-Content -LiteralPath (Join-Path $suiteDirectory 'child.pid'))

    if ($null -ne (Get-Process -Id $childId -ErrorAction SilentlyContinue)) {
        throw 'Timed-out suite left its child process alive.'
    }

    $failureLog = Get-Content -LiteralPath (Join-Path $resultDirectory '01-throw.Tests.ps1.stderr.log') -Raw

    if ($failureLog -notmatch 'intentional fixture failure') {
        throw 'Failure output was not retained.'
    }

    Write-Output 'PASS: runner enforces PS5.1/STA, process isolation, failures, deadlines, owned tree cleanup and useful logs.'
} finally {
    $resolvedDirectory = (Resolve-Path $directory).ProviderPath

    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
