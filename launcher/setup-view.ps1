# Create a consistently docked explanatory label.
function New-SetupLabel {
    param([string]$Text)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = 'Fill'
    $label.AutoSize = $true
    $label.Margin = New-Object Windows.Forms.Padding(3, 6, 3, 6)
    $label.TextAlign = 'MiddleLeft'
    return $label
}

# Build a labelled text field with the same responsive columns in every section.
function New-SetupInputField {
    param([string]$Text, $InputControl)
    $labelColumnWidth = 200
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Fill'
    $row.AutoSize = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.ColumnCount = 2
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', $labelColumnWidth)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $label = New-SetupLabel -Text $Text
    $InputControl.Dock = 'Fill'
    $row.Controls.Add($label, 0, 0)
    $row.Controls.Add($InputControl, 1, 0)
    return @{ Row = $row; Label = $label }
}

# Append named rows once in display order, with content-sized spacing throughout.
function Add-SetupLayoutRows {
    param($Layout, [Collections.Specialized.OrderedDictionary]$Rows)
    $Layout.RowCount = $Rows.Count
    $rowIndex = 0

    foreach ($entry in $Rows.GetEnumerator()) {
        [void]$Layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
        $Layout.Controls.Add($entry.Value, 0, $rowIndex)
        $rowIndex++
    }
}

