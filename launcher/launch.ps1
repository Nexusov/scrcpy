$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'last-run.log'
$errorLogPath = Join-Path $PSScriptRoot 'last-run-errors.log'
$env:ADB = Join-Path $PSScriptRoot 'adb.exe'
$env:ADB_MDNS_OPENSCREEN = '1'
$instance = $null

# Raise the current application window after another shortcut invocation.
function Show-CurrentLauncherWindow {
    $process = $script:session.NativeProcess

    if ($null -ne $script:session.SetupProcess) {
        $process = $script:session.SetupProcess
    }

    if ($null -ne $process -and -not $process.HasExited) {
        $shell = New-Object -ComObject WScript.Shell

        try {
            $null = $shell.AppActivate($process.Id)
        } finally {
            $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }

        if ($script:session.NativeVisible -or $null -ne $script:session.SetupProcess) {
            return
        }
    }

    $script:form.Show()
    $script:form.WindowState = 'Normal'
    $script:form.Activate()
}

# Start a single background probe without blocking the Windows Forms event loop.
function Start-ConnectionProbe {
    $worker = [PowerShell]::Create()
    $null = $worker.AddScript({
        param($rootDirectory, $configuration, $cancellation, $progress)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $rootDirectory 'launcher-core.ps1')
        . (Join-Path $rootDirectory 'connection-core.ps1')
        function Invoke-AdbCommand {
            param([string]$RootDirectory, [string[]]$Arguments, [int]$TimeoutMilliseconds = 12000)
            Invoke-ConnectionAdb -RootDirectory $RootDirectory -Arguments $Arguments -TimeoutMilliseconds $TimeoutMilliseconds -Cancellation $cancellation
        }
        Find-ReadyPhone -RootDirectory $rootDirectory -Configuration $configuration -Progress $progress
    }).AddArgument($PSScriptRoot).AddArgument($script:session.Configuration).AddArgument($script:session.Cancellation).AddArgument($script:session.Progress)
    $script:session.Worker = $worker
    $script:session.Pending = $worker.BeginInvoke()
}

# Open setup as a child while retaining the launcher instance lock.
function Start-LauncherSetup {
    $script:session.SetupRequested = $false
    $script:session.SetupProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $PSScriptRoot 'setup.ps1') + '"')) -WindowStyle Hidden -PassThru
    $script:statusLabel.Text = 'Complete device setup to continue.'
    $script:retryButton.Enabled = $false
    $script:setupButton.Enabled = $false
}

# Reject stale probe results after settings are changed or reset in another window.
function Start-VerifiedMirroringProcess {
    param($Target)
    Invoke-DeviceConfigurationLock -RootDirectory $PSScriptRoot -Action {
        $configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot

        if ($null -eq $configuration) {
            $script:session.Configuration = $null
            $script:session.Paused = $true
            $script:statusLabel.Text = 'Device setup was reset. Complete Settings, then retry.'
            $script:retryButton.Enabled = $true
            $script:setupButton.Enabled = $true
            $script:session.Progress.Status = ''
            return
        }

        $previousConfiguration = $script:session.Configuration
        $configurationChanged = $null -eq $previousConfiguration -or
            $configuration.UsbSerial -cne $previousConfiguration.UsbSerial -or
            $configuration.WirelessService -cne $previousConfiguration.WirelessService -or
            (Get-ConnectionMode -Configuration $configuration) -ne (Get-ConnectionMode -Configuration $previousConfiguration)

        if ($configurationChanged) {
            $script:session.Configuration = $configuration
            $script:session.Progress.Status = ''
            $script:session.Started = [DateTime]::UtcNow
            $script:session.NextProbe = [DateTime]::MinValue
            $script:hintLabel.Text = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $configuration)
            return
        }

        if ($null -ne $Target) {
            Start-MirroringProcess -Target $Target
        }
    }
}
# Start exactly one native session and copy its logs without blocking the UI.
function Start-MirroringProcess {
    param($Target)
    $env:SCRCPY_RECONNECT_SERIAL = $null

    if ((Get-ConnectionMode -Configuration $script:session.Configuration) -ne 'usb') {
        $env:SCRCPY_RECONNECT_SERIAL = $Target.WirelessTarget
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $PSScriptRoot 'scrcpy.exe'
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.Arguments = '-s "' + $Target.Serial + '" --window-title=Phone-Seamless --pause-on-exit=false'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $script:session.OutputFile = [IO.File]::Open($logPath, 'Append', 'Write', 'ReadWrite')
    $script:session.ErrorFile = [IO.File]::Open($errorLogPath, 'Create', 'Write', 'ReadWrite')
    $script:session.NativeProcess = [Diagnostics.Process]::Start($startInfo)
    $script:session.NativeStarted = [DateTime]::UtcNow
    $script:session.OutputCopy = $script:session.NativeProcess.StandardOutput.BaseStream.CopyToAsync($script:session.OutputFile)
    $script:session.ErrorCopy = $script:session.NativeProcess.StandardError.BaseStream.CopyToAsync($script:session.ErrorFile)
    $script:statusLabel.Text = 'Opening your phone screen...'
    $script:retryButton.Enabled = $false
    $script:setupButton.Enabled = $false
}

# Bound only native window startup; phone discovery may wait indefinitely.
function Test-NativeStartupTimeout {
    param($Session, [DateTime]$Now = [DateTime]::UtcNow)
    $nativeStartupTimeoutSeconds = 30

    if ($Session.NativeVisible -or $null -eq $Session.NativeStarted) {
        return $false
    }

    return ($Now - $Session.NativeStarted).TotalSeconds -ge $nativeStartupTimeoutSeconds
}

# Stop only the native child owned by this launch attempt.
function Stop-MirroringStartup {
    $process = $script:session.NativeProcess

    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }

    Close-MirroringResources
    $script:session.Paused = $true
    $script:statusLabel.Text = 'The screen did not open within 30 seconds. Open logs for details, or retry.'
    $script:retryButton.Enabled = $true
    $script:setupButton.Enabled = $true
}

