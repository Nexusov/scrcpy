# Load the shared settings contract for the standalone view and setup wizard.
. (Join-Path $PSScriptRoot 'option-catalog.ps1')
. (Join-Path $PSScriptRoot 'options-store.ps1')
. (Join-Path $PSScriptRoot 'diagnostics-view.ps1')

# Read controls into a draft without writing device or mirroring configuration.
function Get-OptionsViewSettings {
    param([hashtable]$View)
    $options = @{}

    foreach ($entry in $View.Entries) {

        if ($entry.Option.Availability -ne 'editable') {
            continue
        }

        if ($entry.Option.Kind -eq 'switch') {

            if ($entry.Input.Checked) {
                $options[$entry.Option.Name] = $true
            }

            continue
        }

        if ($null -ne $entry.Enable) {

            if ($entry.Enable.Checked) {
                $options[$entry.Option.Name] = $entry.Input.Text.Trim()
            }

            continue
        }

        if ($entry.Input.Text.Trim()) {
            $options[$entry.Option.Name] = $entry.Input.Text.Trim()
        }
    }

    return @{ Options = $options; Reconnect = $View.Reconnect.Checked }
}

# Populate each option once; filtering never reconstructs editors or loses drafts.
function Set-OptionsViewSettings {
    param([hashtable]$View, [hashtable]$Settings)
    $View.Reconnect.Checked = $Settings.Reconnect

    foreach ($entry in $View.Entries) {
        $present = $Settings.Options.ContainsKey($entry.Option.Name)

        if ($entry.Option.Availability -ne 'editable') {
            continue
        }

        if ($entry.Option.Kind -eq 'switch') {
            $entry.Input.Checked = $present -and [bool]$Settings.Options[$entry.Option.Name]
            continue
        }

        $entry.Input.Text = ''

        if ($present) {
            $entry.Input.Text = [string]$Settings.Options[$entry.Option.Name]
        }

        if ($null -ne $entry.Enable) {
            $entry.Enable.Checked = $present
            $entry.Input.Enabled = $present
        }
    }
}

# Mount only the selected editor so layout cost is independent of catalogue size.
function Show-OptionsViewSelection {
    param([hashtable]$View)

    if ($View.Filtering) {
        return
    }

    $selectedIndex = $View.OptionList.SelectedIndex

    if ($selectedIndex -ge 0) {
        $selectedRow = $View.FilteredEntries[$selectedIndex].Row

        if ($selectedRow.Parent -eq $View.AdvancedLayout) {
            return
        }
    }

    $View.AdvancedLayout.SuspendLayout()

    try {
        $View.AdvancedLayout.Controls.Clear()
        $View.AdvancedLayout.RowStyles.Clear()
        $View.AdvancedLayout.RowCount = 0

        if ($selectedIndex -lt 0) {
            return
        }

        $entry = $View.FilteredEntries[$selectedIndex]
        Add-OptionsRow -Layout $View.AdvancedLayout -Control $entry.Row
    } finally {
        $View.AdvancedLayout.ResumeLayout($true)
    }
}

# Filter catalogue labels without laying out hidden editors or changing their drafts.
function Update-OptionsViewFilter {
    param([hashtable]$View)
    $searchText = $View.Search.Text.Trim()
    $groupName = [string]$View.Group.SelectedItem
    $selectedName = ''

    if ($View.OptionList.SelectedIndex -ge 0) {
        $selectedName = $View.FilteredEntries[$View.OptionList.SelectedIndex].Option.Name
    }

    $matches = New-Object Collections.Generic.List[object]
    $View.Filtering = $true
    $View.OptionList.BeginUpdate()

    try {
        $View.OptionList.Items.Clear()

        foreach ($entry in $View.Entries) {

            if ($entry.Option.Basic) {
                continue
            }

            $matchesGroup = $groupName -eq 'All groups' -or $entry.Option.Group -eq $groupName
            $searchable = $entry.Option.Name + ' ' + $entry.Option.Label + ' ' + $entry.Option.Description
            $matchesSearch = -not $searchText -or $searchable.IndexOf($searchText, [StringComparison]::OrdinalIgnoreCase) -ge 0

            if (-not ($matchesGroup -and $matchesSearch)) {
                continue
            }

            $matches.Add($entry)
            [void]$View.OptionList.Items.Add($entry.Option.Label + '  (--' + $entry.Option.Name + ')')
        }

        $View.FilteredEntries = $matches.ToArray()
        $selectedIndex = -1

        for ($entryIndex = 0; $entryIndex -lt $matches.Count; $entryIndex++) {

            if ($matches[$entryIndex].Option.Name -eq $selectedName) {
                $selectedIndex = $entryIndex
                break
            }
        }

        if ($selectedIndex -lt 0 -and $matches.Count) {
            $selectedIndex = 0
        }

        $View.OptionList.SelectedIndex = $selectedIndex
        $View.FilterStatus.Text = "$($matches.Count) advanced options match. Select an option below to edit it."
    } finally {
        $View.OptionList.EndUpdate()
        $View.Filtering = $false
    }

    Show-OptionsViewSelection -View $View
}

