param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$syntaxTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'launcher\setup.ps1'), [ref]$null, [ref]$null)
$definitions = $syntaxTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-SetupInput', 'Test-SavedWifiSelection') }, $false)

foreach ($definition in $definitions) {
    Invoke-Expression $definition.Extent.Text
}

$script:savedConfiguration = [pscustomobject]@{ UsbSerial = 'SAVED'; WirelessService = '192.168.1.2:4000'; ConnectionMode = 'wifi' }
$script:pairingState = @{}
$pairingCode = [pscustomobject]@{ Text = '' }
$endpoint = [pscustomobject]@{ Text = '' }
$connectionEndpoint = [pscustomobject]@{ Text = '' }
$manualAddresses = [pscustomobject]@{ Checked = $false }
$devices = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Serial = 'OTHER' } }
$mode = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ Value = 'wifi' } }

if ((Get-SetupInput).Serial -cne 'SAVED' -or -not (Test-SavedWifiSelection)) {
    throw 'A hidden USB selection must not replace the saved Wi-Fi identity.'
}

$mode.SelectedItem.Value = 'auto'

if ((Get-SetupInput).Serial -cne 'OTHER' -or (Test-SavedWifiSelection)) {
    throw 'Another selected USB phone must not inherit saved Wi-Fi credentials.'
}

$devices.SelectedItem.Serial = 'SAVED'

if (-not (Test-SavedWifiSelection)) {
    throw 'The same saved phone should retain its Wi-Fi pairing.'
}

$script:savedConfiguration = $null
$mode.SelectedItem.Value = 'wifi'

if ((Get-SetupInput).Serial) {
    throw 'Fresh Wi-Fi setup must not inherit a hidden USB identity.'
}

Write-Output 'PASS: Four independent saved identity selection scenarios.'