# Release completed native output streams before a deliberate retry.
function Close-MirroringResources {
    foreach ($name in @('OutputCopy', 'ErrorCopy')) {
        $task = $script:session[$name]

        if ($null -ne $task) {
            $null = $task.GetAwaiter().GetResult()
            $script:session[$name] = $null
        }
    }

    foreach ($name in @('OutputFile', 'ErrorFile', 'NativeProcess')) {
        $resource = $script:session[$name]

        if ($null -ne $resource) {
            $resource.Dispose()
            $script:session[$name] = $null
        }
    }
}

# Advance asynchronous setup, probing, and native startup without overlapping work.
function Update-LauncherSession {
    if ($script:session.Closing) {
        return
    }

    if ($instance.Signal.WaitOne(0)) {
        Show-CurrentLauncherWindow
    }

    if ($null -ne $script:session.SetupProcess) {

        if (-not $script:session.SetupProcess.HasExited) {
            $script:session.SetupProcess.Refresh()

            if ($script:session.SetupProcess.MainWindowHandle -ne [IntPtr]::Zero) {
                $script:form.Hide()
            }

            return
        }

        $setupExitCode = $script:session.SetupProcess.ExitCode
        $script:session.SetupProcess.Dispose()
        $script:session.SetupProcess = $null

        if ($setupExitCode -ne 0) {
            $script:form.Close()
            return
        }

        $script:session.Configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot
        $script:session.Progress.Status = ''

        if ($null -eq $script:session.Configuration) {
            throw 'Setup did not save a valid configuration. Run Settings.vbs to try again.'
        }

        $script:hintLabel.Text = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $script:session.Configuration)
        $script:session.Started = [DateTime]::UtcNow
        $script:session.Paused = $false
        $script:session.NextProbe = [DateTime]::MinValue
        $script:statusLabel.Text = 'Connecting to your phone...'
        $script:retryButton.Enabled = $true
        $script:setupButton.Enabled = $true
        Show-CurrentLauncherWindow
    }

    if ($null -ne $script:session.NativeProcess) {
        $script:session.NativeProcess.Refresh()

        if ($script:session.NativeProcess.HasExited) {
            Close-MirroringResources

            if ($script:session.NativeVisible) {
                $script:form.Close()
                return
            }

            $script:session.Paused = $true
            $script:statusLabel.Text = 'The screen could not open. Open logs for details, then retry.'
            $script:retryButton.Enabled = $true
            $script:setupButton.Enabled = $true
            return
        }

        if (-not $script:session.NativeVisible -and $script:session.NativeProcess.MainWindowHandle -ne [IntPtr]::Zero) {
            $script:session.NativeVisible = $true
            $script:form.Hide()
        }

        if (Test-NativeStartupTimeout -Session $script:session) {
            Stop-MirroringStartup
            Add-Content -LiteralPath $logPath -Value 'Native startup timed out after 30 seconds before a window appeared.'
        }

        return
    }

    if ($null -ne $script:session.Pending) {

        if (-not $script:session.Pending.IsCompleted) {
            Update-WaitingStatus
            return
        }

        $targets = @()

        try {
            $targets = @($script:session.Worker.EndInvoke($script:session.Pending))
        } catch {
            Add-Content -LiteralPath $logPath -Value $_.Exception.Message
        } finally {
            $script:session.Worker.Dispose()
            $script:session.Worker = $null
            $script:session.Pending = $null
            $script:session.NextProbe = [DateTime]::UtcNow.AddSeconds(2)
        }

        if (-not $script:session.SetupRequested) {
            Start-VerifiedMirroringProcess -Target ($targets | Select-Object -First 1)
            return
        }
    }

    if ($script:session.SetupRequested) {
        Start-LauncherSetup
        return
    }

    if ($script:session.Paused) {
        return
    }

    Update-WaitingStatus

    if ([DateTime]::UtcNow -ge $script:session.NextProbe) {
        Start-ConnectionProbe
    }
}

