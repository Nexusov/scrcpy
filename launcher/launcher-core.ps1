. (Join-Path $PSScriptRoot 'adb-process.ps1')
. (Join-Path $PSScriptRoot 'configuration-store.ps1')

# List physical USB devices with their model and authorization state.
function Get-SetupDevices {
    param([string]$RootDirectory, $Cancellation)
    $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('devices', '-l')

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

# Parse multicast ADB advertisements and discard malformed endpoints.
function Get-AdbServices {
    param([string]$RootDirectory, [string]$ServiceType, $Cancellation)
    $discoveryTimeoutMilliseconds = 3000
    $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('mdns', 'services') -TimeoutMilliseconds $discoveryTimeoutMilliseconds

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

# Find pairing advertisements while the phone pairing-code dialog remains open.
function Get-PairingServices {
    param([string]$RootDirectory, $Cancellation)
    return Get-AdbServices -RootDirectory $RootDirectory -Cancellation $Cancellation -ServiceType '_adb-tls-pairing._tcp'
}

# Filter connection advertisements to the selected phone identity.
function Get-PhoneWirelessServices {
    param([string]$RootDirectory, [string]$UsbSerial, $Cancellation)
    $prefix = 'adb-' + $UsbSerial + '-'
    return @(Get-AdbServices -RootDirectory $RootDirectory -Cancellation $Cancellation -ServiceType '_adb-tls-connect._tcp' |
        Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) })
}

# Retain successful pairing across connection retries and verify identity before returning settings.
function Complete-WirelessPairing {
    param([string]$RootDirectory, [string]$UsbSerial, [string]$PairingCode, [string]$Endpoint = '', [string]$ConnectionEndpoint = '', [hashtable]$PairingState = @{}, $Cancellation)

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
        $services = @(Get-PairingServices -RootDirectory $RootDirectory -Cancellation $Cancellation)
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
        $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('pair', $Endpoint, $PairingCode)
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
            $discoveredServices = @(Get-AdbServices -RootDirectory $RootDirectory -Cancellation $Cancellation -ServiceType '_adb-tls-connect._tcp')

            if ($hasUsbIdentity) {
                $discoveredServices = @($discoveredServices | Where-Object { $_.Name.StartsWith('adb-' + $UsbSerial + '-') })
            }

            $wirelessServices = @($discoveredServices | Where-Object { ($_.Endpoint -split ':')[0] -eq $pairingAddress })
        } catch [OperationCanceledException] {
            throw
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
            $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('connect', $service.Endpoint)

            if ($result.ExitCode -ne 0) {
                continue
            }

            $identity = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('-s', $service.Endpoint, 'shell', 'getprop', 'ro.serialno')
            $connectedSerial = $identity.Output.Trim()
            $validIdentity = Test-PhoneConfiguration -Configuration ([pscustomobject]@{ UsbSerial = $connectedSerial; WirelessService = '' })
            $verifiedIdentity = $identity.ExitCode -eq 0 -and $validIdentity

            if ($hasUsbIdentity) {
                $verifiedIdentity = $verifiedIdentity -and $connectedSerial -ceq $UsbSerial
            }
        } catch [OperationCanceledException] {
            throw
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

