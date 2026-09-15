. (Join-Path $PSScriptRoot 'configuration-store.ps1')
. (Join-Path $PSScriptRoot 'connection-core.ps1')

# Create controller state without constructing windows or starting processes.
function New-LaunchSession {
    param([string]$RootDirectory, [hashtable]$Dependencies)
    $configuration = & $Dependencies.GetConfiguration $RootDirectory
    $settingsError = ''

    try {
        $settings = & $Dependencies.GetSettings $RootDirectory
    } catch {
        $settings = @{ Options = @{}; Reconnect = $true }
        $settingsError = $_.Exception.Message
    }
    $hint = 'Complete Settings to connect your phone.'

    if ($null -ne $configuration) {
        $hint = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $configuration)
    }

    $session = @{
        RootDirectory = $RootDirectory
        Dependencies = $Dependencies
        Configuration = $configuration
        Settings = $settings
        Phase = 'Waiting'
        Generation = 0
        Probe = $null
        Native = $null
        SettingsProcess = $null
        SettingsRequested = ($null -eq $configuration)
        Started = [DateTime]::UtcNow
        NextProbe = [DateTime]::MinValue
        NativeStarted = $null
        Progress = [hashtable]::Synchronized(@{ Status = '' })
        Presentation = @{
            Status = 'Connecting to your phone...'
            Hint = $hint
            Visible = $true
            FocusRequested = $false
        }
        Timing = @{
            RetrySeconds = 2
            WaitingSeconds = 10
            NativeStartupSeconds = 30
        }
    }

    if ($settingsError) {
        $session.SettingsRequested = $false
        Set-LaunchFailure -Session $session -Message 'Saved scrcpy settings are invalid. Open Settings to correct them.'
        & $Dependencies.Log $RootDirectory $settingsError
    }

    return $session
}

# Expose presentation data without leaking controls into connection decisions.
function Get-LaunchPresentation {
    param($Session)
    $canChangeSettings = $Session.Phase -in @('Waiting', 'Probing', 'Failed') -and -not $Session.SettingsRequested
    return @{
        Status = $Session.Presentation.Status
        Hint = $Session.Presentation.Hint
        Visible = $Session.Presentation.Visible
        FocusRequested = $Session.Presentation.FocusRequested
        CloseRequested = $Session.Phase -eq 'Closing'
        RetryEnabled = $canChangeSettings
        SettingsEnabled = $canChangeSettings
        FocusProcess = Get-LaunchFocusProcess -Session $Session
    }
}

# Select the current owned window as the target for a repeated launch.
function Get-LaunchFocusProcess {
    param($Session)

    if ($null -ne $Session.SettingsProcess) {
        return $Session.SettingsProcess
    }

    if ($null -ne $Session.Native) {
        return $Session.Native.Process
    }

    return $null
}

# Discard current discovery before reading fresh saved settings.
function Request-LaunchRetry {
    param($Session)

    if ($Session.Phase -notin @('Waiting', 'Probing', 'Failed') -or $Session.SettingsRequested) {
        return
    }

    $Session.Generation++

    if ($null -ne $Session.Probe) {
        $Session.Probe.Cancellation.Cancel()
    }

    $Session.Progress = [hashtable]::Synchronized(@{ Status = '' })
    $Session.Configuration = & $Session.Dependencies.GetConfiguration $Session.RootDirectory
    $Session.Settings = & $Session.Dependencies.GetSettings $Session.RootDirectory

    if ($null -eq $Session.Configuration) {
        Set-LaunchFailure -Session $Session -Message 'Complete Settings, then retry.'
        return
    }

    $Session.Phase = 'Waiting'
    $Session.Presentation.Hint = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $Session.Configuration)
    $Session.Presentation.Status = 'Connecting to your phone...'
    $Session.NextProbe = [DateTime]::MinValue
    $Session.Started = [DateTime]::UtcNow
}

# Queue Settings until active discovery has released its owned process.
function Request-LaunchSettings {
    param($Session)

    if ($Session.Phase -notin @('Waiting', 'Probing', 'Failed')) {
        return
    }

    $Session.SettingsRequested = $true
    $Session.Generation++

    if ($null -ne $Session.Probe) {
        $Session.Probe.Cancellation.Cancel()
    }

    $Session.Presentation.Status = 'Finishing the current check before opening settings...'
}