# Create settings controls without entering a message loop.
function New-SetupView {
    param([hashtable]$Session, [string]$Version = '')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = 'scrcpy Seamless - Settings'

    if ($Version) {
        $form.Text += ' - ' + $Version
    }

    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(700, 610)
    $form.MinimumSize = New-Object Drawing.Size(620, 580)
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.AutoScaleMode = 'Dpi'
    $scrollPanel = New-Object Windows.Forms.Panel
    $scrollPanel.Dock = 'Fill'
    $scrollPanel.AutoScroll = $true
    $form.Controls.Add($scrollPanel)
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Top'
    $layout.AutoSize = $true
    $layout.AutoSizeMode = 'GrowAndShrink'
    $layout.Padding = New-Object Windows.Forms.Padding(20)
    $layout.ColumnCount = 1
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $scrollPanel.Controls.Add($layout)

    $introduction = New-SetupLabel 'Choose how scrcpy connects. USB + Wi-Fi uses USB when available and reconnects wirelessly if the cable is removed.'
    $mode = New-Object Windows.Forms.ComboBox
    $mode.Dock = 'Fill'
    $mode.DropDownStyle = 'DropDownList'
    $mode.DisplayMember = 'Label'
    [void]$mode.Items.Add([pscustomobject]@{ Value = 'auto'; Label = 'USB + Wi-Fi (recommended)' })
    [void]$mode.Items.Add([pscustomobject]@{ Value = 'usb'; Label = 'USB only' })
    [void]$mode.Items.Add([pscustomobject]@{ Value = 'wifi'; Label = 'Wi-Fi only (no USB cable)' })
    $mode.SelectedIndex = 0

    $usbInstructions = New-SetupLabel 'USB: connect and authorize your phone, then select it below.'
    $refreshButtonColumnWidth = 110
    $deviceRow = New-Object Windows.Forms.TableLayoutPanel
    $deviceRow.Dock = 'Fill'
    $deviceRow.AutoSize = $true
    $deviceRow.AutoSizeMode = 'GrowAndShrink'
    $deviceRow.ColumnCount = 2
    [void]$deviceRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$deviceRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', $refreshButtonColumnWidth)))
    $devices = New-Object Windows.Forms.ComboBox
    $devices.Dock = 'Fill'
    $devices.DropDownStyle = 'DropDownList'
    $devices.DisplayMember = 'Label'
    $refresh = New-Object Windows.Forms.Button
    $refresh.Text = 'Refresh'
    $refresh.Dock = 'Fill'
    $deviceRow.Controls.Add($devices, 0, 0)
    $deviceRow.Controls.Add($refresh, 1, 0)

    $wifiInstructions = New-SetupLabel ''
    $pairingCode = New-Object Windows.Forms.TextBox
    $pairingCode.MaxLength = 6
    $pairingCode.UseSystemPasswordChar = $true
    $pairingField = New-SetupInputField -Text 'Pairing code (6 digits)' -InputControl $pairingCode
    $pairingRow = $pairingField.Row
    $manualAddresses = New-Object Windows.Forms.CheckBox
    $manualAddresses.Text = 'Enter addresses manually'
    $manualAddresses.AutoSize = $true
    $manualAddresses.Dock = 'Fill'
    $endpoint = New-Object Windows.Forms.TextBox
    $endpointField = New-SetupInputField -Text 'Pairing IP:port (optional)' -InputControl $endpoint
    $endpointRow = $endpointField.Row
    $pairingHint = New-SetupLabel 'Leave blank to try automatic discovery. If your phone cannot be identified automatically, enter the address shown in its pairing dialog.'
    $connectionEndpoint = New-Object Windows.Forms.TextBox
    $connectionField = New-SetupInputField -Text 'Connection IP:port' -InputControl $connectionEndpoint
    $connectionRow = $connectionField.Row
    $connectionHint = New-SetupLabel 'Only if discovery fails: use the address on the main Wireless debugging screen, not the pairing dialog.'

    $status = New-SetupLabel ''
    $status.TextAlign = 'TopLeft'
    $status.AutoEllipsis = $false
    $status.Padding = New-Object Windows.Forms.Padding(0, 14, 0, 0)
    $createShortcut = New-Object Windows.Forms.CheckBox
    $createShortcut.Text = 'Create a desktop shortcut'
    $createShortcut.Checked = $true
    $createShortcut.AutoSize = $true
    $createShortcut.Dock = 'Fill'
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.WrapContents = $true
    $buttons.AutoSize = $true
    $buttons.AutoSizeMode = 'GrowAndShrink'
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.AutoSize = $true
    $finish = New-Object Windows.Forms.Button
    $finish.Text = 'Pair and finish'
    $finish.AutoSize = $true
    $buttons.Controls.AddRange(@($cancel, $finish))
    $manageButtons = New-Object Windows.Forms.FlowLayoutPanel
    $manageButtons.AutoSize = $true
    $manageButtons.AutoSizeMode = 'GrowAndShrink'
    $manageButtons.Dock = 'Fill'
    $shortcutNow = New-Object Windows.Forms.Button
    $shortcutNow.Text = 'Create shortcut now'
    $shortcutNow.AutoSize = $true
    $changePhone = New-Object Windows.Forms.Button
    $changePhone.Text = 'Set up another phone'
    $changePhone.AutoSize = $true
    $manageButtons.Controls.AddRange(@($shortcutNow, $changePhone))
    $resetSetup = New-Object Windows.Forms.Button
    $resetSetup.Text = 'Reset device setup...'
    $resetSetup.AutoSize = $true
    $resetSetup.Anchor = 'Top, Left'
    $resetSetup.Margin = New-Object Windows.Forms.Padding(3, 16, 3, 3)

    $rows = [ordered]@{
        Introduction = $introduction
        ConnectionMode = $mode
        UsbInstructions = $usbInstructions
        Devices = $deviceRow
        WifiInstructions = $wifiInstructions
        PairingCode = $pairingRow
        ManualAddresses = $manualAddresses
        PairingAddress = $endpointRow
        PairingHint = $pairingHint
        ConnectionAddress = $connectionRow
        ConnectionHint = $connectionHint
        Status = $status
        ShortcutOption = $createShortcut
        Completion = $buttons
        Management = $manageButtons
        Reset = $resetSetup
    }
    Add-SetupLayoutRows -Layout $layout -Rows $rows
    $usbControls = @($usbInstructions, $deviceRow)
    $wifiControls = @($wifiInstructions, $pairingRow)
    $manualControls = @($endpointRow, $pairingHint, $connectionRow, $connectionHint)

    $view = @{
        Session = $Session
        Form = $form
        Layout = $layout
        Panel = $scrollPanel
        Rendering = $false
        RenderedDevices = $null
        Mode = $mode
        Devices = $devices
        Refresh = $refresh
        PairingCode = $pairingCode
        Endpoint = $endpoint
        ConnectionEndpoint = $connectionEndpoint
        ManualAddresses = $manualAddresses
        CreateShortcut = $createShortcut
        Finish = $finish
        Cancel = $cancel
        ShortcutNow = $shortcutNow
        ChangePhone = $changePhone
        ResetSetup = $resetSetup
        Status = $status
        WifiInstructions = $wifiInstructions
        PairingRow = $pairingRow
        PairingLabel = $pairingField.Label
        Rows = $rows
        UsbControls = $usbControls
        WifiControls = $wifiControls
        ManualControls = $manualControls
        EditableControls = @($mode, $devices, $refresh, $pairingCode, $manualAddresses, $endpoint, $connectionEndpoint, $createShortcut, $shortcutNow, $changePhone, $resetSetup)
    }
    $inputChanged = {

        if ($view.Rendering) {
            return
        }

        $previousMode = $view.Session.Input.Mode
        Set-SetupInput -Session $view.Session -Values (Get-SetupViewInput -View $view)

        if ($previousMode -ne $view.Session.Input.Mode) {
            Update-SetupStatus -Session $view.Session
        }

        Update-SetupView -View $view
    }.GetNewClosure()
    $devices.Add_SelectedIndexChanged($inputChanged)
    $mode.Add_SelectedIndexChanged($inputChanged)
    $pairingCode.Add_TextChanged($inputChanged)
    $endpoint.Add_TextChanged($inputChanged)
    $connectionEndpoint.Add_TextChanged($inputChanged)
    $manualAddresses.Add_CheckedChanged($inputChanged)
    $createShortcut.Add_CheckedChanged($inputChanged)
    $refresh.Add_Click({
        Start-SetupWork -Session $view.Session -Operation 'devices'
        Update-SetupView -View $view
    }.GetNewClosure())
    $finish.Add_Click({
        Complete-Setup -Session $view.Session
        Update-SetupView -View $view
        Complete-SetupView -View $view
    }.GetNewClosure())
    $shortcutNow.Add_Click({
        New-SetupShortcut -Session $view.Session
        Update-SetupView -View $view
    }.GetNewClosure())
    $changePhone.Add_Click({
        Start-AnotherPhoneSetup -Session $view.Session
        Update-SetupView -View $view
    }.GetNewClosure())
    $resetSetup.Add_Click({
        try {
            & $view.Session.Dependencies.AssertResetAvailable -RootDirectory $view.Session.RootDirectory
            $confirmation = [Windows.Forms.MessageBox]::Show($view.Form, 'Remove the saved phone and connection settings? The next launch will require setup. Desktop shortcuts, logs, and phone pairing will remain. To forget this PC on the phone, open Wireless debugging > Paired devices > select this PC > Forget.', 'Reset device setup', 'YesNo', 'Warning', 'Button2')
            Reset-SetupState -Session $view.Session -Confirmed ($confirmation -eq 'Yes')
        } catch {
            $view.Session.Status = 'Device setup could not be reset: ' + $_.Exception.Message
        }

        Update-SetupView -View $view
    }.GetNewClosure())
    $cancel.Add_Click({ $view.Form.Close() }.GetNewClosure())
    $form.Add_FormClosing({
        param($sender, $eventArguments)

        if ($view.Session.Outcome -eq 'Saved') {
            return
        }

        $eventArguments.Cancel = -not (Request-SetupCancellation -Session $view.Session)
        Update-SetupView -View $view
    }.GetNewClosure())
    $timer = New-Object Windows.Forms.Timer
    $uiRefreshIntervalMilliseconds = 150
    $timer.Interval = $uiRefreshIntervalMilliseconds
    $timer.Add_Tick({
        Update-SetupSession -Session $view.Session
        Update-SetupView -View $view
        Complete-SetupView -View $view
    }.GetNewClosure())
    $view.Timer = $timer
    $form.Add_Shown({
        $view.Timer.Start()
        Start-SetupWork -Session $view.Session -Operation 'devices'
        Update-SetupView -View $view
    }.GetNewClosure())
    Update-SetupView -View $view
    return $view
}

