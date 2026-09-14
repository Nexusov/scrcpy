. (Join-Path $PSScriptRoot 'launcher-core.ps1')
. (Join-Path $PSScriptRoot 'shortcut.ps1')

# Construct application services separately from the settings presentation.
function New-SetupDependencies {
    return @{
        ReadConfiguration = { param($RootDirectory) Get-PhoneConfiguration -RootDirectory $RootDirectory }
        ReadSnapshot = { param($RootDirectory) Get-DeviceConfigurationSnapshot -RootDirectory $RootDirectory }
        SaveConfiguration = { param($RootDirectory, $Configuration, $ExpectedSnapshot) Save-PhoneConfiguration -RootDirectory $RootDirectory -Configuration $Configuration -ExpectedSnapshot $ExpectedSnapshot -PassThruSnapshot }
        ResetConfiguration = { param($RootDirectory) Reset-DeviceConfiguration -RootDirectory $RootDirectory -Confirmed $true }
        AssertResetAvailable = { param($RootDirectory) Assert-DeviceResetAvailable -RootDirectory $RootDirectory }
        CreateShortcut = { param($RootDirectory) New-DesktopShortcut -RootDirectory $RootDirectory }
        StartWork = { param($RootDirectory, $Operation, $Values, $PairingState) New-SetupWorker -RootDirectory $RootDirectory -Operation $Operation -Values $Values -PairingState $PairingState }
    }
}

# Start cancellable infrastructure work with a fixed copy of submitted values.
function New-SetupWorker {
    param([string]$RootDirectory, [string]$Operation, [hashtable]$Values, $PairingState)
    $cancellation = New-Object Threading.CancellationTokenSource
    $worker = [powershell]::Create()

    try {
        [void]$worker.AddScript({
            param($Directory, $Action, $InputValues, $Cancellation, $PairingState)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $Directory 'launcher-core.ps1')

            if ($Action -eq 'devices') {
                return @(Get-SetupDevices -RootDirectory $Directory -Cancellation $Cancellation)
            }

            if ($Action -eq 'usb') {
                return [pscustomobject]@{ UsbSerial = $InputValues.Serial; WirelessService = ''; ConnectionMode = 'usb' }
            }

            if ($InputValues.ReuseExisting) {
                $PairingState = @{ Endpoint = $InputValues.ConnectionEndpoint; Serial = $InputValues.Serial; Existing = $true }
            }

            $configuration = Complete-WirelessPairing -RootDirectory $Directory -UsbSerial $InputValues.Serial -PairingCode $InputValues.Code -Endpoint $InputValues.Endpoint -ConnectionEndpoint $InputValues.ConnectionEndpoint -PairingState $PairingState -Cancellation $Cancellation
            $configuration | Add-Member -NotePropertyName ConnectionMode -NotePropertyValue $InputValues.Mode -Force
            return $configuration
        }).AddArgument($RootDirectory).AddArgument($Operation).AddArgument($Values.Clone()).AddArgument($cancellation).AddArgument($PairingState)
        return @{ Worker = $worker; Handle = $worker.BeginInvoke(); Operation = $Operation; Cancellation = $cancellation; Secret = $Values.Code }
    } catch {
        $worker.Dispose()
        $cancellation.Dispose()
        throw
    }
}
