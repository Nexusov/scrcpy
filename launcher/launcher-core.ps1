# Run ADB with bounded execution and without opening a console.
function Invoke-AdbCommand {
    param([string]$RootDirectory, [string[]]$Arguments, [int]$TimeoutMilliseconds = 12000)

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

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
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

# Validate both legacy Wi-Fi settings and the new USB-only configuration.
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
    return $validSerial -and $validService
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
        throw 'Wireless discovery failed. Check that both devices use the same network.'
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
    param([string]$RootDirectory, [string]$UsbSerial, [string]$PairingCode, [string]$Endpoint = '', [string]$ConnectionEndpoint = '')

    if (-not (Test-PhoneConfiguration -Configuration ([pscustomobject]@{ UsbSerial = $UsbSerial; WirelessService = '' }))) {
        throw 'Select a valid USB phone first.'
    }

    if ($ConnectionEndpoint -and -not (Test-PairingEndpoint -Endpoint $ConnectionEndpoint)) {
        throw 'Use the IPv4 address and connection port from the main Wireless debugging screen.'
    }

    if ($PairingCode -notmatch '^\d{6}$') {
        throw 'Enter the six-digit pairing code shown on your phone.'
    }

    if (-not $Endpoint) {
        $services = @(Get-PairingServices -RootDirectory $RootDirectory)
        $matchingServices = @($services | Where-Object { $_.Name.StartsWith('adb-' + $UsbSerial + '-') })

        if ($matchingServices.Count -ne 1) {
            throw 'Enter the IP address and pairing port from the phone pairing-code screen.'
        }

        $Endpoint = $matchingServices[0].Endpoint
    }

    if (-not (Test-PairingEndpoint -Endpoint $Endpoint)) {
        throw 'Use the IPv4 address and pairing port shown on the phone, for example 192.168.1.10:37000.'
    }

    $pairingAddress = ($Endpoint -split ':')[0]

    if ($ConnectionEndpoint -and ($ConnectionEndpoint -split ':')[0] -ne $pairingAddress) {
        throw 'The pairing and connection addresses must belong to the same phone IP.'
    }

    $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('pair', $Endpoint, $PairingCode)
    $pairingSucceeded = $result.ExitCode -eq 0 -and $result.Output -match 'Successfully paired'

    if (-not $pairingSucceeded) {
        throw 'Pairing failed. Keep the pairing-code screen open and try its current code and pairing port.'
    }

    $discoveryAttempts = 3
    $discoveryDelayMilliseconds = 500
    $wirelessServices = @()

    for ($attempt = 0; $attempt -lt $discoveryAttempts; $attempt++) {
        try {
            $wirelessServices = @(Get-PhoneWirelessServices -RootDirectory $RootDirectory -UsbSerial $UsbSerial |
                Where-Object { ($_.Endpoint -split ':')[0] -eq $pairingAddress })
        } catch {

            if (-not $ConnectionEndpoint) {
                throw 'Pairing succeeded, but discovery failed. Enter the connection IP:port from the main Wireless debugging screen and try again with a new pairing code.'
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
        throw 'Pairing completed, but this USB phone was not discovered over Wi-Fi. Check the selected phone and network, then try again. Settings were not changed.'
    }

    foreach ($service in $wirelessServices) {
        try {
            $result = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('connect', $service.Endpoint)

            if ($result.ExitCode -ne 0) {
                continue
            }

            $identity = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('-s', $service.Endpoint, 'shell', 'getprop', 'ro.serialno')
            $verifiedIdentity = $identity.ExitCode -eq 0 -and $identity.Output.Trim() -ceq $UsbSerial
        } catch {
            continue
        }

        if ($verifiedIdentity) {
            $wirelessTarget = $service.Endpoint

            if ($service.Name) {
                $wirelessTarget = $service.Name + '._adb-tls-connect._tcp'
            }

            return [pscustomobject]@{
                UsbSerial = $UsbSerial
                WirelessService = $wirelessTarget
            }
        }
    }

    throw 'The Wi-Fi connection could not be verified as the selected USB phone. Settings were not changed.'
}
