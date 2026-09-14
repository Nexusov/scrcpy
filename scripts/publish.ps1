$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$commitMessage = 'Add device setup reset and Settings launcher'
$sourcePaths = @('README.md', 'launcher', 'scripts', 'tests', 'docs/CHANGES.md')
$releaseTag = 'v1.0.0'

# Run Git against the project containing this dist directory and stop on failure.
function Invoke-ProjectGit {
    param([string[]]$Arguments)
    & git -C $projectDirectory @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Git failed: $($Arguments -join ' '). Resolve the error above and run this file again."
    }
}

try {
    $branch = Invoke-ProjectGit -Arguments @('branch', '--show-current')

    if ($branch -ne 'main') {
        throw 'Switch the project to main before publishing.'
    }

    $stagedPaths = @(Invoke-ProjectGit -Arguments @('diff', '--cached', '--name-only'))
    foreach ($stagedPath in $stagedPaths) {
        $allowed = $stagedPath -in @('README.md', 'docs/CHANGES.md') -or $stagedPath -match '^(launcher|scripts|tests)/'

        if (-not $allowed) {
            throw "An unrelated file is already staged: $stagedPath. Unstage or commit it separately before publishing."
        }
    }

    Invoke-ProjectGit -Arguments (@('add', '--') + $sourcePaths)
    $changes = @(Invoke-ProjectGit -Arguments @('diff', '--cached', '--name-only'))

    if ($changes.Count) {
        Invoke-ProjectGit -Arguments @('commit', '-m', $commitMessage)
    }

    if (-not $changes.Count) {
        Write-Host 'No new source changes to commit. Pushing existing commits.'
    }

    Invoke-ProjectGit -Arguments @('push', 'origin', 'main')
    $tagReference = 'refs/tags/' + $releaseTag
    $remoteTag = @(Invoke-ProjectGit -Arguments @('ls-remote', '--refs', 'origin', $tagReference))
    $expectedTag = ''

    if ($remoteTag.Count) {
        $expectedTag = ($remoteTag[0] -split '\s+')[0]
    }

    Invoke-ProjectGit -Arguments @('tag', '-f', $releaseTag, 'HEAD')
    Invoke-ProjectGit -Arguments @('push', ('--force-with-lease=' + $tagReference + ':' + $expectedTag), 'origin', $tagReference)
    Write-Host "Source code published and $releaseTag updated. Release ZIP assets must be uploaded separately." -ForegroundColor Green
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
