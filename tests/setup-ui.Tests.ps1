param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent), [string]$PreviewDirectory = '')
$ErrorActionPreference = 'Stop'
$setupSource = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'launcher\setup.ps1'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-ui-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$mockCore = @'
function Get-PhoneConfiguration { param($RootDirectory) return $null }
function Get-ConnectionMode { param($Configuration) return $Configuration.ConnectionMode }
function Get-SetupDevices {
    param($RootDirectory)
    return [pscustomobject]@{ Serial = 'test-phone'; State = 'device'; Model = 'Test phone' }
}
function Complete-WirelessPairing {
    param($RootDirectory, $UsbSerial, $PairingCode, $Endpoint, $ConnectionEndpoint, $PairingState)

    if ($PairingCode -ne '123456') {
        throw 'Unexpected test pairing code.'
    }

    return [pscustomobject]@{ UsbSerial = 'test-phone'; WirelessService = 'test-service._adb-tls-connect._tcp' }
}
function Save-PhoneConfiguration {
    param($RootDirectory, $Configuration)
    $Configuration | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RootDirectory 'saved.json')
}
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'launcher-core.ps1'), $mockCore)
$exercise = @'
$createShortcut.Checked = $false
# Waits only for mocked background operations without showing a window.
function Wait-TestOperation {
    $deadline = [datetime]::UtcNow.AddSeconds(10)

    while ($null -ne $script:pendingWork -and [datetime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }

    if ($null -ne $script:pendingWork) {
        throw 'Mock operation timed out.'
    }
}

$layout.Font = $form.Font
$scrollPanel.Controls.Remove($layout)
$layout.Width = $form.ClientSize.Width
$layout.CreateControl()
$mode.SelectedIndex = $modeIndex
Update-SetupActions
$expectedMode = @('auto', 'usb', 'wifi')[$modeIndex]
$expectsUsb = $expectedMode -ne 'wifi'
$expectsWifi = $expectedMode -ne 'usb'

if ($deviceRow.Visible -ne $expectsUsb -or $pairingRow.Visible -ne $expectsWifi) {
    throw "Incorrect visible sections for $expectedMode."
}

if ($endpointRow.Visible -or $connectionRow.Visible -or $finish.Enabled) {
    throw "Invalid initial fields or finish state for $expectedMode."
}

$pairingCode.Text = '123456'

if ($finish.Enabled -ne ($expectedMode -eq 'wifi')) {
    throw "Incorrect cable requirement for $expectedMode."
}

$timer.Start()
Start-SetupWork -Operation 'devices'

if ($mode.Enabled -or $finish.Enabled) {
    throw 'Mode and finish must be disabled during background work.'
}

Wait-TestOperation

if (-not $finish.Enabled) {
    throw "Finish did not enable for $expectedMode."
}

$manualAddresses.Checked = $true

if ($endpointRow.Visible -ne $expectsWifi) {
    throw "Incorrect manual field visibility for $expectedMode."
}

$endpoint.Text = '127.0.0.1:12345'
$connectionEndpoint.Text = '127.0.0.1:12345'
$manualAddresses.Checked = $false
$inputValues = Get-SetupInput

if ($inputValues.Endpoint -or $inputValues.ConnectionEndpoint) {
    throw 'Hidden address fields were not ignored.'
}

if ($expectedMode -eq 'wifi' -and $inputValues.Serial) {
    throw 'Wi-Fi mode must not forward a USB serial.'
}

if ($PreviewDirectory) {
    [void][IO.Directory]::CreateDirectory($PreviewDirectory)
    $layout.PerformLayout()
    $bitmap = New-Object Drawing.Bitmap($layout.Width, $layout.Height)
    $layout.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $layout.Width, $layout.Height)))
    $bitmap.Save((Join-Path $PreviewDirectory "setup-$expectedMode.png"), [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

Complete-Setup
Wait-TestOperation
$saved = Get-Content -LiteralPath (Join-Path $script:setupRoot 'saved.json') -Raw | ConvertFrom-Json

if ($saved.ConnectionMode -ne $expectedMode -or -not $script:setupSaved) {
    throw "Incorrect saved mode: $expectedMode."
}

if (($expectedMode -eq 'usb') -and $saved.WirelessService) {
    throw 'USB mode saved wireless settings.'
}

$layout.Dispose()
Write-Output "PASS: $expectedMode visibility, requirements, hidden values, async state and save."
'@
foreach ($modeIndex in 0..2) {
    $testSource = $setupSource.Replace('[void]$form.ShowDialog()', $exercise).Replace('exit 0', 'return').Replace('exit 1', '')
    & ([scriptblock]::Create($testSource)) -RootDirectory $testRoot
}
