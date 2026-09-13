[CmdletBinding()]
param([string]$RuntimeDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot

if (-not $RuntimeDirectory) {
    $RuntimeDirectory = Join-Path $repositoryDirectory 'outputs\scrcpy-seamless'
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
New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null

foreach ($runtimeFile in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $RuntimeDirectory $runtimeFile) -Destination $stagingDirectory
}

foreach ($launcherFile in @('launch.ps1', 'launch.vbs', 'phone.example.json')) {
    Copy-Item -LiteralPath (Join-Path $repositoryDirectory ('launcher\' + $launcherFile)) -Destination $stagingDirectory
}

foreach ($documentFile in @('LICENSE', 'README.md', 'THIRD_PARTY.md')) {
    Copy-Item -LiteralPath (Join-Path $repositoryDirectory $documentFile) -Destination $stagingDirectory
}

Copy-Item -LiteralPath (Join-Path $repositoryDirectory 'docs') -Destination $stagingDirectory -Recurse

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
