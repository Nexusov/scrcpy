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
function New-DesktopShortcut {
    param($RootDirectory)
    $marker = Join-Path $RootDirectory 'shortcut-count.txt'
    $count = 0

    if (Test-Path -LiteralPath $marker) {
        $count = [int](Get-Content -LiteralPath $marker -Raw)
    }

    Set-Content -LiteralPath $marker -Value ($count + 1)
}
function Save-PhoneConfiguration {
    param($RootDirectory, $Configuration)
    $Configuration | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RootDirectory 'saved.json')
}
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'launcher-core.ps1'), $mockCore)
[IO.File]::WriteAllText((Join-Path $testRoot 'shortcut.ps1'), $mockCore)
$exercise = @'
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

# Suppresses dialogs in the offline test while recording nonfatal warnings.
function Show-ShortcutWarning {
    $script:shortcutWarningShown = $true
}

$shortcutMarker = Join-Path $script:setupRoot 'shortcut-count.txt'
$shortcutCountBefore = 0

if (Test-Path -LiteralPath $shortcutMarker) {
    $shortcutCountBefore = [int](Get-Content -LiteralPath $shortcutMarker -Raw)
}

if (-not $createShortcut.Checked) {
    throw 'Desktop shortcut must be selected by default.'
}

Complete-ShortcutSetup

if ($shortcutCountBefore -eq 0 -and (Test-Path -LiteralPath $shortcutMarker)) {
    throw 'Shortcut was created before setup completed.'
}

$createShortcut.Checked = $modeIndex -ne 1
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

if (-not $createShortcut.Visible) {
    throw 'Shortcut option must be visible in every mode.'
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

$shortcutCountAfter = 0

if (Test-Path -LiteralPath $shortcutMarker) {
    $shortcutCountAfter = [int](Get-Content -LiteralPath $shortcutMarker -Raw)
}

$expectedCount = $shortcutCountBefore + [int]$createShortcut.Checked

if ($shortcutCountAfter -ne $expectedCount) {
    throw 'Shortcut creation did not respect the checkbox.'
}

$layout.Dispose()
Write-Output "PASS: $expectedMode visibility, requirements, hidden values, async state and save."
'@
foreach ($modeIndex in 0..2) {
    $testSource = $setupSource.Replace('[void]$form.ShowDialog()', $exercise).Replace('exit 0', 'return').Replace('exit 1', '')
    & ([scriptblock]::Create($testSource)) -RootDirectory $testRoot
}

$cancelExercise = @'
$beforeCancel = Get-Content -LiteralPath (Join-Path $script:setupRoot 'shortcut-count.txt') -Raw
Complete-ShortcutSetup
$form.Close()
$afterCancel = Get-Content -LiteralPath (Join-Path $script:setupRoot 'shortcut-count.txt') -Raw

if ($beforeCancel -ne $afterCancel -or $script:setupSaved) {
    throw 'Cancel unexpectedly created a shortcut or saved settings.'
}

Write-Output 'PASS: cancel does not create a shortcut.'
'@
$testSource = $setupSource.Replace('[void]$form.ShowDialog()', $cancelExercise).Replace('exit 0', 'return').Replace('exit 1', '')
& ([scriptblock]::Create($testSource)) -RootDirectory $testRoot

[IO.File]::WriteAllText((Join-Path $testRoot 'shortcut.ps1'), 'function New-DesktopShortcut { param($RootDirectory) throw "Mock shortcut failure" }')
$failureExercise = @'
function Show-ShortcutWarning {
    $script:shortcutWarningShown = $true
}
$script:shortcutWarningShown = $false
$mode.SelectedIndex = 1
[void]$devices.Items.Add([pscustomobject]@{ Serial = 'test-phone'; Label = 'Test phone' })
$devices.SelectedIndex = 0
$timer.Start()
Complete-Setup
$deadline = [datetime]::UtcNow.AddSeconds(10)

while ($null -ne $script:pendingWork -and [datetime]::UtcNow -lt $deadline) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 15
}

if (-not $script:setupSaved -or -not $script:shortcutWarningShown -or $null -ne $script:pendingWork) {
    throw 'Shortcut failure prevented successful setup completion.'
}

Write-Output 'PASS: shortcut failure warns without losing successful setup.'
'@
$testSource = $setupSource.Replace('[void]$form.ShowDialog()', $failureExercise).Replace('exit 0', 'return').Replace('exit 1', '')
& ([scriptblock]::Create($testSource)) -RootDirectory $testRoot
