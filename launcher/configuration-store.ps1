# Infer USB-only or automatic mode for settings saved before explicit modes existed.
function Get-ConnectionMode {
    param($Configuration)

    if ($Configuration.ConnectionMode) {
        return [string]$Configuration.ConnectionMode
    }

    if ($Configuration.WirelessService) {
        return 'auto'
    }

    return 'usb'
}

# Reject placeholder identities and connection modes inconsistent with their saved endpoint.
function Test-PhoneConfiguration {
    param($Configuration)

    if ($null -eq $Configuration) {
        return $false
    }

    $serial = [string]$Configuration.UsbSerial
    $service = [string]$Configuration.WirelessService
    $validSerial = $serial -match '^[A-Za-z0-9_-]+$' -and $serial -ne 'YOUR_USB_SERIAL'
    $expectedService = '^adb-' + [regex]::Escape($serial) + '-[A-Za-z0-9_-]+\._adb-tls-connect\._tcp$'
    $validService = -not $service -or $service -match $expectedService -or (Test-PairingEndpoint -Endpoint $service)
    $mode = Get-ConnectionMode -Configuration $Configuration
    $validMode = $mode -in @('usb', 'wifi', 'auto')
    $modeMatchesService = ($mode -eq 'usb' -and -not $service) -or ($mode -ne 'usb' -and [bool]$service)
    $validConfiguration = $validSerial -and $validService -and $validMode -and $modeMatchesService
    return $validConfiguration
}

# Read valid saved settings without modifying absent or malformed files.
function Get-PhoneConfiguration {
    param([string]$RootDirectory)
    $path = Join-Path $RootDirectory 'phone.json'

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $configuration = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        if (Test-PhoneConfiguration -Configuration $configuration) {
            return $configuration
        }
    } catch {
        return $null
    }

    return $null
}

# Replace the settings file atomically after validation; callers own the configuration lock.
function Write-PhoneConfigurationAtomic {
    param([string]$RootDirectory, $Configuration)

    if (-not (Test-PhoneConfiguration -Configuration $Configuration)) {
        throw 'The device configuration is invalid.'
    }

    $path = Join-Path $RootDirectory 'phone.json'
    $temporaryPath = Join-Path $RootDirectory ('phone-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = [ordered]@{
        UsbSerial = [string]$Configuration.UsbSerial
        WirelessService = [string]$Configuration.WirelessService
        ConnectionMode = Get-ConnectionMode -Configuration $Configuration
    } | ConvertTo-Json

    try {
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))

        if (Test-Path -LiteralPath $path) {
            [IO.File]::Replace($temporaryPath, $path, [NullString]::Value)
            return
        }

        [IO.File]::Move($temporaryPath, $path)
    } finally {

        if (Test-Path -LiteralPath $temporaryPath) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

# Accept only an explicit IPv4 address paired with a valid TCP port.
function Test-PairingEndpoint {
    param([string]$Endpoint)

    if ($Endpoint -notmatch '^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$') {
        return $false
    }

    $address = $Matches[1]
    $port = [int]$Matches[2]
    $invalidOctets = @($address.Split('.') | Where-Object { [int]$_ -gt 255 })
    return -not $invalidOctets.Count -and $port -gt 0 -and $port -le 65535
}

# Serializes reset with the launcher's final configuration check and native startup.
function Invoke-DeviceConfigurationLock {
    param([string]$RootDirectory, [scriptblock]$Action)
    $directory = [IO.Path]::GetFullPath($RootDirectory).TrimEnd('\').ToLowerInvariant()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($directory))).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }

    $mutex = New-Object Threading.Mutex($false, ('Local\scrcpy-seamless-configuration-' + $digest))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw 'Device settings are in use. Wait a moment and try again.'
        }

        & $Action
    }
    finally {

        if ($acquired) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}

# Refuses reset while this portable application's native session is running.
function Assert-DeviceResetAvailable {
    param([string]$RootDirectory)
    $executablePath = [IO.Path]::GetFullPath((Join-Path $RootDirectory 'scrcpy.exe'))
    foreach ($process in @(Get-Process -Name scrcpy -ErrorAction SilentlyContinue)) {
        try {
            # Windows may report a DOS short path; normalize both sides equally.
            $processPath = [IO.Path]::GetFullPath($process.Path)
        }
        catch {
            throw 'Cannot verify whether scrcpy is running. Close any mirroring windows before resetting device setup.'
        }

        if ([string]::Equals($processPath, $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Close the mirroring window before resetting device setup, then try again.'
        }
    }
}

# Removes only this application's saved configuration after explicit confirmation.
function Reset-DeviceConfiguration {
    param([string]$RootDirectory, [bool]$Confirmed = $false)

    if (-not $Confirmed) {
        return $false
    }

    Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action {
        Assert-DeviceResetAvailable -RootDirectory $RootDirectory
        $configurationPath = Join-Path ([IO.Path]::GetFullPath($RootDirectory)) 'phone.json'

        if (Test-Path -LiteralPath $configurationPath -PathType Container) {
            throw 'phone.json is a directory instead of a settings file. No files were removed.'
        }

        if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
            Remove-Item -LiteralPath $configurationPath -ErrorAction Stop
        }

        return $true
    }
}

# Capture persisted text for optimistic concurrency, preserving absent versus empty files.
function Get-DeviceConfigurationSnapshot {
    param([string]$RootDirectory)
    $path = Join-Path $RootDirectory 'phone.json'

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    return [IO.File]::ReadAllText($path)
}

# Save under the shared lock and optionally require the caller's original snapshot.
function Save-PhoneConfiguration {
    param([string]$RootDirectory, $Configuration, $ExpectedSnapshot, [switch]$PassThruSnapshot)
    $checkSnapshot = $PSBoundParameters.ContainsKey('ExpectedSnapshot')
    Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action {
        $currentSnapshot = Get-DeviceConfigurationSnapshot -RootDirectory $RootDirectory

        if ($checkSnapshot -and $currentSnapshot -cne $ExpectedSnapshot) {
            throw 'Device settings changed in another window. Close and reopen Settings before saving.'
        }

        Write-PhoneConfigurationAtomic -RootDirectory $RootDirectory -Configuration $Configuration

        if ($PassThruSnapshot) {
            Get-DeviceConfigurationSnapshot -RootDirectory $RootDirectory
        }
    }
}
