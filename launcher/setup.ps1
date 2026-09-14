param([string]$RootDirectory = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup-session.ps1')
. (Join-Path $PSScriptRoot 'setup-view.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
$session = $null
$view = $null

try {
    $session = New-SetupSession -RootDirectory ([IO.Path]::GetFullPath($RootDirectory))
    $view = New-SetupView -Session $session -Version (Get-SeamlessVersion)
    [void]$view.Form.ShowDialog()
} catch {
    $message = $_.Exception.Message
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($message, 'scrcpy Seamless - Settings', 'OK', 'Error')
} finally {

    if ($null -ne $session) {
        Close-SetupSession -Session $session
    }

    if ($null -ne $view) {
        Close-SetupView -View $view
    }
}

if ($null -ne $session -and $session.Outcome -eq 'Saved') {
    exit 0
}

exit 1
