$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'launcher/reset.ps1')
$directory = Join-Path $env:TEMP ('scrcpy-reset-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
# Fails with the invariant that was violated.
function Assert-Reset { param($Condition, $Message)

    if (-not $Condition) {
        throw $Message
    }
}
# Supplies explicit process paths without touching real sessions.
function Get-Process { param($Name, $ErrorAction) return $script:fakeProcesses }
$script:fakeProcesses = @()
foreach ($name in @('phone.json', 'last-run.log', 'adbkey', 'shortcut.lnk')) {
    [IO.File]::WriteAllText((Join-Path $directory $name), 'sentinel')
}
Assert-Reset (-not (Reset-DeviceConfiguration -RootDirectory $directory)) 'Unconfirmed reset accepted.'
Assert-Reset (Test-Path (Join-Path $directory 'phone.json')) 'Cancelled reset deleted settings.'
$script:fakeProcesses = @([pscustomobject]@{ Path = Join-Path $directory 'scrcpy.exe' })
$refused = $false
try { Reset-DeviceConfiguration -RootDirectory $directory -Confirmed $true } catch { $refused = $true }
Assert-Reset $refused 'Active native stream allowed reset.'
Assert-Reset (Test-Path (Join-Path $directory 'phone.json')) 'Active reset deleted settings.'
$script:fakeProcesses = @([pscustomobject]@{ Path = 'C:\OtherApp\scrcpy.exe' })
Assert-Reset (Reset-DeviceConfiguration -RootDirectory $directory -Confirmed $true) 'Unrelated process blocked reset.'
Assert-Reset (-not (Test-Path (Join-Path $directory 'phone.json'))) 'Reset kept config.'
foreach ($name in @('last-run.log', 'adbkey', 'shortcut.lnk')) {
    Assert-Reset ((Get-Content (Join-Path $directory $name)) -eq 'sentinel') ('Reset modified ' + $name)
}
Assert-Reset (Reset-DeviceConfiguration -RootDirectory $directory -Confirmed $true) 'Empty reset failed.'
$script:fakeProcesses = @()
. (Join-Path $repository 'launcher/setup-session.ps1')
. (Join-Path $repository 'launcher/setup-view.ps1')
$configuration = [pscustomobject]@{ UsbSerial = 'old'; WirelessService = 'adb-old-test._adb-tls-connect._tcp'; ConnectionMode = 'wifi' }
Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration
$session = New-SetupSession -RootDirectory $directory
$view = New-SetupView -Session $session

try {
    Assert-Reset ($null -ne $session.SavedConfiguration) 'Saved fixture failed to load.'
    Remove-Item -LiteralPath (Join-Path $directory 'phone.json')
    $staleSaveRefused = $false

    try {
        Save-SetupConfiguration -Session $session -Configuration $configuration
    } catch {
        $staleSaveRefused = $true
    }

    Assert-Reset $staleSaveRefused 'Another window reset was silently overwritten.'
    Assert-Reset (-not (Test-Path (Join-Path $directory 'phone.json'))) 'Stale save restored deleted configuration.'
    $session.PairingState.Endpoint = 'pending'
    $session.Input.PairingEndpoint = '192.168.1.1:1'
    $session.Input.PairingCode = '123456'
    $session.PendingWork = @{}
    Update-SetupView -View $view
    Assert-Reset (-not $view.ResetSetup.Enabled) 'Busy reset button remains enabled.'
    Reset-SetupState -Session $session -Confirmed $true
    Assert-Reset ($null -ne $session.SavedConfiguration) 'Busy reset changed draft state.'
    $session.PendingWork = $null
    Reset-SetupState -Session $session -Confirmed $true
    Update-SetupView -View $view
    Assert-Reset (-not $session.SavedConfiguration) 'Session kept saved configuration.'
    Assert-Reset (-not $session.PairingState.Count) 'Session kept draft pairing.'
    Assert-Reset (-not $view.Endpoint.Text -and -not $view.PairingCode.Text -and -not $view.Devices.Items.Count) 'View kept stale identity inputs.'
    Assert-Reset ($session.Outcome -eq 'Open') 'Reset incorrectly completed settings.'
    Assert-Reset (-not (Test-Path (Join-Path $directory 'phone.json'))) 'Reset did not remove settings.'
} finally {
    $session.PendingWork = $null
    Close-SetupSession -Session $session
    Close-SetupView -View $view
    $resolvedDirectory = [IO.Path]::GetFullPath($directory)

    if ($resolvedDirectory.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
    }
}

Write-Output 'PASS: reset confirmation, active session guard, exact scope, empty reset, draft cleanup and busy state.'
