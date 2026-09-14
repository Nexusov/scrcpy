$ErrorActionPreference = 'Stop'
$storePath = Join-Path $PSScriptRoot '../launcher/configuration-store.ps1'
. $storePath
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-store-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$phonePath = Join-Path $directory 'phone.json'
$worker = $null
$signal = [hashtable]::Synchronized(@{ Acquired = $false; Release = $false })

# Refuse regressions in atomic settings concurrency and reset scope.
function Assert-Store { param($Condition, $Message)
    if (-not $Condition) { throw $Message }
}

# Require an operation to reject stale or malformed writes.
function Assert-StoreRejected { param($Action, $Message)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-Store $rejected $Message
}

# Avoid inspecting unrelated desktop sessions during a persistence unit test.
function Get-Process { param($Name, $ErrorAction) return @() }
try {
    $configuration = [pscustomobject]@{ UsbSerial = 'phone-A'; WirelessService = ''; ConnectionMode = 'usb' }
    $firstSnapshot = Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $null -PassThruSnapshot
    Assert-Store ($firstSnapshot -ceq (Get-DeviceConfigurationSnapshot -RootDirectory $directory)) 'First-run null snapshot save failed.'
    [IO.File]::WriteAllText($phonePath, '')
    Assert-StoreRejected { Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $null } 'Empty file was confused with absent configuration.'
    Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot ''
    $oldSnapshot = Get-DeviceConfigurationSnapshot -RootDirectory $directory
    $configuration.UsbSerial = 'phone-B'
    Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $oldSnapshot
    Assert-StoreRejected { Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $oldSnapshot } 'Competing write was overwritten.'
    Assert-Store ((Get-PhoneConfiguration -RootDirectory $directory).UsbSerial -eq 'phone-B') 'Rejected stale save changed device.'
    $snapshotBeforeReset = Get-DeviceConfigurationSnapshot -RootDirectory $directory
    $null = Reset-DeviceConfiguration -RootDirectory $directory -Confirmed $true
    Assert-StoreRejected { Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $snapshotBeforeReset } 'Stale window restored reset settings.'
    Assert-Store (-not (Test-Path $phonePath)) 'Reset was undone by stale save.'
    [IO.File]::WriteAllText($phonePath, '{invalid json')
    Assert-Store ($null -eq (Get-PhoneConfiguration -RootDirectory $directory)) 'Malformed settings accepted.'
    Assert-Store ((Get-DeviceConfigurationSnapshot -RootDirectory $directory) -ceq '{invalid json') 'Reading malformed settings modified file.'
    Remove-Item -LiteralPath $phonePath
    $worker = [PowerShell]::Create()
    $null = $worker.AddScript({
        param($StorePath, $Directory, $Signal)
        . $StorePath
        Invoke-DeviceConfigurationLock -RootDirectory $Directory -Action {
            $Signal.Acquired = $true
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not $Signal.Release -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
        }
    }).AddArgument([IO.Path]::GetFullPath($storePath)).AddArgument($directory).AddArgument($signal)
    $pending = $worker.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while (-not $signal.Acquired -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    Assert-Store $signal.Acquired 'Competing worker did not acquire store lock.'
    Assert-StoreRejected { Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration } 'Concurrent store write bypassed lock.'
    $signal.Release = $true
    $null = $worker.EndInvoke($pending)
    Save-PhoneConfiguration -RootDirectory $directory -Configuration $configuration -ExpectedSnapshot $null
    Assert-Store ((Get-PhoneConfiguration -RootDirectory $directory).UsbSerial -eq 'phone-B') 'Released lock was not reusable.'
    Write-Output 'PASS: absent/empty snapshots, competing writes, reset, malformed reads and cross-worker locking.'
} finally {
    $signal.Release = $true
    if ($null -ne $worker) { $worker.Dispose() }
    $resolvedDirectory = (Resolve-Path $directory).ProviderPath
    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
