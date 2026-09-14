. (Join-Path $PSScriptRoot 'launcher-core.ps1')
. (Join-Path $PSScriptRoot 'connection-core.ps1')

# Connect controller operations to process and persistence adapters.
function New-LaunchDependencies {
    return @{
        GetConfiguration = { param($RootDirectory) Get-PhoneConfiguration -RootDirectory $RootDirectory }
        ConfigurationLock = { param($RootDirectory, $Action) Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action $Action }
        StartProbe = { param($RootDirectory, $Configuration, $Cancellation, $Progress) New-LaunchProbeWorker -RootDirectory $RootDirectory -Configuration $Configuration -Cancellation $Cancellation -Progress $Progress }
        StartNative = { param($RootDirectory, $Configuration, $Target) New-LaunchNativeProcess -RootDirectory $RootDirectory -Configuration $Configuration -Target $Target }
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
    param($RootDirectory, $Configuration, $Target)
    $native = @{
        Process = $null
        OutputFile = $null
        ErrorFile = $null
        OutputCopy = $null
        ErrorCopy = $null
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'scrcpy.exe'
    $startInfo.WorkingDirectory = $RootDirectory
    $startInfo.Arguments = '-s "' + $Target.Serial + '" --window-title=Phone-Seamless --pause-on-exit=false'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB'] = Join-Path $RootDirectory 'adb.exe'
    $startInfo.EnvironmentVariables['ADB_MDNS_OPENSCREEN'] = '1'
    $startInfo.EnvironmentVariables.Remove('SCRCPY_RECONNECT_SERIAL')

    if ((Get-ConnectionMode -Configuration $Configuration) -ne 'usb') {
        $startInfo.EnvironmentVariables['SCRCPY_RECONNECT_SERIAL'] = $Target.WirelessTarget
    }

    try {
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

        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        foreach ($name in @('OutputCopy', 'ErrorCopy')) {

            if ($null -ne $Native[$name]) {
                $null = $Native[$name].GetAwaiter().GetResult()
            }
        }
    } finally {
        foreach ($name in @('OutputFile', 'ErrorFile', 'Process')) {

            if ($null -ne $Native[$name]) {
                $Native[$name].Dispose()
            }
        }
    }
}
