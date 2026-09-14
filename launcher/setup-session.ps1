. (Join-Path $PSScriptRoot 'setup-runtime.ps1')




# Create an independent settings session without constructing controls or starting work.
function New-SetupSession {
    param([string]$RootDirectory, [hashtable]$Dependencies = @{})
    $services = New-SetupDependencies

    foreach ($name in $Dependencies.Keys) {
        $services[$name] = $Dependencies[$name]
    }

    $snapshot = & $services.ReadSnapshot -RootDirectory $RootDirectory
    $configuration = & $services.ReadConfiguration -RootDirectory $RootDirectory

    if ((& $services.ReadSnapshot -RootDirectory $RootDirectory) -cne $snapshot) {
        throw 'Device settings changed while opening this window. Open Settings again.'
    }

    $session = @{
        RootDirectory = $RootDirectory
        Dependencies = $services
        ConfigurationSnapshot = $snapshot
        SavedConfiguration = $configuration
        PendingWork = $null
        PairingState = [hashtable]::Synchronized(@{})
        Outcome = 'Open'
        Status = ''
        Warning = ''
        Devices = @()
        Input = @{
            Mode = 'auto'; SelectedSerial = ''; PairingCode = ''
            ManualAddresses = $false; PairingEndpoint = ''; ConnectionEndpoint = ''
            CreateShortcut = $true
        }
    }

    if ($null -ne $configuration) {
        $session.Input.Mode = Get-ConnectionMode -Configuration $configuration
    }

    Restore-SetupSavedDevice -Session $session
    Update-SetupStatus -Session $session
    return $session
}

# Preserve a saved device as an offline choice after each discovery attempt.
function Restore-SetupSavedDevice {
    param([hashtable]$Session)

    if ($null -eq $Session.SavedConfiguration) {
        return
    }

    $serial = $Session.SavedConfiguration.UsbSerial

    if (-not @($Session.Devices | Where-Object { $_.Serial -eq $serial }).Count) {
        $Session.Devices += [pscustomobject]@{ Serial = $serial; Label = "Saved phone ($serial)" }
    }

    $Session.Input.SelectedSerial = $serial
}

# Accept a named input snapshot; controller policies never read window controls.
function Set-SetupInput {
    param([hashtable]$Session, [hashtable]$Values)

    if ($null -ne $Session.PendingWork) {
        return
    }

    if ($Values.ContainsKey('PairingCode') -and $Session.Input.PairingCode -cne $Values.PairingCode) {
        $Session.PairingState.Clear()
    }

    foreach ($name in $Session.Input.Keys.Clone()) {

        if ($Values.ContainsKey($name)) {
            $Session.Input[$name] = $Values[$name]
        }
    }
}

# Reuse credentials only for the saved identity and unchanged connection fields.
function Test-SavedWifiSelection {
    param([hashtable]$Session)
    $saved = $Session.SavedConfiguration
    $inputValues = $Session.Input

    if ($null -eq $saved -or -not $saved.WirelessService) {
        return $false
    }

    $hasPairingChanges = $inputValues.PairingCode -or $Session.PairingState.Endpoint -or $inputValues.ManualAddresses

    if ($hasPairingChanges) {
        return $false
    }

    if ($inputValues.Mode -eq 'wifi') {
        return $true
    }

    return $inputValues.SelectedSerial -and $inputValues.SelectedSerial -eq $saved.UsbSerial
}

