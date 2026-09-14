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

# Refresh the saved endpoint when one unambiguous advertisement identifies this phone.
function Get-CurrentWirelessTarget {
    param([string]$RootDirectory, $Configuration, $Cancellation)

    try {
        $services = @(Get-PhoneWirelessServices -RootDirectory $RootDirectory -Cancellation $Cancellation -UsbSerial $Configuration.UsbSerial)

        if ($services.Count -eq 1) {
            return $services[0].Name + '._adb-tls-connect._tcp'
        }
    } catch [OperationCanceledException] {
        throw
    } catch {
        # The saved endpoint remains usable when multicast discovery is unavailable.
    }

    return [string]$Configuration.WirelessService
}

# Prefer authorized USB when requested, otherwise verify the selected Wi-Fi identity.
function Find-ReadyPhone {
    param([string]$RootDirectory, $Configuration, $Progress = @{}, $Cancellation)
    $probeTimeoutMilliseconds = 2000
    $mode = Get-ConnectionMode -Configuration $Configuration
    $wirelessTarget = [string]$Configuration.WirelessService

    if ($mode -ne 'wifi') {
        $Progress.Status = 'Checking the USB connection...'
        try {
            $usbState = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('-s', $Configuration.UsbSerial, 'get-state') -TimeoutMilliseconds $probeTimeoutMilliseconds

            if ($usbState.ExitCode -eq 0 -and $usbState.Output.Trim() -eq 'device') {
                
                if ($mode -eq 'auto') {
                    $wirelessTarget = Get-CurrentWirelessTarget -RootDirectory $RootDirectory -Configuration $Configuration -Cancellation $Cancellation
                }

                return [pscustomobject]@{
                    Serial = $Configuration.UsbSerial
                    WirelessTarget = $wirelessTarget
                }
            }

            if (($usbState.Output + $usbState.Error) -match 'unauthorized') {
                $Progress.Status = 'Phone found over USB. Unlock it and authorize USB debugging.'
            }
        } catch [OperationCanceledException] {
            throw
        } catch {
            # A USB transport failure must not prevent Wi-Fi fallback.
        }
    }

    if ($mode -eq 'usb') {
        return $null
    }

    $Progress.Status = 'Looking for your phone over Wi-Fi...'
    $wirelessTarget = Get-CurrentWirelessTarget -RootDirectory $RootDirectory -Configuration $Configuration -Cancellation $Cancellation

    $Progress.Status = 'Trying the Wi-Fi connection...'
    $null = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('connect', $wirelessTarget) -TimeoutMilliseconds $probeTimeoutMilliseconds
    $state = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('-s', $wirelessTarget, 'get-state') -TimeoutMilliseconds $probeTimeoutMilliseconds

    if ($state.ExitCode -ne 0 -or $state.Output.Trim() -ne 'device') {
        $Progress.Status = 'Wi-Fi connection unavailable. Retrying automatically...'
        return $null
    }

    $Progress.Status = 'Phone connected. Verifying the saved device...'
    $identity = Invoke-AdbCommand -RootDirectory $RootDirectory -Cancellation $Cancellation -Arguments @('-s', $wirelessTarget, 'shell', 'getprop', 'ro.serialno') -TimeoutMilliseconds $probeTimeoutMilliseconds

    if ($identity.ExitCode -ne 0 -or $identity.Output.Trim() -cne $Configuration.UsbSerial) {
        $Progress.Status = 'Could not verify the saved phone. Check your device in Settings.'
        return $null
    }

    return [pscustomobject]@{
        Serial = $wirelessTarget
        WirelessTarget = $wirelessTarget
    }
}
