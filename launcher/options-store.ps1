. (Join-Path $PSScriptRoot 'option-catalog.ps1')
. (Join-Path $PSScriptRoot 'configuration-store.ps1')

# Return defaults without changing native quality or existing device setup.
function New-ScrcpySettings {
    return @{ Options = @{}; Reconnect = $true }
}

# Capture exact persisted bytes as text for optimistic concurrency.
function Get-ScrcpySettingsSnapshot {
    param([string]$RootDirectory)
    $path = Join-Path $RootDirectory 'scrcpy-settings.json'

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    return [IO.File]::ReadAllText($path)
}

# Reject unknown flags, invalid values and native reconnection conflicts centrally.
function Assert-ScrcpySettings {
    param($Settings)

    if ($null -eq $Settings -or $Settings.Reconnect -isnot [bool]) {
        throw 'Reconnect must be true or false.'
    }

    if ($Settings.Options -isnot [Collections.IDictionary]) {
        throw 'Options must be a settings dictionary.'
    }

    $catalog = @{}

    foreach ($option in Get-ScrcpyOptionCatalog) {
        $catalog[$option.Name] = $option
    }

    foreach ($name in $Settings.Options.Keys) {
        $option = $catalog[$name]

        if ($null -eq $option -or $option.Availability -ne 'editable') {
            throw "--$name is not an editable mirroring setting. Use its dedicated Settings control."
        }

        $value = $Settings.Options[$name]

        if ($option.Kind -eq 'switch') {

            if ($value -isnot [bool]) {
                throw "--$name must be enabled or disabled."
            }

            if (-not $value) {
                continue
            }
        }

        if ($option.Kind -eq 'value') {

            if ($value -isnot [string] -or $value -match '[\x00-\x1F]') {
                throw "--$name must be a single text value without control characters."
            }

            if (-not $value.Length -and -not $option.ArgumentOptional) {
                throw "Enter a value for --$name or restore its default."
            }

            if ($value.Length -and $option.Values.Count -and $value -cnotin $option.Values) {
                throw "--$name accepts: $($option.Values -join ', ')."
            }

            if ($value.Length -and $option.Pattern -and $value -cnotmatch $option.Pattern) {
                throw "Invalid value for --${name}. $($option.ArgumentHint)"
            }
        }

        $hasDisabledTimeLimit = $name -eq 'time-limit' -and $value -match '^0+$'
        $conflictsWithReconnect = $Settings.Reconnect -and -not $option.SeamlessCompatible -and -not $hasDisabledTimeLimit

        if ($conflictsWithReconnect) {
            throw "--$name requires turning off Seamless reconnection in Mirroring settings."
        }

        $usesAccessoryInput = $name -in @('keyboard', 'mouse', 'gamepad') -and $value -eq 'aoa'

        if ($usesAccessoryInput) {
            throw 'AOA input is unavailable in this portable build. Select SDK, UHID or disabled input.'
        }
    }

    Assert-ScrcpyOptionCombinations -Options $Settings.Options
}

# Catch common mutually exclusive sources before the native parser runs.
function Assert-ScrcpyOptionCombinations {
    param([Collections.IDictionary]$Options)
    $cameraOptions = @('camera-id', 'camera-facing', 'camera-size', 'camera-ar')
    $hasCameraSelection = @($cameraOptions | Where-Object { $Options.Contains($_) }).Count
    $hasCameraFrameRate = $Options.Contains('camera-fps') -and [double]$Options['camera-fps'] -ne 0
    $hasCameraOptions = $hasCameraSelection -or $hasCameraFrameRate -or $Options['camera-high-speed']
    $usesCamera = $Options['video-source'] -eq 'camera'
    $hasDisplayId = $Options.Contains('display-id') -and [double]$Options['display-id'] -ne 0
    $hasMaximumSize = $Options.Contains('max-size') -and [double]$Options['max-size'] -ne 0
    $hasNewDisplay = $Options.Contains('new-display')
    $hasRecording = $Options.Contains('record')
    $videoPlaybackDisabled = $Options['no-video'] -or $Options['no-video-playback'] -or $Options['no-playback'] -or $Options['no-window']
    $videoDisabled = $Options['no-video'] -or ($videoPlaybackDisabled -and -not $hasRecording)
    $audioPlaybackDisabled = $Options['no-audio-playback'] -or $Options['no-playback']
    $audioDisabled = $Options['no-audio'] -or ($audioPlaybackDisabled -and -not $hasRecording)

    if ($hasCameraOptions -and -not $usesCamera) {
        throw 'Choose Camera as the video source before setting camera parameters.'
    }

    if ($Options.Contains('camera-id') -and $Options.Contains('camera-facing')) {
        throw 'Choose either a camera ID or camera facing, not both.'
    }

    if ($Options.Contains('camera-size') -and $Options.Contains('camera-ar')) {
        throw 'Choose either an exact camera size or a camera aspect ratio.'
    }

    if ($usesCamera -and $hasDisplayId) {
        throw 'Display ID cannot be used with camera capture.'
    }

    if ($hasNewDisplay -and $hasDisplayId) {
        throw 'Choose either a new virtual display or an existing display ID.'
    }

    if ($Options.Contains('camera-size') -and $hasMaximumSize) {
        throw 'Choose either an exact camera size or a maximum resolution.'
    }

    if ($Options['camera-high-speed'] -and -not $hasCameraFrameRate) {
        throw 'High-speed camera capture requires an explicit nonzero camera frame rate.'
    }

    if ($usesCamera -and $Options.Contains('display-ime-policy')) {
        throw 'Display IME policy applies to display capture, not camera capture.'
    }

    if ($hasNewDisplay -and ($usesCamera -or $videoDisabled)) {
        throw 'A new virtual display requires display video capture.'
    }

    if ($Options['flex-display'] -and (-not $hasNewDisplay -or $usesCamera)) {
        throw 'Flexible display sizing requires a new virtual display.'
    }

    $hasNoOutputOrControl = $videoDisabled -and $audioDisabled -and $Options['no-control']

    if ($hasNoOutputOrControl) {
        throw 'Keep video, audio or device control enabled so the session has something to do.'
    }

    if ($hasRecording -and $videoDisabled -and $audioDisabled) {
        throw 'Recording requires video or audio capture.'
    }

    $hasInvalidSdkMouse = $videoPlaybackDisabled -and $Options['mouse'] -eq 'sdk' -and -not $usesCamera -and -not $Options['no-control']

    if ($hasInvalidSdkMouse) {
        throw 'SDK mouse input requires video playback. Select UHID for a session without video playback.'
    }
}

