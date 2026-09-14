$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/launch-runtime.ps1')
. (Join-Path $PSScriptRoot '../launcher/launch-session.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-launch-controller-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$testState = @{ Saved = $null; Launched = ''; LaunchCount = 0; Log = ''; Settings = $null }
$checks = 0

# Assert controller outcomes using real runspaces and observable fake native children.
function Assert-Launch {
    param($Condition, $Message)

    if (-not $Condition) {
        throw $Message
    }

    $script:checks++
}

# Build detached saved configuration fixtures.
function New-LaunchTestConfiguration {
    param($Serial)
    return [pscustomobject]@{ UsbSerial = $Serial; WirelessService = ''; ConnectionMode = 'usb' }
}

# Model the process contract without opening a native window.
function New-LaunchTestProcess {
    $process = [pscustomobject]@{ HasExited = $false; MainWindowHandle = [IntPtr]::Zero; ExitCode = 0; Disposed = $false }
    $process | Add-Member ScriptMethod Refresh { }
    $process | Add-Member ScriptMethod Kill { $this.HasExited = $true }
    $process | Add-Member ScriptMethod WaitForExit { }
    $process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return $process
}

# Bound only deterministic fixture completion, never a real phone operation.
function Complete-TestProbe {
    param($Session)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while (-not $Session.Probe.Work.Handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 10
    }

    Assert-Launch $Session.Probe.Work.Handle.IsCompleted 'Fixture probe did not complete.'
    Update-LaunchSession -Session $Session
}

$dependencies = New-LaunchDependencies
$dependencies.GetConfiguration = { param($RootDirectory) return $testState.Saved }.GetNewClosure()
$dependencies.ConfigurationLock = { param($RootDirectory, $Action) & $Action }
$dependencies.StartNative = {
    param($RootDirectory, $Configuration, $Target)
    $testState.Launched = $Target.Serial
    $testState.LaunchCount++
    return @{ Process = New-LaunchTestProcess }
}.GetNewClosure()
$dependencies.CloseNative = {
    param($Native)

    if ($null -ne $Native) {
        $Native.Process.Kill()
        $Native.Process.Dispose()
    }
}
$dependencies.StartSettings = { param($RootDirectory) return $testState.Settings }.GetNewClosure()
$dependencies.Log = { param($RootDirectory, $Message) $testState.Log = $Message }.GetNewClosure()
$session = $null

try {
    [IO.File]::WriteAllText((Join-Path $directory 'launcher-core.ps1'), '')
    [IO.File]::WriteAllText((Join-Path $directory 'connection-core.ps1'), @"
function Find-ReadyPhone {
    param(`$RootDirectory, `$Configuration, `$Progress, `$Cancellation)
    while (-not `$Cancellation.IsCancellationRequested -and -not `$Progress.Release) { Start-Sleep -Milliseconds 10 }
    if (`$Progress.Empty) { return `$null }
    return [pscustomobject]@{ Serial = `$Configuration.UsbSerial; WirelessTarget = '' }
}
"@)
    foreach ($scenario in @('changed', 'same', 'reset')) {
        $testState.Saved = New-LaunchTestConfiguration 'phone-A'
        $testState.Launched = ''
        $session = New-LaunchSession -RootDirectory $directory -Dependencies $dependencies
        Update-LaunchSession -Session $session
        $oldProbe = $session.Probe
        $oldProgress = $session.Progress
        $session.Configuration.UsbSerial = 'mutated'
        Assert-Launch ($oldProbe.Configuration.UsbSerial -eq 'phone-A') 'Probe snapshot shared mutable configuration.'
        $testState.Saved = New-LaunchTestConfiguration 'phone-A'

        if ($scenario -eq 'changed') {
            $testState.Saved = New-LaunchTestConfiguration 'phone-B'
        }

        if ($scenario -eq 'reset') {
            $testState.Saved = $null
        }

        Request-LaunchRetry -Session $session
        Assert-Launch $oldProbe.Cancellation.IsCancellationRequested 'Retry failed to cancel old probe.'
        Assert-Launch (-not [object]::ReferenceEquals($oldProgress, $session.Progress)) 'Stale progress can overwrite current attempt.'
        Complete-TestProbe -Session $session
        Assert-Launch (-not $testState.Launched -and $null -eq $session.Probe) 'Old result launched or worker remained attached.'
        Update-LaunchSession -Session $session

        if ($scenario -eq 'reset') {
            Assert-Launch ($session.Phase -eq 'Failed' -and $null -eq $session.Probe) 'Reset automatically resumed discovery.'
            Close-LaunchSession -Session $session
            continue
        }

        $session.Progress.Release = $true
        Complete-TestProbe -Session $session
        Assert-Launch ($testState.Launched -eq $testState.Saved.UsbSerial -and $session.Phase -eq 'Starting') 'Fresh probe did not launch current phone.'
        Assert-Launch (Get-LaunchPresentation -Session $session).Visible 'Waiting view hid before native HWND.'
        $native = $session.Native
        $native.Process.MainWindowHandle = [IntPtr]42
        Update-LaunchSession -Session $session
        Assert-Launch ($session.Phase -eq 'Streaming' -and -not (Get-LaunchPresentation -Session $session).Visible) 'Native HWND did not transition to Streaming.'
        $native.Process.HasExited = $true
        Update-LaunchSession -Session $session
        Assert-Launch ($session.Phase -eq 'Closing' -and $native.Process.Disposed) 'User closed stream but launcher restarted.'
        Close-LaunchSession -Session $session
    }

    # External edits without Retry must also invalidate the in-flight snapshot.
    foreach ($scenario in @('unchanged', 'phone', 'service', 'mode', 'reset', 'empty')) {
        $testState.Saved = New-LaunchTestConfiguration 'phone-A'
        $testState.Launched = ''
        $session = New-LaunchSession -RootDirectory $directory -Dependencies $dependencies
        Update-LaunchSession -Session $session

        switch ($scenario) {
            'phone' { $testState.Saved = New-LaunchTestConfiguration 'phone-B' }
            'service' { $testState.Saved.WirelessService = '192.168.1.3:40000' }
            'mode' { $testState.Saved.ConnectionMode = 'auto' }
            'reset' { $testState.Saved = $null }
            'empty' { $session.Progress.Empty = $true }
        }

        $session.Progress.Release = $true
        Complete-TestProbe -Session $session
        Assert-Launch ([bool]$testState.Launched -eq ($scenario -eq 'unchanged')) "External $scenario change accepted an obsolete target."
        Assert-Launch (-not $session.SettingsRequested) 'External reset opened duplicate Settings.'
        Close-LaunchSession -Session $session
    }

    # A process that exits before creating a window requires deliberate retry.
    $testState.Saved = New-LaunchTestConfiguration 'phone-A'
    $session = New-LaunchSession -RootDirectory $directory -Dependencies $dependencies
    Update-LaunchSession -Session $session
    $session.Progress.Release = $true
    Complete-TestProbe -Session $session
    $session.Native.Process.HasExited = $true
    Update-LaunchSession -Session $session
    $launchCount = $testState.LaunchCount
    $session.Presentation.FocusRequested = $true
    $presentation = Get-LaunchPresentation -Session $session
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Failed' -and $presentation.RetryEnabled -and $presentation.SettingsEnabled) 'Early native exit did not expose recovery.'
    Assert-Launch ($testState.LaunchCount -eq $launchCount -and $null -eq $session.Probe -and $presentation.FocusRequested) 'Refocusing failed session created another stream.'
    Close-LaunchSession -Session $session
    $testState.Saved = New-LaunchTestConfiguration 'phone-A'
    $session = New-LaunchSession -RootDirectory $directory -Dependencies $dependencies
    Update-LaunchSession -Session $session
    $session.Progress.Release = $true
    Complete-TestProbe -Session $session
    $native = $session.Native
    $session.NativeStarted = [DateTime]::UtcNow.AddSeconds(-31)
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Failed' -and $native.Process.Disposed) 'Native startup deadline did not clean up and pause.'
    Update-LaunchSession -Session $session
    Assert-Launch ($null -eq $session.Probe) 'Failed startup silently restarted discovery.'
    Request-LaunchRetry -Session $session
    $session.Started = [DateTime]::UtcNow.AddHours(-1)
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Probing') 'Native deadline incorrectly limited discovery.'
    $session.Progress.Status = 'Authorize USB debugging.'
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Presentation.Status -match 'Still waiting.*Authorize') 'Delayed status erased actionable hint.'
    $testState.Settings = New-LaunchTestProcess
    Request-LaunchSettings -Session $session
    Complete-TestProbe -Session $session
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Settings' -and $session.Presentation.Visible) 'Settings child hid waiting view before HWND.'
    Assert-Launch (-not (Request-LaunchClose -Session $session)) 'Parent interrupted Settings cancellation authority.'
    Assert-Launch $session.Presentation.FocusRequested 'Blocked close did not focus Settings.'
    $testState.Settings.MainWindowHandle = [IntPtr]44
    Update-LaunchSession -Session $session
    Assert-Launch (-not $session.Presentation.Visible) 'Visible Settings child did not hide waiting view.'
    $testState.Settings.HasExited = $true
    Update-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Waiting' -and $session.Presentation.Visible) 'Successful Settings did not resume waiting.'
    Update-LaunchSession -Session $session
    $probe = $session.Probe
    Assert-Launch (Request-LaunchClose -Session $session) 'Waiting close was rejected.'
    Close-LaunchSession -Session $session
    Assert-Launch ($session.Phase -eq 'Closing' -and $null -eq $session.Probe) 'Shutdown kept active discovery.'
    Write-Output "$checks direct launch-controller assertions passed."
} finally {

    if ($null -ne $session) {
        Close-LaunchSession -Session $session
    }

    $resolvedDirectory = (Resolve-Path $directory).ProviderPath

    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
