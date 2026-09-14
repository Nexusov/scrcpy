param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent), [string]$PreviewDirectory = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'launcher/setup-session.ps1')
. (Join-Path $ProjectRoot 'launcher/setup-view.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-settings-view-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$checks = 0
$shortcutCount = 0

# Fail with the visible or controller invariant that regressed.
function Assert-SetupView {
    param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }

    $script:checks++
}

# Inject an asynchronous phone boundary while running production completion logic.
function New-ViewTestWorker {
    param($RootDirectory, $Operation, $Values, $PairingState)
    $worker = [PowerShell]::Create()
    $cancellation = New-Object Threading.CancellationTokenSource
    [void]$worker.AddScript({
        param($Operation, $Values)
        Start-Sleep -Milliseconds 50

        if ($Operation -eq 'devices') {
            return [pscustomobject]@{ Serial = 'test-phone'; State = 'device'; Model = 'Test phone' }
        }

        $service = ''

        if ($Operation -ne 'usb') {
            $service = '192.168.1.8:40001'
        }

        return [pscustomobject]@{ UsbSerial = 'test-phone'; WirelessService = $service; ConnectionMode = $Values.Mode }
    }).AddArgument($Operation).AddArgument($Values)
    return @{ Worker = $worker; Handle = $worker.BeginInvoke(); Cancellation = $cancellation; Operation = $Operation; Secret = $Values.Code }
}

# Wait for test work using production controller updates without a GUI event loop.
function Wait-ViewTestWorker {
    param([hashtable]$View)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while ($null -ne $View.Session.PendingWork) {

        if ([DateTime]::UtcNow -gt $deadline) {
            throw 'Test worker timed out.'
        }

        Start-Sleep -Milliseconds 20
        Update-SetupSession -Session $View.Session
    }

    Update-SetupView -View $View
}

