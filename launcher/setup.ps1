param([string]$RootDirectory = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:setupRoot = [System.IO.Path]::GetFullPath($RootDirectory)
$script:pendingWork = $null
$script:setupSaved = $false
$script:pairingState = [hashtable]::Synchronized(@{})
. (Join-Path $script:setupRoot 'launcher-core.ps1')
# Captures the exact saved state to detect edits from another settings window.
function Get-SetupConfigurationSnapshot {
    $path = Join-Path $script:setupRoot 'phone.json'

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    return [IO.File]::ReadAllText($path)
}

# Saves only if another window has not reset or replaced the configuration.
function Save-SetupConfiguration {
    param($Configuration)
    . (Join-Path $script:setupRoot 'reset.ps1')
    Invoke-DeviceConfigurationLock -RootDirectory $script:setupRoot -Action {
        $currentSnapshot = Get-SetupConfigurationSnapshot

        if ($currentSnapshot -cne $script:configurationSnapshot) {
            throw 'Device settings changed in another window. Close and reopen Settings before saving.'
        }

        Save-PhoneConfiguration -RootDirectory $script:setupRoot -Configuration $Configuration
        $script:configurationSnapshot = Get-SetupConfigurationSnapshot
    }
}
$script:configurationSnapshot = Get-SetupConfigurationSnapshot
$script:savedConfiguration = Get-PhoneConfiguration -RootDirectory $script:setupRoot

if ((Get-SetupConfigurationSnapshot) -cne $script:configurationSnapshot) {
    throw 'Device settings changed while opening this window. Open Settings again.'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'scrcpy Seamless - Settings'
$versionScript = Join-Path $script:setupRoot 'version.ps1'

if (Test-Path -LiteralPath $versionScript) {
    . $versionScript
    $form.Text += ' - ' + (Get-SeamlessVersion)
}
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(700, 610)
$form.MinimumSize = New-Object System.Drawing.Size(620, 580)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleMode = 'Dpi'

$scrollPanel = New-Object System.Windows.Forms.Panel
$scrollPanel.Dock = 'Fill'
$scrollPanel.AutoScroll = $true
$form.Controls.Add($scrollPanel)
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Top'
$layout.AutoSize = $true
$layout.AutoSizeMode = 'GrowAndShrink'
$layout.Padding = New-Object System.Windows.Forms.Padding(20)
$layout.ColumnCount = 1
$layout.RowCount = 11
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
foreach ($row in 1..$layout.RowCount) {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
}
$scrollPanel.Controls.Add($layout)

# Creates a consistently docked explanatory label.
function New-SetupLabel {
    param([string]$Text)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = 'Fill'
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 6)
    $label.TextAlign = 'MiddleLeft'
    return $label
}

$layout.Controls.Add((New-SetupLabel 'Choose how scrcpy connects. USB + Wi-Fi uses USB when available and reconnects wirelessly if the cable is removed.'), 0, 0)
$layout.Controls.Add((New-SetupLabel 'USB: connect and authorize your phone, then select it below.'), 0, 1)
$deviceRow = New-Object System.Windows.Forms.TableLayoutPanel
$deviceRow.Dock = 'Fill'
$deviceRow.AutoSize = $true
$deviceRow.AutoSizeMode = 'GrowAndShrink'
$deviceRow.ColumnCount = 2
[void]$deviceRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$deviceRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 110)))
$devices = New-Object System.Windows.Forms.ComboBox
$devices.Dock = 'Fill'
$devices.DropDownStyle = 'DropDownList'
$devices.DisplayMember = 'Label'

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Dock = 'Fill'
$deviceRow.Controls.Add($devices, 0, 0)
$deviceRow.Controls.Add($refresh, 1, 0)
$layout.Controls.Add($deviceRow, 0, 2)
$layout.Controls.Add((New-SetupLabel 'Wi-Fi: connect both devices to the same network. On the phone (Android 11+), open Wireless debugging > Pair device with pairing code.'), 0, 3)

