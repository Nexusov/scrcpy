param([string]$LauncherDirectory = (Join-Path $PSScriptRoot '..\launcher'))

$ErrorActionPreference = 'Stop'
. (Join-Path $LauncherDirectory 'setup-session.ps1')
. (Join-Path $LauncherDirectory 'setup-view.ps1')
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-settings-session-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$checks = 0
$shortcutCalls = 0

# Assert observable controller behavior through supported module entry points.
function Assert-SetupSession {
    param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }

    $script:checks++
}

# Finish bounded test workers without entering a Windows Forms message loop.
function Wait-SetupTestWork {
    param([hashtable]$Session)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while ($null -ne $Session.PendingWork) {

        if ([DateTime]::UtcNow -gt $deadline) {
            throw 'Test worker did not finish.'
        }

        Start-Sleep -Milliseconds 20
        Update-SetupSession -Session $Session
    }
}

try {
    $dependencies = @{
        CreateShortcut = { param($RootDirectory) $script:shortcutCalls++ }
        StartWork = {
            param($RootDirectory, $Operation, $Values, $PairingState)
            New-SetupWorker -RootDirectory $LauncherDirectory -Operation $Operation -Values $Values -PairingState $PairingState
        }
    }
    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    Assert-SetupSession ($null -eq $session.ConfigurationSnapshot -and $null -eq $session.PendingWork) 'Session constructor performed work or lost absent-file snapshot.'
    Assert-SetupSession (-not (Get-SetupActionState -Session $session).CanFinish) 'Initial automatic mode accepts missing phone.'
    Set-SetupInput -Session $session -Values @{ Mode = 'wifi'; PairingCode = '123456'; SelectedSerial = 'stale-usb' }
    Assert-SetupSession (Get-SetupActionState -Session $session).CanFinish 'Wi-Fi setup unnecessarily requires USB.'
    Assert-SetupSession (-not (Get-SetupInput -Session $session).Serial) 'New Wi-Fi setup inherited a hidden USB identity.'
    $session.PairingState.Endpoint = '192.168.1.8:12345'
    Set-SetupInput -Session $session -Values @{ Mode = 'auto' }
    Assert-SetupSession ([bool]$session.PairingState.Endpoint) 'Partial input cleared retained pairing.'
    Set-SetupInput -Session $session -Values @{ PairingCode = '654321' }
    Assert-SetupSession (-not $session.PairingState.Endpoint) 'New pairing code retained previous pairing stage.'
    $failedSession = New-SetupSession -RootDirectory $testDirectory -Dependencies @{ StartWork = { throw 'fake worker failure' } }
    Start-SetupWork -Session $failedSession -Operation 'devices'
    Assert-SetupSession ($null -eq $failedSession.PendingWork -and $failedSession.Status -match 'could not start') 'Worker creation failure trapped settings in a busy state.'

    $configuration = [pscustomobject]@{ UsbSerial = 'phone123'; WirelessService = '192.168.1.8:40000'; ConnectionMode = 'wifi' }
    Save-PhoneConfiguration -RootDirectory $testDirectory -Configuration $configuration
    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    Assert-SetupSession ($session.Input.Mode -eq 'wifi' -and $session.Input.SelectedSerial -eq 'phone123') 'Saved mode and offline identity not restored.'
    Assert-SetupSession (Test-SavedWifiSelection -Session $session) 'Saved pairing cannot be reused offline.'
    Set-SetupInput -Session $session -Values @{ SelectedSerial = 'other-phone' }
    Assert-SetupSession ((Get-SetupInput -Session $session).Serial -eq 'phone123') 'Hidden device selection changed saved Wi-Fi identity.'
    Set-SetupInput -Session $session -Values @{ Mode = 'auto' }
    Assert-SetupSession (-not (Test-SavedWifiSelection -Session $session)) 'Another USB device inherited saved Wi-Fi credentials.'
    Set-SetupInput -Session $session -Values @{ SelectedSerial = 'phone123' }
    Complete-Setup -Session $session
    Assert-SetupSession ($session.Outcome -eq 'Saved' -and $shortcutCalls -eq 1) 'Saved pairing did not save and create optional shortcut.'
    Assert-SetupSession ($null -eq $session.PendingWork) 'Saved pairing unnecessarily launched a worker.'

    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    Set-SetupInput -Session $session -Values @{ Mode = 'usb'; CreateShortcut = $false }
    Complete-Setup -Session $session
    Wait-SetupTestWork -Session $session
    $saved = Get-PhoneConfiguration -RootDirectory $testDirectory
    Assert-SetupSession ($saved.ConnectionMode -eq 'usb' -and -not $saved.WirelessService) 'Switching to USB retained wireless configuration.'
    Assert-SetupSession ($shortcutCalls -eq 1) 'Unchecked shortcut option mutated the desktop.'

    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    $before = Get-DeviceConfigurationSnapshot -RootDirectory $testDirectory
    Complete-Setup -Session $session
    Assert-SetupSession (-not (Request-SetupCancellation -Session $session)) 'Busy cancellation closed settings before its worker drained.'
    Wait-SetupTestWork -Session $session
    Assert-SetupSession ((Get-DeviceConfigurationSnapshot -RootDirectory $testDirectory) -ceq $before) 'Cancelled completed worker overwrote configuration.'
    Assert-SetupSession ($session.Status -match 'cancelled' -and $session.Outcome -eq 'Open') 'Cancellation lost feedback or saved result.'

    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    New-SetupShortcut -Session $session
    Assert-SetupSession ($shortcutCalls -eq 2 -and $null -eq $session.PendingWork) 'Independent shortcut creation requires a worker.'
    Reset-SetupState -Session $session -Confirmed $false
    Assert-SetupSession ((Get-DeviceConfigurationSnapshot -RootDirectory $testDirectory) -ceq $before) 'Unconfirmed reset changed configuration.'
    Reset-SetupState -Session $session -Confirmed $true
    Assert-SetupSession ($null -eq (Get-PhoneConfiguration -RootDirectory $testDirectory) -and $session.Input.Mode -eq 'auto') 'Confirmed reset did not return to initial state.'

    Save-PhoneConfiguration -RootDirectory $testDirectory -Configuration $configuration
    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    [void](Reset-DeviceConfiguration -RootDirectory $testDirectory -Confirmed $true)
    Complete-Setup -Session $session
    Assert-SetupSession ($session.Outcome -eq 'Open' -and $session.Status -match 'changed in another window') 'Stale settings resurrected an external reset.'
    Assert-SetupSession (-not (Test-Path (Join-Path $testDirectory 'phone.json'))) 'Stale save recreated removed file.'

    Save-PhoneConfiguration -RootDirectory $testDirectory -Configuration $configuration
    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies @{ CreateShortcut = { throw 'fake shortcut failure' } }
    Complete-Setup -Session $session
    Assert-SetupSession ($session.Outcome -eq 'Saved' -and $session.Warning) 'Shortcut failure discarded successful configuration.'

    $session = New-SetupSession -RootDirectory $testDirectory -Dependencies $dependencies
    $view = New-SetupView -Session $session -Version 'test-build'

    try {
        Assert-SetupSession (-not $view.Form.Visible -and -not $view.Timer.Enabled) 'View constructor opened a window or started work.'
        Assert-SetupSession ($view.Mode.SelectedItem.Value -eq 'wifi' -and $view.CreateShortcut.Checked) 'View did not render saved mode/default shortcut.'
        Assert-SetupSession ($view.Finish.Text -eq 'Save settings' -and $view.ResetSetup.Text -eq 'Reset device setup...') 'View action labels changed.'
        $renderedDevices = $view.RenderedDevices
        Update-SetupView -View $view
        Assert-SetupSession ([object]::ReferenceEquals($renderedDevices, $view.RenderedDevices)) 'Idle rendering rebuilds device state.'
        $view.Mode.SelectedItem = @($view.Mode.Items | Where-Object { $_.Value -eq 'usb' })[0]
        Assert-SetupSession ($session.Input.Mode -eq 'usb' -and $view.Finish.Text -eq 'Save USB setup') 'Event closure lost session after factory returned.'
        $view.CreateShortcut.Checked = $false
        Assert-SetupSession (-not $session.Input.CreateShortcut) 'Shortcut checkbox event did not update session.'
        Assert-SetupSession ($view.Panel.AutoScroll -and $view.Form.MinimumSize.Width -eq 620) 'Responsive scrolling settings layout changed.'
    } finally {
        Close-SetupView -View $view
        Close-SetupSession -Session $session
    }

    Write-Output "PASS: $checks direct settings session/view checks."
} finally {
    $resolvedDirectory = [IO.Path]::GetFullPath($testDirectory)

    if ($resolvedDirectory.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
    }
}
