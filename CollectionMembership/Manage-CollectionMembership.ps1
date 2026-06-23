param(
    [string]$CollectionID       = "",
    [string]$CollectionName     = "",
    [string]$PatternRequired    = "ins-req-dev-*",
    [string]$PatternAvailable   = "ins-avl-dev-*",
    [string]$SiteCode           = "",
    [ValidateSet('auto','de','en')]
    [string]$Language           = 'auto'
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Localization
$strings = @{
    de = @{
        FormTitle          = 'Collection-Mitgliedschaft: {0}'
        FormTitleNoColl    = 'Collection-Mitgliedschaft verwalten'
        NotMemberOf        = 'Nicht Mitglied in'
        MemberOf           = 'Mitglied in'
        BtnAllRight        = 'Alle >'
        BtnAllLeft         = '< Alle'
        SelectedCollection = 'Gewählte Collection:'
        NoCollSelected     = '(keine Collection gewählt)'
        LblRequired        = 'Pflicht:'
        LblAvailable       = 'Verfügbar:'
        BtnLoad            = 'Laden'
        TabRequired        = 'Pflicht'
        TabAvailable       = 'Verfügbar'
        BtnSave            = 'Speichern'
        PickTitle          = 'Device Collection auswählen'
        SearchTerm         = 'Suchbegriff (* = alle):'
        BtnSearch          = 'Suchen'
        BtnSelect          = 'Auswählen'
        BtnCancel          = 'Abbrechen'
        NoResults          = '(keine Ergebnisse)'
        TitleError         = 'Fehler'
        TitleWarning       = 'Warnung'
        TitleSave          = 'Speichern'
        TitleSaved         = 'Gespeichert'
        TitleConfirm       = 'Bestätigen'
        CmConnectFailed    = "CM-Verbindung fehlgeschlagen:`n{0}"
        SearchFailed       = "Suche fehlgeschlagen:`n{0}"
        NoCollLoad         = "Keine Collection ausgewählt.`nBitte über '...' eine Collection wählen oder das Tool aus dem Kontextmenü starten."
        NeedPattern        = 'Bitte mindestens ein Namensmuster eingeben.'
        StatusConnecting   = 'Verbinde mit ConfigMgr...'
        StatusLoading      = "Lade '{0}'..."
        StatusChecking     = '[{0}]  Prüfe Mitgliedschaft ({1} / {2})...'
        StatusLoaded       = '{0} Collections geladen  --  {1} Mitgliedschaft(en) aktiv'
        LoadFailed         = "Fehler beim Laden:`n{0}"
        LoadFailedShort    = 'Fehler beim Laden.'
        NoChanges          = 'Keine Änderungen erkannt.'
        SaveConfirm        = "Änderungen für '{0}' speichern?`n`n"
        SaveAdd            = "Hinzufügen : {0} Collection(s)`n"
        SaveRemove         = "Entfernen  : {0} Collection(s)`n"
        SaveErrors         = "Abgeschlossen mit Fehlern:`n`n{0}"
        SaveOk             = 'Erfolgreich gespeichert.'
        StatusSaved        = 'Gespeichert  --  {0} Änderung(en) übernommen'
        ModuleNotFound     = 'ConfigurationManager-Modul nicht gefunden. Bitte die AdminConsole auf diesem Computer installieren.'
        NoSiteCode         = 'Site Code konnte nicht ermittelt werden.'
    }
    en = @{
        FormTitle          = 'Collection membership: {0}'
        FormTitleNoColl    = 'Manage collection membership'
        NotMemberOf        = 'Not member of'
        MemberOf           = 'Member of'
        BtnAllRight        = 'All >'
        BtnAllLeft         = '< All'
        SelectedCollection = 'Selected collection:'
        NoCollSelected     = '(no collection selected)'
        LblRequired        = 'Required:'
        LblAvailable       = 'Available:'
        BtnLoad            = 'Load'
        TabRequired        = 'Required'
        TabAvailable       = 'Available'
        BtnSave            = 'Save'
        PickTitle          = 'Select device collection'
        SearchTerm         = 'Search term (* = all):'
        BtnSearch          = 'Search'
        BtnSelect          = 'Select'
        BtnCancel          = 'Cancel'
        NoResults          = '(no results)'
        TitleError         = 'Error'
        TitleWarning       = 'Warning'
        TitleSave          = 'Save'
        TitleSaved         = 'Saved'
        TitleConfirm       = 'Confirm'
        CmConnectFailed    = "CM connection failed:`n{0}"
        SearchFailed       = "Search failed:`n{0}"
        NoCollLoad         = "No collection selected.`nUse '...' to choose a collection or start the tool from the context menu."
        NeedPattern        = 'Please enter at least one name pattern.'
        StatusConnecting   = 'Connecting to ConfigMgr...'
        StatusLoading      = "Loading '{0}'..."
        StatusChecking     = '[{0}]  Checking membership ({1} / {2})...'
        StatusLoaded       = '{0} collections loaded  --  {1} membership(s) active'
        LoadFailed         = "Error while loading:`n{0}"
        LoadFailedShort    = 'Error while loading.'
        NoChanges          = 'No changes detected.'
        SaveConfirm        = "Save changes for '{0}'?`n`n"
        SaveAdd            = "Add    : {0} collection(s)`n"
        SaveRemove         = "Remove : {0} collection(s)`n"
        SaveErrors         = "Completed with errors:`n`n{0}"
        SaveOk             = 'Successfully saved.'
        StatusSaved        = 'Saved  --  {0} change(s) applied'
        ModuleNotFound     = 'ConfigurationManager module not found. Please install the AdminConsole on this computer.'
        NoSiteCode         = 'Could not determine site code.'
    }
}

$useDe = switch ($Language) {
    'de'    { $true }
    'en'    { $false }
    default { [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de' }
}
$L = if ($useDe) { $strings.de } else { $strings.en }
#endregion

#region CM connection
function Initialize-CMConnection {
    param([string]$SC = "")

    $modulePath = $null
    if ($env:SMS_ADMIN_UI_PATH) {
        $c = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) "ConfigurationManager.psd1"
        if (Test-Path $c) { $modulePath = $c }
    }
    if (-not $modulePath) {
        foreach ($p in @(
            "${env:ProgramFiles(x86)}\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )) { if (Test-Path $p) { $modulePath = $p; break } }
    }
    if (-not $modulePath) {
        throw $L.ModuleNotFound
    }
    if (-not (Get-Module ConfigurationManager -ErrorAction SilentlyContinue)) {
        Import-Module $modulePath -ErrorAction Stop
    }
    if (-not $SC) {
        $drive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($drive) { $SC = $drive.Name }
        else { $SC = (Get-WmiObject -Namespace "root\sms" -Class "SMS_ProviderLocation" -ErrorAction Stop | Select-Object -First 1).SiteCode }
    }
    if (-not $SC) { throw $L.NoSiteCode }
    if (-not (Get-PSDrive -Name $SC -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SC -PSProvider CMSite -Root "" -ErrorAction Stop | Out-Null
    }
    Set-Location "$SC`:" -ErrorAction Stop
    return $SC
}
#endregion

#region Helpers
function fnNewEntry {
    param($col)
    $obj = [PSCustomObject]@{
        DisplayText    = "$($col.Name)  [$($col.CollectionID)]"
        CollectionID   = $col.CollectionID
        CollectionName = $col.Name
    }
    $obj | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { $this.DisplayText } -Force
    $obj
}

function fnRefresh {
    param($lb, $list)
    $lb.BeginUpdate()
    $lb.Items.Clear()
    foreach ($item in $list) { [void]$lb.Items.Add($item) }
    $lb.EndUpdate()
}
#endregion

#region Data model
$script:SiteCode             = ""
$script:ActiveCollectionID   = $CollectionID
$script:ActiveCollectionName = $CollectionName

$script:tabData = @{
    req = @{
        Pattern          = $PatternRequired
        LeftItems        = [System.Collections.Generic.List[PSCustomObject]]::new()
        RightItems       = [System.Collections.Generic.List[PSCustomObject]]::new()
        OriginalRightIDs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        LbLeft           = $null
        LbRight          = $null
        Buttons          = @()
    }
    avl = @{
        Pattern          = $PatternAvailable
        LeftItems        = [System.Collections.Generic.List[PSCustomObject]]::new()
        RightItems       = [System.Collections.Generic.List[PSCustomObject]]::new()
        OriginalRightIDs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        LbLeft           = $null
        LbRight          = $null
        Buttons          = @()
    }
}
#endregion

#region Panel factory
function New-MembershipPanel {
    param([hashtable]$TD)

    $leftList  = $TD.LeftItems
    $rightList = $TD.RightItems

    # Captured by GetNewClosure() — fnRefresh is NOT visible inside closures
    $doRefresh = {
        param($lb, $list)
        $lb.BeginUpdate()
        $lb.Items.Clear()
        foreach ($item in $list) { [void]$lb.Items.Add($item) }
        $lb.EndUpdate()
    }

    $lblL = New-Object System.Windows.Forms.Label
    $lblL.Text = $L.NotMemberOf; $lblL.Dock = "Fill"
    $lblL.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblL.TextAlign = "MiddleLeft"

    $lblR = New-Object System.Windows.Forms.Label
    $lblR.Text = $L.MemberOf; $lblR.Dock = "Fill"
    $lblR.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblR.TextAlign = "MiddleLeft"

    $lbL = New-Object System.Windows.Forms.ListBox
    $lbL.Dock = "Fill"; $lbL.SelectionMode = "MultiExtended"
    $lbL.ScrollAlwaysVisible = $true; $lbL.IntegralHeight = $false; $lbL.BorderStyle = "FixedSingle"

    $lbR = New-Object System.Windows.Forms.ListBox
    $lbR.Dock = "Fill"; $lbR.SelectionMode = "MultiExtended"
    $lbR.ScrollAlwaysVisible = $true; $lbR.IntegralHeight = $false; $lbR.BorderStyle = "FixedSingle"

    $TD.LbLeft  = $lbL
    $TD.LbRight = $lbR

    $bR  = New-Object System.Windows.Forms.Button; $bR.Text  = ">"          ; $bR.Size = New-Object System.Drawing.Size(76,28); $bR.Margin  = New-Object System.Windows.Forms.Padding(10,4,10,4); $bR.Enabled  = $false
    $bAR = New-Object System.Windows.Forms.Button; $bAR.Text = $L.BtnAllRight; $bAR.Size = New-Object System.Drawing.Size(76,28); $bAR.Margin = New-Object System.Windows.Forms.Padding(10,4,10,4); $bAR.Enabled = $false
    $bL  = New-Object System.Windows.Forms.Button; $bL.Text  = "<"          ; $bL.Size = New-Object System.Drawing.Size(76,28); $bL.Margin  = New-Object System.Windows.Forms.Padding(10,4,10,4); $bL.Enabled  = $false
    $bAL = New-Object System.Windows.Forms.Button; $bAL.Text = $L.BtnAllLeft ; $bAL.Size = New-Object System.Drawing.Size(76,28); $bAL.Margin = New-Object System.Windows.Forms.Padding(10,4,10,4); $bAL.Enabled = $false
    $TD.Buttons = @($bR, $bAR, $bL, $bAL)

    $bR.Add_Click(({
        $sel = @($lbL.SelectedItems); if (-not $sel) { return }
        $ex  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $rightList) { [void]$ex.Add($i.CollectionID) }
        foreach ($item in $sel) {
            if (-not $ex.Contains($item.CollectionID)) { $rightList.Add($item); [void]$ex.Add($item.CollectionID) }
            [void]$leftList.Remove($item)
        }
        & $doRefresh $lbL $leftList; & $doRefresh $lbR $rightList
    }).GetNewClosure())

    $bAR.Add_Click(({
        $ex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $rightList) { [void]$ex.Add($i.CollectionID) }
        foreach ($item in @($leftList)) {
            if (-not $ex.Contains($item.CollectionID)) { $rightList.Add($item); [void]$ex.Add($item.CollectionID) }
        }
        $leftList.Clear()
        & $doRefresh $lbL $leftList; & $doRefresh $lbR $rightList
    }).GetNewClosure())

    $bL.Add_Click(({
        $sel = @($lbR.SelectedItems); if (-not $sel) { return }
        $ex  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $leftList) { [void]$ex.Add($i.CollectionID) }
        foreach ($item in $sel) {
            if (-not $ex.Contains($item.CollectionID)) { $leftList.Add($item); [void]$ex.Add($item.CollectionID) }
            [void]$rightList.Remove($item)
        }
        & $doRefresh $lbL $leftList; & $doRefresh $lbR $rightList
    }).GetNewClosure())

    $bAL.Add_Click(({
        $ex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $leftList) { [void]$ex.Add($i.CollectionID) }
        foreach ($item in @($rightList)) {
            if (-not $ex.Contains($item.CollectionID)) { $leftList.Add($item); [void]$ex.Add($item.CollectionID) }
        }
        $rightList.Clear()
        & $doRefresh $lbL $leftList; & $doRefresh $lbR $rightList
    }).GetNewClosure())

    $arrowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $arrowPanel.Dock = "Fill"; $arrowPanel.FlowDirection = "TopDown"
    $arrowPanel.WrapContents = $false; $arrowPanel.AutoSize = $false
    $arrowPanel.Controls.AddRange(@($bR, $bAR, $bL, $bAL))
    $arrowPanel.Add_Resize(({
        $total  = (28 + 8) * 4
        $topPad = [Math]::Max(0, [int](($arrowPanel.ClientSize.Height - $total) / 2))
        $arrowPanel.Padding = New-Object System.Windows.Forms.Padding(10, $topPad, 10, 0)
    }).GetNewClosure())

    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = "Fill"; $table.ColumnCount = 3; $table.RowCount = 2
    $table.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 6)
    $table.ColumnStyles.Clear()
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 46)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 116)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 54)))
    $table.RowStyles.Clear()
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $table.Controls.Add($lblL,       0, 0)
    $table.Controls.Add($lblR,       2, 0)
    $table.Controls.Add($lbL,        0, 1)
    $table.Controls.Add($arrowPanel, 1, 1)
    $table.Controls.Add($lbR,        2, 1)

    return $table
}
#endregion