$pairingRow = New-Object System.Windows.Forms.TableLayoutPanel
$pairingRow.Dock = 'Fill'
$pairingRow.AutoSize = $true
$pairingRow.AutoSizeMode = 'GrowAndShrink'
$pairingRow.ColumnCount = 2
[void]$pairingRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 200)))
[void]$pairingRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$pairingRow.Controls.Add((New-SetupLabel 'Pairing code (6 digits)'), 0, 0)
$pairingCode = New-Object System.Windows.Forms.TextBox
$pairingCode.Dock = 'Fill'
$pairingCode.MaxLength = 6
$pairingCode.UseSystemPasswordChar = $true
$pairingRow.Controls.Add($pairingCode, 1, 0)
$layout.Controls.Add($pairingRow, 0, 4)

$endpointRow = New-Object System.Windows.Forms.TableLayoutPanel
$endpointRow.Dock = 'Fill'
$endpointRow.AutoSize = $true
$endpointRow.AutoSizeMode = 'GrowAndShrink'
$endpointRow.ColumnCount = 2
[void]$endpointRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 200)))
[void]$endpointRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$endpointRow.Controls.Add((New-SetupLabel 'Pairing IP:port (optional)'), 0, 0)
$endpoint = New-Object System.Windows.Forms.TextBox
$endpoint.Dock = 'Fill'
$endpointRow.Controls.Add($endpoint, 1, 0)
$layout.Controls.Add($endpointRow, 0, 5)
$layout.Controls.Add((New-SetupLabel 'Leave blank to try automatic discovery. If your phone cannot be identified automatically, enter the address shown in its pairing dialog.'), 0, 6)

$connectionRow = New-Object System.Windows.Forms.TableLayoutPanel
$connectionRow.Dock = 'Fill'
$connectionRow.AutoSize = $true
$connectionRow.AutoSizeMode = 'GrowAndShrink'
$connectionRow.ColumnCount = 2
[void]$connectionRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 200)))
[void]$connectionRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$connectionRow.Controls.Add((New-SetupLabel 'Connection IP:port'), 0, 0)
$connectionEndpoint = New-Object System.Windows.Forms.TextBox
$connectionEndpoint.Dock = 'Fill'
$connectionRow.Controls.Add($connectionEndpoint, 1, 0)
$layout.Controls.Add($connectionRow, 0, 7)
$layout.Controls.Add((New-SetupLabel 'Only if discovery fails: use the address on the main Wireless debugging screen, not the pairing dialog.'), 0, 8)

$status = New-SetupLabel 'Looking for USB devices...'
$status.TextAlign = 'TopLeft'
$status.AutoEllipsis = $false
$status.Padding = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
$layout.Controls.Add($status, 0, 9)
$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'
$buttons.FlowDirection = 'RightToLeft'
$buttons.WrapContents = $true
$buttons.AutoSize = $true
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.AutoSize = $true
$finish = New-Object System.Windows.Forms.Button
$finish.Text = 'Pair and finish'
$finish.AutoSize = $true
$buttons.Controls.AddRange(@($cancel, $finish))
$layout.Controls.Add($buttons, 0, 10)
$usbInstructions = $layout.GetControlFromPosition(0, 1)
$wifiInstructions = $layout.GetControlFromPosition(0, 3)
$pairingHint = $layout.GetControlFromPosition(0, 6)
$connectionHint = $layout.GetControlFromPosition(0, 8)
$usbControls = @($usbInstructions, $deviceRow)
$wifiControls = @($wifiInstructions, $pairingRow)
$manualControls = @($endpointRow, $pairingHint, $connectionRow, $connectionHint)
foreach ($control in @($layout.Controls)) {
    $row = $layout.GetRow($control)

    if ($row -ge 1) {
        $layout.SetRow($control, $row + 1)
    }
}
$mode = New-Object System.Windows.Forms.ComboBox
$mode.Dock = 'Fill'
$mode.DropDownStyle = 'DropDownList'
$mode.DisplayMember = 'Label'
[void]$mode.Items.Add([pscustomobject]@{ Value = 'auto'; Label = 'USB + Wi-Fi (recommended)' })
[void]$mode.Items.Add([pscustomobject]@{ Value = 'usb'; Label = 'USB only' })
[void]$mode.Items.Add([pscustomobject]@{ Value = 'wifi'; Label = 'Wi-Fi only (no USB cable)' })
$mode.SelectedIndex = 0
$layout.Controls.Add($mode, 0, 1)
foreach ($control in @($layout.Controls)) {
    $row = $layout.GetRow($control)

    if ($row -ge 6) {
        $layout.SetRow($control, $row + 1)
    }
}
$manualAddresses = New-Object System.Windows.Forms.CheckBox
$manualAddresses.Text = 'Enter addresses manually'
$manualAddresses.AutoSize = $true
$manualAddresses.Dock = 'Fill'
$layout.Controls.Add($manualAddresses, 0, 6)
$layout.RowCount = 13
while ($layout.RowStyles.Count -lt $layout.RowCount) {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
}

