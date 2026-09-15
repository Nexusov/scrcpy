. (Join-Path $PSScriptRoot 'launcher-core.ps1')
. (Join-Path $PSScriptRoot 'connection-core.ps1')
. (Join-Path $PSScriptRoot 'options-store.ps1')

# Connect controller operations to process and persistence adapters.
function New-LaunchDependencies {
    return @{
        GetConfiguration = { param($RootDirectory) Get-PhoneConfiguration -RootDirectory $RootDirectory }
        GetSettings = { param($RootDirectory) Get-ScrcpySettings -RootDirectory $RootDirectory }
        ConfigurationLock = { param($RootDirectory, $Action) Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action $Action }
        StartProbe = { param($RootDirectory, $Configuration, $Cancellation, $Progress) New-LaunchProbeWorker -RootDirectory $RootDirectory -Configuration $Configuration -Cancellation $Cancellation -Progress $Progress }
        StartNative = { param($RootDirectory, $Configuration, $Target, $Settings) New-LaunchNativeProcess -RootDirectory $RootDirectory -Configuration $Configuration -Target $Target -Settings $Settings }
        CloseNative = { param($Native) Close-LaunchNativeResources -Native $Native }
        StartSettings = { param($RootDirectory) Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $RootDirectory 'setup.ps1') + '"')) -WindowStyle Hidden -PassThru }
        Log = { param($RootDirectory, $Message) Add-Content -LiteralPath (Join-Path $RootDirectory 'last-run.log') -Value $Message }
    }
}

# Start discovery with explicit operation-local state in an independent runspace.
function New-LaunchProbeWorker {
    param($RootDirectory, $Configuration, $Cancellation, $Progress)
    $worker = [PowerShell]::Create()

    try {
        $null = $worker.AddScript({
            param($RootDirectory, $Configuration, $Cancellation, $Progress)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $RootDirectory 'launcher-core.ps1')
            . (Join-Path $RootDirectory 'connection-core.ps1')
            Find-ReadyPhone -RootDirectory $RootDirectory -Configuration $Configuration -Progress $Progress -Cancellation $Cancellation
        }).AddArgument($RootDirectory).AddArgument($Configuration).AddArgument($Cancellation).AddArgument($Progress)
        return @{ Worker = $worker; Handle = $worker.BeginInvoke() }
    } catch {
        $worker.Dispose()
        throw
    }
}

# Open one owned native client with process-local environment and asynchronous logs.
function New-LaunchNativeProcess {
    param($RootDirectory, $Configuration, $Target, $Settings)

    if ($null -eq $Settings) {
        $Settings = Get-ScrcpySettings -RootDirectory $RootDirectory
    }

    $native = @{
        Process = $null
        OutputFile = $null
        ErrorFile = $null
        OutputCopy = $null
        ErrorCopy = $null
        ExpectsWindow = -not $Settings.Options['no-window']
        StopEvent = $null
        ShutdownTimeoutMilliseconds = 10000
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'scrcpy.exe'
    $startInfo.WorkingDirectory = $RootDirectory
    $arguments = @('-s', [string]$Target.Serial)
    $arguments += @(Get-ScrcpyArguments -Settings $Settings)

    if (-not $Settings.Options.ContainsKey('window-title')) {
        $arguments += '--window-title=Phone-Seamless'
    }

    $arguments += '--pause-on-exit=false'
    $startInfo.Arguments = ConvertTo-ScrcpyCommandLine -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB'] = Join-Path $RootDirectory 'adb.exe'
    $startInfo.EnvironmentVariables['ADB_MDNS_OPENSCREEN'] = '1'
    $startInfo.EnvironmentVariables.Remove('SCRCPY_RECONNECT_SERIAL')

    $canReconnect = $Settings.Reconnect -and (Get-ConnectionMode -Configuration $Configuration) -ne 'usb'

    if ($canReconnect) {
        $startInfo.EnvironmentVariables['SCRCPY_RECONNECT_SERIAL'] = $Target.WirelessTarget
    }

    try {
        $stopEventName = 'Local\scrcpy-stop-' + [guid]::NewGuid().ToString('N')
        $native.StopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $stopEventName)
        $startInfo.EnvironmentVariables['SCRCPY_STOP_EVENT'] = $stopEventName
        $native.OutputFile = [IO.File]::Open((Join-Path $RootDirectory 'last-run.log'), 'Append', 'Write', 'ReadWrite')
        $native.ErrorFile = [IO.File]::Open((Join-Path $RootDirectory 'last-run-errors.log'), 'Create', 'Write', 'ReadWrite')
        $native.Process = [Diagnostics.Process]::Start($startInfo)
        $native.OutputCopy = $native.Process.StandardOutput.BaseStream.CopyToAsync($native.OutputFile)
        $native.ErrorCopy = $native.Process.StandardError.BaseStream.CopyToAsync($native.ErrorFile)
        return $native
    } catch {
        Close-LaunchNativeResources -Native $native
        throw
    }
}

# Reap only the owned child and drain its streams before releasing file handles.
function Close-LaunchNativeResources {
    param($Native)

    if ($null -eq $Native) {
        return
    }

    try {
        $process = $Native.Process
        $forced = $false

        if ($null -ne $process -and -not $process.HasExited) {
            $stopped = $false

            if ($null -ne $Native.StopEvent) {
                $null = $Native.StopEvent.Set()
                $stopped = $process.WaitForExit($Native.ShutdownTimeoutMilliseconds)
            }

            if (-not $stopped) {
                $forced = $true
                $process.Kill()
                $process.WaitForExit()
            }
        }

        foreach ($name in @('OutputCopy', 'ErrorCopy')) {

            if ($null -ne $Native[$name]) {
                $null = $Native[$name].GetAwaiter().GetResult()
            }
        }

        if ($forced -and $null -ne $Native.ErrorFile) {
            $message = [Text.Encoding]::UTF8.GetBytes("Native shutdown timed out; forced exit. An active recording may be incomplete.`r`n")
            $Native.ErrorFile.Write($message, 0, $message.Length)
        }
    } finally {
        foreach ($name in @('OutputFile', 'ErrorFile', 'Process', 'StopEvent')) {

            if ($null -ne $Native[$name]) {
                $Native[$name].Dispose()
            }
        }
    }
}
