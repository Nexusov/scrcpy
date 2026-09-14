# Run ADB with bounded execution and without opening a console.
function Invoke-AdbCommand {
    param([string]$RootDirectory, [string[]]$Arguments, [int]$TimeoutMilliseconds = 12000)

    if ($script:setupCancellation -and $script:setupCancellation.IsCancellationRequested) {
        throw [OperationCanceledException]::new('Setup cancelled. Saved settings were not changed.')
    }

    foreach ($argument in $Arguments) {

        if ($argument -notmatch '^[A-Za-z0-9_:.=\-]+$') {
            throw 'Invalid ADB argument.'
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'adb.exe'
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.WorkingDirectory = $RootDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB_MDNS_OPENSCREEN'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        $null = $process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while (-not $process.WaitForExit(100)) {

            if ($script:setupCancellation -and $script:setupCancellation.IsCancellationRequested) {
                $process.Kill()
                $process.WaitForExit()
                throw [OperationCanceledException]::new('Setup cancelled. Saved settings were not changed.')
            }

            if ([DateTime]::UtcNow -ge $deadline) {
                break
            }
        }

        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
            throw 'ADB timed out. Check the phone connection and try again.'
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.GetAwaiter().GetResult()
            Error = $errorTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

# Infer the original behavior when older settings have no explicit mode.
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

# Validate explicit connection modes and backwards-compatible device settings.
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

# Read settings without replacing malformed or existing files.
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

# Replace settings atomically only after a successful setup action.
function Save-PhoneConfiguration {
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

# List USB devices, including devices awaiting authorization.
function Get-SetupDevices {
    param([string]$RootDirectory)
    $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('devices', '-l')

    if ($result.ExitCode -ne 0) {
        throw 'ADB could not list devices. Check the USB driver and try again.'
    }

    foreach ($line in ($result.Output -split '\r?\n')) {

        if ($line -notmatch '^(?<serial>[A-Za-z0-9_-]+)\s+(?<state>device|unauthorized|offline)\b(?<details>.*)$') {
            continue
        }

        $serial = $Matches.serial
        $state = $Matches.state
        $details = $Matches.details
        $model = $serial

        if ($serial -match '^emulator-\d+$') {
            continue
        }

        if ($details -match '\bmodel:(\S+)') {
            $model = $Matches[1].Replace('_', ' ')
        }

        [pscustomobject]@{ Serial = $serial; State = $state; Model = $model }
    }
}

# Parse advertised ADB services and validate their IPv4 endpoints.
function Get-AdbServices {
    param([string]$RootDirectory, [string]$ServiceType)
    $discoveryTimeoutMilliseconds = 3000
    $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('mdns', 'services') -TimeoutMilliseconds $discoveryTimeoutMilliseconds

    if ($result.ExitCode -ne 0) {
        throw 'Wireless discovery failed. Make sure Wireless debugging is enabled and your phone and PC are on the same network.'
    }

    foreach ($line in ($result.Output -split '\r?\n')) {
        $fields = $line.Trim() -split '\s+'

        if ($fields.Count -ne 3) {
            continue
        }

        $matchesType = $fields[1].TrimEnd('.') -eq $ServiceType

        if (-not $matchesType -or -not (Test-PairingEndpoint -Endpoint $fields[2])) {
            continue
        }

        $name = $fields[0].TrimEnd('.')
        $suffix = '.' + $ServiceType

        if ($name.EndsWith($suffix)) {
            $name = $name.Substring(0, $name.Length - $suffix.Length)
        }

        [pscustomobject]@{ Name = $name; Endpoint = $fields[2] }
    }
}

# Accept only explicit IPv4 addresses and valid TCP ports.
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

# Find pairing advertisements while the phone's pairing-code screen is open.
function Get-PairingServices {
    param([string]$RootDirectory)
    return Get-AdbServices -RootDirectory $RootDirectory -ServiceType '_adb-tls-pairing._tcp'
}

# Find only connection advertisements belonging to the selected USB phone.
function Get-PhoneWirelessServices {
    param([string]$RootDirectory, [string]$UsbSerial)
    $prefix = 'adb-' + $UsbSerial + '-'
    return @(Get-AdbServices -RootDirectory $RootDirectory -ServiceType '_adb-tls-connect._tcp' |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) })
}

# Pair over Wi-Fi and verify the connected phone before returning settings.
function Complete-WirelessPairing {
    param([string]$RootDirectory, [string]$UsbSerial, [string]$PairingCode, [string]$Endpoint = '', [string]$ConnectionEndpoint = '', [hashtable]$PairingState = @{})

    if ($PairingState.Endpoint -and $PairingState.Serial -cne $UsbSerial) {
        throw 'The selected phone changed. Choose Set up another phone before pairing a different device.'
    }

    $hasUsbIdentity = -not [string]::IsNullOrEmpty($UsbSerial)

    if ($hasUsbIdentity -and -not (Test-PhoneConfiguration -Configuration ([pscustomobject]@{ UsbSerial = $UsbSerial; WirelessService = '' }))) {
        throw 'Select a valid USB phone first.'
    }

    if ($ConnectionEndpoint -and -not (Test-PairingEndpoint -Endpoint $ConnectionEndpoint)) {
        throw 'Use the IPv4 address and connection port from the main Wireless debugging screen.'
    }

    if ($PairingState.Endpoint) {
        $Endpoint = $PairingState.Endpoint
    }

    if (-not $PairingState.Endpoint -and $PairingCode -notmatch '^\d{6}$') {
        throw 'Enter the six-digit pairing code shown on your phone.'
    }

    if (-not $Endpoint) {
        $services = @(Get-PairingServices -RootDirectory $RootDirectory)
        $matchingServices = $services

        if ($hasUsbIdentity) {
            $matchingServices = @($services | Where-Object { $_.Name.StartsWith('adb-' + $UsbSerial + '-') })
        }

        if ($matchingServices.Count -ne 1) {
            throw 'Could not identify a single pairing device. Make sure Wireless debugging is enabled, keep the pairing-code dialog open, and check that your phone and PC are on the same network. If needed, enter the IP address and pairing port shown in that dialog.'
        }

        $Endpoint = $matchingServices[0].Endpoint
    }

    if (-not (Test-PairingEndpoint -Endpoint $Endpoint)) {
        throw 'Use the IPv4 address and pairing port shown on the phone, for example 192.168.1.10:37000.'
    }

    $pairingAddress = ($Endpoint -split ':')[0]

    if (-not $PairingState.Existing -and $ConnectionEndpoint -eq $Endpoint) {
        throw 'Pairing and connection ports are different. Leave Connection IP:port blank for discovery, or use the address on the main Wireless debugging screen.'
    }

    if ($ConnectionEndpoint -and ($ConnectionEndpoint -split ':')[0] -ne $pairingAddress) {
        throw 'The pairing and connection addresses must belong to the same phone IP.'
    }

    if (-not $PairingState.Endpoint) {
        $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('pair', $Endpoint, $PairingCode)
        $pairingSucceeded = $result.ExitCode -eq 0 -and $result.Output -match 'Successfully paired'

        if (-not $pairingSucceeded) {
            throw 'Pairing failed. Make sure Wireless debugging is enabled, keep the pairing-code dialog open, and enter the current code and pairing port.'
        }

        $PairingState.Serial = $UsbSerial
        $PairingState.Endpoint = $Endpoint
    }

    $discoveryAttempts = 3
    $discoveryDelayMilliseconds = 500
    $wirelessServices = @()

    for ($attempt = 0; $attempt -lt $discoveryAttempts; $attempt++) {
        try {
            $discoveredServices = @(Get-AdbServices -RootDirectory $RootDirectory -ServiceType '_adb-tls-connect._tcp')

            if ($hasUsbIdentity) {
                $discoveredServices = @($discoveredServices | Where-Object { $_.Name.StartsWith('adb-' + $UsbSerial + '-') })
            }

            $wirelessServices = @($discoveredServices | Where-Object { ($_.Endpoint -split ':')[0] -eq $pairingAddress })
        } catch {

            if (-not $ConnectionEndpoint) {
                throw 'Pairing succeeded, but discovery failed. Make sure Wireless debugging is still enabled and both devices are on the same network. Enter Connection IP:port from the main Wireless debugging screen and retry the connection; pairing does not need to be repeated.'
            }
        }

        if ($wirelessServices.Count) {
            break
        }

        Start-Sleep -Milliseconds $discoveryDelayMilliseconds
    }

    if ($ConnectionEndpoint) {
        $wirelessServices += [pscustomobject]@{ Name = ''; Endpoint = $ConnectionEndpoint }
    }

    if (-not $wirelessServices.Count) {
        throw 'Pairing completed, but the phone was not discovered over Wi-Fi. Make sure Wireless debugging is enabled and both devices are on the same network. If needed, enter Connection IP:port from the main Wireless debugging screen and retry the connection; pairing does not need to be repeated. Settings were not changed.'
    }

    foreach ($service in $wirelessServices) {
        try {
            $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('connect', $service.Endpoint)

            if ($result.ExitCode -ne 0) {
                continue
            }

            $identity = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('-s', $service.Endpoint, 'shell', 'getprop', 'ro.serialno')
            $connectedSerial = $identity.Output.Trim()
            $validIdentity = Test-PhoneConfiguration -Configuration ([pscustomobject]@{ UsbSerial = $connectedSerial; WirelessService = '' })
            $verifiedIdentity = $identity.ExitCode -eq 0 -and $validIdentity

            if ($hasUsbIdentity) {
                $verifiedIdentity = $verifiedIdentity -and $connectedSerial -ceq $UsbSerial
            }
        } catch {
            continue
        }

        if ($verifiedIdentity) {
            $wirelessTarget = $service.Endpoint

            if ($service.Name.StartsWith('adb-' + $connectedSerial + '-')) {
                $wirelessTarget = $service.Name + '._adb-tls-connect._tcp'
            }

            return [pscustomobject]@{
                UsbSerial = $connectedSerial
                WirelessService = $wirelessTarget
            }
        }
    }

    throw 'The Wi-Fi device identity could not be verified. Make sure Wireless debugging is enabled, both devices are on the same network, and the connection address belongs to your phone. Settings were not changed.'
}