# Derive mode-specific action availability from plain session data.
function Get-SetupActionState {
    param([hashtable]$Session)
    $values = $Session.Input
    $needsUsb = $values.Mode -ne 'wifi'
    $needsWifi = $values.Mode -ne 'usb'
    $canReuseWifi = Test-SavedWifiSelection -Session $Session
    $hasPairingCode = $values.PairingCode -match '^\d{6}$'
    $canRefreshConnection = $null -ne $Session.SavedConfiguration -and $values.ManualAddresses -and (Test-PairingEndpoint -Endpoint $values.ConnectionEndpoint.Trim())
    $wifiReady = -not $needsWifi -or $hasPairingCode -or $canReuseWifi -or $Session.PairingState.Endpoint -or $canRefreshConnection
    $usbReady = -not $needsUsb -or [bool]$values.SelectedSerial
    $isIdle = $null -eq $Session.PendingWork
    $canFinish = $isIdle -and $usbReady -and $wifiReady
    $finishText = 'Pair and finish'

    if ($canReuseWifi) {
        $finishText = 'Save settings'
    }

    if ($canRefreshConnection -and -not $hasPairingCode) {
        $finishText = 'Verify and save'
    }

    if ($Session.PairingState.Endpoint) {
        $finishText = 'Retry connection'
    }

    if (-not $needsWifi) {
        $finishText = 'Save USB setup'
    }

    $wifiInstructions = 'Wi-Fi: connect both devices to the same network. On the phone (Android 11+), open Wireless debugging > Pair device with pairing code.'
    $pairingLabel = 'Pairing code (6 digits)'

    if ($null -ne $Session.SavedConfiguration -and $Session.SavedConfiguration.WirelessService) {
        $wifiInstructions = 'Your saved pairing can be reused. Keep Wireless debugging enabled and both devices on the same network. Enter a new code only if the phone has forgotten this PC. To replace the phone, use Set up another phone.'
        $pairingLabel = 'New pairing code (optional)'
    }

    return @{
        IsIdle = $isIdle; CanFinish = $canFinish; FinishText = $finishText
        NeedsUsb = $needsUsb; NeedsWifi = $needsWifi
        ShowManualAddresses = $needsWifi -and $values.ManualAddresses
        WifiInstructions = $wifiInstructions; PairingLabel = $pairingLabel
    }
}

# Explain the selected mode without overwriting operation results during rendering.
function Update-SetupStatus {
    param([hashtable]$Session)

    if ($null -ne $Session.SavedConfiguration) {
        $Session.Status = 'Saved phone: ' + $Session.SavedConfiguration.UsbSerial + '. Save to keep its pairing, or enter a new code to pair again. Set up another phone replaces settings only after saving.'
        return
    }

    $Session.Status = 'Select an authorized USB phone and enter its Wi-Fi pairing code. USB + Wi-Fi requires both connections.'

    if ($Session.Input.Mode -eq 'usb') {
        $Session.Status = 'Connect your phone by USB, enable USB debugging, and approve this PC on your phone. No Wi-Fi pairing is needed.'
        return
    }

    if ($Session.Input.Mode -eq 'wifi') {
        $Session.Status = 'No USB cable is needed. Enter your phone pairing code. Enable manual addresses if automatic discovery cannot find it.'
    }
}

# Capture operation values while excluding hidden stale device and address inputs.
function Get-SetupInput {
    param([hashtable]$Session)
    $values = $Session.Input
    $serial = ''

    if ($null -ne $Session.SavedConfiguration) {
        $serial = $Session.SavedConfiguration.UsbSerial
    }

    if ($values.Mode -ne 'wifi' -and $values.SelectedSerial) {
        $serial = $values.SelectedSerial
    }

    $pairingAddress = ''
    $connectionAddress = ''

    if ($values.ManualAddresses -and $values.Mode -ne 'usb') {
        $pairingAddress = $values.PairingEndpoint.Trim()
        $connectionAddress = $values.ConnectionEndpoint.Trim()
    }

    $reuseExisting = $null -ne $Session.SavedConfiguration -and -not $values.PairingCode -and [bool]$connectionAddress
    return @{
        ReuseExisting = $reuseExisting; Serial = $serial; Code = $values.PairingCode
        Mode = $values.Mode; Endpoint = $pairingAddress; ConnectionEndpoint = $connectionAddress
    }
}




# Schedule one operation and retain its cancellation ownership in the session.
function Start-SetupWork {
    param([hashtable]$Session, [string]$Operation, [hashtable]$Values = @{})

    if ($null -ne $Session.PendingWork) {
        return
    }

    try {
        $Session.PendingWork = & $Session.Dependencies.StartWork -RootDirectory $Session.RootDirectory -Operation $Operation -Values $Values -PairingState $Session.PairingState
    } catch {
        $Session.Status = 'Setup could not start: ' + $_.Exception.Message
        return
    }
    $Session.Status = 'Checking USB devices...'

    if ($Operation -eq 'pair') {
        $Session.Status = 'Working... Keep your phone on the same Wi-Fi network and its pairing dialog open. This can take a moment.'
    }

    if ($Operation -eq 'pair' -and ($Session.PairingState.Endpoint -or $Values.ReuseExisting)) {
        $Session.Status = 'Pairing is available. Connecting and verifying your phone... Keep Wireless debugging enabled and both devices on the same network.'
    }

    if ($Operation -eq 'usb') {
        $Session.Status = 'Saving USB settings...'
    }
}