# Save an explicitly accepted draft and report validation errors inside the window.
function Save-OptionsViewSettings {
    param([hashtable]$View)

    try {
        $settings = Get-OptionsViewSettings -View $View
        Assert-ScrcpySettings -Settings $settings
        Save-ScrcpySettings -RootDirectory $View.RootDirectory -Settings $settings -ExpectedSnapshot $View.Snapshot
        $View.Snapshot = Get-ScrcpySettingsSnapshot -RootDirectory $View.RootDirectory
        $View.SavedDraft = $settings | ConvertTo-Json -Depth 8 -Compress
        $View.Status.Text = 'Settings saved. Changes apply the next time you start mirroring.'
        return $true
    } catch {
        $View.Status.Text = 'Settings could not be saved: ' + $_.Exception.Message
        return $false
    }
}

# Report whether closing would discard unapplied mirroring edits.
function Test-OptionsViewDirty {
    param([hashtable]$View)
    $currentDraft = Get-OptionsViewSettings -View $View
    $savedDraft = $View.SavedDraft | ConvertFrom-Json

    if ($currentDraft.Reconnect -ne $savedDraft.Reconnect) {
        return $true
    }

    $savedNames = @($savedDraft.Options.PSObject.Properties | ForEach-Object { $_.Name })

    if ($currentDraft.Options.Count -ne $savedNames.Count) {
        return $true
    }

    foreach ($name in $savedNames) {

        if (-not $currentDraft.Options.ContainsKey($name) -or [string]$currentDraft.Options[$name] -cne [string]$savedDraft.Options.$name) {
            return $true
        }
    }

    return $false
}

# Create a scrollable, width-constrained layout for dynamically described options.
function New-OptionsLayout {
    param($Parent)
    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.AutoScroll = $true
    $Parent.Controls.Add($panel)
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Top'
    $layout.AutoSize = $true
    $layout.ColumnCount = 1
    $layout.SuspendLayout()
    $layout.Padding = New-Object Windows.Forms.Padding(16)
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $panel.Controls.Add($layout)
    return $layout
}

# Append an automatically sized row to a vertical options layout.
function Add-OptionsRow {
    param($Layout, $Control)
    $rowIndex = $Layout.RowCount
    $Layout.RowCount++
    [void]$Layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $Control.Dock = 'Top'
    $Layout.Controls.Add($Control, 0, $rowIndex)
}