# Change only the status after ten seconds while keeping helpful instructions visible.
function Update-WaitingStatus {
    $waitingThresholdSeconds = 10
    $status = [string]$script:session.Progress.Status

    if (([DateTime]::UtcNow - $script:session.Started).TotalSeconds -ge $waitingThresholdSeconds) {
        $script:statusLabel.Text = 'Still waiting for your phone. Retrying automatically...'

        if ($status) {
            $script:statusLabel.Text = 'Still waiting. ' + $status
        }

        return
    }

    if ($status) {
        $script:statusLabel.Text = $status
    }
}

try {
    . (Join-Path $PSScriptRoot 'launcher-core.ps1')
    . (Join-Path $PSScriptRoot 'connection-core.ps1')
    . (Join-Path $PSScriptRoot 'instance.ps1')
    . (Join-Path $PSScriptRoot 'reset.ps1')
    . (Join-Path $PSScriptRoot 'version.ps1')
    $instance = Enter-LauncherInstance

    if (-not $instance.IsPrimary) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    Set-Content -LiteralPath $logPath -Value ('scrcpy Seamless ' + (Get-SeamlessVersion) + ' | Started: ' + (Get-Date -Format o)) -Encoding UTF8
    $configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot
    $script:session = @{
        Configuration = $configuration; Worker = $null; Pending = $null
        NativeProcess = $null; NativeVisible = $false; SetupProcess = $null
        SetupRequested = ($null -eq $configuration); Paused = $false; Closing = $false
        Started = [DateTime]::UtcNow; NextProbe = [DateTime]::MinValue
        OutputFile = $null; ErrorFile = $null; OutputCopy = $null; ErrorCopy = $null
        Cancellation = [hashtable]::Synchronized(@{ Requested = $false })
        Progress = [hashtable]::Synchronized(@{ Status = '' }); NativeStarted = $null
    }
    $script:form = New-Object Windows.Forms.Form
    $script:form.Text = 'scrcpy Seamless ' + (Get-SeamlessVersion) + ' - Connecting'
    $script:form.ClientSize = New-Object Drawing.Size(560, 215)
    $script:form.StartPosition = 'CenterScreen'
    $script:form.FormBorderStyle = 'FixedDialog'
    $script:form.MaximizeBox = $false
    $script:form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $script:form.AutoScaleMode = 'Dpi'
    $script:statusLabel = New-Object Windows.Forms.Label
    $script:statusLabel.Location = New-Object Drawing.Point(20, 20)
    $script:statusLabel.Size = New-Object Drawing.Size(520, 45)
    $script:statusLabel.Text = 'Connecting to your phone...'
    $script:hintLabel = New-Object Windows.Forms.Label
    $script:hintLabel.Location = New-Object Drawing.Point(20, 70)
    $script:hintLabel.Size = New-Object Drawing.Size(520, 75)
    $script:hintLabel.Text = 'Complete the setup wizard to connect your phone.'

    if ($null -ne $configuration) {
        $script:hintLabel.Text = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $configuration)
    }

    $script:retryButton = New-Object Windows.Forms.Button
    $script:retryButton.Text = 'Retry now'
    $script:retryButton.Location = New-Object Drawing.Point(200, 165)
    $script:retryButton.Size = New-Object Drawing.Size(105, 32)
    $script:setupButton = New-Object Windows.Forms.Button
    $script:setupButton.Text = 'Settings'
    $script:setupButton.Location = New-Object Drawing.Point(315, 165)
    $script:setupButton.Size = New-Object Drawing.Size(105, 32)
    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object Drawing.Point(430, 165)
    $cancelButton.Size = New-Object Drawing.Size(105, 32)
    $logsButton = New-Object Windows.Forms.Button
    $logsButton.Text = 'Open logs'
    $logsButton.Location = New-Object Drawing.Point(20, 165)
    $logsButton.Size = New-Object Drawing.Size(105, 32)
    $logsButton.Add_Click({
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $logPath + '"')
        } catch {
            $script:statusLabel.Text = 'Could not open the log folder. Logs are stored next to the runtime scripts.'
        }
    })
    $script:form.Controls.AddRange(@($script:statusLabel, $script:hintLabel, $script:retryButton, $script:setupButton, $cancelButton, $logsButton))
    $script:form.CancelButton = $cancelButton
    $script:retryButton.Add_Click({
        $configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot

        if ($null -eq $configuration) {
            $script:session.Paused = $true
            $script:statusLabel.Text = 'Complete Settings, then retry.'
            return
        }

        $script:session.Configuration = $configuration
        $script:hintLabel.Text = Get-ConnectionHint -Mode (Get-ConnectionMode -Configuration $configuration)
        $script:session.Paused = $false
        $script:session.NextProbe = [DateTime]::MinValue
        $script:session.Started = [DateTime]::UtcNow
        $script:session.Progress.Status = ''
        $script:statusLabel.Text = 'Connecting to your phone...'
    })
    $script:setupButton.Add_Click({
        $script:session.SetupRequested = $true
        $script:setupButton.Enabled = $false
        $script:retryButton.Enabled = $false
        $script:statusLabel.Text = 'Finishing the current check before opening settings...'
    })
    $cancelButton.Add_Click({ $script:form.Close() })
    $script:form.Add_FormClosing({
        param($sender, $eventArguments)

        if ($null -ne $script:session.SetupProcess -and -not $script:session.SetupProcess.HasExited) {
            $eventArguments.Cancel = $true
            Show-CurrentLauncherWindow
            return
        }

        $script:session.Closing = $true
        $script:session.Cancellation.Requested = $true
    })
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        try {
            Update-LauncherSession
        } catch {
            $script:session.Paused = $true
            $script:retryButton.Enabled = $true
            $script:setupButton.Enabled = $true
            
            if ($null -eq $script:session.NativeProcess) {
                Close-MirroringResources
            }
            $script:statusLabel.Text = 'Could not start mirroring. Check last-run.log and try Settings.'
            Add-Content -LiteralPath $logPath -Value $_.Exception.Message
        }
    })
    $timer.Start()
    [Windows.Forms.Application]::Run($script:form)
} catch {
    $_ | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    $shell = New-Object -ComObject WScript.Shell
    $null = $shell.Popup("$($_.Exception.Message)`nDetails: $logPath", 0, 'scrcpy Seamless', 16)
} finally {

    if ($null -ne $timer) {
        $timer.Stop()
        $timer.Dispose()
    }

    if ($null -ne $script:session) {
        foreach ($name in @('NativeProcess', 'SetupProcess')) {
            $process = $script:session[$name]

            if ($null -ne $process -and -not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }

        if ($null -ne $script:session.Worker) {
            $script:session.Cancellation.Requested = $true
            # Cancellable ADB waits terminate only the process owned by this probe.
            try {
                $null = $script:session.Worker.EndInvoke($script:session.Pending)
            } catch {
                # Cancellation is expected when the waiting window closes.
            }
            $script:session.Worker.Dispose()
        }

        Close-MirroringResources

        if ($null -ne $script:session.SetupProcess) {
            $script:session.SetupProcess.Dispose()
        }
    }

    if ($null -ne $script:form) {
        $script:form.Dispose()
    }

    if ($null -ne $instance) {
        Exit-LauncherInstance -Instance $instance
    }
}
