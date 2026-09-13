param([string]$RootDirectory = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:setupRoot = [System.IO.Path]::GetFullPath($RootDirectory)
$script:pendingWork = $null
$script:setupSaved = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'scrcpy Seamless - Device setup'
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

$layout.Controls.Add((New-SetupLabel 'Connect your phone by USB, unlock it, enable USB debugging, and accept the authorization prompt on the phone.'), 0, 0)
$layout.Controls.Add((New-SetupLabel '1. Select your authorized USB phone'), 0, 1)
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
$layout.Controls.Add((New-SetupLabel '2. Optional Wi-Fi fallback (Android 11+). Connect the phone and PC to the same network. On the phone, open Wireless debugging > Pair device with pairing code.'), 0, 3)

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
$usbOnly = New-Object System.Windows.Forms.Button
$usbOnly.Text = 'Use USB only'
$usbOnly.AutoSize = $true
$pair = New-Object System.Windows.Forms.Button
$pair.Text = 'Pair and finish'
$pair.AutoSize = $true
$buttons.Controls.AddRange(@($cancel, $usbOnly, $pair))
$layout.Controls.Add($buttons, 0, 10)

# Runs ADB and configuration writes away from the Windows Forms thread.
function Start-SetupWork {
    param([string]$Operation, [hashtable]$Values = @{})

    if ($null -ne $script:pendingWork) {
        return
    }

    $worker = [powershell]::Create()
    [void]$worker.AddScript({
        param($Directory, $Action, $InputValues)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $Directory 'launcher-core.ps1')

        if ($Action -eq 'devices') {
            return @(Get-SetupDevices -RootDirectory $Directory)
        }

        if ($Action -eq 'pair') {
            $configuration = Complete-WirelessPairing -RootDirectory $Directory -UsbSerial $InputValues.Serial -PairingCode $InputValues.Code -Endpoint $InputValues.Endpoint -ConnectionEndpoint $InputValues.ConnectionEndpoint
            Save-PhoneConfiguration -RootDirectory $Directory -Configuration $configuration
            return
        }

        $configuration = [pscustomobject]@{ UsbSerial = $InputValues.Serial; WirelessService = '' }
        Save-PhoneConfiguration -RootDirectory $Directory -Configuration $configuration
    }).AddArgument($script:setupRoot).AddArgument($Operation).AddArgument($Values)
    $script:pendingWork = @{ Worker = $worker; Handle = $worker.BeginInvoke(); Operation = $Operation }
    $devices.Enabled = $false
    $refresh.Enabled = $false
    $pair.Enabled = $false
    $usbOnly.Enabled = $false
    $pairingCode.Enabled = $false
    $endpoint.Enabled = $false
    $connectionEndpoint.Enabled = $false
    $cancel.Enabled = $false
    $status.Text = 'Checking USB devices...'

    if ($Operation -ne 'devices') {
        $status.Text = 'Working... Keep your phone connected and the pairing dialog open. This can take a moment.'
    }
}

# Enables actions only when an authorized phone has been selected.
function Update-SetupActions {
    $selectedDevice = $devices.SelectedItem
    $hasDevice = $null -ne $selectedDevice
    $usbOnly.Enabled = $hasDevice
    $pair.Enabled = $hasDevice
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

        if ($pending.Operation -ne 'devices') {
            $script:setupSaved = $true
            return
        }

        $devices.Items.Clear()
        $authorizedDevices = @($result | Where-Object { $_.State -eq 'device' })
        foreach ($device in $authorizedDevices) {
            [void]$devices.Items.Add([pscustomobject]@{ Serial = $device.Serial; Label = "$($device.Model) ($($device.Serial))" })
        }

        if ($devices.Items.Count -eq 1) {
            $devices.SelectedIndex = 0
        }

        $status.Text = 'Select your phone, then configure Wi-Fi or choose Use USB only. Settings are saved only when you finish.'

        if (-not $authorizedDevices.Count) {
            $status.Text = 'No authorized USB phone found. Enable USB debugging and accept the prompt on your unlocked phone, then click Refresh. If no prompt appears, check the USB cable and install the phone manufacturer''s USB driver if needed.'
        }
    }
    catch {
        $message = $_.Exception.Message
        $secret = $pairingCode.Text

        if ($secret) {
            $message = $message.Replace($secret, '[redacted]')
        }

        $status.Text = "Setup could not finish: $message"
    }
    finally {
        $pending.Worker.Dispose()
        $script:pendingWork = $null

        if ($script:setupSaved) {
            $form.DialogResult = 'OK'
            $form.Close()
        }

        if (-not $script:setupSaved) {
            $devices.Enabled = $true
            $refresh.Enabled = $true
            $pairingCode.Enabled = $true
            $endpoint.Enabled = $true
            $connectionEndpoint.Enabled = $true
            $cancel.Enabled = $true
            Update-SetupActions
        }
    }
})
$devices.Add_SelectedIndexChanged({ Update-SetupActions })
$refresh.Add_Click({ Start-SetupWork -Operation 'devices' })
$usbOnly.Add_Click({
    $selection = $devices.SelectedItem

    if ($null -eq $selection) {
        return
    }

    Start-SetupWork -Operation 'usb' -Values @{ Serial = $selection.Serial }
})
$pair.Add_Click({
    $selection = $devices.SelectedItem

    if ($null -eq $selection) {
        return
    }

    if ($pairingCode.Text -notmatch '^\d{6}$') {
        $status.Text = 'Enter the current six-digit code shown in the phone''s pairing dialog.'
        return
    }

    Start-SetupWork -Operation 'pair' -Values @{ Serial = $selection.Serial; Code = $pairingCode.Text; Endpoint = $endpoint.Text.Trim(); ConnectionEndpoint = $connectionEndpoint.Text.Trim() }
})
$cancel.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    param($sender, $eventArguments)

    if ($null -ne $script:pendingWork -and -not $script:setupSaved) {
        $eventArguments.Cancel = $true
        $status.Text = 'Please wait for the current operation to finish before closing setup.'
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
