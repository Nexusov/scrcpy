# Display asynchronous native diagnostics with cancellation and selectable output.
function Show-ScrcpyDiagnostics {
    param([string]$RootDirectory, [string]$Name, $Owner, $Settings)
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object Windows.Forms.Form
    $form.Text = 'scrcpy - ' + $Name
    $form.Size = New-Object Drawing.Size(800, 580)
    $form.MinimumSize = New-Object Drawing.Size(500, 300)
    $form.StartPosition = 'CenterParent'
    $output = New-Object Windows.Forms.TextBox
    $output.Multiline = $true
    $output.ReadOnly = $true
    $output.ScrollBars = 'Both'
    $output.WordWrap = $false
    $output.Dock = 'Fill'
    $output.Text = 'Reading information... Close this window to cancel.'
    $form.Controls.Add($output)
    $cancellation = New-Object Threading.CancellationTokenSource
    $worker = [PowerShell]::Create()
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 150
    $state = @{ Completed = $false; Closing = $false; Handle = $null }

    try {
        $null = $worker.AddScript({
            param($RootDirectory, $Name, $Settings, $Cancellation)
            . (Join-Path $RootDirectory 'diagnostics-runtime.ps1')
            Invoke-ScrcpyDiagnostic -RootDirectory $RootDirectory -Name $Name -Settings $Settings -Cancellation $Cancellation
        }).AddArgument($RootDirectory).AddArgument($Name).AddArgument($Settings).AddArgument($cancellation)
        $state.Handle = $worker.BeginInvoke()
        $timer.Add_Tick({

            if (-not $state.Handle.IsCompleted) {
                return
            }

            $timer.Stop()
            $state.Completed = $true

            try {
                $results = @($worker.EndInvoke($state.Handle))

                if ($worker.HadErrors) {
                    throw ($worker.Streams.Error | Out-String)
                }

                $output.Text = ($results | ForEach-Object { "Exit code: $($_.ExitCode)`r`n$($_.Text)" }) -join "`r`n"
            } catch {
                $output.Text = $_.Exception.Message
            }

            if ($state.Closing) {
                $form.Close()
            }
        }.GetNewClosure())
        $form.Add_FormClosing({
            param($sender, $eventArguments)

            if (-not $state.Completed) {
                $eventArguments.Cancel = $true
                $state.Closing = $true
                $cancellation.Cancel()
                $output.Text = 'Cancelling...'
            }
        }.GetNewClosure())
        $timer.Start()
        [void]$form.ShowDialog($Owner)
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $cancellation.Cancel()
        $worker.Dispose()
        $cancellation.Dispose()
        $form.Dispose()
    }
}
