$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'launcher/launcher-core.ps1')
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-settings-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
# Fail with the scenario that regressed.
function Assert-Setup { param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}
$script:pairCount = 0
$script:connectionReady = $false
# Simulate discovery becoming available after successful pairing.
function Get-AdbServices { param($RootDirectory, $ServiceType)

    if ($script:connectionReady) {
        return [pscustomobject]@{ Name = 'adb-phone123-test'; Endpoint = '192.168.1.8:40001'; TransportName = 'adb-phone123-test.' + $ServiceType }
    }
    return @()
}
# Keep pairing calls countable and identity verification realistic.
function Invoke-AdbCommand { param($RootDirectory, $Arguments)

    if ($Arguments[0] -eq 'pair') {
        $script:pairCount++
        return [pscustomobject]@{ ExitCode = 0; Output = 'Successfully paired'; Error = '' }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = 'phone123'; Error = '' }
}
$pairingState = @{}
$connectionRejected = $false
try {
    Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingCode 123456 -Endpoint '192.168.1.8:40000' -PairingState $pairingState
} catch {
    $connectionRejected = $true
}
Assert-Setup $connectionRejected 'Unavailable connection was incorrectly accepted.'
Assert-Setup ($pairingState.Endpoint -eq '192.168.1.8:40000') 'Successful pairing state lost.'
$script:connectionReady = $true
$configuration = Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingCode '' -PairingState $pairingState
Assert-Setup ($script:pairCount -eq 1) 'Connection retry repeated pairing.'
Assert-Setup ($configuration.UsbSerial -eq 'phone123') 'Retry did not verify identity.'
$identityRejected = $false
try {
    Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial differentPhone -PairingCode '' -PairingState $pairingState
} catch { $identityRejected = $true }
Assert-Setup $identityRejected 'Changed device reused another phone pairing.'
Write-Output 'PASS: pairing retained, retried once, and identity bound.'
$configuration = Complete-WirelessPairing -RootDirectory $testDirectory -UsbSerial phone123 -PairingState @{ Endpoint = '192.168.1.8:40001'; Serial = 'phone123'; Existing = $true } -ConnectionEndpoint '192.168.1.8:40001'
Assert-Setup ($script:pairCount -eq 1 -and $configuration.UsbSerial -eq 'phone123') 'Saved endpoint refresh repeated pairing or missed identity.'
Write-Output 'PASS: saved connection endpoint can refresh without pairing.'


$resolvedDirectory = [IO.Path]::GetFullPath($testDirectory)
if ($resolvedDirectory.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
