# Construct the waiting window and bind caller-provided actions without starting a loop.
function New-LaunchView {
    param([string]$Version, [hashtable]$Actions)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object Windows.Forms.Form
    $form.Text = 'scrcpy Seamless ' + $Version + ' - Connecting'
    $form.ClientSize = New-Object Drawing.Size(560, 215)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.AutoScaleMode = 'Dpi'
    $status = New-Object Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(20, 20)
    $status.Size = New-Object Drawing.Size(520, 45)
    $hint = New-Object Windows.Forms.Label
    $hint.Location = New-Object Drawing.Point(20, 70)
    $hint.Size = New-Object Drawing.Size(520, 75)
    $buttons = @{}

    foreach ($specification in @(@('Logs','Open logs',20), @('Retry','Retry now',200), @('Settings','Settings',315), @('Cancel','Cancel',430))) {
        $button = New-Object Windows.Forms.Button
        $button.Text = $specification[1]
        $button.Location = New-Object Drawing.Point($specification[2], 165)
        $button.Size = New-Object Drawing.Size(105, 32)
        $buttons[$specification[0]] = $button
        $form.Controls.Add($button)
    }

    $buttons.Retry.Add_Click(({ & $Actions.Retry }).GetNewClosure())
    $buttons.Settings.Add_Click(({ & $Actions.Settings }).GetNewClosure())
    $buttons.Logs.Add_Click(({ & $Actions.Logs }).GetNewClosure())
    $buttons.Cancel.Add_Click(({ $form.Close() }).GetNewClosure())
    $form.Add_FormClosing(({
        param($Sender, $EventArguments)
        $EventArguments.Cancel = -not (& $Actions.Close)
    }).GetNewClosure())
    $form.Controls.AddRange(@($status, $hint))
    $form.CancelButton = $buttons.Cancel
    return @{ Form = $form; Status = $status; Hint = $hint; Retry = $buttons.Retry; Settings = $buttons.Settings }
}

# Focus the existing child window, or keep the waiting window usable before HWND exists.
function Show-LaunchViewFocus {
    param($View, $Process)

    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Refresh()

        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            $shell = New-Object -ComObject WScript.Shell

            try {
                $null = $shell.AppActivate($Process.Id)
            } finally {
                $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }

            return
        }
    }

    $View.Form.Show()
    $View.Form.WindowState = 'Normal'
    $View.Form.Activate()
}

# Render a controller snapshot without changing connection decisions.
function Update-LaunchView {
    param($View, $Presentation)
    $View.Status.Text = $Presentation.Status
    $View.Hint.Text = $Presentation.Hint
    $View.Retry.Enabled = $Presentation.RetryEnabled
    $View.Settings.Enabled = $Presentation.SettingsEnabled

    if ($Presentation.CloseRequested) {
        $View.Form.Close()
        return
    }

    if (-not $Presentation.Visible) {
        $View.Form.Hide()
    }

    if ($Presentation.Visible -and -not $View.Form.Visible) {
        $View.Form.Show()
    }

    if ($Presentation.FocusRequested) {
        Show-LaunchViewFocus -View $View -Process $Presentation.FocusProcess
    }
}
