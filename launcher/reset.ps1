# Serializes reset with the launcher's final configuration check and native startup.
function Invoke-DeviceConfigurationLock {
    param([string]$RootDirectory, [scriptblock]$Action)
    $directory = [IO.Path]::GetFullPath($RootDirectory).TrimEnd('\').ToLowerInvariant()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($directory))).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }

    $mutex = New-Object Threading.Mutex($false, ('Local\scrcpy-seamless-configuration-' + $digest))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw 'Device settings are in use. Wait a moment and try again.'
        }

        & $Action
    }
    finally {

        if ($acquired) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}

# Refuses reset while this portable application's native session is running.
function Assert-DeviceResetAvailable {
    param([string]$RootDirectory)
    $executablePath = [IO.Path]::GetFullPath((Join-Path $RootDirectory 'scrcpy.exe'))
    foreach ($process in @(Get-Process -Name scrcpy -ErrorAction SilentlyContinue)) {
        try {
            $processPath = $process.Path
        }
        catch {
            throw 'Cannot verify whether scrcpy is running. Close any mirroring windows before resetting device setup.'
        }

        if (-not $processPath) {
            throw 'Cannot verify whether scrcpy is running. Close any mirroring windows before resetting device setup.'
        }

        if ([string]::Equals($processPath, $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Close the mirroring window before resetting device setup, then try again.'
        }
    }
}

# Removes only this application's saved configuration after explicit confirmation.
function Reset-DeviceConfiguration {
    param([string]$RootDirectory, [bool]$Confirmed = $false)

    if (-not $Confirmed) {
        return $false
    }

    Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action {
        Assert-DeviceResetAvailable -RootDirectory $RootDirectory
        $configurationPath = Join-Path ([IO.Path]::GetFullPath($RootDirectory)) 'phone.json'

        if (Test-Path -LiteralPath $configurationPath -PathType Container) {
            throw 'phone.json is a directory instead of a settings file. No files were removed.'
        }

        if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
            Remove-Item -LiteralPath $configurationPath -ErrorAction Stop
        }

        return $true
    }
}
