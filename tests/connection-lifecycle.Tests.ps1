param([string]$LauncherDirectory = (Join-Path $PSScriptRoot '..\launcher'))
$ErrorActionPreference = 'Stop'
$syntaxTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $LauncherDirectory 'launch.ps1'), [ref]$null, [ref]$null)
$functions = $syntaxTree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)

foreach ($definition in $functions) {
    Invoke-Expression $definition.Extent.Text
}

$script:checks = 0

# Assert lifecycle behavior without creating a window or a real phone connection.
function Assert-Lifecycle {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }

    $script:checks++
}

# Substitute observable counters for native process and window actions.
function Close-MirroringResources { $script:session.NativeProcess = $null }
function Start-ConnectionProbe { $script:probeCount++ }
function Start-MirroringProcess { param($Target) $script:launchCount++ }
function Show-CurrentLauncherWindow { $script:focusCount++ }
function Start-LauncherSetup { $script:setupCount++ }

# Create fresh in-memory controls and session flags for each scenario.
function Reset-Lifecycle {
    $script:probeCount = 0
    $script:launchCount = 0
    $script:focusCount = 0
    $script:setupCount = 0
    $script:form = [pscustomobject]@{ Closed = $false; Hidden = $false }
    $script:form | Add-Member ScriptMethod Close { $this.Closed = $true }
    $script:form | Add-Member ScriptMethod Hide { $this.Hidden = $true }
    $script:statusLabel = [pscustomobject]@{ Text = 'Connecting to your phone...' }
    $script:retryButton = [pscustomobject]@{ Enabled = $false }
    $script:setupButton = [pscustomobject]@{ Enabled = $false }
    $script:instance = [pscustomobject]@{ Signal = (New-Object Threading.AutoResetEvent($false)) }
    $script:session = @{
        Closing = $false; SetupProcess = $null; NativeProcess = $null
        NativeVisible = $false; Pending = $null; Worker = $null
        SetupRequested = $false; Paused = $false
        Started = [DateTime]::UtcNow; NextProbe = [DateTime]::MinValue
    }
}

# Model the three native startup phases without a native executable.
function New-TestNativeProcess {
    param([bool]$Exited, [long]$Handle)
    $process = [pscustomobject]@{ HasExited = $Exited; MainWindowHandle = [IntPtr]$Handle }
    $process | Add-Member ScriptMethod Refresh { }
    return $process
}

Reset-Lifecycle
$script:session.NativeProcess = New-TestNativeProcess -Exited $false -Handle 0
Update-LauncherSession
Assert-Lifecycle (-not $script:form.Hidden) 'Waiting window hid before native HWND existed.'
Assert-Lifecycle ($script:probeCount -eq 0 -and $script:launchCount -eq 0) 'Native startup spawned overlapping work.'
$script:session.NativeProcess.MainWindowHandle = [IntPtr]42
Update-LauncherSession
Assert-Lifecycle ($script:form.Hidden -and $script:session.NativeVisible) 'Native window did not replace waiting window.'
$script:session.NativeProcess.HasExited = $true
Update-LauncherSession
Assert-Lifecycle $script:form.Closed 'Closing native window did not end launcher.'
Assert-Lifecycle ($script:probeCount -eq 0) 'Closing native window restarted a probe.'
$instance.Signal.Dispose()

Reset-Lifecycle
$script:session.NativeProcess = New-TestNativeProcess -Exited $true -Handle 0
Update-LauncherSession
Assert-Lifecycle ($script:session.Paused -and -not $script:form.Closed) 'Startup failure should stay visible and pause retries.'
Update-LauncherSession
Assert-Lifecycle ($script:probeCount -eq 0) 'Startup failure silently created more sessions.'
Assert-Lifecycle ($script:retryButton.Enabled -and $script:setupButton.Enabled) 'Startup failure disabled recovery buttons.'
$instance.Signal.Dispose()

Reset-Lifecycle
$script:session.Started = [DateTime]::UtcNow.AddSeconds(-11)
Update-WaitingStatus
Assert-Lifecycle ($script:statusLabel.Text -like 'Still waiting*') 'Delayed status missing after ten seconds.'
$script:session.Closing = $true
Update-LauncherSession
Assert-Lifecycle ($script:probeCount -eq 0) 'Cancelled session scheduled a new probe.'
$instance.Signal.Dispose()

Reset-Lifecycle
$script:session.Paused = $true
$null = $instance.Signal.Set()
Update-LauncherSession
Assert-Lifecycle ($script:focusCount -eq 1 -and $script:launchCount -eq 0) 'Repeated shortcut should focus, not launch another session.'
$instance.Signal.Dispose()
Write-Output "$script:checks lifecycle assertions passed without displaying windows."
