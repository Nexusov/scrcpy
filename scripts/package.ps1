[CmdletBinding()]
param([string]$RuntimeDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot

if (-not $RuntimeDirectory) {
    $RuntimeDirectory = Join-Path $repositoryDirectory 'outputs\scrcpy-seamless'
}

# Accept an existing flat runtime or an extracted portable package.
$nestedRuntimeDirectory = Join-Path $RuntimeDirectory 'app'

if (Test-Path -LiteralPath (Join-Path $nestedRuntimeDirectory 'scrcpy.exe') -PathType Leaf) {
    $RuntimeDirectory = $nestedRuntimeDirectory
}

$runtimeFiles = @(
    'scrcpy.exe', 'scrcpy-server', 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll',
    'SDL3.dll', 'avcodec-62.dll', 'avformat-62.dll', 'avutil-60.dll',
    'swresample-6.dll', 'scrcpy.png', 'disconnected.png'
)

# Validate every input before creating the release staging directory.
foreach ($runtimeFile in $runtimeFiles) {
    $runtimePath = Join-Path $RuntimeDirectory $runtimeFile

    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Missing runtime file: $runtimePath"
    }
}

$distributionDirectory = Join-Path $repositoryDirectory 'dist'
$stagingDirectory = Join-Path $distributionDirectory ('package-' + [guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $distributionDirectory 'scrcpy-seamless-win64.zip'
$applicationDirectory = Join-Path $stagingDirectory 'app'
New-Item -ItemType Directory -Path $applicationDirectory -Force | Out-Null

foreach ($runtimeFile in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $RuntimeDirectory $runtimeFile) -Destination $applicationDirectory
}

foreach ($launcherFile in @('launch.ps1', 'launch.vbs', 'launcher-core.ps1', 'connection-core.ps1', 'instance.ps1', 'shortcut.ps1', 'setup.ps1', 'setup.vbs', 'phone.example.json')) {
    Copy-Item -LiteralPath (Join-Path $repositoryDirectory ('launcher\' + $launcherFile)) -Destination $applicationDirectory
}

# Keep only the public entry points beside the user documentation.
Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'launcher\Start.vbs') -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'launcher\setup.vbs') -Destination (Join-Path $stagingDirectory 'Setup.vbs')

foreach ($documentFile in @('LICENSE', 'README.md', 'THIRD_PARTY.md')) {
    $document = Get-Content -LiteralPath (Join-Path $repositoryDirectory $documentFile) -Raw -Encoding UTF8
    $document = $document.Replace('](docs/', '](app/docs/').Replace('](licenses/', '](app/licenses/')

    if ($documentFile -eq 'THIRD_PARTY.md') {
        $document = $document.Replace('`licenses/', '`app/licenses/')
    }

    [IO.File]::WriteAllText((Join-Path $stagingDirectory $documentFile), $document, [Text.UTF8Encoding]::new($false))
}

Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'docs') -Destination $applicationDirectory -Recurse
Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'licenses') -Destination $applicationDirectory -Recurse

Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal -Force
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath ($archivePath + '.sha256') -Value ($archiveHash + '  ' + [IO.Path]::GetFileName($archivePath)) -Encoding ASCII

# Only remove this invocation's generated directory within dist.
$resolvedStagingDirectory = (Resolve-Path -LiteralPath $stagingDirectory).ProviderPath
$expectedParent = (Resolve-Path -LiteralPath $distributionDirectory).ProviderPath

if ((Split-Path -Parent $resolvedStagingDirectory) -ne $expectedParent) {
    throw 'Unexpected release staging directory; cleanup cancelled.'
}

Remove-Item -LiteralPath $resolvedStagingDirectory -Recurse -Force
Write-Host "Packaged: $archivePath"
Write-Host 'No personal phone settings, logs or build tools were included.'

