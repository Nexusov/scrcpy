$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
$files = foreach ($name in @('launcher', 'scripts', 'tests')) {
    Get-ChildItem -LiteralPath (Join-Path $repositoryDirectory $name) -Filter '*.ps1' -Recurse -File
}

foreach ($file in $files) {
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)

    if ($parseErrors.Count) {
        throw ($file.FullName + ': ' + ($parseErrors.Message -join '; '))
    }
}

Write-Output ('Parsed ' + $files.Count + ' files with Windows PowerShell ' + $PSVersionTable.PSVersion + '.')
