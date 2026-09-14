[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'provenance.ps1')
$sourceFingerprintBeforeBuild = Get-NativeSourceFingerprint -RepositoryDirectory $repositoryDirectory
$sourceDirectory = Join-Path $repositoryDirectory 'src\scrcpy'
$buildDirectory = Join-Path $repositoryDirectory '.build'
$distributionDirectory = Join-Path $repositoryDirectory 'dist'
$configuration = @{
    compiler = 'gcc'
    archiver = 'ar'
    windres = 'windres'
    pkgConfig = 'pkg-config'
    meson = 'meson'
    ninja = 'ninja'
    pkgConfigDirectories = @()
    compilerBinDirectory = ''
}

if ($ConfigPath) {
    $configurationFile = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    foreach ($property in $configurationFile.PSObject.Properties) {

        if (!$configuration.ContainsKey($property.Name)) {
            throw "Unknown build configuration property: $($property.Name)"
        }

        $configuration[$property.Name] = $property.Value
    }
}

if (!(Test-Path -LiteralPath (Join-Path $sourceDirectory 'meson.build') -PathType Leaf)) {
    throw "Source directory is missing: $sourceDirectory"
}

# Resolve an installed tool without downloading or installing dependencies.
function Resolve-BuildTool {
    param([string]$Tool)

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        throw 'Build tool commands must not be empty.'
    }

    $command = Get-Command -Name $Tool -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return $command.Source
}

# Quote executable paths for Meson environment command parsing.
function ConvertTo-ToolCommand {
    param([string]$ExecutablePath)

    if ($ExecutablePath -match '\s') {
        return '"' + $ExecutablePath + '"'
    }

    return $ExecutablePath
}

$environmentNames = @('PATH', 'CC', 'AR', 'WINDRES', 'PKG_CONFIG', 'PKG_CONFIG_PATH', 'NINJA')
$originalEnvironment = @{}

foreach ($environmentName in $environmentNames) {
    $originalEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
}

try {
    $compilerBinDirectory = $configuration.compilerBinDirectory

    if ($compilerBinDirectory) {
        $compilerBinDirectory = (Resolve-Path -LiteralPath $compilerBinDirectory).ProviderPath
        $env:PATH = $compilerBinDirectory + [IO.Path]::PathSeparator + $env:PATH
    }

    $env:CC = ConvertTo-ToolCommand (Resolve-BuildTool $configuration.compiler)
    $env:AR = ConvertTo-ToolCommand (Resolve-BuildTool $configuration.archiver)
    $env:WINDRES = ConvertTo-ToolCommand (Resolve-BuildTool $configuration.windres)
    $env:PKG_CONFIG = ConvertTo-ToolCommand (Resolve-BuildTool $configuration.pkgConfig)
    $mesonExecutable = Resolve-BuildTool $configuration.meson
    $ninjaExecutable = Resolve-BuildTool $configuration.ninja
    $env:NINJA = $ninjaExecutable

    $pkgConfigDirectories = @($configuration.pkgConfigDirectories | ForEach-Object {
        (Resolve-Path -LiteralPath $_).ProviderPath
    })

    if ($pkgConfigDirectories.Length) {
        $pkgConfigPathParts = @($pkgConfigDirectories)

        if ($env:PKG_CONFIG_PATH) {
            $pkgConfigPathParts += $env:PKG_CONFIG_PATH
        }

        $env:PKG_CONFIG_PATH = $pkgConfigPathParts -join [IO.Path]::PathSeparator
    }

    $setupArguments = @(
        'setup', $buildDirectory, $sourceDirectory,
        '--buildtype=debugoptimized',
        '-Dcompile_server=false', '-Dportable=true', '-Dusb=false'
    )

    if (Test-Path -LiteralPath (Join-Path $buildDirectory 'meson-private\coredata.dat')) {
        $setupArguments += '--reconfigure'
    }

    if ($compilerBinDirectory) {
        $compilerPrefix = '-B' + $compilerBinDirectory.Replace('\', '/').TrimEnd('/') + '/'
        $compilerArguments = "['" + $compilerPrefix.Replace("'", "\'") + "']"
        $setupArguments += "-Dc_args=$compilerArguments"
        $setupArguments += "-Dc_link_args=$compilerArguments"
    }

    & $mesonExecutable @setupArguments

    if ($LASTEXITCODE) {
        throw "Meson setup failed with exit code $LASTEXITCODE."
    }

    & $ninjaExecutable '-C' $buildDirectory

    if ($LASTEXITCODE) {
        throw "Ninja build failed with exit code $LASTEXITCODE."
    }

    $compiledExecutable = Join-Path $buildDirectory 'app\scrcpy.exe'

    if (!(Test-Path -LiteralPath $compiledExecutable -PathType Leaf)) {
        throw "The compiled executable was not found: $compiledExecutable"
    }

    New-Item -ItemType Directory -Path $distributionDirectory -Force | Out-Null
    $outputExecutable = Join-Path $distributionDirectory 'scrcpy.exe'
    Copy-Item -LiteralPath $compiledExecutable -Destination $outputExecutable -Force

    if ((Get-NativeSourceFingerprint -RepositoryDirectory $repositoryDirectory) -ne $sourceFingerprintBeforeBuild) {
        throw 'Native sources changed while compilation was running. Rebuild before packaging.'
    }

    Write-NativeBuildManifest -RepositoryDirectory $repositoryDirectory -ExecutablePath $outputExecutable -SourceFingerprint $sourceFingerprintBeforeBuild
    Write-Host "Built: $outputExecutable"
    Write-Host 'This executable requires compatible runtime DLLs and the scrcpy server. The installed portable application was not modified.'
}
finally {
    foreach ($environmentName in $environmentNames) {
        [Environment]::SetEnvironmentVariable($environmentName, $originalEnvironment[$environmentName], 'Process')
    }
}