#region Form
$form = New-Object System.Windows.Forms.Form
$form.Text          = if ($script:ActiveCollectionName) { $L.FormTitle -f $script:ActiveCollectionName } else { $L.FormTitleNoColl }
$form.Size          = New-Object System.Drawing.Size(960, 720)
$form.MinimumSize   = New-Object System.Drawing.Size(720, 540)
$form.StartPosition = "CenterScreen"
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

# --- Top strip ---
$stripTop = New-Object System.Windows.Forms.Panel
$stripTop.Dock      = "Top"
$stripTop.Height    = 84
$stripTop.BackColor = [System.Drawing.SystemColors]::Control
$stripTop.Padding   = New-Object System.Windows.Forms.Padding(10, 8, 10, 6)

$lblSelected = New-Object System.Windows.Forms.Label
$lblSelected.Text = $L.SelectedCollection; $lblSelected.AutoSize = $true
$lblSelected.Location = New-Object System.Drawing.Point(10, 13)

$txtSelected = New-Object System.Windows.Forms.TextBox
$txtSelected.Location  = New-Object System.Drawing.Point(168, 10)
$txtSelected.Width     = 462
$txtSelected.ReadOnly  = $true
$txtSelected.BackColor = [System.Drawing.SystemColors]::Window
$txtSelected.Text      = if ($script:ActiveCollectionName) { "$($script:ActiveCollectionName)  [$($script:ActiveCollectionID)]" } else { $L.NoCollSelected }

