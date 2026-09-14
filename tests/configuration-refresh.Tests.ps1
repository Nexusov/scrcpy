$ErrorActionPreference = 'Stop'
$launcherDirectory = Join-Path $PSScriptRoot '..\launcher'
. (Join-Path $launcherDirectory 'launcher-core.ps1')
. (Join-Path $launcherDirectory 'connection-core.ps1')
. (Join-Path $launcherDirectory 'reset.ps1')
$syntaxTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $launcherDirectory 'launch.ps1'), [ref]$null, [ref]$null)
$definition = $syntaxTree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-VerifiedMirroringProcess' }, $false)
Invoke-Expression ($definition.Extent.Text.Replace('$PSScriptRoot', '$launcherDirectory'))
# Replace only external configuration reads and native startup.
function Get-PhoneConfiguration { param($RootDirectory) return $script:savedConfiguration }
function Start-MirroringProcess { param($Target) $script:launchCount++ }
# Assert that a completed probe cannot use configuration that was reset or changed.
function Assert-Refresh { param($Condition, $Message)

    if (-not $Condition) {
        throw $Message
    }
}
$originalConfiguration = [pscustomobject]@{ UsbSerial = 'phone-original'; WirelessService = '192.168.1.2:12345'; ConnectionMode = 'auto' }
foreach ($scenario in @('unchanged', 'reset', 'phone', 'service', 'mode')) {
    $script:launchCount = 0
    $script:savedConfiguration = [pscustomobject]@{ UsbSerial = 'phone-original'; WirelessService = '192.168.1.2:12345'; ConnectionMode = 'auto' }
    $script:session = @{ Configuration = $originalConfiguration; SetupRequested = $false; Progress = @{ Status = 'previous' }; Started = [DateTime]::UtcNow; NextProbe = [DateTime]::UtcNow }
    $script:hintLabel = [pscustomobject]@{ Text = '' }
    $script:statusLabel = [pscustomobject]@{ Text = '' }
    $script:retryButton = [pscustomobject]@{ Enabled = $false }
    $script:setupButton = [pscustomobject]@{ Enabled = $false }
    switch ($scenario) {
        'reset' { $script:savedConfiguration = $null }
        'phone' { $script:savedConfiguration.UsbSerial = 'another-phone' }
        'service' { $script:savedConfiguration.WirelessService = '192.168.1.2:54321' }
        'mode' { $script:savedConfiguration.ConnectionMode = 'wifi' }
    }
    Start-VerifiedMirroringProcess -Target ([pscustomobject]@{ Serial = 'old-probe-result' })
    Assert-Refresh ($script:launchCount -eq [int]($scenario -eq 'unchanged')) "Stale launch for $scenario."
    Assert-Refresh (-not $script:session.SetupRequested) "Reset opened duplicate Settings for $scenario."
}
$script:launchCount = 0
Start-VerifiedMirroringProcess -Target $null
Assert-Refresh ($script:launchCount -eq 0) 'Empty discovery results launched mirroring.'
Write-Host 'PASS: reset, changed phone/service/mode discard stale probes; unchanged config launches; empty probe does not launch.'