$createShortcut = New-Object System.Windows.Forms.CheckBox
$createShortcut.Text = 'Create a desktop shortcut'
$createShortcut.Checked = $true
$createShortcut.AutoSize = $true
$createShortcut.Dock = 'Fill'
$buttonRow = $layout.GetRow($buttons)
$layout.SetRow($buttons, $buttonRow + 1)
$layout.Controls.Add($createShortcut, 0, $buttonRow)
$layout.RowCount = $buttonRow + 2
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))

$manageButtons = New-Object Windows.Forms.FlowLayoutPanel
$manageButtons.AutoSize = $true
$manageButtons.Dock = 'Fill'
$shortcutNow = New-Object Windows.Forms.Button
$shortcutNow.Text = 'Create shortcut now'
$shortcutNow.AutoSize = $true
$changePhone = New-Object Windows.Forms.Button
$changePhone.Text = 'Set up another phone'
$changePhone.AutoSize = $true
$manageButtons.Controls.AddRange(@($shortcutNow, $changePhone))
$layout.Controls.Add($manageButtons, 0, $layout.RowCount)
$layout.RowCount++
$resetSetup = New-Object Windows.Forms.Button
$resetSetup.Text = 'Reset device setup...'
$resetSetup.AutoSize = $true
$resetSetup.Anchor = 'Left'
$resetSetup.Margin = New-Object Windows.Forms.Padding(3, 16, 3, 3)
$layout.Controls.Add($resetSetup, 0, $layout.RowCount)
$layout.RowCount++

# Restores the saved identity without requiring the phone to be online.
function Restore-SavedDevice {

    if (-not $script:savedConfiguration) {
        return
    }

    $savedSerial = $script:savedConfiguration.UsbSerial
    $savedItem = @($devices.Items | Where-Object { $_.Serial -eq $savedSerial })

    if (-not $savedItem.Count) {
        $savedItem = @([pscustomobject]@{ Serial = $savedSerial; Label = "Saved phone ($savedSerial)" })
        [void]$devices.Items.Add($savedItem[0])
    }

    $devices.SelectedItem = $savedItem[0]
}

# Creates the optional shortcut only after settings have been saved successfully.
function Complete-ShortcutSetup {

    if (-not $script:setupSaved -or -not $createShortcut.Checked) {
        return
    }

    try {
        . (Join-Path $script:setupRoot 'shortcut.ps1')
        New-DesktopShortcut -RootDirectory $script:setupRoot
    }
    catch {
        Show-ShortcutWarning
    }
}