# Read a versioned file and preserve every explicit override independently of phone pairing.
function Get-ScrcpySettings {
    param([string]$RootDirectory)
    $snapshot = Get-ScrcpySettingsSnapshot -RootDirectory $RootDirectory

    if ($null -eq $snapshot) {
        return New-ScrcpySettings
    }

    try {
        $document = $snapshot | ConvertFrom-Json

        if ($document.SchemaVersion -ne 1 -or $document.Options -isnot [pscustomobject]) {
            throw 'Unsupported settings format.'
        }

        $settings = @{ Options = @{}; Reconnect = $document.Reconnect }

        foreach ($property in $document.Options.PSObject.Properties) {
            $settings.Options[$property.Name] = $property.Value
        }

        Assert-ScrcpySettings -Settings $settings
        return $settings
    } catch {
        throw "Cannot read scrcpy-settings.json: $($_.Exception.Message) Open Settings to restore or correct mirroring settings."
    }
}

# Atomically save validated overrides without overwriting another Settings window's edits.
function Save-ScrcpySettings {
    param([string]$RootDirectory, $Settings, $ExpectedSnapshot)
    Assert-ScrcpySettings -Settings $Settings
    $checkSnapshot = $PSBoundParameters.ContainsKey('ExpectedSnapshot')
    Invoke-DeviceConfigurationLock -RootDirectory $RootDirectory -Action {
        $current = Get-ScrcpySettingsSnapshot -RootDirectory $RootDirectory

        if ($checkSnapshot -and $current -cne $ExpectedSnapshot) {
            throw 'Mirroring settings changed in another window. Reopen Settings before saving.'
        }

        $orderedOptions = [ordered]@{}

        foreach ($name in @($Settings.Options.Keys | Sort-Object)) {
            $value = $Settings.Options[$name]

            if ($value -is [bool] -and -not $value) {
                continue
            }

            $orderedOptions[$name] = $value
        }

        $document = [ordered]@{ SchemaVersion = 1; Reconnect = $Settings.Reconnect; Options = $orderedOptions }
        $path = Join-Path $RootDirectory 'scrcpy-settings.json'
        $temporary = Join-Path $RootDirectory ('scrcpy-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')

        try {
            [IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

            if (Test-Path -LiteralPath $path) {
                [IO.File]::Replace($temporary, $path, [NullString]::Value)
                return
            }

            [IO.File]::Move($temporary, $path)
        } finally {

            if (Test-Path -LiteralPath $temporary) {
                [IO.File]::Delete($temporary)
            }
        }
    }
}

# Produce separate arguments; no user text is ever evaluated as PowerShell or shell code.
function Get-ScrcpyArguments {
    param($Settings)
    Assert-ScrcpySettings -Settings $Settings

    foreach ($name in @($Settings.Options.Keys | Sort-Object)) {
        $value = $Settings.Options[$name]

        if ($value -is [bool]) {

            if ($value) {
                '--' + $name
            }

            continue
        }

        if (-not $value.Length) {
            '--' + $name
            continue
        }

        '--' + $name + '=' + $value
    }
}

# Quote Windows CRT arguments, including embedded quotes and trailing backslashes.
function ConvertTo-ScrcpyCommandLine {
    param([string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }

    return $quoted -join ' '
}
