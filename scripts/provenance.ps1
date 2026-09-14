# Hash native sources consistently across Windows and Unix text checkouts.
function Get-NativeSourceFingerprint {
    param([string]$RepositoryDirectory)
    $sourceDirectory = Join-Path $RepositoryDirectory 'src\scrcpy'
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse)
    $sourcePaths = [string[]]@($sourceFiles | ForEach-Object { $_.FullName.Substring($sourceDirectory.Length).TrimStart('\', '/').Replace('\', '/') })
    [Array]::Sort($sourcePaths, [StringComparer]::Ordinal)
    $entries = foreach ($sourcePath in $sourcePaths) {
        $file = Get-Item -LiteralPath (Join-Path $sourceDirectory $sourcePath)
        $relativePath = $sourcePath
        $bytes = [IO.File]::ReadAllBytes($file.FullName)

        if ($bytes -notcontains 0) {
            try {
                $textEncoding = New-Object Text.UTF8Encoding($false, $true)
                $bytes = $textEncoding.GetBytes($textEncoding.GetString($bytes).Replace("`r`n", "`n"))
            } catch [Text.DecoderFallbackException] {
                # Non-UTF-8 files retain their original binary identity.
            }
        }

        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        } finally {
            $hasher.Dispose()
        }
        "$relativePath $hash"
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

# Save provenance beside the client produced by the native build.
function Write-NativeBuildManifest {
    param([string]$RepositoryDirectory, [string]$ExecutablePath, [string]$SourceFingerprint)

    if (-not $SourceFingerprint) {
        $SourceFingerprint = Get-NativeSourceFingerprint -RepositoryDirectory $RepositoryDirectory
    }
    $manifest = [ordered]@{
        SchemaVersion = 1
        Origin = 'local-build'
        SourceFingerprint = $SourceFingerprint
        ExecutableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath ($ExecutablePath + '.manifest.json') -Encoding UTF8
}

# Reject stale native outputs instead of silently packaging the installed client.
function Resolve-PackageNativeClient {
    param([string]$RepositoryDirectory, [string]$RuntimeDirectory, $ReleaseManifest)
    $sourceFingerprint = Get-NativeSourceFingerprint -RepositoryDirectory $RepositoryDirectory
    $builtExecutable = Join-Path $RepositoryDirectory 'dist\scrcpy.exe'
    $builtManifest = $builtExecutable + '.manifest.json'
    $hasBuiltOutput = (Test-Path -LiteralPath $builtExecutable) -or (Test-Path -LiteralPath $builtManifest)

    if ($hasBuiltOutput) {
        if (-not (Test-Path -LiteralPath $builtExecutable) -or -not (Test-Path -LiteralPath $builtManifest)) {
            throw 'Incomplete native build output. Rebuild the client or remove both stale native build files from dist.'
        }
        $provenance = Get-Content -LiteralPath $builtManifest -Raw | ConvertFrom-Json
        $hash = (Get-FileHash -LiteralPath $builtExecutable -Algorithm SHA256).Hash
        $validBuild = $provenance.SchemaVersion -eq 1 -and $provenance.Origin -eq 'local-build' -and
            $provenance.SourceFingerprint -eq $sourceFingerprint -and $provenance.ExecutableSha256 -eq $hash

        if (-not $validBuild) {
            throw 'Native build provenance does not match current sources or executable. Rebuild before packaging.'
        }
        return @{
            Path = $builtExecutable
            Origin = 'local-build'
            SourceFingerprint = $sourceFingerprint
            Sha256 = $hash
        }
    }

    if ($sourceFingerprint -ne $ReleaseManifest.NativeBaseline.SourceFingerprint) {
        throw 'Native sources differ from the imported runtime baseline. Build the native client before packaging.'
    }
    $runtimeExecutable = Join-Path $RuntimeDirectory 'scrcpy.exe'
    $hash = (Get-FileHash -LiteralPath $runtimeExecutable -Algorithm SHA256).Hash

    if ($hash -ne $ReleaseManifest.NativeBaseline.ExecutableSha256) {
        throw 'Runtime client does not match the reviewed imported baseline.'
    }
    return @{
        Path = $runtimeExecutable
        Origin = 'imported-baseline'
        SourceFingerprint = $sourceFingerprint
        Sha256 = $hash
    }
}
