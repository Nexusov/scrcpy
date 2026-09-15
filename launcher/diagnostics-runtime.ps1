. (Join-Path $PSScriptRoot 'options-store.ps1')
. (Join-Path $PSScriptRoot 'launcher-core.ps1')
. (Join-Path $PSScriptRoot 'connection-core.ps1')

# Run one catalogue-approved informational action without starting a stream.
function Invoke-ScrcpyDiagnostic {
    param([string]$RootDirectory, [string]$Name, $Settings, $Cancellation, [int]$TimeoutMilliseconds = 30000)
    $option = @(Get-ScrcpyOptionCatalog | Where-Object { $_.Name -eq $Name -and $_.Availability -eq 'action' })

    if ($option.Count -ne 1) {
        throw 'Choose an informational action from the settings catalogue.'
    }

    $arguments = @(('--' + $Name), '--pause-on-exit=false')

    if ($Name -notin @('help', 'version')) {
        $configuration = Get-PhoneConfiguration -RootDirectory $RootDirectory

        if ($null -eq $configuration) {
            throw 'Save device setup on the Connection tab before listing device capabilities.'
        }

        $target = Find-ReadyPhone -RootDirectory $RootDirectory -Configuration $configuration -Cancellation $Cancellation

        if ($null -eq $target) {
            throw 'Phone unavailable. Connect USB or enable Wireless debugging on the same network, then try again.'
        }

        $arguments += @('--serial=' + $target.Serial)

        if ($null -ne $Settings -and $Name -eq 'list-camera-sizes') {
            foreach ($name in @('camera-id', 'camera-facing')) {

                if ($Settings.Options.ContainsKey($name)) {
                    $arguments += '--' + $name + '=' + $Settings.Options[$name]
                }
            }
        }
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'scrcpy.exe'
    $startInfo.WorkingDirectory = $RootDirectory
    $startInfo.Arguments = ConvertTo-ScrcpyCommandLine -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB'] = Join-Path $RootDirectory 'adb.exe'
    $startInfo.EnvironmentVariables.Remove('SCRCPY_RECONNECT_SERIAL')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    $pollMilliseconds = 100

    try {

        if (Test-AdbCancellation -Cancellation $Cancellation) {
            throw [OperationCanceledException]::new('Cancelled.')
        }

        $started = $process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()

        while (-not $process.WaitForExit($pollMilliseconds)) {

            if (Test-AdbCancellation -Cancellation $Cancellation) {
                throw [OperationCanceledException]::new('Cancelled.')
            }

            if ($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw [TimeoutException]::new('The diagnostic timed out. Check your phone and try again.')
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Text = $output.GetAwaiter().GetResult() + [Environment]::NewLine + $errorOutput.GetAwaiter().GetResult()
        }
    } finally {

        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        $process.Dispose()
    }
}
