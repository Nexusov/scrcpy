# Exercise real launcher processes against a disposable fake ADB and client.
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$assertionCount = 0

# Stop at the first regression with a readable assertion message.
function Assert-Condition {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }

    $script:assertionCount++
}

# Verify a failed action leaves the saved configuration unchanged.
function Assert-RejectedPairing {
    param([hashtable]$Parameters)
    $before = [IO.File]::ReadAllText((Join-Path $temporaryDirectory 'phone.json'))
    $rejected = $false

    try {
        $configuration = Complete-WirelessPairing -RootDirectory $temporaryDirectory @Parameters
        Save-PhoneConfiguration -RootDirectory $temporaryDirectory -Configuration $configuration
    } catch {
        $rejected = $true
    }

    Assert-Condition $rejected 'Pairing should have failed.'
    Assert-Condition ($before -ceq [IO.File]::ReadAllText((Join-Path $temporaryDirectory 'phone.json'))) 'Failed pairing changed settings.'
}

try {
    Copy-Item (Join-Path $repository 'launcher\launch.ps1'), (Join-Path $repository 'launcher\launcher-core.ps1') $temporaryDirectory
    # The same test executable behaves as ADB or scrcpy based on its file name.
    $fakeProgram = @'
using System;
using System.IO;
using System.Threading;
public static class FakeDeviceTool {
    public static int Main(string[] arguments) {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string name = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (name == "scrcpy") {
            File.WriteAllText(Path.Combine(root, "launch-result.txt"), string.Join(" ", arguments) + "\n" + Environment.GetEnvironmentVariable("SCRCPY_RECONNECT_SERIAL"));
            return 0;
        }
        if (File.Exists(Path.Combine(root, "timeout.flag"))) { Thread.Sleep(3000); }
        string command = string.Join(" ", arguments);
        if (command == "devices -l") { Console.Write(File.ReadAllText(Path.Combine(root, "devices.txt"))); }
        if (command == "mdns services") { Console.Write(File.ReadAllText(Path.Combine(root, "services.txt"))); }
        if (command.StartsWith("pair ")) {
            File.WriteAllText(Path.Combine(root, "pair-called.txt"), "called");
            if (File.Exists(Path.Combine(root, "reject.flag"))) { Console.Write("Failed to pair"); return 1; }
            Console.Write("Successfully paired");
        }
        if (command.StartsWith("connect ")) { Console.Write("connected"); }
        if (command.EndsWith("getprop ro.serialno")) { Console.Write(File.ReadAllText(Path.Combine(root, "identity.txt"))); }
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $fakeProgram -OutputAssembly (Join-Path $temporaryDirectory 'adb.exe') -OutputType ConsoleApplication
    Copy-Item (Join-Path $temporaryDirectory 'adb.exe') (Join-Path $temporaryDirectory 'scrcpy.exe')
    . (Join-Path $temporaryDirectory 'launcher-core.ps1')
    $legacy = [pscustomobject]@{ UsbSerial = 'TEST123'; WirelessService = 'adb-TEST123-paired._adb-tls-connect._tcp' }
    Save-PhoneConfiguration -RootDirectory $temporaryDirectory -Configuration $legacy
    Assert-Condition ((Get-PhoneConfiguration $temporaryDirectory).WirelessService -eq $legacy.WirelessService) 'Legacy configuration rejected.'
    Assert-Condition (-not (Test-PairingEndpoint '999.1.1.1:5000')) 'Invalid IPv4 accepted.'
    Assert-Condition (-not (Test-PairingEndpoint '192.168.1.2:65536')) 'Invalid port accepted.'
    Set-Content (Join-Path $temporaryDirectory 'devices.txt') "TEST123 device model:Test_Phone`nLOCKED unauthorized`nemulator-5554 device`n192.168.1.2:4000 device"
    Set-Content (Join-Path $temporaryDirectory 'services.txt') "adb-TEST123-pair _adb-tls-pairing._tcp 192.168.1.2:4000`nadb-TEST123-paired _adb-tls-connect._tcp 192.168.1.2:5000"
    Set-Content (Join-Path $temporaryDirectory 'identity.txt') 'TEST123'
    $devices = @(Get-SetupDevices $temporaryDirectory)
    Assert-Condition ($devices.Count -eq 2) 'Network or emulator mistaken for USB.'
    Assert-Condition ($devices[1].State -eq 'unauthorized') 'Authorization state lost.'
    $paired = Complete-WirelessPairing -RootDirectory $temporaryDirectory -UsbSerial TEST123 -PairingCode 123456
    Assert-Condition ($paired.WirelessService -eq $legacy.WirelessService) 'Automatic pairing failed.'
    Set-Content (Join-Path $temporaryDirectory 'identity.txt') 'OTHER'
    Assert-RejectedPairing @{ UsbSerial = 'TEST123'; PairingCode = '123456' }
    Set-Content (Join-Path $temporaryDirectory 'identity.txt') 'TEST123'
    [IO.File]::Delete((Join-Path $temporaryDirectory 'pair-called.txt'))
    Set-Content (Join-Path $temporaryDirectory 'services.txt') "adb-OTHER-pair _adb-tls-pairing._tcp 192.168.1.9:4000`nadb-TEST123-paired _adb-tls-connect._tcp 192.168.1.2:5000"
    Assert-RejectedPairing @{ UsbSerial = 'TEST123'; PairingCode = '123456' }
    Assert-Condition (-not (Test-Path (Join-Path $temporaryDirectory 'pair-called.txt'))) 'Paired a different advertised phone.'
    Set-Content (Join-Path $temporaryDirectory 'services.txt') ''
    $manual = Complete-WirelessPairing -RootDirectory $temporaryDirectory -UsbSerial TEST123 -PairingCode 123456 -Endpoint '192.168.1.2:4000' -ConnectionEndpoint '192.168.1.2:5000'
    Assert-Condition ($manual.WirelessService -eq '192.168.1.2:5000') 'Manual discovery fallback failed.'
    Set-Content (Join-Path $temporaryDirectory 'reject.flag') ''
    Assert-RejectedPairing @{ UsbSerial = 'TEST123'; PairingCode = '123456'; Endpoint = '192.168.1.2:4000' }
    [IO.File]::Delete((Join-Path $temporaryDirectory 'reject.flag'))

    # Existing users bypass the wizard, and USB takes priority over saved Wi-Fi.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temporaryDirectory 'launch.ps1')
    Assert-Condition ($LASTEXITCODE -eq 0) 'Legacy launch failed.'
    $launchResult = Get-Content (Join-Path $temporaryDirectory 'launch-result.txt') -Raw
    Assert-Condition ($launchResult.StartsWith('-s TEST123 ')) 'USB did not take priority.'
    Set-Content (Join-Path $temporaryDirectory 'devices.txt') ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temporaryDirectory 'launch.ps1')
    $launchResult = Get-Content (Join-Path $temporaryDirectory 'launch-result.txt') -Raw
    Assert-Condition ($launchResult.StartsWith('-s adb-TEST123-paired._adb-tls-connect._tcp ')) 'Saved Wi-Fi launch failed.'
    Save-PhoneConfiguration $temporaryDirectory ([pscustomobject]@{ UsbSerial = 'TEST123'; WirelessService = '' })
    Set-Content (Join-Path $temporaryDirectory 'devices.txt') 'TEST123 device'
    $env:SCRCPY_RECONNECT_SERIAL = 'must-be-cleared'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temporaryDirectory 'launch.ps1')
    $launchResult = Get-Content (Join-Path $temporaryDirectory 'launch-result.txt') -Raw
    Assert-Condition ($launchResult.EndsWith("`n")) 'USB-only inherited reconnect configuration.'

    # A cancelled first run must not start scrcpy or write settings.
    [IO.File]::Delete((Join-Path $temporaryDirectory 'phone.json'))
    [IO.File]::Delete((Join-Path $temporaryDirectory 'launch-result.txt'))
    Set-Content (Join-Path $temporaryDirectory 'setup.ps1') 'exit 1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temporaryDirectory 'launch.ps1')
    Assert-Condition (-not (Test-Path (Join-Path $temporaryDirectory 'launch-result.txt'))) 'Cancelled setup launched scrcpy.'
    Assert-Condition (-not (Test-Path (Join-Path $temporaryDirectory 'phone.json'))) 'Cancelled setup wrote settings.'
    Set-Content (Join-Path $temporaryDirectory 'timeout.flag') ''
    $timedOut = $false

    try {
        Invoke-AdbCommand $temporaryDirectory @('devices') -TimeoutMilliseconds 100 | Out-Null
    } catch {
        $timedOut = $_.Exception.Message -match 'timed out'
    }

    Assert-Condition $timedOut 'ADB timeout failed.'
    Write-Host "Passed $assertionCount launcher assertions on Windows PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $env:SCRCPY_RECONNECT_SERIAL = $null
    $resolved = [IO.Path]::GetFullPath($temporaryDirectory)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

    if ((Split-Path -Parent $resolved) -eq $expectedParent) {
        [IO.Directory]::Delete($resolved, $true)
    }
}
