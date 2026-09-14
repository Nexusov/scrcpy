# Acquire a per-user desktop session lock and notify the existing launcher.
function Enter-LauncherInstance {
    param([ValidatePattern('^[A-Za-z0-9._-]+$')][string]$InstanceName = 'scrcpy.Seamless')
    $mutex = New-Object Threading.Mutex($false, ('Local\' + $InstanceName + '.Launcher'))
    $signal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, ('Local\' + $InstanceName + '.Activate'))
    $isPrimary = $false

    try {
        $isPrimary = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $isPrimary = $true
    }

    if (-not $isPrimary) {
        $null = $signal.Set()
    }

    return [pscustomobject]@{ IsPrimary = $isPrimary; Mutex = $mutex; Signal = $signal }
}

# Release ownership on the same UI thread that acquired it.
function Exit-LauncherInstance {
    param($Instance)

    if ($Instance.IsPrimary) {
        $Instance.Mutex.ReleaseMutex()
    }

    $Instance.Signal.Dispose()
    $Instance.Mutex.Dispose()
}
