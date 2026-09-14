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
Copy-Item (Join-Path $repository 'launcher/reset.ps1') $directory
Copy-Item (Join-Path $repository 'launcher/launcher-core.ps1') $directory
[IO.File]::WriteAllText((Join-Path $directory 'phone.json'), '{"UsbSerial":"old","WirelessService":"adb-old-test._adb-tls-connect._tcp","ConnectionMode":"wifi"}')
$source = [IO.File]::ReadAllText((Join-Path $repository 'launcher/setup.ps1'))
$source = $source -replace '(?m)^        \$confirmation = .*$', "        `$confirmation = 'Yes'"
$exercise = @'
$previousConfiguration = $script:savedConfiguration
Assert-Reset ($null -ne $previousConfiguration) 'Saved fixture failed to load.'
Remove-Item -LiteralPath (Join-Path $script:setupRoot 'phone.json')
$staleSaveRefused = $false
try { Save-SetupConfiguration -Configuration $previousConfiguration } catch { $staleSaveRefused = $true }
Assert-Reset $staleSaveRefused 'Another window reset was silently overwritten.'
Assert-Reset (-not (Test-Path (Join-Path $script:setupRoot 'phone.json'))) 'Stale save restored deleted configuration.'
$script:pairingState.Endpoint = 'pending'
$endpoint.Text = '192.168.1.1:1'
Reset-SetupState
Assert-Reset (-not $script:savedConfiguration) 'UI kept saved configuration.'
Assert-Reset (-not $script:pairingState.Count) 'UI kept draft pairing.'
Assert-Reset (-not $endpoint.Text -and -not $pairingCode.Text -and -not $devices.Items.Count) 'UI kept stale identity inputs.'
Assert-Reset (-not $script:setupSaved) 'Reset incorrectly completed setup.'
Assert-Reset (-not (Test-Path (Join-Path $script:setupRoot 'phone.json'))) 'UI reset did not remove settings.'
$script:pendingWork = @{}
Update-SetupActions
Assert-Reset (-not $resetSetup.Enabled) 'Busy reset button remains enabled.'
$script:pendingWork = $null
'@
$source = $source.Replace('[void]$form.ShowDialog()', $exercise).Replace('exit 0', 'return').Replace('exit 1', '')
& ([scriptblock]::Create($source)) -RootDirectory $directory
Write-Output 'PASS: reset confirmation, active session guard, exact scope, empty reset, UI cleanup and busy state.'
