# Acquire a per-user desktop session lock and notify the existing launcher.
function Enter-LauncherInstance {
    $mutex = New-Object Threading.Mutex($false, 'Local\scrcpy.Seamless.Launcher')
    $signal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\scrcpy.Seamless.Activate')
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