# Commit through the store snapshot guard before any optional desktop action.
function Save-SetupConfiguration {
    param([hashtable]$Session, $Configuration)
    $Session.ConfigurationSnapshot = & $Session.Dependencies.SaveConfiguration -RootDirectory $Session.RootDirectory -Configuration $Configuration -ExpectedSnapshot $Session.ConfigurationSnapshot
    $Session.SavedConfiguration = $Configuration
    $Session.Outcome = 'Saved'

    if (-not $Session.Input.CreateShortcut) {
        return
    }

    try {
        & $Session.Dependencies.CreateShortcut -RootDirectory $Session.RootDirectory
    } catch {
        $Session.Warning = 'Device setup was saved, but the desktop shortcut could not be created. You can still launch the application from Start.vbs in its folder.'
    }
}

# Submit the selected connection scenario without reading view properties.
function Complete-Setup {
    param([hashtable]$Session)

    if (-not (Get-SetupActionState -Session $Session).CanFinish) {
        return
    }

    $values = Get-SetupInput -Session $Session

    if ($values.Mode -ne 'usb' -and (Test-SavedWifiSelection -Session $Session)) {
        try {
            $configuration = [pscustomobject]@{ UsbSerial = $values.Serial; WirelessService = $Session.SavedConfiguration.WirelessService; ConnectionMode = $values.Mode }
            Save-SetupConfiguration -Session $Session -Configuration $configuration
        } catch {
            $Session.Status = 'Settings could not be saved: ' + $_.Exception.Message
        }
        return
    }

    if ($values.Mode -eq 'usb') {
        Start-SetupWork -Session $Session -Operation 'usb' -Values $values
        return
    }

    if ($values.Endpoint -and $values.Endpoint -eq $values.ConnectionEndpoint) {
        $Session.Status = 'The pairing and connection ports are different. Use the pairing dialog address for Pairing IP:port, and the main Wireless debugging screen address for Connection IP:port.'
        return
    }

    Start-SetupWork -Session $Session -Operation 'pair' -Values $values
}

# Apply a completed discovery result while retaining the saved offline identity.
function Set-SetupDevices {
    param([hashtable]$Session, [array]$Devices)
    $Session.Devices = @($Devices | Where-Object { $_.State -eq 'device' } | ForEach-Object {
        [pscustomobject]@{ Serial = $_.Serial; Label = "$($_.Model) ($($_.Serial))" }
    })
    $Session.Input.SelectedSerial = ''

    if ($Session.Devices.Count -eq 1) {
        $Session.Input.SelectedSerial = $Session.Devices[0].Serial
    }

    Restore-SetupSavedDevice -Session $Session
    Update-SetupStatus -Session $Session

    $missingUsb = $null -eq $Session.SavedConfiguration -and -not $Session.Devices.Count -and $Session.Input.Mode -ne 'wifi'

    if ($missingUsb) {
        $Session.Status = 'No authorized USB phone found. Connect and authorize your phone, then click Refresh, or select Wi-Fi only to continue without a cable.'
    }
}

