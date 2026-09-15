param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $ProjectRoot 'launcher/options-view.ps1')
$directory = Join-Path $env:TEMP ('scrcpy-options-view-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)

# Fail on a user-visible settings behavior regression.
function Assert-OptionsView {
    param($Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

$owner = New-Object Windows.Forms.Form
$owner.Size = New-Object Drawing.Size(900, 800)
$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$owner.Controls.Add($tabs)
try {
    $view = New-OptionsView -Tabs $tabs -RootDirectory $directory
    $owner.Show()
    [Windows.Forms.Application]::DoEvents()
    $switchWatch = [Diagnostics.Stopwatch]::StartNew()
    $tabs.SelectedIndex = 1
    [Windows.Forms.Application]::DoEvents()
    $switchWatch.Stop()
    Assert-OptionsView ($switchWatch.Elapsed.TotalSeconds -lt 3) 'Opening Advanced blocked the shown window for more than three seconds.'
    Assert-OptionsView ($view.AdvancedLayout.Controls.Count -eq 1) 'Advanced laid out multiple option editors.'
    Write-Output ("Shown Advanced tab opened in {0} ms." -f $switchWatch.ElapsedMilliseconds)
    Assert-OptionsView ($view.Entries.Count -eq @(Get-ScrcpyOptionCatalog).Count) 'The UI omitted native options.'
    Assert-OptionsView (-not (Test-OptionsViewDirty $view)) 'A newly opened default view is dirty.'
    $fps = @($view.Entries | Where-Object { $_.Option.Name -eq 'max-fps' })[0]
    $fps.Input.Text = '60'
    Assert-OptionsView (Test-OptionsViewDirty $view) 'An FPS edit was not detected.'
    Assert-OptionsView (-not (Test-Path (Join-Path $directory 'scrcpy-settings.json'))) 'Editing implicitly saved settings.'
    Assert-OptionsView (Save-OptionsViewSettings $view) $view.Status.Text
    Assert-OptionsView ((Get-ScrcpySettings $directory).Options['max-fps'] -eq '60') 'The save did not persist FPS.'
    Assert-OptionsView (-not (Test-OptionsViewDirty $view)) 'A saved view is still dirty.'
    $fps.Input.Text = 'invalid'
    Assert-OptionsView (-not (Save-OptionsViewSettings $view)) 'Invalid FPS was accepted.'
    Assert-OptionsView ((Get-ScrcpySettings $directory).Options['max-fps'] -eq '60') 'Failed validation changed saved settings.'
    Set-OptionsViewSettings $view @{ Options = @{}; Reconnect = $true }
    Assert-OptionsView ((Get-OptionsViewSettings $view).Options.Count -eq 0) 'Restore defaults retained overrides.'
    Assert-OptionsView ((Get-ScrcpySettings $directory).Options['max-fps'] -eq '60') 'Restore defaults saved before acceptance.'
    $view.Search.Text = 'window-title'
    $advancedEntry = $view.FilteredEntries[$view.OptionList.SelectedIndex]
    $advancedEntry.Input.Text = 'My mirroring window'
    $view.Search.Text = 'camera'
    Assert-OptionsView ($null -eq $advancedEntry.Row.Parent) 'Filtered editors remained in the live layout.'
    $view.Search.Text = 'window-title'
    Assert-OptionsView ($view.FilteredEntries[$view.OptionList.SelectedIndex].Input.Text -eq 'My mirroring window') 'Filtering discarded an advanced draft.'
    $view.Search.Text = ''
    Assert-OptionsView ($view.FilteredEntries[$view.OptionList.SelectedIndex].Option.Name -eq 'window-title') 'Clearing search changed a still-matching selection.'
    Assert-OptionsView (Save-OptionsViewSettings $view) $view.Status.Text
    Assert-OptionsView ((Get-ScrcpySettings $directory).Options['window-title'] -eq 'My mirroring window') 'Advanced drafts were not saved.'
    Set-OptionsViewSettings $view @{ Options = @{ 'max-fps' = '60' }; Reconnect = $true }
    Assert-OptionsView (Save-OptionsViewSettings $view) $view.Status.Text
    Set-OptionsViewSettings $view @{ Options = @{}; Reconnect = $true }
    Assert-OptionsView ($advancedEntry.Input.Text -eq '') 'Reset retained a detached editor draft.'
    $view.Search.Text = 'camera'
    Assert-OptionsView ($view.FilterStatus.Text -match 'options match') 'Search did not update its result count.'
    Assert-OptionsView ($fps.Input.Text -eq '') 'Filtering changed an editor value.'
    $view.Search.Text = 'nonexistent-unique-option'
    Assert-OptionsView ($view.FilterStatus.Text -like '0 advanced*') 'Search treated an unmatched query as a match.'
    $optional = @($view.Entries | Where-Object { $_.Option.ArgumentOptional -and $_.Option.Availability -eq 'editable' })[0]
    $view.Search.Text = $optional.Option.Name
    Assert-OptionsView ($optional.Row.Parent -eq $view.AdvancedLayout) 'Search did not mount the optional-argument editor.'
    $optional.Enable.Checked = $true
    Assert-OptionsView ((Get-OptionsViewSettings $view).Options.ContainsKey($optional.Option.Name)) 'Bare optional argument was lost.'
    $optional.Enable.Checked = $false
    Assert-OptionsView (-not (Get-OptionsViewSettings $view).Options.ContainsKey($optional.Option.Name)) 'Disabled optional argument remained enabled.'
    $view.Search.Text = ''
    $view.Group.SelectedItem = $optional.Option.Group
    Assert-OptionsView ($view.FilteredEntries[$view.OptionList.SelectedIndex].Option.Name -eq $optional.Option.Name) 'Group filtering changed a matching selection.'
    Assert-OptionsView (@($view.FilteredEntries | Where-Object { $_.Option.Group -ne $optional.Option.Group }).Count -eq 0) 'Group filtering retained unrelated options.'
    $view.Group.SelectedIndex = 0
    $interactionWatch = [Diagnostics.Stopwatch]::StartNew()

    foreach ($searchQuery in @('camera', 'audio', 'window', '', 'no-match-fixture', '')) {
        $view.Search.Text = $searchQuery
        $tabs.SelectedIndex = 0
        $tabs.SelectedIndex = 1
        $owner.Width += 1
        [Windows.Forms.Application]::DoEvents()
        Assert-OptionsView ($view.AdvancedLayout.Controls.Count -le 1) 'Filtering mounted multiple editors.'
    }

    Assert-OptionsView ($interactionWatch.Elapsed.TotalSeconds -lt 5) 'Repeated search, resize and tab changes blocked the window.'
    Write-Output ("Six shown search/resize/tab cycles completed in {0} ms." -f $interactionWatch.ElapsedMilliseconds)
    Assert-OptionsView (-not (Test-Path (Join-Path $directory 'phone.json'))) 'Mirroring settings created device configuration.'
    $view.Tooltip.Dispose()
    $view.Footer.Dispose()
    $tabs.Dispose()
    Assert-OptionsView ($advancedEntry.Row.IsDisposed) 'Closing the view leaked detached editors.'
    Assert-OptionsView ((Get-ScrcpySettings $directory).Options['max-fps'] -eq '60') 'Closing discarded drafts changed saved settings.'
    [IO.File]::WriteAllText((Join-Path $directory 'scrcpy-settings.json'), '{broken')
    $tabs = New-Object Windows.Forms.TabControl
    $view = New-OptionsView -Tabs $tabs -RootDirectory $directory
    Assert-OptionsView ($view.Status.Text -match 'could not be loaded') 'Corrupt settings were not explained.'
    Assert-OptionsView ((Get-OptionsViewSettings $view).Options.Count -eq 0) 'Corrupt settings did not offer safe defaults.'
    Assert-OptionsView (Save-OptionsViewSettings $view) 'Explicit saving could not recover corrupt settings.'
    Write-Output 'Options UI save, validation, drafts, reset, filtering and optional flags passed.'
} finally {

    if ($null -ne $view) {
        $view.Tooltip.Dispose()
        $view.Footer.Dispose()
    }

    $tabs.Dispose()
    $owner.Dispose()
    Remove-Item -LiteralPath $directory -Recurse -Force
}
