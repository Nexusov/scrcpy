[CmdletBinding()]
param(
    [string]$TestDirectory,
    [string]$ResultDirectory,
    [string]$ArchivePath,
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-process.ps1')
Initialize-TestProcessJobType
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
$powerShellPath = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'

if (-not $TestDirectory) {
    $TestDirectory = Join-Path $repositoryDirectory 'tests'
}

if (-not $ResultDirectory) {
    $ResultDirectory = Join-Path $repositoryDirectory ('dist/test-results/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

if ($ArchivePath -and -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Requested archive does not exist: $ArchivePath"
}

if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 is required to run the test suite.'
}

$null = New-Item -ItemType Directory -Path $ResultDirectory -Force
$suites = @(Get-ChildItem -LiteralPath $TestDirectory -Filter '*.Tests.ps1' -File | Sort-Object Name)

if (-not $suites.Count) {
    throw "No test suites found in $TestDirectory"
}

$results = @()

foreach ($suite in $suites) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $eventName = 'Local\scrcpy-test-start-' + [guid]::NewGuid().ToString('N')
    $ready = $null
    $job = $null
    $process = $null
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + (Join-Path $PSScriptRoot 'test-host.ps1') + '" -SuitePath "' + $suite.FullName + '" -ReadyEvent "' + $eventName + '"'

    if ($suite.Name -eq 'package-layout.Tests.ps1' -and $ArchivePath) {
        $startInfo.Arguments += ' -ArchivePath "' + [IO.Path]::GetFullPath($ArchivePath) + '"'
    }

    $startInfo.WorkingDirectory = $repositoryDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $status = 'PASS'
    $exitCode = -1

    try {
        $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $eventName)
        $job = New-Object Seamless.TestProcessJob
        $process = [Diagnostics.Process]::Start($startInfo)
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $job.Attach($process.Handle)
        $null = $ready.Set()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $status = 'TIMEOUT'
            $job.Terminate()

            if (-not $process.WaitForExit(5000)) {
                throw 'The owned test process did not exit after job termination.'
            }
        }

        $exitCode = $process.ExitCode
        $job.Dispose()

        if ($status -ne 'TIMEOUT' -and $exitCode) {
            $status = 'FAIL'
        }

        if (-not $outputTask.Wait(5000) -or -not $errorTask.Wait(5000)) {
            throw 'Test output streams did not close after process completion.'
        }

        [IO.File]::WriteAllText((Join-Path $ResultDirectory ($suite.Name + '.stdout.log')), $outputTask.Result)
        [IO.File]::WriteAllText((Join-Path $ResultDirectory ($suite.Name + '.stderr.log')), $errorTask.Result)
    } catch {
        $status = 'ERROR'
        [IO.File]::WriteAllText((Join-Path $ResultDirectory ($suite.Name + '.runner.log')), $_.Exception.Message)

        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill()
        }
    } finally {

        if ($null -ne $job) {
            $job.Dispose()
        }

        if ($null -ne $ready) {
            $ready.Dispose()
        }

        $stopwatch.Stop()

        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    $results += [pscustomobject]@{ Suite = $suite.Name; Status = $status; ExitCode = $exitCode; Seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2) }
    Write-Host ("{0}: {1} ({2:N1}s)" -f $status, $suite.Name, $stopwatch.Elapsed.TotalSeconds)

    if ($status -ne 'PASS') {
        foreach ($suffix in @('stdout.log', 'stderr.log', 'runner.log')) {
            $logPath = Join-Path $ResultDirectory ($suite.Name + '.' + $suffix)

            if (Test-Path -LiteralPath $logPath) {
                Get-Content -LiteralPath $logPath -Tail 30 | ForEach-Object { Write-Host $_ }
            }
        }
    }
}

$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResultDirectory 'results.json') -Encoding UTF8
$failures = @($results | Where-Object { $_.Status -ne 'PASS' })
Write-Host ("{0}/{1} suites passed. Logs: {2}" -f ($results.Count - $failures.Count), $results.Count, $ResultDirectory)

if ($failures.Count) {
    exit 1
}
