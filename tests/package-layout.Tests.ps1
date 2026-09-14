param([string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot

if (-not $ArchivePath) {
    $ArchivePath = Join-Path $repositoryDirectory 'dist\scrcpy-seamless-win64.zip'
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy layout test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testDirectory | Out-Null
# Fail with a clear assertion rather than launching a real phone session.
function Assert-Layout { param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}
Expand-Archive -LiteralPath $ArchivePath -DestinationPath (Join-Path $testDirectory 'package')
$packageDirectory = Join-Path $testDirectory 'package'
$rootNames = @(Get-ChildItem -LiteralPath $packageDirectory | Select-Object -ExpandProperty Name | Sort-Object)
Assert-Layout (($rootNames -join '|') -eq 'app|LICENSE|README.md|Setup.vbs|Start.vbs|THIRD_PARTY.md') 'Unexpected public package entries.'
Assert-Layout (-not (Get-ChildItem $packageDirectory -Recurse -File | Where-Object { $_.Name -eq 'phone.json' -or $_.Extension -eq '.log' })) 'Private files in ZIP.'
$expectedHash = ((Get-Content ($ArchivePath + '.sha256') -Raw).Trim() -split '\s+')[0]
Assert-Layout ((Get-FileHash $ArchivePath).Hash -eq $expectedHash) 'Checksum mismatch.'
foreach ($document in @('README.md','THIRD_PARTY.md')) {
    $markdown = Get-Content (Join-Path $packageDirectory $document) -Raw
    foreach ($match in [regex]::Matches($markdown, '\]\(([^)]+)\)')) {
        $link = $match.Groups[1].Value

        if ($link -match '^(https?:|#)') {
            continue
        }
        Assert-Layout (Test-Path (Join-Path $packageDirectory $link)) "Missing document link: $link"
    }
}
foreach ($layout in @('flat','nested')) {
    $publicDirectory = Join-Path $testDirectory ($layout + ' folder with spaces')
    $runtimeDirectory = $publicDirectory

    if ($layout -eq 'nested') {
        $runtimeDirectory = Join-Path $publicDirectory 'app'
    }
    New-Item -ItemType Directory $runtimeDirectory -Force | Out-Null
    Copy-Item (Join-Path $repositoryDirectory 'launcher\Start.vbs'),(Join-Path $repositoryDirectory 'launcher\setup.vbs') $publicDirectory
    Copy-Item (Join-Path $repositoryDirectory 'launcher\launch.vbs') $runtimeDirectory
    foreach ($scriptName in @('launch','setup')) {
        Set-Content (Join-Path $runtimeDirectory ($scriptName + '.ps1')) -Value ('Set-Content -LiteralPath (Join-Path $PSScriptRoot "' + $scriptName + '.ok") -Value "ok"')
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($entry in @('Start.vbs','setup.vbs')) {
        [void]$shell.Run(('wscript.exe "' + (Join-Path $publicDirectory $entry) + '"'), 0, $true)
    }
    $launchTimeoutSeconds = 10
    $pollIntervalMilliseconds = 100
    $deadline = [DateTime]::UtcNow.AddSeconds($launchTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not ((Test-Path (Join-Path $runtimeDirectory 'launch.ok')) -and (Test-Path (Join-Path $runtimeDirectory 'setup.ok')))) {
        Start-Sleep -Milliseconds $pollIntervalMilliseconds
    }
    Assert-Layout (Test-Path (Join-Path $runtimeDirectory 'launch.ok')) "$layout Start wrapper failed."
    Assert-Layout (Test-Path (Join-Path $runtimeDirectory 'setup.ok')) "$layout Setup wrapper failed."
    $desktopDirectory = Join-Path $publicDirectory 'fake desktop'
    New-Item -ItemType Directory $desktopDirectory | Out-Null
    Set-Content (Join-Path $runtimeDirectory 'scrcpy.exe') 'test icon sentinel'
    . (Join-Path $repositoryDirectory 'launcher\shortcut.ps1')
    New-DesktopShortcut -RootDirectory $runtimeDirectory -DesktopDirectory $desktopDirectory
    New-DesktopShortcut -RootDirectory $runtimeDirectory -DesktopDirectory $desktopDirectory
    $links = @(Get-ChildItem $desktopDirectory -Filter '*.lnk')
    Assert-Layout ($links.Count -eq 1) 'Duplicate shortcuts.'
    $shortcut = $shell.CreateShortcut($links[0].FullName)
    Assert-Layout ($shortcut.Arguments -eq ('"' + (Join-Path $publicDirectory 'Start.vbs') + '"')) "$layout shortcut target incorrect."
    Assert-Layout ($shortcut.IconLocation -eq ((Join-Path $runtimeDirectory 'scrcpy.exe') + ',0')) "$layout shortcut icon incorrect."
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
Write-Host 'PASS: ZIP root, privacy, checksums, relative links, real hidden VBS launches and shortcut idempotence in flat/nested paths with spaces.'
Write-Host "Disposable test data: $testDirectory"
