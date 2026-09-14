# Identify a packaged build or the checked-out release from one shared manifest.
function Get-SeamlessVersion {
    $manifestPath = Join-Path $PSScriptRoot 'release-manifest.json'

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'release-manifest.json'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    return "$($manifest.Release) (build $($manifest.Build))"
}
