$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/options-store.ps1')

# Fail a regression with its user-visible consequence.
function Assert-Option { param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

# Verify invalid drafts fail before modifying persisted settings.
function Assert-InvalidOption { param($Settings)
    $rejected = $false

    try {
        Assert-ScrcpySettings -Settings $Settings
    } catch {
        $rejected = $true
    }

    Assert-Option $rejected ('Invalid options accepted: ' + ($Settings | ConvertTo-Json -Compress))
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-options-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory

try {
    $settings = Get-ScrcpySettings -RootDirectory $directory
    Assert-Option ($settings.Reconnect -and -not $settings.Options.Count) 'Defaults changed native quality.'
    $phonePath = Join-Path $directory 'phone.json'
    [IO.File]::WriteAllText($phonePath, 'private phone sentinel')
    $settings.Options = @{ 'max-fps' = '60'; 'video-bit-rate' = '4M'; 'max-size' = '1280'; 'no-audio' = $true }
    Save-ScrcpySettings -RootDirectory $directory -Settings $settings -ExpectedSnapshot $null
    $snapshot = Get-ScrcpySettingsSnapshot -RootDirectory $directory
    $loaded = Get-ScrcpySettings -RootDirectory $directory
    Assert-Option ($loaded.Options['max-fps'] -ceq '60') 'FPS override was not preserved.'
    Assert-Option ($loaded.Options['no-audio'] -is [bool]) 'Boolean type changed in persistence.'
    Assert-Option ([IO.File]::ReadAllText($phonePath) -ceq 'private phone sentinel') 'Mirroring save modified phone setup.'
    $staleRejected = $false

    try {
        Save-ScrcpySettings -RootDirectory $directory -Settings $settings -ExpectedSnapshot $null
    } catch {
        $staleRejected = $true
    }

    Assert-Option $staleRejected 'A stale Settings window overwrote another save.'
    Assert-Option ((Get-ScrcpySettingsSnapshot $directory) -ceq $snapshot) 'Rejected save changed file.'
    Assert-InvalidOption @{ Options = @{ 'unknown-flag' = 'value' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'serial' = 'other-phone' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'no-audio' = 'true' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'max-fps' = "60`n--no-audio" }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'max-fps' = '-5' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'video-codec' = 'bogus' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'record' = 'video.mp4' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'keyboard' = 'aoa' }; Reconnect = $true }
    Assert-InvalidOption @{ Options = @{ 'no-window' = $true }; Reconnect = $true }
    Assert-ScrcpySettings @{ Options = @{ 'record' = 'video.mp4'; 'time-limit' = '10' }; Reconnect = $false }
    Assert-InvalidOption @{ Options = @{ 'otg' = $true }; Reconnect = $false }
    $optional = @{ Options = @{ 'new-display' = '' }; Reconnect = $true }
    Assert-Option (@(Get-ScrcpyArguments $optional)[0] -ceq '--new-display') 'Optional bare flag became a default.'
    Save-ScrcpySettings -RootDirectory $directory -Settings $optional -ExpectedSnapshot $snapshot
    Assert-Option ((Get-ScrcpySettings $directory).Options.ContainsKey('new-display')) 'Bare optional flag lost on disk.'

    # Exercise real Windows argument decoding rather than comparing a quoting implementation to itself.
    $program = @'
using System;
public static class ArgumentEcho {
    public static void Main(string[] arguments) {
        foreach (string argument in arguments) Console.WriteLine(Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(argument)));
    }
}
'@
    $executable = Join-Path $directory 'echo.exe'
    Add-Type -TypeDefinition $program -OutputAssembly $executable -OutputType ConsoleApplication
    $arguments = @('plain', '', 'space title', 'embedded"quote', 'G:\folder with spaces\', 'a\\"b', '--record=video & $(whoami).mkv')
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.Arguments = ConvertTo-ScrcpyCommandLine -Arguments $arguments
    $process = [Diagnostics.Process]::Start($startInfo)

    try {
        $actual = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $expected = ($arguments | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join [Environment]::NewLine
        Assert-Option ($actual -ceq ($expected + [Environment]::NewLine)) 'Windows argument boundaries changed.'
    } finally {
        $process.Dispose()
    }

    [IO.File]::WriteAllText((Join-Path $directory 'scrcpy-settings.json'), '{ invalid')
    $corruptRejected = $false

    try {
        Get-ScrcpySettings $directory
    } catch {
        $corruptRejected = $true
    }

    Assert-Option $corruptRejected 'Corrupt settings silently reset quality.'
    Write-Output 'PASS: settings round-trip, atomic concurrency, device isolation, validation, optional flags, real Windows argument decoding and corrupt file handling.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $directory).ProviderPath

    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected test directory.'
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}
