param([string]$PreviewDirectory = "")
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'launcher/launcher-core.ps1')
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-settings-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
# Fail with the scenario that regressed.
function Assert-Setup { param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}
$script:pairCount = 0
$script:connectionReady = $false
# Simulate discovery becoming available after successful pairing.
function Get-AdbServices { param($RootDirectory, $ServiceType)

    if ($script:connectionReady) {
        return [pscustomobject]@{ Name = 'adb-phone123-test'; Endpoint = '192.168.1.8:40001' }
    }
    return @()
}
# Keep pairing calls countable and identity verification realistic.
function Invoke-AdbCommand { param($RootDirectory, $Arguments)

    if ($Arguments[0] -eq 'pair') {
        $script:pairCount++
        return [pscustomobject]@{ ExitCode = 0; Output = 'Successfully paired'; Error = '' }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = 'phone123'; Error = '' }
}
$pairingState = @{}
try {
    Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingCode 123456 -Endpoint '192.168.1.8:40000' -PairingState $pairingState
    throw 'Expected unavailable connection to fail.'
} catch {
    Assert-Setup ($pairingState.Endpoint -eq '192.168.1.8:40000') 'Successful pairing state lost.'
}
$script:connectionReady = $true
$configuration = Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingCode '' -PairingState $pairingState
Assert-Setup ($script:pairCount -eq 1) 'Connection retry repeated pairing.'
Assert-Setup ($configuration.UsbSerial -eq 'phone123') 'Retry did not verify identity.'
$identityRejected = $false
try {
    Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial differentPhone -PairingCode '' -PairingState $pairingState
} catch { $identityRejected = $true }
Assert-Setup $identityRejected 'Changed device reused another phone pairing.'
Write-Output 'PASS: pairing retained, retried once, and identity bound.'
$configuration = Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingState @{ Endpoint = '192.168.1.8:40001'; Serial = 'phone123'; Existing = $true } -ConnectionEndpoint '192.168.1.8:40001'
Assert-Setup ($script:pairCount -eq 1 -and $configuration.UsbSerial -eq 'phone123') 'Saved endpoint refresh repeated pairing or missed identity.'
Write-Output 'PASS: saved connection endpoint can refresh without pairing.'

# Exercise production UI with its real core and no visible modal form.
Copy-Item (Join-Path $repository 'launcher/launcher-core.ps1') $testDirectory
Copy-Item (Join-Path $repository 'launcher/reset.ps1') $testDirectory
[IO.File]::WriteAllText((Join-Path $testDirectory 'shortcut.ps1'), 'function New-DesktopShortcut { param($RootDirectory) Set-Content (Join-Path $RootDirectory "shortcut-created") yes }')
$setupSource = [IO.File]::ReadAllText((Join-Path $repository 'launcher/setup.ps1'))
$saved = [pscustomobject]@{ UsbSerial = 'phone123'; WirelessService = '192.168.1.8:40001'; ConnectionMode = 'wifi' }
Save-PhoneConfiguration -RootDirectory $testDirectory -Configuration $saved
$exercise = @'
Assert-Setup ($mode.SelectedItem.Value -eq 'wifi') 'Saved mode was not restored.'
Assert-Setup ($devices.SelectedItem.Serial -eq 'phone123') 'Saved phone not restored offline.'
Assert-Setup $finish.Enabled 'Existing settings require pairing again.'

if ($PreviewDirectory) {
    [void][IO.Directory]::CreateDirectory($PreviewDirectory)
    $layout.Font = $form.Font
    $scrollPanel.Controls.Remove($layout)
    $layout.Width = $form.ClientSize.Width
    $layout.CreateControl()
    $layout.PerformLayout()
    $bitmap = New-Object Drawing.Bitmap($layout.Width, $layout.Height)
    $layout.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $layout.Width, $layout.Height)))
    $bitmap.Save((Join-Path $PreviewDirectory 'setup-saved.png'), [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$createShortcut.Checked = $false
$mode.SelectedIndex = 0
Assert-Setup $finish.Enabled 'Saved phone cannot switch Wi-Fi to auto offline.'
$manualAddresses.Checked = $true
Assert-Setup (-not (Test-SavedWifiSelection)) 'Manual edits silently reused old endpoint.'
$manualAddresses.Checked = $false
$mode.SelectedIndex = 1
$timer.Start()
Complete-Setup
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ($script:pendingWork -and [DateTime]::UtcNow -lt $deadline) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}
$actual = Get-PhoneConfiguration -RootDirectory $script:setupRoot
Assert-Setup ($actual.ConnectionMode -eq 'usb' -and -not $actual.WirelessService) 'Switch to USB failed or retained invalid service.'
Write-Output 'PASS: saved device/mode restored offline and USB mode switch saved.'
'@
$testSource = $setupSource.Replace('[void]$form.ShowDialog()', $exercise).Replace('exit 0', 'return').Replace('exit 1', '')
& ([scriptblock]::Create($testSource)) -RootDirectory $testDirectory

# Bound cancellation latency and ensure only the launched ADB client is stopped.
$fakeAdbSource = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
public static class FakeAdb {
    public static void Main() {
        File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "client.pid"), Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(30000);
    }
}
'@
Add-Type -TypeDefinition $fakeAdbSource -OutputAssembly (Join-Path $testDirectory 'adb.exe') -OutputType ConsoleApplication
. (Join-Path $repository 'launcher/launcher-core.ps1')
$script:setupCancellation = New-Object Threading.CancellationTokenSource
$script:setupCancellation.CancelAfter(300)
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$cancelled = $false
try {
    Invoke-AdbCommand -RootDirectory $testDirectory -Arguments @('devices')
} catch {
    $cancelled = $_.Exception -is [OperationCanceledException]
}
$elapsed.Stop()
Assert-Setup ($cancelled -and $elapsed.ElapsedMilliseconds -lt 2000) 'ADB cancellation was not bounded.'
$childProcessIdentifier = [int](Get-Content (Join-Path $testDirectory 'client.pid'))
Assert-Setup (-not (Get-Process -Id $childProcessIdentifier -ErrorAction SilentlyContinue)) 'Cancelled ADB child survived.'
$script:setupCancellation.Dispose()
$script:setupCancellation = $null
Write-Output 'PASS: real ADB child cancellation under two seconds and process reaped.'

# Cancel after a worker finishes, before the UI can commit its result.
Save-PhoneConfiguration -RootDirectory $testDirectory -Configuration $saved
$exercise = @'
$createShortcut.Checked = $false
$before = [IO.File]::ReadAllText((Join-Path $script:setupRoot 'phone.json'))
Start-SetupWork -Operation usb -Values @{ Serial = 'replacement'; Mode = 'usb' }
$script:pendingWork.Cancellation.Cancel()
$timer.Start()
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ($script:pendingWork -and [DateTime]::UtcNow -lt $deadline) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}
Assert-Setup (-not $script:pendingWork) 'Cancelled worker failed to drain.'
Assert-Setup ($before -ceq [IO.File]::ReadAllText((Join-Path $script:setupRoot 'phone.json'))) 'Cancelled result overwrote saved config.'
Assert-Setup ($status.Text -match 'cancelled') 'Cancel feedback missing.'
Write-Output 'PASS: cancellation before UI commit preserves existing config.'
'@
$testSource = $setupSource.Replace('[void]$form.ShowDialog()', $exercise).Replace('exit 0', 'return').Replace('exit 1', '')
& ([scriptblock]::Create($testSource)) -RootDirectory $testDirectory
