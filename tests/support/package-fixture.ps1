# Build a complete disposable package with synthetic runtime inputs for offline tests.
function New-PackageTestFixture {
    param([string]$RepositoryDirectory)
    . (Join-Path $RepositoryDirectory 'scripts/provenance.ps1')
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-package-fixture-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory

    try {
        foreach ($name in @('scripts', 'launcher', 'docs', 'licenses')) {
            Copy-Item -LiteralPath (Join-Path $RepositoryDirectory $name) -Destination $directory -Recurse
        }

        foreach ($name in @('README.md', 'LICENSE', 'THIRD_PARTY.md', 'release-manifest.json')) {
            Copy-Item -LiteralPath (Join-Path $RepositoryDirectory $name) -Destination $directory
        }

        $runtimeDirectory = Join-Path $directory 'runtime'
        $null = New-Item -ItemType Directory -Path $runtimeDirectory
        $manifestPath = Join-Path $directory 'release-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        foreach ($property in $manifest.RuntimeFiles.PSObject.Properties) {
            $runtimePath = Join-Path $runtimeDirectory $property.Name
            Set-Content -LiteralPath $runtimePath -Value ('fixture for ' + $property.Name)
            $property.Value = (Get-FileHash -LiteralPath $runtimePath).Hash
        }

        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $null = New-Item -ItemType Directory -Path (Join-Path $directory 'src/scrcpy') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $directory 'dist')
        Set-Content -LiteralPath (Join-Path $directory 'src/scrcpy/example.c') -Value 'fixture source'
        $executablePath = Join-Path $directory 'dist/scrcpy.exe'
        Set-Content -LiteralPath $executablePath -Value 'fresh client fixture'
        Write-NativeBuildManifest -RepositoryDirectory $directory -ExecutablePath $executablePath
        $fixture = @{ Directory = $directory; RuntimeDirectory = $runtimeDirectory; ArchivePath = (Join-Path $directory 'dist/scrcpy-seamless-win64.zip') }
        $result = Invoke-PackageTestFixture -Fixture $fixture

        if ($result.ExitCode) {
            throw ($result.Output -join "`n")
        }

        return $fixture
    } catch {
        Remove-PackageTestFixture -Directory $directory
        throw
    }
}

# Run the production packager and expose failures to both positive and negative tests.
function Invoke-PackageTestFixture {
    param($Fixture)
    $ErrorActionPreference = 'Continue'
    $powerShellPath = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $output = & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Fixture.Directory 'scripts/package.ps1') -RuntimeDirectory $Fixture.RuntimeDirectory 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

# Remove only the fixture directory created beneath this user's temporary directory.
function Remove-PackageTestFixture {
    param([string]$Directory)
    $resolvedDirectory = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $validParent = (Split-Path -Parent $resolvedDirectory) -eq [IO.Path]::GetTempPath().TrimEnd('\')
    $validName = (Split-Path -Leaf $resolvedDirectory) -like 'scrcpy-package-fixture-*'

    if (-not $validParent -or -not $validName) {
        throw 'Unexpected package fixture cleanup path.'
    }

    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