# Reports a shortcut failure without treating saved device setup as a failure.
function Show-ShortcutWarning {
    [void][Windows.Forms.MessageBox]::Show($form, 'Device setup was saved, but the desktop shortcut could not be created. You can still launch the application from start.vbs in its folder.', 'scrcpy Seamless - Shortcut', 'OK', 'Warning')
}
# Runs cancellable ADB operations away from the Windows Forms thread.
function Start-SetupWork {
    param([string]$Operation, [hashtable]$Values = @{})

    if ($null -ne $script:pendingWork) {
        return
    }

    $cancellation = New-Object Threading.CancellationTokenSource
    $worker = [powershell]::Create()
    [void]$worker.AddScript({
        param($Directory, $Action, $InputValues, $Cancellation, $PairingState)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $Directory 'launcher-core.ps1')
        $script:setupCancellation = $Cancellation

        if ($Action -eq 'devices') {
            return @(Get-SetupDevices -RootDirectory $Directory)
        }

        if ($Action -eq 'pair') {

            if ($InputValues.ReuseExisting) {
                $PairingState = @{ Endpoint = $InputValues.ConnectionEndpoint; Serial = $InputValues.Serial; Existing = $true }
            }

            $configuration = Complete-WirelessPairing -RootDirectory $Directory -UsbSerial $InputValues.Serial -PairingCode $InputValues.Code -Endpoint $InputValues.Endpoint -ConnectionEndpoint $InputValues.ConnectionEndpoint -PairingState $PairingState
            $configuration | Add-Member -NotePropertyName ConnectionMode -NotePropertyValue $InputValues.Mode -Force
            return $configuration
        }

        $configuration = [pscustomobject]@{ UsbSerial = $InputValues.Serial; WirelessService = ''; ConnectionMode = 'usb' }
        return $configuration
    }).AddArgument($script:setupRoot).AddArgument($Operation).AddArgument($Values).AddArgument($cancellation).AddArgument($script:pairingState)
    $script:pendingWork = @{ Worker = $worker; Handle = $worker.BeginInvoke(); Operation = $Operation; Cancellation = $cancellation }
    Update-SetupActions
    $status.Text = 'Checking USB devices...'

    if ($Operation -eq 'pair') {
        $status.Text = 'Working... Keep your phone on the same Wi-Fi network and its pairing dialog open. This can take a moment.'
    }

    if ($Operation -eq 'pair' -and ($script:pairingState.Endpoint -or $Values.ReuseExisting)) {
        $status.Text = 'Pairing is available. Connecting and verifying your phone... Keep Wireless debugging enabled and both devices on the same network.'
    }

    if ($Operation -eq 'usb') {
        $status.Text = 'Saving USB settings...'
    }
}

# Reflects the selected transport mode without requiring hidden inputs.
function Update-SetupActions {
    $connectionMode = $mode.SelectedItem.Value
    $wifiInstructions.Text = 'Wi-Fi: connect both devices to the same network. On the phone (Android 11+), open Wireless debugging > Pair device with pairing code.'
    $pairingRow.GetControlFromPosition(0, 0).Text = 'Pairing code (6 digits)'

    if ($script:savedConfiguration -and $script:savedConfiguration.WirelessService) {
        $wifiInstructions.Text = 'Your saved pairing can be reused. Keep Wireless debugging enabled and both devices on the same network. Enter a new code only if the phone has forgotten this PC. To replace the phone, use Set up another phone.'
        $pairingRow.GetControlFromPosition(0, 0).Text = 'New pairing code (optional)'
    }

    $isIdle = $null -eq $script:pendingWork
    $needsUsb = $connectionMode -ne 'wifi'
    $needsWifi = $connectionMode -ne 'usb'
    $hasUsbDevice = $null -ne $devices.SelectedItem
    $canReuseWifi = Test-SavedWifiSelection
    $hasPairingCode = $pairingCode.Text -match '^\d{6}$'
    $usbReady = -not $needsUsb -or $hasUsbDevice
    $canRefreshConnection = $script:savedConfiguration -and $manualAddresses.Checked -and (Test-PairingEndpoint -Endpoint $connectionEndpoint.Text.Trim())
    $wifiReady = -not $needsWifi -or $hasPairingCode -or $canReuseWifi -or $script:pairingState.Endpoint -or $canRefreshConnection
    $canFinish = $isIdle -and $usbReady -and $wifiReady
    $finish.Enabled = $canFinish
    $finish.Text = 'Pair and finish'

    if ($canReuseWifi) {
        $finish.Text = 'Save settings'
    }

    if ($canRefreshConnection -and -not $hasPairingCode) {
        $finish.Text = 'Verify and save'
    }

    if ($script:pairingState.Endpoint) {
        $finish.Text = 'Retry connection'
    }

    if (-not $needsWifi) {
        $finish.Text = 'Save USB setup'
    }

    foreach ($control in $usbControls) {
        $control.Visible = $needsUsb
    }

    foreach ($control in $wifiControls) {
        $control.Visible = $needsWifi
    }

    $manualAddresses.Visible = $needsWifi
    foreach ($control in $manualControls) {
        $control.Visible = $needsWifi -and $manualAddresses.Checked
    }

    foreach ($control in @($mode, $devices, $refresh, $pairingCode, $manualAddresses, $endpoint, $connectionEndpoint, $createShortcut, $shortcutNow, $changePhone, $resetSetup)) {
        $control.Enabled = $isIdle
    }
}