$btnPickColl = New-Object System.Windows.Forms.Button
$btnPickColl.Text     = "..."
$btnPickColl.Location = New-Object System.Drawing.Point(638, 10)
$btnPickColl.Size     = New-Object System.Drawing.Size(36, 26)
$btnPickColl.Font     = New-Object System.Drawing.Font("Segoe UI", 8)

$lblPat1 = New-Object System.Windows.Forms.Label
$lblPat1.Text = $L.LblRequired; $lblPat1.AutoSize = $true
$lblPat1.Location = New-Object System.Drawing.Point(10, 46)

$txtPatReq = New-Object System.Windows.Forms.TextBox
$txtPatReq.Location = New-Object System.Drawing.Point(68, 43); $txtPatReq.Width = 220
$txtPatReq.Text = $PatternRequired

$lblPat2 = New-Object System.Windows.Forms.Label
$lblPat2.Text = $L.LblAvailable; $lblPat2.AutoSize = $true
$lblPat2.Location = New-Object System.Drawing.Point(298, 46)

$txtPatAvl = New-Object System.Windows.Forms.TextBox
$txtPatAvl.Location = New-Object System.Drawing.Point(370, 43); $txtPatAvl.Width = 220
$txtPatAvl.Text = $PatternAvailable

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = $L.BtnLoad; $btnLoad.Location = New-Object System.Drawing.Point(600, 41)
$btnLoad.Size = New-Object System.Drawing.Size(80, 26)

