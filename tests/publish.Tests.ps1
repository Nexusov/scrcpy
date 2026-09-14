$ErrorActionPreference = 'Stop'
$repositoryDirectory = Split-Path -Parent $PSScriptRoot
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-publish-' + [guid]::NewGuid().ToString('N'))
$checkout = Join-Path $temporaryDirectory 'checkout'
$remote = Join-Path $temporaryDirectory 'remote.git'
$null = New-Item -ItemType Directory -Path $checkout -Force

# Execute fixture Git commands with explicit failures.
function Invoke-TestGit { param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $result = & git -C $checkout @Arguments 2>&1
    if ($LASTEXITCODE) { throw ($result -join "`n") }
    return $result
}

# Assert publication effects against a disposable local bare repository.
function Assert-Publish { param($Condition, $Message)
    if (-not $Condition) { throw $Message }
}

# Capture expected script failure without stopping the negative test.
function Invoke-TestPublish {
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $checkout 'scripts/publish.ps1') -CommitMessage 'Fixture update' 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}
try {
    & git init --bare $remote *> $null
    $null = Invoke-TestGit @('init', '-b', 'main')
    $null = Invoke-TestGit @('config', 'user.name', 'Publication test')
    $null = Invoke-TestGit @('config', 'user.email', 'test@example.invalid')
    foreach ($directory in @('scripts', 'src', 'licenses', '.github')) { $null = New-Item -ItemType Directory -Path (Join-Path $checkout $directory) }
    Copy-Item (Join-Path $repositoryDirectory 'scripts/publish.ps1') (Join-Path $checkout 'scripts')
    Copy-Item (Join-Path $repositoryDirectory 'release-manifest.json') $checkout
    Set-Content (Join-Path $checkout 'README.md') 'fixture'
    $null = Invoke-TestGit @('add', '.')
    $null = Invoke-TestGit @('commit', '-m', 'Initial fixture')
    $null = Invoke-TestGit @('remote', 'add', 'origin', $remote)
    $null = Invoke-TestGit @('push', '-u', 'origin', 'main')
    $null = Invoke-TestGit @('tag', 'v1.0.0')
    $null = Invoke-TestGit @('push', 'origin', 'v1.0.0')
    foreach ($path in @('src/client.c', 'licenses/test.txt', '.github/ci.yml', 'CONTRIBUTING.md')) { Set-Content (Join-Path $checkout $path) 'public change' }
    $result = Invoke-TestPublish
    Assert-Publish ($result.ExitCode -eq 0) ($result.Output -join "`n")
    $head = Invoke-TestGit @('rev-parse', 'HEAD')
    $tag = Invoke-TestGit @('ls-remote', '--refs', 'origin', 'refs/tags/v1.0.0')
    Assert-Publish ($tag -match $head) 'Release tag did not follow published commit.'
    Assert-Publish ((Invoke-TestGit @('log', '-1', '--format=%s')) -eq 'Fixture update') 'Commit message parameter ignored.'
    $result = Invoke-TestPublish
    Assert-Publish ($result.ExitCode -eq 0 -and (Invoke-TestGit @('rev-parse', 'HEAD')) -eq $head) 'Repeated publish was not idempotent.'
    Set-Content (Join-Path $checkout 'personal.txt') 'private'
    $result = Invoke-TestPublish
    Assert-Publish ($result.ExitCode -ne 0) 'Unaccounted file was silently omitted.'
    Remove-Item -LiteralPath (Join-Path $checkout 'personal.txt')
    Set-Content (Join-Path $checkout 'src/phone.json') 'private'
    $null = Invoke-TestGit @('add', '-f', 'src/phone.json')
    $result = Invoke-TestPublish
    Assert-Publish ($result.ExitCode -ne 0) 'Forced-staged private settings were published.'
    $null = Invoke-TestGit @('reset', 'HEAD', '--', 'src/phone.json')
    Remove-Item -LiteralPath (Join-Path $checkout 'src/phone.json')
    # Reject the main push at the remote; the tag must remain unchanged.
    [IO.File]::WriteAllText((Join-Path $remote 'hooks/pre-receive'), "#!/bin/sh`nexit 1`n", [Text.UTF8Encoding]::new($false))
    Add-Content (Join-Path $checkout 'README.md') 'another change'
    $result = Invoke-TestPublish
    Assert-Publish ($result.ExitCode -ne 0) 'Rejected remote push was reported successful.'
    Assert-Publish ((Invoke-TestGit @('ls-remote', '--refs', 'origin', 'refs/tags/v1.0.0')) -eq $tag) 'Tag moved after failed main push.'
    Write-Output 'PASS: public source coverage, message, repeated publish, dirty/private refusal and failed-main tag protection.'
} finally {
    $resolvedDirectory = (Resolve-Path -LiteralPath $temporaryDirectory).ProviderPath
    if ((Split-Path -Parent $resolvedDirectory) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force
}