# Let the Settings child finish its own cancellation before closing the launcher.
function Request-LaunchClose {
    param($Session)

    if ($null -ne $Session.SettingsProcess -and -not $Session.SettingsProcess.HasExited) {
        $Session.Presentation.FocusRequested = $true
        return $false
    }

    $Session.Phase = 'Closing'
    $Session.Generation++

    if ($null -ne $Session.Probe) {
        $Session.Probe.Cancellation.Cancel()
    }

    return $true
}

# Pause automatic retries after a recoverable startup or configuration error.
function Set-LaunchFailure {
    param($Session, [string]$Message)
    $Session.Phase = 'Failed'
    $Session.Presentation.Visible = $true
    $Session.Presentation.Status = $Message
}

# Start one probe with a detached configuration snapshot and independent cancellation.
function Start-LaunchProbe {
    param($Session)
    $configuration = $Session.Configuration
    $snapshot = [pscustomobject]@{
        UsbSerial = [string]$configuration.UsbSerial
        WirelessService = [string]$configuration.WirelessService
        ConnectionMode = Get-ConnectionMode -Configuration $configuration
    }
    $Session.Generation++
    $cancellation = New-Object Threading.CancellationTokenSource
    $progress = [hashtable]::Synchronized(@{ Status = '' })

    try {
        $work = & $Session.Dependencies.StartProbe $Session.RootDirectory $snapshot $cancellation $progress
        $Session.Probe = @{
            Work = $work
            Configuration = $snapshot
            Generation = $Session.Generation
            Cancellation = $cancellation
        }
        $Session.Progress = $progress
        $Session.Phase = 'Probing'
    } catch {
        $cancellation.Dispose()
        throw
    }
}

# Verify persisted identity while holding the same lock used by saving and reset.
function Accept-LaunchProbe {
    param($Session, $Probe, $Target)
    $canAccept = $Probe.Generation -eq $Session.Generation -and
        $Session.Phase -notin @('Closing', 'Failed') -and -not $Session.SettingsRequested

    if (-not $canAccept) {
        return
    }

    & $Session.Dependencies.ConfigurationLock $Session.RootDirectory {
        $configuration = & $Session.Dependencies.GetConfiguration $Session.RootDirectory

        if ($null -eq $configuration) {
            $Session.Configuration = $null
            Set-LaunchFailure -Session $Session -Message 'Device setup was reset. Complete Settings, then retry.'
            return
        }

        $snapshot = $Probe.Configuration
        $changed = $configuration.UsbSerial -cne $snapshot.UsbSerial -or
            $configuration.WirelessService -cne $snapshot.WirelessService -or
            (Get-ConnectionMode -Configuration $configuration) -ne $snapshot.ConnectionMode

        if ($changed) {
            $Session.Configuration = $configuration
            $Session.Progress.Status = ''
            $Session.Started = [DateTime]::UtcNow
            $Session.NextProbe = [DateTime]::MinValue
            $Session.Presentation.Hint = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $configuration)
            return
        }

        if ($null -eq $Target) {
            return
        }

        $Session.Settings = & $Session.Dependencies.GetSettings $Session.RootDirectory
        $Session.Native = & $Session.Dependencies.StartNative $Session.RootDirectory $configuration $Target $Session.Settings
        $Session.NativeStarted = [DateTime]::UtcNow
        $Session.Phase = 'Starting'
        $Session.Presentation.Status = 'Opening your phone screen...'
    }
}

# Dispose a finished probe before scheduling another attempt.
function Complete-LaunchProbe {
    param($Session)
    $probe = $Session.Probe
    $targets = @()

    try {
        $targets = @($probe.Work.Worker.EndInvoke($probe.Work.Handle))
    } catch {
        & $Session.Dependencies.Log $Session.RootDirectory $_.Exception.Message
    } finally {
        $probe.Work.Worker.Dispose()
        $probe.Cancellation.Dispose()
        $Session.Probe = $null
        $Session.NextProbe = [DateTime]::UtcNow.AddSeconds($Session.Timing.RetrySeconds)
    }

    if ($Session.Phase -eq 'Probing') {
        $Session.Phase = 'Waiting'
    }

    if ($probe.Generation -ne $Session.Generation) {
        $Session.NextProbe = [DateTime]::MinValue
        return
    }

    Accept-LaunchProbe -Session $Session -Probe $probe -Target ($targets | Select-Object -First 1)
}

# Render waiting progress while leaving connection attempts unlimited.
function Update-LaunchWaitingStatus {
    param($Session)
    $status = [string]$Session.Progress.Status

    if (([DateTime]::UtcNow - $Session.Started).TotalSeconds -ge $Session.Timing.WaitingSeconds) {
        $Session.Presentation.Status = 'Still waiting for your phone. Retrying automatically...'

        if ($status) {
            $Session.Presentation.Status = 'Still waiting. ' + $status
        }

        return
    }

    if ($status) {
        $Session.Presentation.Status = $status
    }
}

