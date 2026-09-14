# Run only the current probe's ADB process with a cancellable, bounded wait.
function Invoke-ConnectionAdb {
    param([string]$RootDirectory, [string[]]$Arguments, [int]$TimeoutMilliseconds, $Cancellation)

    if ($Cancellation.Requested) {
        throw 'Connection cancelled.'
    }

    foreach ($argument in $Arguments) {

        if ($argument -notmatch '^[A-Za-z0-9_:.=\-]+$') {
            throw 'Invalid ADB argument.'
        }
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $RootDirectory 'adb.exe'
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.WorkingDirectory = $RootDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['ADB_MDNS_OPENSCREEN'] = '1'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $pollMilliseconds = 100
    $started = $false

    try {
        $null = $process.Start()
        $started = $true
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

        while (-not $process.WaitForExit($pollMilliseconds)) {
            $stopRequested = $Cancellation.Requested -or [DateTime]::UtcNow -ge $deadline

            if ($stopRequested) {
                throw 'Connection check cancelled or timed out.'
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.GetAwaiter().GetResult()
            Error = $errorTask.GetAwaiter().GetResult()
        }
    } finally {

        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }

        $process.Dispose()
    }
}

# Provide immediate instructions for the selected connection mode.
function Get-ConnectionHint {
    param([string]$Mode)

    if ($Mode -eq 'usb') {
        return 'Connect your phone using a data cable, enable USB debugging, unlock the phone, and authorize this PC.'
    }

    if ($Mode -eq 'wifi') {
        return 'Make sure Wireless debugging is enabled and your phone and PC are on the same network.'
    }

    return 'Connect and authorize your phone over USB, or enable Wireless debugging and connect your phone and PC to the same network.'
}

# Resolve an authorized device before creating the native mirroring process.
function Find-ReadyPhone {
    param([string]$RootDirectory, $Configuration, $Progress = @{})
    $probeTimeoutMilliseconds = 2000
    $mode = Get-ConnectionMode -Configuration $Configuration
    $wirelessTarget = [string]$Configuration.WirelessService

    if ($mode -ne 'wifi') {
        $Progress.Status = 'Checking the USB connection...'
        try {
            $usbState = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('-s', $Configuration.UsbSerial, 'get-state') -TimeoutMilliseconds $probeTimeoutMilliseconds

            if ($usbState.ExitCode -eq 0 -and $usbState.Output.Trim() -eq 'device') {
                
                if ($mode -eq 'auto') {
                    try {
                        $services = @(Get-PhoneWirelessServices -RootDirectory $RootDirectory -UsbSerial $Configuration.UsbSerial)

                        if ($services.Count -eq 1) {
                            $wirelessTarget = $services[0].Name + '._adb-tls-connect._tcp'
                        }
                    } catch {
                        # USB remains usable while Wi-Fi discovery is unavailable.
                    }
                }

                return [pscustomobject]@{ Serial = $Configuration.UsbSerial; WirelessTarget = $wirelessTarget }
            }

            if (($usbState.Output + $usbState.Error) -match 'unauthorized') {
                $Progress.Status = 'Phone found over USB. Unlock it and authorize USB debugging.'
            }
        } catch {
            # A USB transport failure must not prevent Wi-Fi fallback.
        }
    }

    if ($mode -eq 'usb') {
        return $null
    }

    try {
        $Progress.Status = 'Looking for your phone over Wi-Fi...'
        $services = @(Get-PhoneWirelessServices -RootDirectory $RootDirectory -UsbSerial $Configuration.UsbSerial)

        if ($services.Count -eq 1) {
            $wirelessTarget = $services[0].Name + '._adb-tls-connect._tcp'
        }
    } catch {
        # A saved endpoint can still work when multicast discovery is unavailable.
    }

    $Progress.Status = 'Trying the Wi-Fi connection...'
    $null = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('connect', $wirelessTarget) -TimeoutMilliseconds $probeTimeoutMilliseconds
    $state = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('-s', $wirelessTarget, 'get-state') -TimeoutMilliseconds $probeTimeoutMilliseconds

    if ($state.ExitCode -ne 0 -or $state.Output.Trim() -ne 'device') {
        $Progress.Status = 'Wi-Fi connection unavailable. Retrying automatically...'
        return $null
    }

    $Progress.Status = 'Phone connected. Verifying the saved device...'
    $identity = Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('-s', $wirelessTarget, 'shell', 'getprop', 'ro.serialno') -TimeoutMilliseconds $probeTimeoutMilliseconds

    if ($identity.ExitCode -ne 0 -or $identity.Output.Trim() -cne $Configuration.UsbSerial) {
        $Progress.Status = 'Could not verify the saved phone. Check your device in Setup.'
        return $null
    }

    return [pscustomobject]@{ Serial = $wirelessTarget; WirelessTarget = $wirelessTarget }
}