$stripTop.Controls.AddRange(@($lblSelected, $txtSelected, $btnPickColl, $lblPat1, $txtPatReq, $lblPat2, $txtPatAvl, $btnLoad))

# --- Bottom strip ---
$stripBottom = New-Object System.Windows.Forms.Panel
$stripBottom.Dock = "Bottom"; $stripBottom.Height = 50
$stripBottom.BackColor = [System.Drawing.SystemColors]::Control

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false; $lblStatus.Location = New-Object System.Drawing.Point(10, 16)
$lblStatus.Width = 600; $lblStatus.ForeColor = [System.Drawing.SystemColors]::GrayText

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = $L.BtnSave; $btnSave.Size = New-Object System.Drawing.Size(110, 28)
$btnSave.Anchor = "Right,Bottom"; $btnSave.Enabled = $false

$stripBottom.Controls.AddRange(@($lblStatus, $btnSave))
$stripBottom.Add_Resize({
    $btnSave.Location = New-Object System.Drawing.Point(
        ($stripBottom.ClientSize.Width - $btnSave.Width - 10), 11)
    $lblStatus.Width = $stripBottom.ClientSize.Width - $btnSave.Width - 30
})

$separator = New-Object System.Windows.Forms.Panel
$separator.Dock = "Bottom"; $separator.Height = 1
$separator.BackColor = [System.Drawing.SystemColors]::ControlDark

