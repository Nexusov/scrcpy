[CmdletBinding()]
param([string]$RuntimeDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'provenance.ps1')
$manifestPath = Join-Path $repositoryDirectory 'release-manifest.json'
$releaseManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if (-not $RuntimeDirectory) {
    $RuntimeDirectory = Join-Path $repositoryDirectory 'outputs\scrcpy-seamless'
}

# Accept an existing flat runtime or an extracted portable package.
$nestedRuntimeDirectory = Join-Path $RuntimeDirectory 'app'

if (Test-Path -LiteralPath (Join-Path $nestedRuntimeDirectory 'scrcpy.exe') -PathType Leaf) {
    $RuntimeDirectory = $nestedRuntimeDirectory
}

$runtimeFiles = @($releaseManifest.RuntimeFiles.PSObject.Properties.Name)
$nativeClient = Resolve-PackageNativeClient -RepositoryDirectory $repositoryDirectory -RuntimeDirectory $RuntimeDirectory -ReleaseManifest $releaseManifest

# Validate every input before creating the release staging directory.
foreach ($runtimeFile in $runtimeFiles) {
    $runtimePath = Join-Path $RuntimeDirectory $runtimeFile

    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Missing runtime file: $runtimePath"
    }

    if ((Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash -ne $releaseManifest.RuntimeFiles.$runtimeFile) {
        throw "Runtime file differs from the reviewed manifest: $runtimeFile"
    }
}

$distributionDirectory = Join-Path $repositoryDirectory 'dist'
$stagingDirectory = Join-Path $distributionDirectory ('package-' + [guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $distributionDirectory 'scrcpy-seamless-win64.zip'
$applicationDirectory = Join-Path $stagingDirectory 'app'
New-Item -ItemType Directory -Path $applicationDirectory -Force | Out-Null
Copy-Item -LiteralPath $nativeClient.Path -Destination (Join-Path $applicationDirectory 'scrcpy.exe')
Copy-Item -LiteralPath $manifestPath -Destination $applicationDirectory
[pscustomobject]$nativeClient | Select-Object Origin, SourceFingerprint, Sha256 | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $applicationDirectory 'native-provenance.json') -Encoding UTF8

foreach ($runtimeFile in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $RuntimeDirectory $runtimeFile) -Destination $applicationDirectory
}

foreach ($launcherFile in @('launch.ps1', 'launch-session.ps1', 'launch-runtime.ps1', 'launch-view.ps1', 'launch.vbs', 'launcher-core.ps1', 'adb-process.ps1', 'configuration-store.ps1', 'connection-core.ps1', 'instance.ps1', 'version.ps1', 'shortcut.ps1', 'reset.ps1', 'setup.ps1', 'setup-session.ps1', 'setup-runtime.ps1', 'setup-view.ps1', 'setup.vbs', 'phone.example.json')) {
    Copy-Item -LiteralPath (Join-Path $repositoryDirectory ('launcher\' + $launcherFile)) -Destination $applicationDirectory
}

# Keep only the public entry points beside the user documentation.
foreach ($settingsFile in @('option-catalog.ps1', 'option-catalog.json', 'options-store.ps1', 'options-view.ps1', 'diagnostics-runtime.ps1', 'diagnostics-view.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repositoryDirectory ('launcher\' + $settingsFile)) -Destination $applicationDirectory
}

Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'launcher\Start.vbs') -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'launcher\Settings.vbs') -Destination (Join-Path $stagingDirectory 'Settings.vbs')

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


