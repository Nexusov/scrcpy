# Creates a launcher shortcut without replacing unrelated desktop files.
function New-DesktopShortcut {
    param([string]$RootDirectory, [string]$DesktopDirectory = [Environment]::GetFolderPath('DesktopDirectory'))
    $root = [IO.Path]::GetFullPath($RootDirectory)
    $runtimeDirectory = $root
    $parentDirectory = Split-Path -Parent $root
    $isNestedRuntime = (Split-Path -Leaf $root) -eq 'app' -and (Test-Path -LiteralPath (Join-Path $parentDirectory 'Start.vbs') -PathType Leaf)

    if ($isNestedRuntime) {
        $root = $parentDirectory
    }

    $launcher = Join-Path $root 'Start.vbs'

    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw 'The application launcher is missing.'
    }

    if (-not (Test-Path -LiteralPath $DesktopDirectory -PathType Container)) {
        throw 'The desktop directory is unavailable.'
    }

    $shell = New-Object -ComObject WScript.Shell
    $description = 'scrcpy Seamless launcher'
    $candidateNames = @('scrcpy.lnk', 'scrcpy Seamless.lnk')
    $maximumCandidates = 100
    $shortcutPath = ''
    $shortcut = $null

    try {
        foreach ($candidateIndex in 0..$maximumCandidates) {
            $name = 'scrcpy Seamless (' + ($candidateIndex + 1) + ').lnk'

            if ($candidateIndex -lt $candidateNames.Count) {
                $name = $candidateNames[$candidateIndex]
            }

            $candidatePath = Join-Path $DesktopDirectory $name
            $exists = Test-Path -LiteralPath $candidatePath

            if ($exists -and -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                continue
            }

            $candidate = $shell.CreateShortcut($candidatePath)
            $knownArguments = @('"' + $launcher + '"', '"' + (Join-Path $root 'launch.vbs') + '"')
            $hostName = [IO.Path]::GetFileName($candidate.TargetPath)
            $isScriptHost = $hostName -in @('wscript.exe', 'cscript.exe')
            $sameLauncher = $isScriptHost -and $candidate.Arguments -in $knownArguments
            $isOurShortcut = $candidate.Description -eq $description -or $sameLauncher

            if (-not $exists -or $isOurShortcut) {
                $shortcutPath = $candidatePath
                $shortcut = $candidate
                break
            }

            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($candidate)
        }

        if (-not $shortcutPath) {
            throw 'No available shortcut filename was found.'
        }

        $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $shortcut.Arguments = '"' + $launcher + '"'
        $shortcut.WorkingDirectory = $root
        $shortcut.Description = $description
        $shortcut.WindowStyle = 1
        $icon = Join-Path $runtimeDirectory 'scrcpy.exe'

        if (Test-Path -LiteralPath $icon -PathType Leaf) {
            $shortcut.IconLocation = $icon + ',0'
        }

        $shortcut.Save()
    }
    finally {

        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }

        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}