# Build one labelled editor from the shared option catalogue.
function New-OptionsEditor {
    param($Option, [hashtable]$Context)
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.AutoSize = $true
    $row.SuspendLayout()
    $row.ColumnCount = 1
    $row.Margin = New-Object Windows.Forms.Padding(0, 5, 0, 14)
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.Text = $Option.Label + '  (--' + $Option.Name + ')'
    Add-OptionsRow -Layout $row -Control $label
    $inputControl = $null
    $enable = $null

    if ($Option.Availability -eq 'editable') {

        if ($Option.Kind -eq 'switch') {
            $inputControl = New-Object Windows.Forms.CheckBox
            $inputControl.AutoSize = $true
            $inputControl.Text = $Option.Label
            $label.Text = '--' + $Option.Name
        } else {
            $inputControl = New-Object Windows.Forms.TextBox

            if ($Option.Values.Count) {
                $inputControl = New-Object Windows.Forms.ComboBox
                $inputControl.DropDownStyle = 'DropDown'
                [void]$inputControl.Items.Add('')
                $inputControl.Items.AddRange([object[]]$Option.Values)
            }

            if ($Option.ArgumentOptional) {
                $enable = New-Object Windows.Forms.CheckBox
                $enable.Text = 'Use this option (a blank value uses its implicit default)'
                $enable.AutoSize = $true
                Add-OptionsRow -Layout $row -Control $enable
                $enable.Add_CheckedChanged({ $inputControl.Enabled = $enable.Checked }.GetNewClosure())
            }
        }

        $inputControl.AccessibleName = $Option.Label
        $inputControl.AccessibleDescription = $Option.Description
        Add-OptionsRow -Layout $row -Control $inputControl
    }

    $help = New-Object Windows.Forms.Label
    $help.AutoSize = $true
    $descriptionLimit = 180
    $help.Text = ($Option.Description -split '[\r\n]')[0]

    if ($help.Text.Length -gt $descriptionLimit) {
        $help.Text = $help.Text.Substring(0, $descriptionLimit) + '...'
    }

    $Context.Tooltip.SetToolTip($help, $Option.Description)
    $help.AccessibleDescription = $Option.Description

    if ($Option.Kind -eq 'value' -and $Option.Availability -eq 'editable') {
        $help.Text += ' Blank: scrcpy default.'
    }

    if ($Option.Reason) {
        $help.Text += ' ' + $Option.Reason
    }

    if (-not $Option.SeamlessCompatible -and $Option.Availability -eq 'editable') {
        $help.Text += ' Turn off seamless reconnection to use this option.'
    }

    Add-OptionsRow -Layout $row -Control $help

    if ($Option.Availability -eq 'action') {
        $action = New-Object Windows.Forms.Button
        $action.Text = 'Show ' + $Option.Label.ToLowerInvariant()
        $action.AutoSize = $true
        $action.Add_Click({
            Show-ScrcpyDiagnostics -RootDirectory $Context.RootDirectory -Name $Option.Name -Owner $row.FindForm() -Settings (Get-OptionsViewSettings -View $Context.View)
        }.GetNewClosure())
        Add-OptionsRow -Layout $row -Control $action
    }

    $row.ResumeLayout($false)
    return @{ Option = $Option; Row = $row; Input = $inputControl; Enable = $enable }
}

