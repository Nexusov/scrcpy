$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../launcher/launch-view.ps1')
$observed = @{ Retry = 0; Settings = 0; Logs = 0; Close = 0 }
$actions = @{
    Retry = { $observed.Retry++ }.GetNewClosure()
    Settings = { $observed.Settings++ }.GetNewClosure()
    Logs = { $observed.Logs++ }.GetNewClosure()
    Close = { $observed.Close++; return $false }.GetNewClosure()
}
$view = New-LaunchView -Version 'fixture' -Actions $actions

try {
    $flags = [Reflection.BindingFlags]'Instance, NonPublic'
    $click = [Windows.Forms.Button].GetMethod('OnClick', $flags)
    $null = $click.Invoke($view.Retry, @([EventArgs]::Empty))
    $null = $click.Invoke($view.Settings, @([EventArgs]::Empty))
    $closeArguments = New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing, $false)
    $closing = [Windows.Forms.Form].GetMethod('OnFormClosing', $flags)
    $null = $closing.Invoke($view.Form, @($closeArguments.PSObject.BaseObject))

    if ($observed.Retry -ne 1 -or $observed.Settings -ne 1 -or $observed.Close -ne 1 -or -not $closeArguments.Cancel) {
        throw 'View action binding or close cancellation was lost.'
    }

    $presentation = @{ Status = 'Fixture waiting'; Hint = 'Fixture hint'; Visible = $false; CloseRequested = $false; FocusRequested = $false; RetryEnabled = $false; SettingsEnabled = $true }
    Update-LaunchView -View $view -Presentation $presentation

    if ($view.Status.Text -ne $presentation.Status -or $view.Hint.Text -ne $presentation.Hint -or $view.Retry.Enabled -or -not $view.Settings.Enabled) {
        throw 'View did not render the supplied controller state.'
    }

    Write-Output 'PASS: view callback binding, close cancellation and presentation rendering without opening windows.'
} finally {
    $view.Form.Dispose()
}