try {
    $dependencies = @{
        StartWork = { param($RootDirectory, $Operation, $Values, $PairingState) New-ViewTestWorker @PSBoundParameters }
        CreateShortcut = { param($RootDirectory) $script:shortcutCount++ }
    }

    foreach ($modeName in @('auto', 'usb', 'wifi')) {
        $modeDirectory = Join-Path $directory $modeName
        [void][IO.Directory]::CreateDirectory($modeDirectory)
        $session = New-SetupSession -RootDirectory $modeDirectory -Dependencies $dependencies
        $view = New-SetupView -Session $session

        try {
            # Detach the layout for hidden rendering so Visible reflects each control itself.
            $view.Layout.Font = $view.Form.Font
            $view.Panel.Controls.Remove($view.Layout)
            $view.Layout.Width = $view.Form.ClientSize.Width
            $view.Layout.CreateControl()
            Assert-SetupView ($view.Layout.RowStyles.Count -eq $view.Rows.Count) 'Layout has implicit rows with inconsistent spacing.'
            Assert-SetupView (-not @($view.Layout.RowStyles | Where-Object { $_.SizeType -ne 'AutoSize' }).Count) 'Layout includes a row that cannot size to its content.'

            $view.Mode.SelectedItem = @($view.Mode.Items | Where-Object { $_.Value -eq $modeName })[0]
            $view.CreateShortcut.Checked = $modeName -ne 'usb'
            Assert-SetupView ($view.UsbControls[1].Visible -eq ($modeName -ne 'wifi')) "Incorrect USB visibility for $modeName."
            Assert-SetupView ($view.PairingRow.Visible -eq ($modeName -ne 'usb')) "Incorrect Wi-Fi visibility for $modeName."
            Assert-SetupView $view.CreateShortcut.Visible "Shortcut option hidden for $modeName."
            Assert-SetupView (-not $view.ManualControls[0].Visible -and -not $view.Finish.Enabled) "Invalid initial fields for $modeName."
            $view.PairingCode.Text = '123456'
            Assert-SetupView (-not $view.PairingCode.UseSystemPasswordChar) 'Pairing code is hidden by default.'
            Assert-SetupView ($view.HidePairingCode.Visible -eq ($modeName -ne 'usb')) "Incorrect masking option visibility for $modeName."
            $view.HidePairingCode.Checked = $true
            Assert-SetupView $view.PairingCode.UseSystemPasswordChar 'Hide pairing code did not mask the field.'
            Assert-SetupView ($session.Input.PairingCode -eq '123456') 'Masking changed the pairing code.'
            $view.HidePairingCode.Checked = $false
            Assert-SetupView (-not $view.PairingCode.UseSystemPasswordChar -and $view.PairingCode.Text -eq '123456') 'Showing the code changed its value.'
            Assert-SetupView ($view.Finish.Enabled -eq ($modeName -eq 'wifi')) "Incorrect cable requirement for $modeName."
            $countBefore = $shortcutCount
            Start-SetupWork -Session $session -Operation 'devices'
            Update-SetupView -View $view
            Assert-SetupView (-not $view.Mode.Enabled -and -not $view.Finish.Enabled -and $view.Cancel.Enabled) 'Busy operation did not retain Cancel while disabling edit actions.'
            Wait-ViewTestWorker -View $view
            Assert-SetupView $view.Finish.Enabled "Finish did not enable after discovery for $modeName."
            $view.ManualAddresses.Checked = $true
            Assert-SetupView ($view.ManualControls[0].Visible -eq ($modeName -ne 'usb')) "Incorrect manual fields for $modeName."
            $view.Endpoint.Text = '192.168.1.8:12345'
            $view.ConnectionEndpoint.Text = '192.168.1.8:12345'

            if ($modeName -ne 'usb') {
                Complete-Setup -Session $session
                Assert-SetupView ($null -eq $session.PendingWork -and $session.Status -match 'ports are different') 'Identical pairing and connection endpoints were accepted.'
            }

            $view.ManualAddresses.Checked = $false
            $values = Get-SetupInput -Session $session
            Assert-SetupView (-not $values.Endpoint -and -not $values.ConnectionEndpoint) 'Hidden manual values reached the operation.'

            if ($modeName -eq 'wifi') {
                Assert-SetupView (-not $values.Serial) 'Fresh Wi-Fi mode forwarded a hidden USB identity.'
            }

            if ($PreviewDirectory) {
                [void][IO.Directory]::CreateDirectory($PreviewDirectory)
                $view.Layout.PerformLayout()
                $bitmap = New-Object Drawing.Bitmap($view.Layout.Width, $view.Layout.Height)

                try {
                    $view.Layout.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
                    $bitmap.Save((Join-Path $PreviewDirectory "settings-$modeName.png"), [Drawing.Imaging.ImageFormat]::Png)
                } finally {
                    $bitmap.Dispose()
                }
            }

            Complete-Setup -Session $session
            Wait-ViewTestWorker -View $view
            $saved = Get-PhoneConfiguration -RootDirectory $modeDirectory
            Assert-SetupView ($saved.ConnectionMode -eq $modeName -and $session.Outcome -eq 'Saved') "Incorrect saved mode for $modeName."
            Assert-SetupView ($shortcutCount -eq $countBefore + [int]$session.Input.CreateShortcut) "Shortcut checkbox ignored for $modeName."

            if ($modeName -eq 'usb') {
                Assert-SetupView (-not $saved.WirelessService) 'USB settings retained Wi-Fi service.'
            }
        } finally {
            Close-SetupSession -Session $session
            Close-SetupView -View $view
            $view.Layout.Dispose()
        }
    }

    $session = New-SetupSession -RootDirectory $directory -Dependencies $dependencies
    $beforeCancel = $shortcutCount
    Assert-SetupView (Request-SetupCancellation -Session $session) 'Idle settings cancellation was refused.'
    Assert-SetupView ($shortcutCount -eq $beforeCancel -and -not (Test-Path (Join-Path $directory 'phone.json'))) 'Cancel created a shortcut or saved settings.'

    # A worker error must redact its submitted code, even if the draft later changes.
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript({ throw 'Phone rejected code 123456' })
    $session.PendingWork = @{ Worker = $worker; Handle = $worker.BeginInvoke(); Cancellation = New-Object Threading.CancellationTokenSource; Operation = 'pair'; Secret = '123456' }
    $session.Input.PairingCode = '654321'
    $session.PairingState.Endpoint = '192.168.1.8:12345'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while ($null -ne $session.PendingWork -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 20
        Update-SetupSession -Session $session
    }

    Assert-SetupView ($session.Status -match '\[redacted\]' -and $session.Status -notmatch '123456') 'Worker error exposed a pairing code.'
    Assert-SetupView ($session.Status -match 'Pairing completed' -and $session.PairingState.Endpoint) 'Connect failure lost retained pairing state.'
    Close-SetupSession -Session $session

    # Long saved-device guidance and manual fields must wrap without overlap at both supported widths.
    $savedDirectory = Join-Path $directory 'saved-layout'
    [void][IO.Directory]::CreateDirectory($savedDirectory)
    $savedConfiguration = [pscustomobject]@{ UsbSerial = 'phone-with-a-long-serial-123456789'; WirelessService = '192.168.1.8:40001'; ConnectionMode = 'auto' }
    Save-PhoneConfiguration -RootDirectory $savedDirectory -Configuration $savedConfiguration

    foreach ($layoutWidth in @(620, 700)) {
        $session = New-SetupSession -RootDirectory $savedDirectory -Dependencies $dependencies
        $session.Input.ManualAddresses = $true
        $view = New-SetupView -Session $session

        try {
            $view.Layout.Font = $view.Form.Font
            $view.Panel.Controls.Remove($view.Layout)
            $view.Layout.Width = $layoutWidth
            $view.Layout.CreateControl()
            $view.Layout.PerformLayout()
            $previousBottom = 0

            foreach ($entry in $view.Rows.GetEnumerator()) {
                $control = $entry.Value

                if (-not $control.Visible) {
                    continue
                }

                Assert-SetupView ($control.Top -ge $previousBottom) "Visible rows overlap at $layoutWidth pixels: $($entry.Key)."
                Assert-SetupView ($control.Left -ge 0 -and $control.Right -le $view.Layout.Width) "Row exceeds available width at $layoutWidth pixels: $($entry.Key)."
                $previousBottom = $control.Bottom
            }

            $expectedResetTop = $view.Rows.Management.Bottom + $view.Rows.Management.Margin.Bottom + $view.ResetSetup.Margin.Top
            Assert-SetupView ($view.ResetSetup.Top -eq $expectedResetTop) "An empty layout gap remains above Reset at $layoutWidth pixels."
            $requiredStatusHeight = $view.Status.GetPreferredSize((New-Object Drawing.Size($view.Status.Width, 0))).Height
            Assert-SetupView ($view.Status.Height -ge $requiredStatusHeight) "Saved-device status is clipped at $layoutWidth pixels."

            if ($PreviewDirectory) {
                $bitmap = New-Object Drawing.Bitmap($view.Layout.Width, $view.Layout.Height)

                try {
                    $view.Layout.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
                    $bitmap.Save((Join-Path $PreviewDirectory "settings-saved-manual-$layoutWidth.png"), [Drawing.Imaging.ImageFormat]::Png)
                } finally {
                    $bitmap.Dispose()
                }
            }
        } finally {
            Close-SetupSession -Session $session
            Close-SetupView -View $view
            $view.Layout.Dispose()
        }
    }

    Write-Output "PASS: $checks direct settings view/mode/recovery checks."
} finally {
    $resolvedDirectory = [IO.Path]::GetFullPath($directory)

    if ($resolvedDirectory.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
    }
}
