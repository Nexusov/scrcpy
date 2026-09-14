param([string]$LauncherDirectory = (Join-Path $PSScriptRoot '..\launcher'), [string]$CoreDirectory = $LauncherDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $CoreDirectory 'launcher-core.ps1')
. (Join-Path $LauncherDirectory 'connection-core.ps1')
$script:assertions = 0

# Fail fast with a description of the transport regression.
function Assert-Connection {
    param([bool]$Condition, [string]$Description)

    if (-not $Condition) {
        throw $Description
    }

    $script:assertions++
}

# Reset deterministic probe responses without contacting a phone.
function Reset-Probe {
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:usbState = 'device'
    $script:wirelessState = 'device'
    $script:identity = 'phone123'
    $script:usbTimeout = $false
    $script:discoveryError = $false
    $script:advertisements = @()
}

# Model transport responses and record which device was queried.
function Invoke-AdbCommand {
    param($RootDirectory, [string[]]$Arguments, $TimeoutMilliseconds)
    $command = $Arguments -join ' '
    $script:calls.Add($command)
    $output = ''

    if ($command -eq '-s phone123 get-state') {

        if ($script:usbTimeout) {
            throw 'Mock USB timeout'
        }

        $output = $script:usbState
    }

    if ($command -like '* get-state' -and $command -ne '-s phone123 get-state') {
        $output = $script:wirelessState
    }

    if ($command -like '* shell getprop ro.serialno') {
        $output = $script:identity
    }

    return [pscustomobject]@{ ExitCode = 0; Output = $output; Error = '' }
}

# Simulate discovery independently from USB readiness.
function Get-PhoneWirelessServices {
    param($RootDirectory, $UsbSerial)
    $script:calls.Add('discovery')

    if ($script:discoveryError) {
        throw 'Mock discovery unavailable'
    }

    return $script:advertisements
}

$usb = [pscustomobject]@{ UsbSerial = 'phone123'; WirelessService = ''; ConnectionMode = 'usb' }
$wifi = [pscustomobject]@{ UsbSerial = 'phone123'; WirelessService = '192.168.1.10:40000'; ConnectionMode = 'wifi' }
$auto = [pscustomobject]@{ UsbSerial = 'phone123'; WirelessService = '192.168.1.10:40000'; ConnectionMode = 'auto' }
Reset-Probe
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $usb
Assert-Connection ($target.Serial -eq 'phone123') 'USB mode did not select the authorized USB phone.'
Assert-Connection ($script:calls.Count -eq 1) 'USB mode performed a wireless probe.'

Reset-Probe
$script:usbState = 'unauthorized'
$progress = @{}
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $usb -Progress $progress
Assert-Connection ($progress.Status -match 'authorize USB debugging') 'Unauthorized USB status omits the action needed on the phone.'
Assert-Connection ($null -eq $target) 'Unauthorized USB was marked ready.'
Assert-Connection ($script:calls.Count -eq 1) 'Unavailable USB mode attempted Wi-Fi.'

Reset-Probe
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $wifi
Assert-Connection ($target.Serial -eq $wifi.WirelessService) 'Wi-Fi mode did not choose its wireless transport.'
Assert-Connection (-not $script:calls.Contains('-s phone123 get-state')) 'Wi-Fi-only mode probed USB.'

Reset-Probe
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $auto
Assert-Connection ($target.Serial -eq 'phone123') 'Auto mode did not prioritize ready USB.'
Assert-Connection (-not ($script:calls | Where-Object { $_ -like 'connect *' })) 'Auto mode connected Wi-Fi before selecting ready USB.'

Reset-Probe
$script:usbTimeout = $true
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $auto
Assert-Connection ($target.Serial -eq $auto.WirelessService) 'USB timeout prevented auto Wi-Fi fallback.'

Reset-Probe
$script:wirelessState = 'offline'
$progress = @{}
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $wifi -Progress $progress
Assert-Connection ($progress.Status -match 'unavailable' -and $progress.Status -notmatch 'disabled') 'Offline status must not assert Wireless debugging is disabled.'
Assert-Connection ($null -eq $target) 'Offline Wi-Fi transport was marked ready.'
Assert-Connection (-not ($script:calls | Where-Object { $_ -like '*ro.serialno' })) 'Offline device was queried for identity.'

