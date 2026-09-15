param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $ProjectRoot 'launcher/options-view.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-diagnostic-view-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$owner = New-Object Windows.Forms.Form
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$owner.Controls.Add($tabs)
$probe = @{ Output = ''; Timeout = $false; SawDialog = $false; RequestedClose = $false }
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 100

# Exercise the generated button and modal worker through the real message loop.
function Invoke-DiagnosticViewProbe {
    param([hashtable]$View, [string]$Name, [bool]$Cancel)
    $probe.Output = ''
    $probe.Timeout = $false
    $probe.SawDialog = $false
    $probe.RequestedClose = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $timer.Add_Tick({
        $dialog = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq ('scrcpy - ' + $Name) }) | Select-Object -First 1

        if ($null -eq $dialog) {
            return
        }

        $probe.SawDialog = $true
        $textControl = @($dialog.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })[0]

        $nativeStarted = Test-Path -LiteralPath (Join-Path $directory 'diagnostic-process-id.txt')

        if ($Cancel -and -not $probe.RequestedClose -and $nativeStarted) {
            $probe.RequestedClose = $true
            $dialog.Close()
            return
        }

        if (-not $Cancel -and $textControl.Text -ne 'Reading information... Close this window to cancel.') {
            $probe.Output = $textControl.Text
            $dialog.Close()
        }

        if ([DateTime]::UtcNow -gt $deadline) {
            $probe.Timeout = $true
            $dialog.Close()
        }
    }.GetNewClosure())
    $View.Search.Text = $Name
    $tabs.SelectedIndex = 1
    [Windows.Forms.Application]::DoEvents()
    $entry = @($View.Entries | Where-Object { $_.Option.Name -eq $Name })[0]
    $button = @($entry.Row.Controls | Where-Object { $_ -is [Windows.Forms.Button] })[0]
    $timer.Start()
    $button.PerformClick()
    $timer.Stop()

    if (-not $probe.SawDialog -or $probe.Timeout) {
        throw 'Generated action did not display and finish its diagnostic dialog.'
    }
}

try {
    Copy-Item -Path (Join-Path $ProjectRoot 'launcher/*') -Destination $directory
    $program = 'using System; using System.IO; public static class DiagnosticViewFixture { public static void Main(string[] arguments) { File.WriteAllText("diagnostic-process-id.txt", System.Diagnostics.Process.GetCurrentProcess().Id.ToString()); if (Array.IndexOf(arguments, "--version") >= 0) System.Threading.Thread.Sleep(30000); Console.WriteLine("GUI fixture " + String.Join("|", arguments)); } }'
    Add-Type -TypeDefinition $program -OutputAssembly (Join-Path $directory 'scrcpy.exe') -OutputType ConsoleApplication
    $view = New-OptionsView -Tabs $tabs -RootDirectory $directory
    $owner.Show()
    [Windows.Forms.Application]::DoEvents()
    Invoke-DiagnosticViewProbe -View $view -Name 'help' -Cancel $false

    if ($probe.Output -notmatch 'Exit code: 0' -or $probe.Output -notmatch 'GUI fixture --help') {
        throw ('Generated Help action lost worker output: ' + $probe.Output)
    }

    $timer.Dispose()
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 100
    Remove-Item -LiteralPath (Join-Path $directory 'diagnostic-process-id.txt')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-DiagnosticViewProbe -View $view -Name 'version' -Cancel $true

    if ($watch.Elapsed.TotalSeconds -gt 5) {
        throw 'Closing the diagnostic did not cancel promptly.'
    }

    $processIdentifier = [int][IO.File]::ReadAllText((Join-Path $directory 'diagnostic-process-id.txt'))

    if (Get-Process -Id $processIdentifier -ErrorAction SilentlyContinue) {
        throw 'Cancelled diagnostic left its owned native process running.'
    }

    Write-Output 'PASS: generated Help button, modal ownership, worker output and close cancellation.'
} finally {
    $timer.Dispose()

    if ($null -ne $view) {
        $view.Tooltip.Dispose()
        $view.Footer.Dispose()
    }

    $owner.Dispose()
    $resolved = (Resolve-Path -LiteralPath $directory).ProviderPath

    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\')) {
        throw 'Unexpected diagnostic fixture path.'
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}
