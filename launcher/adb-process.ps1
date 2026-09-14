# Check the explicit cancellation source shared with the operation owner.
function Test-AdbCancellation {
    param($Cancellation)

    if ($null -eq $Cancellation) {
        return $false
    }

    return [bool]$Cancellation.IsCancellationRequested
}

# Run only the current probe's ADB process with a cancellable, bounded wait.
function Invoke-AdbCommand {
    param([string]$RootDirectory, [string[]]$Arguments, [int]$TimeoutMilliseconds = 12000, $Cancellation)

    if (Test-AdbCancellation -Cancellation $Cancellation) {
        throw [OperationCanceledException]::new('Operation cancelled.')
    }

    foreach ($argument in $Arguments) {

        if ($argument -notmatch '^[A-Za-z0-9_:.=\-]+$') {
            throw 'Invalid ADB argument.'
        }
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'adb.exe'
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.WorkingDirectory = $RootDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB_MDNS_OPENSCREEN'] = '1'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $pollMilliseconds = 100
    $started = $false

    try {
        $null = $process.Start()
        $started = $true
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

        while (-not $process.WaitForExit($pollMilliseconds)) {
            if (Test-AdbCancellation -Cancellation $Cancellation) {
                throw [OperationCanceledException]::new('Operation cancelled.')
            }

            if ([DateTime]::UtcNow -ge $deadline) {
                throw [TimeoutException]::new('ADB timed out. Check the phone connection and try again.')
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.GetAwaiter().GetResult()
            Error = $errorTask.GetAwaiter().GetResult()
        }
    } finally {

        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        $process.Dispose()
    }
}

