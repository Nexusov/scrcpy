$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'last-run.log'
$errorLogPath = Join-Path $PSScriptRoot 'last-run-errors.log'
$env:ADB = Join-Path $PSScriptRoot 'adb.exe'
$env:ADB_MDNS_OPENSCREEN = '1'

try {
    . (Join-Path $PSScriptRoot 'launcher-core.ps1')
    $configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot

    if ($null -eq $configuration) {
        $setupPath = Join-Path $PSScriptRoot 'setup.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $setupPath

        if ($LASTEXITCODE -ne 0) {
            exit 0
        }

        $configuration = Get-PhoneConfiguration -RootDirectory $PSScriptRoot

        if ($null -eq $configuration) {
            throw 'Setup did not save a valid configuration. Run setup.vbs to try again.'
        }
    }

    Set-Content -LiteralPath $logPath -Value ('Started: ' + (Get-Date -Format o)) -Encoding UTF8
    $adbResult = Invoke-AdbCommand -RootDirectory $PSScriptRoot -Arguments @('start-server')

    if ($adbResult.ExitCode -ne 0) {
        throw 'ADB could not start. Check the application files and USB driver.'
    }

    $env:SCRCPY_RECONNECT_SERIAL = $null
    $connectionMode = Get-ConnectionMode -Configuration $configuration

    if ($connectionMode -ne 'usb') {
        try {
            $services = @(Get-PhoneWirelessServices -RootDirectory $PSScriptRoot -UsbSerial $configuration.UsbSerial)

            if ($services.Count -eq 1) {
                $configuration.WirelessService = $services[0].Name + '._adb-tls-connect._tcp'
                Save-PhoneConfiguration -RootDirectory $PSScriptRoot -Configuration $configuration
            }
        } catch {
            Add-Content -LiteralPath $logPath -Value 'Wireless discovery unavailable; using saved settings.'
        }

        $env:SCRCPY_RECONNECT_SERIAL = $configuration.WirelessService
    }

    $selectedSerial = $configuration.WirelessService

    if ($connectionMode -ne 'wifi') {
        $devices = @(Get-SetupDevices -RootDirectory $PSScriptRoot)
        $usbConnected = @($devices | Where-Object { $_.Serial -ceq $configuration.UsbSerial -and $_.State -eq 'device' }).Count

        if ($usbConnected) {
            $selectedSerial = $configuration.UsbSerial
        }
    }

    if (-not $selectedSerial) {
        throw 'Connect and authorize your phone over USB, or run setup.vbs to enable Wi-Fi fallback.'
    }

    # The client reconnects internally and keeps its SDL window alive.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $PSScriptRoot 'scrcpy.exe'
    $startInfo.Arguments = '-s "' + $selectedSerial + '" --window-title=Phone-Seamless --pause-on-exit=false'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $outputFile = [IO.File]::Open($logPath, 'Append', 'Write', 'ReadWrite')
    $errorFile = [IO.File]::Open($errorLogPath, 'Create', 'Write', 'ReadWrite')

    try {
        $streamProcess = [Diagnostics.Process]::Start($startInfo)
        $outputCopy = $streamProcess.StandardOutput.BaseStream.CopyToAsync($outputFile)
        $errorCopy = $streamProcess.StandardError.BaseStream.CopyToAsync($errorFile)
        $streamProcess.WaitForExit()
        $null = $outputCopy.GetAwaiter().GetResult()
        $null = $errorCopy.GetAwaiter().GetResult()
    } finally {
        $outputFile.Dispose()
        $errorFile.Dispose()
    }

    if ($streamProcess.ExitCode -ne 0) {
        throw "scrcpy exited with code $($streamProcess.ExitCode). See $errorLogPath"
    }
} catch {
    $_ | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    $shell = New-Object -ComObject WScript.Shell
    $null = $shell.Popup("$($_.Exception.Message)`nDetails: $logPath", 0, 'scrcpy Seamless', 16)
    exit 1
}