# Add basic and advanced tabs while keeping their shared draft separate from pairing.
function New-OptionsView {
    param($Tabs, [string]$RootDirectory)
    $basicPage = New-Object Windows.Forms.TabPage
    $basicPage.Text = 'Mirroring'
    $advancedPage = New-Object Windows.Forms.TabPage
    $advancedPage.Text = 'Advanced'
    $Tabs.TabPages.AddRange(@($basicPage, $advancedPage))
    $basicLayout = New-OptionsLayout -Parent $basicPage
    $advancedHost = New-Object Windows.Forms.Panel
    $advancedHost.Dock = 'Fill'
    $advancedHost.TabIndex = 1
    $advancedPage.Controls.Add($advancedHost)
    $optionList = New-Object Windows.Forms.ListBox
    $optionList.Dock = 'Top'
    $optionList.TabIndex = 0
    $optionList.Height = 160
    $optionList.IntegralHeight = $false
    $optionList.HorizontalScrollbar = $true
    $optionList.AccessibleName = 'Advanced options'
    $advancedLayout = New-OptionsLayout -Parent $advancedHost
    $advancedLayout.Parent.TabIndex = 1
    $advancedHost.Controls.Add($optionList)
    $filters = New-Object Windows.Forms.TableLayoutPanel
    $filters.Dock = 'Top'
    $filters.TabIndex = 0
    $filters.AutoSize = $true
    $filters.ColumnCount = 1
    $filters.Padding = New-Object Windows.Forms.Padding(16, 8, 16, 0)
    [void]$filters.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $searchLabel = New-Object Windows.Forms.Label
    $searchLabel.Text = 'Search advanced options by name, flag, or description'
    $searchLabel.AutoSize = $true
    Add-OptionsRow $filters $searchLabel
    $search = New-Object Windows.Forms.TextBox
    $search.TabIndex = 0
    $search.AccessibleName = 'Search advanced options'
    Add-OptionsRow $filters $search
    $group = New-Object Windows.Forms.ComboBox
    $group.DropDownStyle = 'DropDownList'
    $group.TabIndex = 1
    $group.AccessibleName = 'Option group'
    [void]$group.Items.Add('All groups')
    $catalog = @(Get-ScrcpyOptionCatalog)
    $group.Items.AddRange([object[]]@($catalog | ForEach-Object { $_.Group } | Sort-Object -Unique))
    $group.SelectedIndex = 0
    Add-OptionsRow $filters $group
    $filterStatus = New-Object Windows.Forms.Label
    $filterStatus.AutoSize = $true
    Add-OptionsRow $filters $filterStatus
    $advancedPage.Controls.Add($filters)
    $reconnect = New-Object Windows.Forms.CheckBox
    $reconnect.AutoSize = $true
    $reconnect.Text = 'Keep the same window and reconnect when the device disconnects'
    Add-OptionsRow $basicLayout $reconnect
    $reconnectHelp = New-Object Windows.Forms.Label
    $reconnectHelp.AutoSize = $true
    $reconnectHelp.Text = 'Some advanced modes require reconnection to be disabled. FPS is a limit, not a guarantee that the video or phone can produce that many frames.'
    Add-OptionsRow $basicLayout $reconnectHelp
    $entries = @()
    $tooltip = New-Object Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 30000
    $tooltip.IsBalloon = $false
    $context = @{ RootDirectory = $RootDirectory; Tooltip = $tooltip; View = $null }

    foreach ($option in $catalog) {
        $entry = New-OptionsEditor -Option $option -Context $context

        if ($option.Basic) {
            Add-OptionsRow -Layout $basicLayout -Control $entry.Row
        }
        $entries += $entry
    }

    $footer = New-Object Windows.Forms.TableLayoutPanel
    $footer.Dock = 'Bottom'
    $footer.AutoSize = $true
    $footer.ColumnCount = 1
    $footer.Padding = New-Object Windows.Forms.Padding(12, 4, 12, 8)
    [void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.Text = 'Mirroring settings are saved separately from device setup. Changes apply on the next launch.'
    Add-OptionsRow $footer $status
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true
    $save = New-Object Windows.Forms.Button
    $save.Text = 'Save mirroring settings'
    $save.AutoSize = $true
    $reset = New-Object Windows.Forms.Button
    $reset.Text = 'Restore mirroring defaults'
    $reset.AutoSize = $true
    $buttons.Controls.AddRange(@($save, $reset))
    Add-OptionsRow $footer $buttons
    $view = @{ RootDirectory = $RootDirectory; Entries = $entries; OptionList = $optionList; FilteredEntries = @(); Filtering = $false; Reconnect = $reconnect; Search = $search; Group = $group; AdvancedLayout = $advancedLayout; FilterStatus = $filterStatus; Status = $status; Save = $save; Reset = $reset; Footer = $footer; Snapshot = (Get-ScrcpySettingsSnapshot -RootDirectory $RootDirectory) }
    $optionList.Add_SelectedIndexChanged({ Show-OptionsViewSelection -View $view }.GetNewClosure())
    $advancedPage.Add_Disposed({
        foreach ($entry in $entries) {

            if (-not $entry.Option.Basic) {
                $entry.Row.Dispose()
            }
        }
    }.GetNewClosure())
    $context.View = $view
    $view.Tooltip = $tooltip

    try {
        $settings = Get-ScrcpySettings -RootDirectory $RootDirectory
    } catch {
        $settings = @{ Options = @{}; Reconnect = $true }
        $status.Text = 'Saved mirroring settings could not be loaded: ' + $_.Exception.Message + ' Defaults are shown. Save to replace the invalid settings, or close to preserve them.'
    }
    Set-OptionsViewSettings -View $view -Settings $settings
    $view.SavedDraft = (Get-OptionsViewSettings -View $view) | ConvertTo-Json -Depth 8 -Compress
    $search.Add_TextChanged({ Update-OptionsViewFilter -View $view }.GetNewClosure())
    $group.Add_SelectedIndexChanged({ Update-OptionsViewFilter -View $view }.GetNewClosure())
    $save.Add_Click({ [void](Save-OptionsViewSettings -View $view) }.GetNewClosure())
    $reset.Add_Click({
        Set-OptionsViewSettings -View $view -Settings @{ Options = @{}; Reconnect = $true }
        $view.Status.Text = 'Defaults restored in this window. Click Save mirroring settings to apply, or close to discard.'
    }.GetNewClosure())
    Update-OptionsViewFilter -View $view
    $basicLayout.ResumeLayout($true)
    $advancedLayout.ResumeLayout($true)
    return $view
}