Reset-Probe
$script:identity = 'other-phone'
$progress = @{}
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $wifi -Progress $progress
Assert-Connection ($progress.Status -match 'verify the saved phone') 'Wrong phone did not produce identity-specific guidance.'
Assert-Connection ($null -eq $target) 'Wrong-phone Wi-Fi identity was accepted.'

Reset-Probe
$script:discoveryError = $true
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $wifi
Assert-Connection ($target.Serial -eq $wifi.WirelessService) 'Discovery failure prevented saved-address connection.'

Reset-Probe
$script:advertisements = @([pscustomobject]@{Name='adb-phone123-current';Endpoint='192.168.1.10:40001'})
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $wifi
Assert-Connection ($target.Serial -eq 'adb-phone123-current._adb-tls-connect._tcp') 'Current discovery did not replace stale wireless settings.'

Reset-Probe
$script:advertisements = @([pscustomobject]@{Name='adb-phone123-current';Endpoint='192.168.1.10:40001'})
$target = Find-ReadyPhone -RootDirectory 'unused' -Configuration $auto
Assert-Connection ($target.Serial -eq 'phone123') 'Refreshing fallback stopped USB priority.'
Assert-Connection ($target.WirelessTarget -eq 'adb-phone123-current._adb-tls-connect._tcp') 'USB startup retained a stale Wi-Fi fallback target.'

Assert-Connection ((Get-ConnectionHint -Mode 'usb') -match 'USB debugging') 'USB hint omits authorization guidance.'
Assert-Connection ((Get-ConnectionHint -Mode 'wifi') -match 'same network') 'Wi-Fi hint omits network guidance.'
Assert-Connection ((Get-ConnectionHint -Mode 'auto') -match 'USB.*Wireless debugging') 'Auto hint omits one transport.'

# Confirm cancellation actually terminates its owned fake process, not only the worker.
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-cancel-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$fakeProgram = @'
using System;
using System.IO;
using System.Threading;
public static class CancelTestTool {
    public static void Main() {
        File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "pid.txt"), System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(30000);
    }
}
'@
$worker = $null
$ownedProcessId = 0

try {
    Add-Type -TypeDefinition $fakeProgram -OutputAssembly (Join-Path $testDirectory 'adb.exe') -OutputType ConsoleApplication
    $cancellation = (New-Object Threading.CancellationTokenSource)
    $worker = [powershell]::Create()
    [void]$worker.AddScript({
        param($CorePath, $RootDirectory, $Cancellation)
        . $CorePath
        Invoke-AdbCommand -RootDirectory $RootDirectory -Arguments @('devices') -TimeoutMilliseconds 10000 -Cancellation $Cancellation
    }).AddArgument((Join-Path ([IO.Path]::GetFullPath($LauncherDirectory)) 'adb-process.ps1')).AddArgument($testDirectory).AddArgument($cancellation)
    $pending = $worker.BeginInvoke()
    $pidPath = Join-Path $testDirectory 'pid.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    while (-not (Test-Path -LiteralPath $pidPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }

    Assert-Connection (Test-Path -LiteralPath $pidPath) 'Fake ADB did not start.'
    $ownedProcessId = [int][IO.File]::ReadAllText($pidPath)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $cancellation.Cancel()

    try {
        [void]$worker.EndInvoke($pending)
    } catch {
        # Cancellation deliberately throws after releasing the owned process.
    }

    $stopwatch.Stop()
    Assert-Connection ($stopwatch.Elapsed.TotalSeconds -lt 2) 'Cancellation did not terminate promptly.'
    Assert-Connection ($null -eq (Get-Process -Id $ownedProcessId -ErrorAction SilentlyContinue)) 'Cancelled probe left its ADB child alive.'
} finally {

    if ($null -ne $worker) {
        $worker.Dispose()
    }

    if ($ownedProcessId -and $null -ne (Get-Process -Id $ownedProcessId -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $ownedProcessId
    }

    $resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())

    if ($resolvedTestDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTestDirectory -Leaf) -like 'scrcpy-cancel-*') {
        Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
    }
}

Write-Output "$script:assertions connection assertions passed. No real ADB or desktop operations performed."
