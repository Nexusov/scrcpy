$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'support/package-fixture.ps1')
$fixture = New-PackageTestFixture -RepositoryDirectory $repositoryDirectory

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($fixture.ArchivePath)

    try {
        $entry = @($archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'app/scrcpy.exe' })[0]
        $reader = New-Object IO.StreamReader($entry.Open())

        try {

            if ($reader.ReadToEnd().Trim() -ne 'fresh client fixture') {
                throw 'ZIP contains stale installed client.'
            }
        } finally {
            $reader.Dispose()
        }

        if (-not @($archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'app/release-manifest.json' }).Count) {
            throw 'Packaged version manifest missing.'
        }
    } finally {
        $archive.Dispose()
    }

    $manifestPath = Join-Path $fixture.Directory 'release-manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifest.RuntimeFiles.'SDL3.dll' = 'incorrect hash'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath -Encoding UTF8
    $result = Invoke-PackageTestFixture -Fixture $fixture

    if (-not $result.ExitCode) {
        throw 'Mismatched dependency accepted into package.'
    }

    Write-Output 'PASS: actual ZIP uses fresh built client, includes version manifest and rejects dependency mismatch.'
} finally {
    Remove-PackageTestFixture -Directory $fixture.Directory
}