# --- TabControl ---
$tabCtrl = New-Object System.Windows.Forms.TabControl
$tabCtrl.Dock = "Fill"
$tabCtrl.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tabReq = New-Object System.Windows.Forms.TabPage
$tabReq.Text = $L.TabRequired; $tabReq.Padding = New-Object System.Windows.Forms.Padding(0)
$tabReq.UseVisualStyleBackColor = $true

$tabAvl = New-Object System.Windows.Forms.TabPage
$tabAvl.Text = $L.TabAvailable; $tabAvl.Padding = New-Object System.Windows.Forms.Padding(0)
$tabAvl.UseVisualStyleBackColor = $true

$tabReq.Controls.Add((New-MembershipPanel -TD $script:tabData.req))
$tabAvl.Controls.Add((New-MembershipPanel -TD $script:tabData.avl))
$tabCtrl.TabPages.AddRange(@($tabReq, $tabAvl))

$form.Controls.Add($tabCtrl)
$form.Controls.Add($separator)
$form.Controls.Add($stripBottom)
$form.Controls.Add($stripTop)
#endregion

#region Collection picker
$btnPickColl.Add_Click({
    # CM-Verbindung herstellen falls noch nicht geschehen
    if (-not $script:SiteCode) {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $script:SiteCode = Initialize-CMConnection -SC $SiteCode
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                ($L.CmConnectFailed -f $_.Exception.Message), $L.TitleError, "OK", "Error")
            return
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    } else {
        Set-Location "$($script:SiteCode)`:" -ErrorAction SilentlyContinue
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = $L.PickTitle
    $dlg.ClientSize      = New-Object System.Drawing.Size(544, 404)
    $dlg.StartPosition   = "CenterParent"
    $dlg.MinimizeBox     = $false; $dlg.MaximizeBox = $false
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.Font            = $form.Font

    $lblSrch = New-Object System.Windows.Forms.Label
    $lblSrch.Text = $L.SearchTerm; $lblSrch.AutoSize = $true
    $lblSrch.Location = New-Object System.Drawing.Point(10, 12)

    $txtSrch = New-Object System.Windows.Forms.TextBox
    $txtSrch.Location = New-Object System.Drawing.Point(10, 32); $txtSrch.Width = 430

    $btnSrch = New-Object System.Windows.Forms.Button
    $btnSrch.Text = $L.BtnSearch
    $btnSrch.Location = New-Object System.Drawing.Point(448, 30)
    $btnSrch.Size = New-Object System.Drawing.Size(85, 26)

    $lbRes = New-Object System.Windows.Forms.ListBox
    $lbRes.Location = New-Object System.Drawing.Point(10, 66)
    $lbRes.Size = New-Object System.Drawing.Size(523, 290)
    $lbRes.ScrollAlwaysVisible = $true; $lbRes.IntegralHeight = $false

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $L.BtnSelect; $btnOk.DialogResult = "OK"
    $btnOk.Location = New-Object System.Drawing.Point(344, 366); $btnOk.Size = New-Object System.Drawing.Size(90, 28)
    $btnOk.Enabled = $false

    $btnCncl = New-Object System.Windows.Forms.Button
    $btnCncl.Text = $L.BtnCancel; $btnCncl.DialogResult = "Cancel"
    $btnCncl.Location = New-Object System.Drawing.Point(442, 366); $btnCncl.Size = New-Object System.Drawing.Size(90, 28)

    $dlg.Controls.AddRange(@($lblSrch, $txtSrch, $btnSrch, $lbRes, $btnOk, $btnCncl))
    $dlg.CancelButton = $btnCncl

    $script:_pickerCols = @()

    $doPickSearch = {
        $q = $txtSrch.Text.Trim(); if (-not $q) { return }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Set-Location "$($script:SiteCode)`:" -ErrorAction Stop
            $filter = if ($q -eq '*') { '*' } else { "*$q*" }
            $found  = Get-CMDeviceCollection -Name $filter -ErrorAction Stop | Sort-Object Name
            $script:_pickerCols = @($found)
            $lbRes.Items.Clear()
            if ($script:_pickerCols.Count -eq 0) {
                [void]$lbRes.Items.Add($L.NoResults)
            } else {
                foreach ($c in $script:_pickerCols) {
                    [void]$lbRes.Items.Add("$($c.Name)  [$($c.CollectionID)]")
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                ($L.SearchFailed -f $_.Exception.Message), $L.TitleError, "OK", "Error")
        } finally {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $txtSrch.Text = "rol-dev"
    $dlg.Add_Shown({ & $doPickSearch })

    $btnSrch.Add_Click($doPickSearch)
    $txtSrch.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { & $doPickSearch } })
    $lbRes.Add_SelectedIndexChanged({
        $btnOk.Enabled = ($lbRes.SelectedIndex -ge 0 -and
                          $lbRes.SelectedItem  -ne $L.NoResults)
    })
    $lbRes.Add_DoubleClick({
        if ($lbRes.SelectedIndex -ge 0 -and $lbRes.SelectedItem -ne $L.NoResults) {
            $dlg.DialogResult = "OK"; $dlg.Close()
        }
    })

    if ($dlg.ShowDialog($form) -eq 'OK' -and $lbRes.SelectedIndex -ge 0) {
        $sel = $script:_pickerCols[$lbRes.SelectedIndex]
        $script:ActiveCollectionID   = $sel.CollectionID
        $script:ActiveCollectionName = $sel.Name
        $txtSelected.Text = "$($sel.Name)  [$($sel.CollectionID)]"
        $form.Text = $L.FormTitle -f $sel.Name
        $btnLoad.PerformClick()
    }
})
#endregion