# Explains the current mode when the user changes setup options.
function Update-SetupStatus {
    if ($script:savedConfiguration) {
        $status.Text = 'Saved phone: ' + $script:savedConfiguration.UsbSerial + '. Save to keep its pairing, or enter a new code to pair again. Set up another phone replaces settings only after saving.'
        return
    }

    $status.Text = 'Select an authorized USB phone and enter its Wi-Fi pairing code. USB + Wi-Fi requires both connections.'

    if ($mode.SelectedItem.Value -eq 'usb') {
        $status.Text = 'Connect your phone by USB, enable USB debugging, and approve this PC on your phone. No Wi-Fi pairing is needed.'
        return
    }

    if ($mode.SelectedItem.Value -eq 'wifi') {
        $status.Text = 'No USB cable is needed. Enter your phone pairing code. Enable manual addresses if automatic discovery cannot find it.'
    }
}

# Builds mode-specific input while ignoring values in hidden address fields.
function Get-SetupInput {
    $connectionMode = $mode.SelectedItem.Value
    $serial = ''

    if ($script:savedConfiguration) {
        $serial = $script:savedConfiguration.UsbSerial
    }

    if ($connectionMode -ne 'wifi' -and $null -ne $devices.SelectedItem) {
        $serial = $devices.SelectedItem.Serial
    }

    $pairingAddress = ''
    $connectionAddress = ''

    if ($manualAddresses.Checked -and $connectionMode -ne 'usb') {
        $pairingAddress = $endpoint.Text.Trim()
        $connectionAddress = $connectionEndpoint.Text.Trim()
    }

    $reuseExisting = $script:savedConfiguration -and -not $pairingCode.Text -and [bool]$connectionAddress
    return @{ ReuseExisting = $reuseExisting; Serial = $serial; Code = $pairingCode.Text; Mode = $connectionMode; Endpoint = $pairingAddress; ConnectionEndpoint = $connectionAddress }
}

# Reuses credentials only when the selected phone is the saved phone.
function Test-SavedWifiSelection {

    if (-not $script:savedConfiguration -or -not $script:savedConfiguration.WirelessService) {
        return $false
    }

    if ($pairingCode.Text -or $script:pairingState.Endpoint -or $manualAddresses.Checked) {
        return $false
    }

    if ($mode.SelectedItem.Value -eq 'wifi') {
        return $true
    }

    return $devices.SelectedItem -and $devices.SelectedItem.Serial -eq $script:savedConfiguration.UsbSerial
}

