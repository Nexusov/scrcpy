$ErrorActionPreference = 'Stop'
$configurationPath = Join-Path $PSScriptRoot 'phone.json'
$logPath = Join-Path $PSScriptRoot 'last-run.log'
$errorLogPath = Join-Path $PSScriptRoot 'last-run-errors.log'
$env:ADB = Join-Path $PSScriptRoot 'adb.exe'
$env:ADB_MDNS_OPENSCREEN = '1'
$serviceType = '_adb-tls-connect._tcp'

try {
    if (-not (Test-Path -LiteralPath $configurationPath)) {
        throw 'Copy phone.example.json to phone.json and configure your phone before starting.'
    }

    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
    $validConfiguration = $configuration.UsbSerial -match '^[A-Za-z0-9_-]+$' -and
        $configuration.WirelessService -match '^adb-[A-Za-z0-9_-]+\._adb-tls-connect\._tcp$' -and
        $configuration.UsbSerial -ne 'YOUR_USB_SERIAL'

    if (-not $validConfiguration) {
        throw 'Set UsbSerial and WirelessService in phone.json using the instructions in README.md.'
    }

    $servicePrefix = 'adb-' + $configuration.UsbSerial + '-'
    Set-Content -LiteralPath $logPath -Value ('Started: ' + (Get-Date -Format o)) -Encoding UTF8
    # ADB writes normal daemon startup messages to stderr on Windows PowerShell.
    $ErrorActionPreference = 'Continue'
    & $env:ADB start-server 2>&1 | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    $adbExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($adbExitCode -ne 0) {
        throw "ADB startup failed with code $adbExitCode"
    }
    $services = & $env:ADB mdns services 2>$null

    foreach ($serviceLine in $services) {
        $serviceFields = $serviceLine.Trim() -split '\s+'
        $isMatchingService = $serviceFields.Count -eq 3 -and
            $serviceFields[0].StartsWith($servicePrefix) -and
            $serviceFields[1] -eq $serviceType

        if (-not $isMatchingService) {
            continue
        }

        $configuration.WirelessService = $serviceFields[0] + '.' + $serviceType
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
        break
    }

    $env:SCRCPY_RECONNECT_SERIAL = $configuration.WirelessService
    $devices = & $env:ADB devices
    $authorizedDevicePattern = '^' + [regex]::Escape($configuration.UsbSerial) + '\s+device\s*$'
    $usbConnected = @($devices | Where-Object { $_ -match $authorizedDevicePattern }).Count
    $selectedSerial = $configuration.WirelessService

    if ($usbConnected) {
        $selectedSerial = $configuration.UsbSerial
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
        $outputCopy.GetAwaiter().GetResult()
        $errorCopy.GetAwaiter().GetResult()
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