# Read only editable values at the view boundary, never pass controls to a controller.
function Get-SetupViewInput {
    param([hashtable]$View)
    $serial = ''

    if ($null -ne $View.Devices.SelectedItem) {
        $serial = $View.Devices.SelectedItem.Serial
    }

    return @{
        Mode = $View.Mode.SelectedItem.Value
        SelectedSerial = $serial
        PairingCode = $View.PairingCode.Text
        ManualAddresses = $View.ManualAddresses.Checked
        PairingEndpoint = $View.Endpoint.Text
        ConnectionEndpoint = $View.ConnectionEndpoint.Text
        CreateShortcut = $View.CreateShortcut.Checked
    }
}

# Render session data without firing input commands recursively.
function Update-SetupView {
    param([hashtable]$View)
    $session = $View.Session
    $actions = Get-SetupActionState -Session $session
    $View.Rendering = $true

    try {
        $View.Status.Text = $session.Status
        $View.Finish.Enabled = $actions.CanFinish
        $View.Finish.Text = $actions.FinishText
        $View.WifiInstructions.Text = $actions.WifiInstructions
        $View.PairingLabel.Text = $actions.PairingLabel

        foreach ($control in $View.UsbControls) {
            $control.Visible = $actions.NeedsUsb
        }

        foreach ($control in $View.WifiControls) {
            $control.Visible = $actions.NeedsWifi
        }

        $View.ManualAddresses.Visible = $actions.NeedsWifi

        foreach ($control in $View.ManualControls) {
            $control.Visible = $actions.ShowManualAddresses
        }

        foreach ($control in $View.EditableControls) {
            $control.Enabled = $actions.IsIdle
        }

        $View.Mode.SelectedItem = @($View.Mode.Items | Where-Object { $_.Value -eq $session.Input.Mode })[0]

        if (-not [object]::ReferenceEquals($View.RenderedDevices, $session.Devices)) {
            $View.Devices.BeginUpdate()

            try {
                $View.Devices.Items.Clear()

                foreach ($device in $session.Devices) {
                    [void]$View.Devices.Items.Add($device)
                }

                $View.RenderedDevices = $session.Devices
            } finally {
                $View.Devices.EndUpdate()
            }
        }

        $selected = @($View.Devices.Items | Where-Object { $_.Serial -eq $session.Input.SelectedSerial })

        if ($selected.Count) {
            $View.Devices.SelectedItem = $selected[0]
        }

        $View.PairingCode.Text = $session.Input.PairingCode
        $View.Endpoint.Text = $session.Input.PairingEndpoint
        $View.ConnectionEndpoint.Text = $session.Input.ConnectionEndpoint
        $View.ManualAddresses.Checked = $session.Input.ManualAddresses
        $View.CreateShortcut.Checked = $session.Input.CreateShortcut
    } finally {
        $View.Rendering = $false
    }
}

# Deliver optional notifications and close only after controller completion.
function Complete-SetupView {
    param([hashtable]$View)

    if ($View.Session.Outcome -ne 'Saved') {
        return
    }

    if ($View.Session.Warning) {
        [void][Windows.Forms.MessageBox]::Show($View.Form, $View.Session.Warning, 'scrcpy Seamless - Shortcut', 'OK', 'Warning')
        $View.Session.Warning = ''
    }

    $View.Form.DialogResult = 'OK'
    $View.Form.Close()
}

# Dispose view resources independently of session cancellation and persistence.
function Close-SetupView {
    param([hashtable]$View)
    $View.Timer.Stop()
    $View.Timer.Dispose()
    $View.Rendering = $true
    $View.PairingCode.Clear()
    $View.Form.Dispose()
}