# Starts the single finish action for the selected transport mode.
function Complete-Setup {
    Update-SetupActions

    if (-not $finish.Enabled) {
        return
    }

    $values = Get-SetupInput

    if ($values.Mode -ne 'usb' -and (Test-SavedWifiSelection)) {
        try {
            $configuration = [pscustomobject]@{ UsbSerial = $values.Serial; WirelessService = $script:savedConfiguration.WirelessService; ConnectionMode = $values.Mode }
            Save-SetupConfiguration -Configuration $configuration
            $script:setupSaved = $true
            Complete-ShortcutSetup
            $form.DialogResult = 'OK'
            $form.Close()
        } catch {
            $status.Text = 'Settings could not be saved: ' + $_.Exception.Message
        }
        return
    }

    if ($values.Mode -eq 'usb') {
        Start-SetupWork -Operation 'usb' -Values $values
        return
    }

    $sameEndpoint = $values.Endpoint -and $values.Endpoint -eq $values.ConnectionEndpoint

    if ($sameEndpoint) {
        $status.Text = 'The pairing and connection ports are different. Use the pairing dialog address for Pairing IP:port, and the main Wireless debugging screen address for Connection IP:port.'
        return
    }

    Start-SetupWork -Operation 'pair' -Values $values
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $pending = $script:pendingWork

    if ($null -eq $pending) {
        return
    }

    if (-not $pending.Handle.IsCompleted) {
        return
    }

    try {
        $result = @($pending.Worker.EndInvoke($pending.Handle))

        if ($pending.Worker.HadErrors) {
            throw $pending.Worker.Streams.Error[0]
        }

        if ($pending.Cancellation.IsCancellationRequested) {
            throw [OperationCanceledException]::new('Setup cancelled. Saved settings were not changed.')
        }

        if ($pending.Operation -ne 'devices') {
            Save-SetupConfiguration -Configuration $result[0]
            $script:setupSaved = $true
            return
        }

        $devices.Items.Clear()
        $authorizedDevices = @($result | Where-Object { $_.State -eq 'device' })
        foreach ($device in $authorizedDevices) {
            [void]$devices.Items.Add([pscustomobject]@{ Serial = $device.Serial; Label = "$($device.Model) ($($device.Serial))" })
        }

        if ($authorizedDevices.Count -eq 1) {
            $devices.SelectedIndex = 0
        }

        Restore-SavedDevice
        Update-SetupStatus

        if (-not $script:savedConfiguration -and -not $authorizedDevices.Count -and $mode.SelectedItem.Value -ne 'wifi') {
            $status.Text = 'No authorized USB phone found. Connect and authorize your phone, then click Refresh, or select Wi-Fi only to continue without a cable.'
        }
    }
    catch {
        $message = $_.Exception.Message
        $secret = $pairingCode.Text

        if ($secret) {
            $message = $message.Replace($secret, '[redacted]')
        }

        $status.Text = "Setup could not finish: $message"

        if ($script:pairingState.Endpoint) {
            $status.Text = 'Pairing completed. Connection is not ready: ' + $message + ' Use Retry connection, or enter Connection IP:port. A new code is not required.'
        }

        if ($pending.Operation -eq 'devices') {
            $devices.Items.Clear()
            Restore-SavedDevice
            Update-SetupStatus

            if (-not $script:savedConfiguration -and $mode.SelectedItem.Value -ne 'wifi') {
                $status.Text = 'USB discovery did not finish. Check your USB connection and click Refresh, or select Wi-Fi only to continue without a cable.'
            }
        }
    }
    finally {

        if ($pending.Cancellation.IsCancellationRequested) {
            $status.Text = 'Operation cancelled. Saved settings were not changed.'

            if ($script:pairingState.Endpoint) {
                $status.Text += ' Phone pairing completed and remains available; retry the connection without a new code.'
            }
        }

        $pending.Worker.Dispose()
        $pending.Cancellation.Dispose()
        $script:pendingWork = $null

        if ($script:setupSaved) {
            Complete-ShortcutSetup
            $form.DialogResult = 'OK'
            $form.Close()
        }

        if (-not $script:setupSaved) {
            Update-SetupActions
        }
    }
})
$devices.Add_SelectedIndexChanged({ Update-SetupActions })
$pairingCode.Add_TextChanged({ $script:pairingState.Clear(); Update-SetupActions })
$connectionEndpoint.Add_TextChanged({ Update-SetupActions })
$mode.Add_SelectedIndexChanged({ Update-SetupActions; Update-SetupStatus })
$manualAddresses.Add_CheckedChanged({ Update-SetupActions })
if ($script:savedConfiguration) {
    $savedMode = Get-ConnectionMode -Configuration $script:savedConfiguration
    $mode.SelectedItem = @($mode.Items | Where-Object { $_.Value -eq $savedMode })[0]
    Restore-SavedDevice
}
Update-SetupActions
Update-SetupStatus
$refresh.Add_Click({ Start-SetupWork -Operation 'devices' })
$finish.Add_Click({ Complete-Setup })
$shortcutNow.Add_Click({
    try {
        . (Join-Path $script:setupRoot 'shortcut.ps1')
        New-DesktopShortcut -RootDirectory $script:setupRoot
        $status.Text = 'Desktop shortcut created. Device settings were not changed.'
    } catch {
        $status.Text = 'The shortcut could not be created: ' + $_.Exception.Message
    }
})
$changePhone.Add_Click({
    $script:savedConfiguration = $null
    $script:pairingState.Clear()
    $devices.Items.Clear()
    $pairingCode.Clear()
    $endpoint.Clear()
    $connectionEndpoint.Clear()
    Start-SetupWork -Operation 'devices'
})
# Clears saved and pending device setup while retaining unrelated application data.
function Reset-SetupState {

    if ($null -ne $script:pendingWork) {
        return
    }

    try {
        . (Join-Path $script:setupRoot 'reset.ps1')
        Assert-DeviceResetAvailable -RootDirectory $script:setupRoot
        $confirmation = [Windows.Forms.MessageBox]::Show($form, 'Remove the saved phone and connection settings? The next launch will require setup. Desktop shortcuts, logs, and phone pairing will remain. To forget this PC on the phone, open Wireless debugging > Paired devices > select this PC > Forget.', 'Reset device setup', 'YesNo', 'Warning', 'Button2')

        if ($confirmation -ne 'Yes') {
            return
        }

        [void](Reset-DeviceConfiguration -RootDirectory $script:setupRoot -Confirmed $true)
        $script:configurationSnapshot = $null
        $script:savedConfiguration = $null
        $script:setupSaved = $false
        $script:pairingState.Clear()
        $devices.Items.Clear()
        $pairingCode.Clear()
        $endpoint.Clear()
        $connectionEndpoint.Clear()
        $manualAddresses.Checked = $false
        $mode.SelectedIndex = 0
        Update-SetupActions
        $status.Text = 'Device setup was reset. Choose a connection mode to set up your phone again. Phone pairing, logs, and desktop shortcuts were kept.'
    }
    catch {
        $status.Text = 'Device setup could not be reset: ' + $_.Exception.Message
    }
}
$resetSetup.Add_Click({ Reset-SetupState })
$cancel.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    param($sender, $eventArguments)

    if ($null -ne $script:pendingWork -and -not $script:setupSaved) {
        $eventArguments.Cancel = $true
        $script:pendingWork.Cancellation.Cancel()
        $status.Text = 'Cancelling... Saved settings will not be changed. Any completed phone pairing remains available.'
    }
})
$form.Add_Shown({ $timer.Start(); Start-SetupWork -Operation 'devices' })
try {
    [void]$form.ShowDialog()
}
finally {
    $timer.Stop()
    $timer.Dispose()
    $pairingCode.Clear()
    $form.Dispose()
}

if ($script:setupSaved) {
    exit 0
}

exit 1