# Advance owned processes and discovery without overlapping native sessions.
function Update-LaunchSession {
    param($Session)

    if ($Session.Phase -eq 'Closing') {
        return
    }

    if ($null -ne $Session.SettingsProcess) {
        $process = $Session.SettingsProcess
        $process.Refresh()

        if (-not $process.HasExited) {

            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $Session.Presentation.Visible = $false
            }

            return
        }

        $exitCode = $process.ExitCode
        $process.Dispose()
        $Session.SettingsProcess = $null

        if ($exitCode -ne 0) {
            $Session.Phase = 'Closing'
            return
        }

        $Session.Phase = 'Waiting'
        $Session.Presentation.Visible = $true
        $Session.Presentation.FocusRequested = $true
        Request-LaunchRetry -Session $Session
        return
    }

    if ($null -ne $Session.Native) {
        $process = $Session.Native.Process
        $process.Refresh()

        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            $expectsWindow = $Session.Native.ExpectsWindow -ne $false
            & $Session.Dependencies.CloseNative $Session.Native
            $Session.Native = $null

            $completedSession = $Session.Phase -eq 'Streaming' -or (-not $expectsWindow -and $exitCode -eq 0)

            if ($completedSession) {
                $Session.Phase = 'Closing'
                return
            }

            Set-LaunchFailure -Session $Session -Message 'The session stopped unexpectedly. Open logs for details, then retry.'
            return
        }

        if ($Session.Native.ExpectsWindow -eq $false) {
            $Session.Phase = 'Running'
            $Session.Presentation.Visible = $true
            $Session.Presentation.Status = 'scrcpy is running without a window.'
            $Session.Presentation.Hint = 'Close this window to stop the session. Open logs for connection and recording details.'
            return
        }

        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $Session.Phase = 'Streaming'
            $Session.Presentation.Visible = $false
            return
        }

        $startupExpired = $Session.Phase -eq 'Starting' -and
            ([DateTime]::UtcNow - $Session.NativeStarted).TotalSeconds -ge $Session.Timing.NativeStartupSeconds

        if ($startupExpired) {
            & $Session.Dependencies.CloseNative $Session.Native
            $Session.Native = $null
            $timeoutMessage = 'The screen did not open within ' + $Session.Timing.NativeStartupSeconds + ' seconds. Open logs for details, or retry.'
            Set-LaunchFailure -Session $Session -Message $timeoutMessage
            & $Session.Dependencies.Log $Session.RootDirectory $Session.Presentation.Status
        }

        return
    }

    if ($null -ne $Session.Probe) {

        if ($Session.Probe.Work.Handle.IsCompleted) {
            Complete-LaunchProbe -Session $Session
            return
        }

        if (-not $Session.SettingsRequested -and $Session.Phase -ne 'Failed') {
            Update-LaunchWaitingStatus -Session $Session
        }

        return
    }

    if ($Session.SettingsRequested) {
        $Session.SettingsProcess = & $Session.Dependencies.StartSettings $Session.RootDirectory
        $Session.SettingsRequested = $false
        $Session.Phase = 'Settings'
        $Session.Presentation.Status = 'Complete device setup to continue.'
        return
    }

    if ($Session.Phase -eq 'Failed') {
        return
    }

    Update-LaunchWaitingStatus -Session $Session

    if ([DateTime]::UtcNow -ge $Session.NextProbe) {
        Start-LaunchProbe -Session $Session
    }
}

# Release the launcher's owned work when the application event loop ends.
function Close-LaunchSession {
    param($Session)
    $Session.Phase = 'Closing'

    if ($null -ne $Session.Probe) {
        $Session.Probe.Cancellation.Cancel()

        try {
            $null = $Session.Probe.Work.Worker.EndInvoke($Session.Probe.Work.Handle)
        } catch {
            # Cancellation is expected during shutdown.
        } finally {
            $Session.Probe.Work.Worker.Dispose()
            $Session.Probe.Cancellation.Dispose()
            $Session.Probe = $null
        }
    }

    try {
        & $Session.Dependencies.CloseNative $Session.Native
    } finally {
        $Session.Native = $null

        if ($null -ne $Session.SettingsProcess) {
            $process = $Session.SettingsProcess

            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }

            $process.Dispose()
            $Session.SettingsProcess = $null
        }
    }
}