#region Load
$btnLoad.Add_Click({
    if (-not $script:ActiveCollectionID) {
        [System.Windows.Forms.MessageBox]::Show(
            $L.NoCollLoad, $L.TitleWarning, "OK", "Warning")
        return
    }
    $patReq = $txtPatReq.Text.Trim()
    $patAvl = $txtPatAvl.Text.Trim()
    if (-not $patReq -and -not $patAvl) {
        [System.Windows.Forms.MessageBox]::Show($L.NeedPattern, $L.TitleWarning, "OK", "Warning")
        return
    }

    $btnSave.Enabled = $false
    foreach ($td in $script:tabData.Values) { foreach ($b in $td.Buttons) { $b.Enabled = $false } }
    $form.Cursor    = [System.Windows.Forms.Cursors]::WaitCursor
    $lblStatus.Text = $L.StatusConnecting
    $form.Update()

    try {
        if (-not $script:SiteCode) {
            $script:SiteCode = Initialize-CMConnection -SC $SiteCode
        } else {
            Set-Location "$($script:SiteCode)`:" -ErrorAction Stop
        }

        $script:tabData.req.Pattern = $patReq
        $script:tabData.avl.Pattern = $patAvl

        $totalCols   = 0
        $totalMember = 0

        foreach ($key in @('req', 'avl')) {
            $TD  = $script:tabData[$key]
            $pat = $TD.Pattern
            if (-not $pat) { continue }

            $lblStatus.Text = $L.StatusLoading -f $pat
            $form.Update()

            $cols = @(Get-CMDeviceCollection -Name $pat -ErrorAction Stop |
                      Where-Object { $_.CollectionID -ne $script:ActiveCollectionID } |
                      Sort-Object Name)

            $TD.LeftItems.Clear()
            $TD.RightItems.Clear()
            $TD.OriginalRightIDs.Clear()

            $n = $cols.Count; $i = 0
            foreach ($col in $cols) {
                $i++
                if ($i % 5 -eq 0 -or $i -eq 1) {
                    $lblStatus.Text = $L.StatusChecking -f $pat, $i, $n
                    $form.Update()
                }
                $rule  = Get-CMCollectionIncludeMembershipRule `
                             -CollectionId        $col.CollectionID `
                             -IncludeCollectionId $script:ActiveCollectionID `
                             -ErrorAction SilentlyContinue
                $entry = fnNewEntry $col
                if ($rule) {
                    $TD.RightItems.Add($entry)
                    [void]$TD.OriginalRightIDs.Add($col.CollectionID)
                } else {
                    $TD.LeftItems.Add($entry)
                }
            }

            fnRefresh $TD.LbLeft  $TD.LeftItems
            fnRefresh $TD.LbRight $TD.RightItems
            $totalCols   += $n
            $totalMember += $TD.RightItems.Count
        }

        $tabReq.Text     = "$($L.TabRequired)  ($($script:tabData.req.RightItems.Count))"
        $tabAvl.Text     = "$($L.TabAvailable)  ($($script:tabData.avl.RightItems.Count))"
        $btnSave.Enabled = $true
        foreach ($td in $script:tabData.Values) { foreach ($b in $td.Buttons) { $b.Enabled = $true } }
        $lblStatus.Text  = $L.StatusLoaded -f $totalCols, $totalMember
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            ($L.LoadFailed -f $_.Exception.Message), $L.TitleError, "OK", "Error")
        $lblStatus.Text = $L.LoadFailedShort
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$txtPatReq.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $btnLoad.PerformClick() } })
$txtPatAvl.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $btnLoad.PerformClick() } })
#endregion

#region Save
$btnSave.Add_Click({
    $allToAdd    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allToRemove = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($key in @('req', 'avl')) {
        $TD = $script:tabData[$key]
        foreach ($i in $TD.RightItems) { if (-not $TD.OriginalRightIDs.Contains($i.CollectionID)) { $allToAdd.Add($i) } }
        foreach ($i in $TD.LeftItems)  { if (     $TD.OriginalRightIDs.Contains($i.CollectionID)) { $allToRemove.Add($i) } }
    }

    if ($allToAdd.Count -eq 0 -and $allToRemove.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($L.NoChanges, $L.TitleSave, "OK", "Information")
        return
    }

    $msg = $L.SaveConfirm -f $script:ActiveCollectionName
    if ($allToAdd.Count    -gt 0) { $msg += $L.SaveAdd    -f $allToAdd.Count }
    if ($allToRemove.Count -gt 0) { $msg += $L.SaveRemove -f $allToRemove.Count }
    if ([System.Windows.Forms.MessageBox]::Show($msg, $L.TitleConfirm, "YesNo", "Question") -ne 'Yes') { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $errs = [System.Collections.Generic.List[string]]::new()
    try {
        Set-Location "$($script:SiteCode)`:" -ErrorAction Stop
        foreach ($item in $allToAdd) {
            try {
                Add-CMDeviceCollectionIncludeMembershipRule `
                    -CollectionId        $item.CollectionID `
                    -IncludeCollectionId $script:ActiveCollectionID `
                    -ErrorAction Stop
            } catch { $errs.Add("+ $($item.CollectionName): $($_.Exception.Message)") }
        }
        foreach ($item in $allToRemove) {
            try {
                Remove-CMDeviceCollectionIncludeMembershipRule `
                    -CollectionId        $item.CollectionID `
                    -IncludeCollectionId $script:ActiveCollectionID `
                    -Force `
                    -ErrorAction Stop
            } catch { $errs.Add("- $($item.CollectionName): $($_.Exception.Message)") }
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    if ($errs.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            ($L.SaveErrors -f ($errs -join "`n")), $L.TitleWarning, "OK", "Warning")
    } else {
        [System.Windows.Forms.MessageBox]::Show($L.SaveOk, $L.TitleSaved, "OK", "Information")
    }

    foreach ($key in @('req', 'avl')) {
        $TD = $script:tabData[$key]
        $TD.OriginalRightIDs.Clear()
        foreach ($i in $TD.RightItems) { [void]$TD.OriginalRightIDs.Add($i.CollectionID) }
    }
    $tabReq.Text    = "$($L.TabRequired)  ($($script:tabData.req.RightItems.Count))"
    $tabAvl.Text    = "$($L.TabAvailable)  ($($script:tabData.avl.RightItems.Count))"
    $lblStatus.Text = $L.StatusSaved -f ($allToAdd.Count + $allToRemove.Count)
})
#endregion

$form.Add_Shown({ if ($script:ActiveCollectionID) { $btnLoad.PerformClick() } })

[void]$form.ShowDialog()
$form.Dispose()
