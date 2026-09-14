$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launch-runtime.ps1')
. (Join-Path $PSScriptRoot 'launch-session.ps1')
. (Join-Path $PSScriptRoot 'launch-view.ps1')
. (Join-Path $PSScriptRoot 'instance.ps1')
. (Join-Path $PSScriptRoot 'version.ps1')
$instance = $null
$session = $null
$view = $null
$timer = $null
$logPath = Join-Path $PSScriptRoot 'last-run.log'

try {
    $instance = Enter-LauncherInstance

    if (-not $instance.IsPrimary) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Application]::EnableVisualStyles()
    Set-Content -LiteralPath $logPath -Value ('scrcpy Seamless ' + (Get-SeamlessVersion) + ' | Started: ' + (Get-Date -Format o)) -Encoding UTF8
    $session = New-LaunchSession -RootDirectory $PSScriptRoot -Dependencies (New-LaunchDependencies)
    $actions = @{
        Retry = { Request-LaunchRetry -Session $session }
        Settings = { Request-LaunchSettings -Session $session }
        Close = { Request-LaunchClose -Session $session }
        Logs = {
            try {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $logPath + '"')
            } catch {
                $session.Presentation.Status = 'Could not open the log folder. Logs are stored next to the runtime scripts.'
            }
        }
    }
    $view = New-LaunchView -Version (Get-SeamlessVersion) -Actions $actions
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        try {

            if ($instance.Signal.WaitOne(0)) {
                $session.Presentation.FocusRequested = $true
            }

            Update-LaunchSession -Session $session
        } catch {
            Set-LaunchFailure -Session $session -Message 'Could not start mirroring. Open logs and try Settings.'
            Add-Content -LiteralPath $logPath -Value $_.Exception.Message
        }

        Update-LaunchView -View $view -Presentation (Get-LaunchPresentation -Session $session)
        $session.Presentation.FocusRequested = $false
    })
    Update-LaunchView -View $view -Presentation (Get-LaunchPresentation -Session $session)
    $timer.Start()
    [Windows.Forms.Application]::Run($view.Form)
} catch {
    $_ | Out-File -LiteralPath $logPath -Append -Encoding UTF8
    $shell = New-Object -ComObject WScript.Shell

    try {
        $null = $shell.Popup("$($_.Exception.Message)`nDetails: $logPath", 0, 'scrcpy Seamless', 16)
    } finally {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
} finally {

    if ($null -ne $timer) {
        $timer.Stop()
        $timer.Dispose()
    }

    try {

        if ($null -ne $session) {
            Close-LaunchSession -Session $session
        }
    } finally {

        if ($null -ne $view) {
            $view.Form.Dispose()
        }

        if ($null -ne $instance) {
            Exit-LauncherInstance -Instance $instance
        }
    }
}
