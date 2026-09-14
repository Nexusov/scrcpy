$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryDirectory 'scripts/provenance.ps1')
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-provenance-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $temporaryDirectory 'src/scrcpy') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $temporaryDirectory 'runtime') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $temporaryDirectory 'dist') -Force

# Fail with the specific packaging invariant that regressed.
function Assert-Provenance { param($Condition, $Message)
    if (-not $Condition) { throw $Message }
}

# Require rejection without masking an unexpectedly accepted input.
function Assert-Rejected { param($Action, $Message)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-Provenance $rejected $Message
}
try {
    $sourcePath = Join-Path $temporaryDirectory 'src/scrcpy/example.c'
    $runtimeDirectory = Join-Path $temporaryDirectory 'runtime'
    Set-Content $sourcePath 'original source'
    Set-Content (Join-Path $runtimeDirectory 'scrcpy.exe') 'old client'
    $manifest = [pscustomobject]@{ NativeBaseline = [pscustomobject]@{
        SourceFingerprint = Get-NativeSourceFingerprint -RepositoryDirectory $temporaryDirectory
        ExecutableSha256 = (Get-FileHash (Join-Path $runtimeDirectory 'scrcpy.exe')).Hash
    } }
    $selected = Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest
    Assert-Provenance ($selected.Origin -eq 'imported-baseline') 'Validated launcher-only build rejected.'
    $builtExecutable = Join-Path $temporaryDirectory 'dist/scrcpy.exe'
    Set-Content $builtExecutable 'new client'
    Write-NativeBuildManifest -RepositoryDirectory $temporaryDirectory -ExecutablePath $builtExecutable
    $selected = Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest
    Assert-Provenance ($selected.Path -eq $builtExecutable -and $selected.Origin -eq 'local-build') 'Packaging selected stale runtime instead of fresh build.'
    Add-Content $sourcePath 'changed source'
    Assert-Rejected { Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest } 'Changed source accepted old build.'
    Set-Content $sourcePath 'original source'
    Add-Content $builtExecutable 'corrupted'
    Assert-Rejected { Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest } 'Corrupted executable accepted.'
    Remove-Item -LiteralPath $builtExecutable, ($builtExecutable + '.manifest.json')
    Add-Content $sourcePath 'changed source'
    Assert-Rejected { Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest } 'Changed native source accepted imported client.'
    Set-Content $sourcePath 'original source'
    Add-Content (Join-Path $runtimeDirectory 'scrcpy.exe') 'corrupted'
    Assert-Rejected { Resolve-PackageNativeClient -RepositoryDirectory $temporaryDirectory -RuntimeDirectory $runtimeDirectory -ReleaseManifest $manifest } 'Unverified imported executable accepted.'
    Write-Output 'PASS: imported identity, fresh native selection, stale sources and corrupted client rejection.'
} finally {
    $resolvedDirectory = (Resolve-Path -LiteralPath $temporaryDirectory).ProviderPath
    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