# Drain one completed worker; cancelled results can never reach configuration storage.
function Update-SetupSession {
    param([hashtable]$Session)
    $pending = $Session.PendingWork

    if ($null -eq $pending -or -not $pending.Handle.IsCompleted) {
        return
    }

    try {
        $result = @($pending.Worker.EndInvoke($pending.Handle))

        if ($pending.Worker.HadErrors) {
            throw $pending.Worker.Streams.Error[0]
        }

        if ($pending.Cancellation.IsCancellationRequested) {
            throw [OperationCanceledException]::new('Setup cancelled. Saved settings were not changed.')
        }

        if ($pending.Operation -ne 'devices') {
            Save-SetupConfiguration -Session $Session -Configuration $result[0]
            return
        }

        Set-SetupDevices -Session $Session -Devices $result
    } catch {
        $message = $_.Exception.Message

        if ($pending.Secret) {
            $message = $message.Replace($pending.Secret, '[redacted]')
        }

        $Session.Status = "Setup could not finish: $message"

        if ($Session.PairingState.Endpoint) {
            $Session.Status = 'Pairing completed. Connection is not ready: ' + $message + ' Use Retry connection, or enter Connection IP:port. A new code is not required.'
        }

        if ($pending.Operation -eq 'devices') {
            Set-SetupDevices -Session $Session -Devices @()
            $missingUsb = $null -eq $Session.SavedConfiguration -and $Session.Input.Mode -ne 'wifi'

            if ($missingUsb) {
                $Session.Status = 'USB discovery did not finish. Check your USB connection and click Refresh, or select Wi-Fi only to continue without a cable.'
            }
        }
    } finally {

        if ($pending.Cancellation.IsCancellationRequested) {
            $Session.Status = 'Operation cancelled. Saved settings were not changed.'

            if ($Session.PairingState.Endpoint) {
                $Session.Status += ' Phone pairing completed and remains available; retry the connection without a new code.'
            }
        }

        $pending.Worker.Dispose()
        $pending.Cancellation.Dispose()
        $Session.PendingWork = $null
    }
}

# Cancel owned work first; a subsequent close can dismiss the idle settings window.
function Request-SetupCancellation {
    param([hashtable]$Session)

    if ($null -eq $Session.PendingWork) {
        $Session.Outcome = 'Cancelled'
        return $true
    }

    $Session.PendingWork.Cancellation.Cancel()
    $Session.Status = 'Cancelling... Saved settings will not be changed. Any completed phone pairing remains available.'
    return $false
}

# Clear only draft selection when starting another phone's setup.
function Clear-SetupDraft {
    param([hashtable]$Session)
    $Session.SavedConfiguration = $null
    $Session.PairingState.Clear()
    $Session.Devices = @()
    $Session.Input.SelectedSerial = ''
    $Session.Input.PairingCode = ''
    $Session.Input.PairingEndpoint = ''
    $Session.Input.ConnectionEndpoint = ''
}

# Start replacement discovery while keeping persisted settings until a later save.
function Start-AnotherPhoneSetup {
    param([hashtable]$Session)

    if ($null -ne $Session.PendingWork) {
        return
    }

    Clear-SetupDraft -Session $Session
    Start-SetupWork -Session $Session -Operation 'devices'
}

# Reset only after the view obtains explicit confirmation from the user.
function Reset-SetupState {
    param([hashtable]$Session, [bool]$Confirmed)

    if (-not $Confirmed -or $null -ne $Session.PendingWork) {
        return
    }

    try {
        [void](& $Session.Dependencies.ResetConfiguration -RootDirectory $Session.RootDirectory)
        Clear-SetupDraft -Session $Session
        $Session.ConfigurationSnapshot = $null
        $Session.Outcome = 'Open'
        $Session.Input.ManualAddresses = $false
        $Session.Input.Mode = 'auto'
        $Session.Status = 'Device setup was reset. Choose a connection mode to set up your phone again. Phone pairing, logs, and desktop shortcuts were kept.'
    } catch {
        $Session.Status = 'Device setup could not be reset: ' + $_.Exception.Message
    }
}

# Create a shortcut independently from pairing or configuration persistence.
function New-SetupShortcut {
    param([hashtable]$Session)

    if ($null -ne $Session.PendingWork) {
        return
    }

    try {
        & $Session.Dependencies.CreateShortcut -RootDirectory $Session.RootDirectory
        $Session.Status = 'Desktop shortcut created. Device settings were not changed.'
    } catch {
        $Session.Status = 'The shortcut could not be created: ' + $_.Exception.Message
    }
}

# Release worker resources if application teardown occurs outside normal cancellation.
function Close-SetupSession {
    param([hashtable]$Session)
    $pending = $Session.PendingWork
    $Session.Input.PairingCode = ''

    if ($null -eq $pending) {
        return
    }

    $pending.Cancellation.Cancel()

    try {
        [void]$pending.Worker.EndInvoke($pending.Handle)
    } catch {
        # Cancellation discards unfinished work during teardown.
    } finally {
        $pending.Worker.Dispose()
        $pending.Cancellation.Dispose()
        $Session.PendingWork = $null
    }
}
