<#
.SYNOPSIS
    AZITC Toolkit - per-device window for the Configuration Manager console.

.DESCRIPTION
    Windows PowerShell 5.1, WPF, one file. Opened by the console extension with the selected
    device, or by hand. Tabs:

      Software (ARP)  installed software of the device with search, sort, Inspect / Uninstall /
                      Repair / Uninstall + re-evaluate, and the ConfigMgr application list
      Logs            tail of a client log (AppEnforce.log, AppDiscovery.log, ...)
      Client          client notifications (policy, evaluations, inventories) and the toolkit's
                      client-action script

    Everything that reaches the client goes through the AdminService on the SMS Provider - Run
    Scripts for data and actions, client notifications for the schedules. All calls run in a
    background runspace; the window polls it with a DispatcherTimer and never blocks.

.PARAMETER DeviceName
    Name of the device (##SUB:Name## from the console).
.PARAMETER ResourceId
    ResourceId of the device (##SUB:ResourceID##). Resolved from the name when 0.
.PARAMETER SmsProvider
    FQDN of the SMS Provider (##SUB:__Server##).
.PARAMETER SiteCode
    Site code (##SUB:SiteCode##), shown in the title only.
.PARAMETER SkipCertificateCheck
    Accept the provider's self-signed AdminService certificate.
.PARAMETER SelfTest
    No window: connect, load the software list, print a summary, exit. For automated checks.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
#>

[CmdletBinding()]
param(
    [string]$DeviceName = '',
    [int]$ResourceId = 0,
    [Parameter(Mandatory = $true)][string]$SmsProvider,
    [string]$SiteCode = '',
    [switch]$SkipCertificateCheck,
    [switch]$SelfTest,
    [int]$AutoCloseSeconds = 0          # smoke tests: close the window after n seconds
)

$ErrorActionPreference = 'Stop'
$toolVersion = '0.1'
$libraryPath = Join-Path -Path $PSScriptRoot -ChildPath 'AZITC-TK-AdminService.ps1'
if (-not (Test-Path -LiteralPath $libraryPath)) { throw "Library not found: $libraryPath" }
if (-not $DeviceName -and $ResourceId -eq 0) { throw 'Give -DeviceName or -ResourceId.' }

# ============================================================================
# Background runspace: the library lives there, connected once. Every call the window makes is
# a scriptblock handed to Invoke-TKJob; the timer collects the result on the UI thread.
# ============================================================================

$script:Runspace = [runspacefactory]::CreateRunspace()
$script:Runspace.ApartmentState = 'MTA'
$script:Runspace.ThreadOptions = 'ReuseThread'
$script:Runspace.Open()
$script:Runspace.SessionStateProxy.SetVariable('TKLibraryPath', $libraryPath)
$script:Runspace.SessionStateProxy.SetVariable('TKSmsProvider', $SmsProvider)
$script:Runspace.SessionStateProxy.SetVariable('TKSkipCert', [bool]$SkipCertificateCheck)

$script:Job = $null          # @{ PowerShell; Handle; Name; Started; OnDone }

function Invoke-TKJob {
    <#
    .SYNOPSIS
        Starts one scriptblock in the background runspace. $OnDone receives a result object
        @{ Ok; Value; Error; Seconds } on the UI thread when it finishes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [object[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][scriptblock]$OnDone
    )
    if ($script:Job) { throw "A job is still running: $($script:Job.Name)" }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Runspace
    # Global scope of the runspace: the library dot-sourced by the first job stays for the rest.
    $null = $ps.AddScript($Script.ToString(), $false)
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
    $script:Job = @{
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Name       = $Name
        Started    = Get-Date
        OnDone     = $OnDone
    }
}

function Complete-TKJob {
    # Called by the timer; returns $true when a job was finished and handled.
    if (-not $script:Job) { return $false }
    if (-not $script:Job.Handle.IsCompleted) { return $false }
    $job = $script:Job
    $script:Job = $null
    $result = @{ Ok = $false; Value = $null; Error = ''; Seconds = [int]((Get-Date) - $job.Started).TotalSeconds; Name = $job.Name }
    try {
        $out = $job.PowerShell.EndInvoke($job.Handle)
        if ($job.PowerShell.Streams.Error.Count -gt 0) {
            $result.Error = ($job.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
        } else {
            $result.Ok = $true
            if ($out.Count -eq 1) { $result.Value = $out[0] } else { $result.Value = @($out) }
        }
    } catch {
        $result.Error = $_.Exception.Message
        if ($_.Exception.InnerException) { $result.Error = $_.Exception.InnerException.Message }
    } finally {
        $job.PowerShell.Dispose()
    }
    try { & $job.OnDone $result } catch { $ui.StatusText.Text = "Handler error ($($job.Name)): $($_.Exception.Message)"; $script:LastHandlerError = $_.Exception.Message + " at " + $_.InvocationInfo.PositionMessage }
    return $true
}

# The first job: load the library, connect, resolve the device.
$connectScript = {
    param($DeviceName, $ResourceId)
    . $TKLibraryPath
    if ($TKSkipCert) { Connect-TKAdminService -SmsProvider $TKSmsProvider -SkipCertificateCheck } else { Connect-TKAdminService -SmsProvider $TKSmsProvider }
    if ($ResourceId -gt 0) {
        $r = Invoke-TKRest -Method Get -Path "Device?`$filter=MachineId eq $ResourceId"
        $d = @($r.value)
        if ($d.Count -eq 0) { throw "ResourceId $ResourceId not found." }
        $dev = $d[0]
    } else {
        $dev = Get-TKDevice -Name $DeviceName
    }
    # Script GUIDs by name, once; warn about approval here so the window can show it.
    $scripts = @{}
    foreach ($n in 'AZITC-TK-Software-Get', 'AZITC-TK-Software-Action', 'AZITC-TK-Log-Get', 'AZITC-TK-Client-Action') {
        try { $s = Get-TKScript -Name $n -WarningAction SilentlyContinue; $scripts[$n] = "$($s.ScriptGuid) v$($s.ScriptVersion) approval=$($s.ApprovalState)" } catch { $scripts[$n] = "missing: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        Name          = [string]$dev.Name
        ResourceId    = [int]$dev.MachineId
        ClientVersion = [string]$dev.ClientVersion
        Online        = [string]$dev.CNIsOnline
        LastOnline    = [string]$dev.CNLastOnlineTime
        Scripts       = $scripts
    }
}

$softwareScript = {
    param($DeviceName)
    Get-TKSoftware -DeviceName $DeviceName
}

$actionScript = {
    param($DeviceName, $Action, $Key, $ExtraArgs, $KillRunning, $ReEvaluate)
    Invoke-TKSoftwareAction -DeviceName $DeviceName -Action $Action -Key $Key -ExtraArgs $ExtraArgs -KillRunning:$KillRunning -ReEvaluate:$ReEvaluate
}

$logScript = {
    param($DeviceName, $LogName, $Lines, $Pattern)
    Get-TKLog -DeviceName $DeviceName -LogName $LogName -Lines $Lines -Pattern $Pattern
}

$notifyScript = {
    param($ResourceId, $Action)
    Send-TKClientNotification -ResourceId $ResourceId -Action $Action
}

$clientActionScript = {
    param($ResourceId, $Action)
    $scr = Get-TKScript -Name 'AZITC-TK-Client-Action'
    $res = Invoke-TKScript -ResourceId $ResourceId -Script $scr -Parameters @{ Action = $Action } -TimeoutSec 240
    $parsed = $null
    try { $parsed = $res.Output | ConvertFrom-Json } catch { }
    [pscustomobject]@{ OperationId = $res.OperationId; State = $res.State; ExitCode = $res.ExitCode; Result = $parsed; Raw = $res.Output }
}

# ============================================================================
# Self test: no window.
# ============================================================================

if ($SelfTest) {
    $ps = [powershell]::Create(); $ps.Runspace = $script:Runspace
    $null = $ps.AddScript($connectScript.ToString(), $false).AddArgument($DeviceName).AddArgument($ResourceId)
    $dev = $ps.Invoke()[0]; $ps.Dispose()
    "device: $($dev.Name) ($($dev.ResourceId)) client $($dev.ClientVersion) online=$($dev.Online)"
    foreach ($k in $dev.Scripts.Keys | Sort-Object) { "  $k -> $($dev.Scripts[$k])" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ps = [powershell]::Create(); $ps.Runspace = $script:Runspace
    $null = $ps.AddScript($softwareScript.ToString(), $false).AddArgument($dev.Name)
    $sw2 = $ps.Invoke()[0]; $ps.Dispose()
    "software: $($sw2.Items.Count) entries, $($sw2.Apps.Count) apps, $([int]$sw.Elapsed.TotalSeconds) s, op $($sw2.OperationId)"
    $script:Runspace.Close()
    exit 0
}

# ============================================================================
# Window
# ============================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Data

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AZITC Toolkit" Width="1280" Height="800" MinWidth="900" MinHeight="560"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="MinWidth" Value="90"/>
    </Style>
    <Style TargetType="TextBox" x:Key="Mono">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <!-- header -->
    <Border DockPanel.Dock="Top" Background="#F3F3F3" Padding="10,6" BorderBrush="#DDDDDD" BorderThickness="0,0,0,1">
      <DockPanel>
        <TextBlock x:Name="HeaderDevice" FontSize="16" FontWeight="SemiBold" Text="..." VerticalAlignment="Center"/>
        <TextBlock x:Name="HeaderInfo" Margin="16,0,0,0" Foreground="#555555" VerticalAlignment="Center" Text=""/>
      </DockPanel>
    </Border>
    <!-- status bar -->
    <StatusBar DockPanel.Dock="Bottom" Height="26">
      <StatusBarItem><TextBlock x:Name="StatusText" Text="Connecting..."/></StatusBarItem>
      <Separator/>
      <StatusBarItem><TextBlock x:Name="StatusOperation" Text=""/></StatusBarItem>
      <Separator/>
      <StatusBarItem><TextBlock x:Name="StatusElapsed" Text=""/></StatusBarItem>
      <StatusBarItem HorizontalAlignment="Right"><ProgressBar x:Name="StatusProgress" Width="120" Height="12" IsIndeterminate="False" Visibility="Hidden"/></StatusBarItem>
    </StatusBar>
    <TabControl x:Name="Tabs" Margin="8">
      <!-- ================= Software ================= -->
      <TabItem Header="Software (ARP)">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="3*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="SearchBox" Width="240" VerticalContentAlignment="Center" Margin="0,0,12,0"/>
            <Button x:Name="BtnRefresh" Content="Refresh"/>
            <Button x:Name="BtnInspect" Content="Inspect" IsEnabled="False"/>
            <Button x:Name="BtnUninstall" Content="Uninstall" IsEnabled="False"/>
            <Button x:Name="BtnUninstallReEval" Content="Uninstall + re-evaluate" IsEnabled="False"/>
            <Button x:Name="BtnRepair" Content="Repair" IsEnabled="False"/>
            <CheckBox x:Name="ChkKill" Content="Kill running processes first" VerticalAlignment="Center" Margin="6,0,12,0"/>
            <TextBlock Text="Extra args:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="ExtraArgs" MinWidth="160" VerticalContentAlignment="Center"/>
          </DockPanel>
          <DataGrid Grid.Row="1" x:Name="GridSoftware" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single"
                    CanUserSortColumns="True" CanUserReorderColumns="True" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                    AlternatingRowBackground="#FAFAFA" RowHeight="22">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="3*"/>
              <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="120"/>
              <DataGridTextColumn Header="Publisher" Binding="{Binding Publisher}" Width="2*"/>
              <DataGridTextColumn Header="Installed" Binding="{Binding InstallDate}" Width="80"/>
              <DataGridTextColumn Header="Scope" Binding="{Binding Scope}" Width="70"/>
              <DataGridTextColumn Header="Arch" Binding="{Binding Arch}" Width="45"/>
              <DataGridTextColumn Header="MSI" Binding="{Binding IsMsi}" Width="40"/>
              <DataGridTextColumn Header="Quiet" Binding="{Binding HasQuietString}" Width="45"/>
              <DataGridTextColumn Header="Repair" Binding="{Binding RepairPossible}" Width="50"/>
              <DataGridTextColumn Header="MB" Binding="{Binding SizeMB}" Width="55"/>
              <DataGridTextColumn Header="CM application (heuristic match)" Binding="{Binding CMApp}" Width="2*"/>
            </DataGrid.Columns>
          </DataGrid>
          <GridSplitter Grid.Row="2" Height="5" HorizontalAlignment="Stretch" Background="#DDDDDD"/>
          <TabControl Grid.Row="3" x:Name="LowerTabs">
            <TabItem Header="Action result">
              <TextBox x:Name="ActionResult" Style="{StaticResource Mono}" Text=""/>
            </TabItem>
            <TabItem Header="ConfigMgr applications on this device">
              <DataGrid x:Name="GridApps" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" CanUserSortColumns="True"
                        HeadersVisibility="Column" GridLinesVisibility="Horizontal" AlternatingRowBackground="#FAFAFA" RowHeight="22">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Application" Binding="{Binding Name}" Width="3*"/>
                  <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="140"/>
                  <DataGridTextColumn Header="Install state" Binding="{Binding InstallState}" Width="100"/>
                  <DataGridTextColumn Header="Resolved" Binding="{Binding ResolvedState}" Width="90"/>
                  <DataGridTextColumn Header="Eval" Binding="{Binding EvaluationState}" Width="45"/>
                  <DataGridTextColumn Header="Deadline (UTC)" Binding="{Binding Deadline}" Width="140"/>
                  <DataGridTextColumn Header="Allowed" Binding="{Binding AllowedActions}" Width="140"/>
                  <DataGridTextColumn Header="Publisher" Binding="{Binding Publisher}" Width="2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </TabItem>
          </TabControl>
        </Grid>
      </TabItem>
      <!-- ================= Logs ================= -->
      <TabItem Header="Logs">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <TextBlock Text="Log:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <ComboBox x:Name="LogName" Width="260" IsEditable="True" Margin="0,0,12,0"/>
            <TextBlock Text="Lines:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="LogLines" Width="50" Text="100" VerticalContentAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock Text="Pattern (regex):" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="LogPattern" Width="200" VerticalContentAlignment="Center" Margin="0,0,12,0"/>
            <Button x:Name="BtnLog" Content="Get log"/>
            <TextBlock x:Name="LogInfo" VerticalAlignment="Center" Foreground="#555555" Margin="12,0,0,0"/>
          </DockPanel>
          <TextBox Grid.Row="1" x:Name="LogText" Style="{StaticResource Mono}" Text=""/>
        </Grid>
      </TabItem>
      <!-- ================= Client ================= -->
      <TabItem Header="Client">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <GroupBox Grid.Row="0" Header="Client notification (push over the notification channel, seconds, no result beyond the operation)" Padding="6" Margin="0,0,0,8">
            <WrapPanel>
              <Button x:Name="BtnNotifyPolicy" Content="Machine policy" Tag="MachinePolicy"/>
              <Button x:Name="BtnNotifyAppEval" Content="App deployment evaluation" Tag="AppDeploymentEval"/>
              <Button x:Name="BtnNotifySumEval" Content="Update deployment evaluation" Tag="SoftwareUpdateEval"/>
              <Button x:Name="BtnNotifyHwInv" Content="Hardware inventory" Tag="HardwareInventory"/>
              <Button x:Name="BtnNotifySwInv" Content="Software inventory" Tag="SoftwareInventory"/>
              <Button x:Name="BtnNotifyDdr" Content="Discovery data" Tag="DiscoveryData"/>
              <Button x:Name="BtnNotifyCompliance" Content="Check compliance" Tag="CheckCompliance"/>
            </WrapPanel>
          </GroupBox>
          <GroupBox Grid.Row="1" Header="Client-action script (Run Script, ~1 min, reports which schedules fired)" Padding="6" Margin="0,0,0,8">
            <WrapPanel>
              <Button x:Name="BtnScriptPolicy" Content="Machine policy" Tag="MachinePolicy"/>
              <Button x:Name="BtnScriptAppEval" Content="App deployment evaluation" Tag="AppDeploymentEval"/>
              <Button x:Name="BtnScriptAll" Content="Policy, then app evaluation" Tag="All"/>
              <Button x:Name="BtnScriptHwInv" Content="Hardware inventory" Tag="HardwareInventory"/>
              <Button x:Name="BtnScriptSwInv" Content="Software inventory" Tag="SoftwareInventory"/>
              <Button x:Name="BtnScriptUpdScan" Content="Update scan" Tag="SoftwareUpdateScan"/>
            </WrapPanel>
          </GroupBox>
          <TextBox Grid.Row="2" x:Name="ClientText" Style="{StaticResource Mono}" Text=""/>
        </Grid>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $window.FindName($name) }
}

$titleSite = ''
if ($SiteCode) { $titleSite = " [$SiteCode]" }
$window.Title = "AZITC Toolkit $toolVersion - $DeviceName$titleSite - $SmsProvider"
$ui.HeaderDevice.Text = $DeviceName
foreach ($n in 'AppEnforce.log', 'AppDiscovery.log', 'AppIntentEval.log', 'CAS.log', 'ContentTransferManager.log', 'DataTransferService.log', 'PolicyAgent.log', 'CcmExec.log', 'ClientIDManagerStartup.log', 'ccmnotificationagent.log', 'Scripts.log', 'UpdatesDeployment.log', 'WUAHandler.log', 'C:\Windows\Logs\Software\*') { $null = $ui.LogName.Items.Add($n) }
$ui.LogName.SelectedIndex = 0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:Device = $null
$script:SoftwareTable = $null
$script:AppsTable = $null
$script:Busy = $true
$script:Actionable = @($ui.BtnRefresh, $ui.BtnInspect, $ui.BtnUninstall, $ui.BtnUninstallReEval, $ui.BtnRepair, $ui.BtnLog,
    $ui.BtnNotifyPolicy, $ui.BtnNotifyAppEval, $ui.BtnNotifySumEval, $ui.BtnNotifyHwInv, $ui.BtnNotifySwInv, $ui.BtnNotifyDdr, $ui.BtnNotifyCompliance,
    $ui.BtnScriptPolicy, $ui.BtnScriptAppEval, $ui.BtnScriptAll, $ui.BtnScriptHwInv, $ui.BtnScriptSwInv, $ui.BtnScriptUpdScan)

function Set-Busy {
    param([bool]$On, [string]$Text = '')
    $script:Busy = $On
    foreach ($b in $script:Actionable) { $b.IsEnabled = -not $On }
    if ($On) {
        $ui.StatusText.Text = $Text
        $ui.StatusProgress.IsIndeterminate = $true
        $ui.StatusProgress.Visibility = 'Visible'
        $ui.StatusElapsed.Text = '0 s'
    } else {
        $ui.StatusProgress.IsIndeterminate = $false
        $ui.StatusProgress.Visibility = 'Hidden'
        Update-SelectionButtons
    }
}

function Update-SelectionButtons {
    # Uninstall/Repair only for machine-scope entries; the script refuses per-user entries anyway.
    $row = $ui.GridSoftware.SelectedItem
    $has = ($null -ne $row) -and (-not $script:Busy)
    $ui.BtnInspect.IsEnabled = $has
    $machine = $false
    $tip = $null
    if ($has) {
        $machine = ([string]$row.Row['Scope'] -eq 'Machine')
        if (-not $machine) { $tip = 'Per-user installation - cannot be handled from the SYSTEM context of a Run Script.' }
    }
    foreach ($b in @($ui.BtnUninstall, $ui.BtnUninstallReEval, $ui.BtnRepair)) {
        $b.IsEnabled = $has -and $machine
        $b.ToolTip = $tip
    }
    if ($has -and $machine -and -not [bool]$row.Row['RepairPossible']) { $ui.BtnRepair.ToolTip = 'The entry has NoRepair or NoModify set; Repair works for MSI products only.' }
}

function Show-Error {
    param([string]$Text)
    $ui.StatusText.Text = 'Error'
    [System.Windows.MessageBox]::Show($window, $Text, 'AZITC Toolkit', 'OK', 'Error') | Out-Null
}

function Format-Result {
    # Key: value lines for the action result pane, arrays indented.
    param($Object, [string[]]$Skip = @())
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $Object.PSObject.Properties) {
        if ($Skip -contains $p.Name) { continue }
        $v = $p.Value
        if ($null -eq $v) { $v = '' }
        if ($v -is [System.Array]) {
            $null = $sb.AppendLine(('{0,-20} ({1})' -f $p.Name, $v.Count))
            foreach ($e in $v) {
                if ($e -is [string] -or $e -is [ValueType]) { $null = $sb.AppendLine('    ' + [string]$e) }
                else { $null = $sb.AppendLine('    ' + (($e.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')) }
            }
        } else {
            $null = $sb.AppendLine(('{0,-20} {1}' -f $p.Name, [string]$v))
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Software list -> DataTable, with the heuristic CM application match
# ---------------------------------------------------------------------------

function ConvertTo-SoftwareTables {
    param($Software)
    $t = New-Object System.Data.DataTable 'Software'
    foreach ($c in 'Name', 'Version', 'Publisher', 'InstallDate', 'Scope', 'Arch', 'Key', 'CMApp') { $null = $t.Columns.Add($c, [string]) }
    foreach ($c in 'IsMsi', 'HasQuietString', 'HasUninstall', 'RepairPossible') { $null = $t.Columns.Add($c, [bool]) }
    $null = $t.Columns.Add('SizeMB', [double])

    $apps = @($Software.Apps)
    foreach ($i in $Software.Items) {
        $r = $t.NewRow()
        $r['Name'] = [string]$i.Name; $r['Version'] = [string]$i.Version; $r['Publisher'] = [string]$i.Publisher
        $r['InstallDate'] = [string]$i.InstallDate; $r['Scope'] = [string]$i.Scope; $r['Arch'] = [string]$i.Arch; $r['Key'] = [string]$i.Key
        $r['IsMsi'] = [bool]$i.IsMsi; $r['HasQuietString'] = [bool]$i.HasQuietString; $r['HasUninstall'] = [bool]$i.HasUninstall; $r['RepairPossible'] = [bool]$i.RepairPossible
        $r['SizeMB'] = [double]$i.SizeMB
        # Heuristic: the ARP name starts with the application's name (or the other way round),
        # longest application name wins. Labelled as such in the column header.
        $best = $null
        foreach ($a in $apps) {
            $an = [string]$a.N
            if (-not $an) { continue }
            $n = [string]$i.Name
            if ($n.StartsWith($an, [System.StringComparison]::OrdinalIgnoreCase) -or $an.StartsWith($n, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($null -eq $best -or $an.Length -gt ([string]$best.N).Length) { $best = $a }
            }
        }
        if ($best) { $r['CMApp'] = '{0} {1} - {2}/{3}' -f $best.N, $best.SV, $best.IS, $best.RS } else { $r['CMApp'] = '' }
        $t.Rows.Add($r)
    }

    $a2 = New-Object System.Data.DataTable 'Apps'
    foreach ($c in 'Name', 'Version', 'InstallState', 'ResolvedState', 'Deadline', 'AllowedActions', 'Publisher', 'Id') { $null = $a2.Columns.Add($c, [string]) }
    $null = $a2.Columns.Add('EvaluationState', [int])
    foreach ($a in $apps) {
        $r = $a2.NewRow()
        $r['Name'] = [string]$a.N; $r['Version'] = [string]$a.SV; $r['InstallState'] = [string]$a.IS; $r['ResolvedState'] = [string]$a.RS
        $r['Deadline'] = [string]$a.DL; $r['AllowedActions'] = (@($a.AA) -join ', '); $r['Publisher'] = [string]$a.Pub; $r['Id'] = [string]$a.Id
        $r['EvaluationState'] = [int]$a.ES
        $a2.Rows.Add($r)
    }
    return @{ Software = $t; Apps = $a2 }
}

function Apply-Filter {
    if (-not $script:SoftwareTable) { return }
    $text = $ui.SearchBox.Text
    $view = $script:SoftwareTable.DefaultView
    if ([string]::IsNullOrWhiteSpace($text)) { $view.RowFilter = ''; return }
    $esc = $text.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]')
    $view.RowFilter = "Name LIKE '%$esc%' OR Publisher LIKE '%$esc%' OR Version LIKE '%$esc%' OR CMApp LIKE '%$esc%'"
}

# ---------------------------------------------------------------------------
# Jobs the buttons start
# ---------------------------------------------------------------------------

function Start-Refresh {
    Set-Busy $true "Reading software on $($script:Device.Name) (Run Script)..."
    Invoke-TKJob -Name 'Software' -Script $softwareScript -Arguments @($script:Device.Name) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "Software list failed: $($r.Error)"; return }
        $tables = ConvertTo-SoftwareTables -Software $r.Value
        $script:SoftwareTable = $tables.Software
        $script:AppsTable = $tables.Apps
        $ui.GridSoftware.ItemsSource = $script:SoftwareTable.DefaultView
        $ui.GridApps.ItemsSource = $script:AppsTable.DefaultView
        Apply-Filter
        $ui.StatusText.Text = "$($script:SoftwareTable.Rows.Count) entries, $($script:AppsTable.Rows.Count) ConfigMgr applications ($($r.Seconds) s)"
        $ui.StatusOperation.Text = "OperationId $($r.Value.OperationId)"
        $ui.HeaderInfo.Text = "ResourceId $($script:Device.ResourceId)  |  client $($script:Device.ClientVersion)  |  online: $($script:Device.Online)  |  read $(Get-Date -Format 'HH:mm:ss')"
    }
}

function Start-Action {
    param([string]$Action, [bool]$ReEvaluate)
    $row = $ui.GridSoftware.SelectedItem
    if (-not $row) { return }
    $name = [string]$row.Row['Name']; $key = [string]$row.Row['Key']
    if ($Action -ne 'Inspect') {
        $q = "$Action '$name' on $($script:Device.Name)?"
        if ($ReEvaluate) { $q += "`n`nThe application deployment evaluation cycle is triggered afterwards - a required deployment will put it back." }
        $answer = [System.Windows.MessageBox]::Show($window, $q, 'AZITC Toolkit', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
    }
    $ui.LowerTabs.SelectedIndex = 0
    $ui.ActionResult.Text = "$Action '$name' ... (Run Script with parameters; a client reports about 15 s after the script ends)"
    Set-Busy $true "$Action '$name' on $($script:Device.Name)..."
    $jobArgs = @($script:Device.Name, $Action, $key, [string]$ui.ExtraArgs.Text, [bool]$ui.ChkKill.IsChecked, $ReEvaluate)
    Invoke-TKJob -Name $Action -Script $actionScript -Arguments $jobArgs -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { $ui.ActionResult.Text = $r.Error; Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $v = $r.Value
        $ui.ActionResult.Text = (Format-Result -Object $v -Skip @('Schema', 'Kind', 'LogTail')) + "`nLog tail:`n" + ((@($v.LogTail) | ForEach-Object { '    ' + $_ }) -join "`n")
        $state = "$($r.Name): "
        if ($v.PSObject.Properties['Strategy']) { $state += "strategy $($v.Strategy), " }
        if ($v.PSObject.Properties['ExitMeaning'] -and $v.ExitMeaning) { $state += "$($v.ExitMeaning), " }
        $ui.StatusText.Text = $state + "$($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
        if ($r.Name -ne 'Inspect') { Start-Refresh }
    }
}

function Start-Log {
    $lines = 100
    if (-not [int]::TryParse($ui.LogLines.Text, [ref]$lines)) { $lines = 100 }
    $log = [string]$ui.LogName.Text
    if (-not $log) { return }
    Set-Busy $true "Reading $log on $($script:Device.Name)..."
    Invoke-TKJob -Name 'Log' -Script $logScript -Arguments @($script:Device.Name, $log, $lines, [string]$ui.LogPattern.Text) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { $ui.LogText.Text = $r.Error; Show-Error "Log failed: $($r.Error)"; return }
        $v = $r.Value
        if ($v.Error) { $ui.LogText.Text = $v.Error; $ui.LogInfo.Text = ''; $ui.StatusText.Text = 'Log: ' + $v.Error; return }
        $ui.LogText.Text = (@($v.Lines) -join "`r`n")
        $ui.LogInfo.Text = "$($v.Path)  -  $($v.Lines.Count) of $($v.Matched) lines"
        $ui.LogText.ScrollToEnd()
        $ui.StatusText.Text = "Log read in $($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
    }
}

function Start-Notify {
    param([string]$Action)
    Set-Busy $true "Client notification $Action..."
    Invoke-TKJob -Name "Notify $Action" -Script $notifyScript -Arguments @($script:Device.ResourceId, $Action) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $line = "{0}  notification {1} (type {2}) sent, OperationId {3}" -f (Get-Date -Format 'HH:mm:ss'), $r.Value.Action, $r.Value.Type, $r.Value.OperationId
        $ui.ClientText.Text = ($ui.ClientText.Text + $line + "`r`n").TrimStart()
        $ui.StatusText.Text = $line
        $ui.StatusOperation.Text = "OperationId $($r.Value.OperationId)"
    }
}

function Start-ClientScript {
    param([string]$Action)
    Set-Busy $true "Client-action script $Action (Run Script)..."
    Invoke-TKJob -Name "Script $Action" -Script $clientActionScript -Arguments @($script:Device.ResourceId, $Action) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $v = $r.Value
        $line = "{0}  script {1}: state {2}, exit {3}, OperationId {4}" -f (Get-Date -Format 'HH:mm:ss'), $Action, $v.State, $v.ExitCode, $v.OperationId
        if ($v.Result) { $line += "`r`n    triggered: " + ((@($v.Result.Triggered)) -join '; '); if (@($v.Result.Failed).Count) { $line += "`r`n    failed: " + ((@($v.Result.Failed)) -join '; ') } }
        $ui.ClientText.Text = ($ui.ClientText.Text + $line + "`r`n").TrimStart()
        $ui.StatusText.Text = "$($r.Name): $($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
    }
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

$ui.BtnRefresh.Add_Click({ Start-Refresh })
$ui.BtnInspect.Add_Click({ Start-Action -Action 'Inspect' -ReEvaluate $false })
$ui.BtnUninstall.Add_Click({ Start-Action -Action 'Uninstall' -ReEvaluate $false })
$ui.BtnUninstallReEval.Add_Click({ Start-Action -Action 'Uninstall' -ReEvaluate $true })
$ui.BtnRepair.Add_Click({ Start-Action -Action 'Repair' -ReEvaluate $false })
$ui.BtnLog.Add_Click({ Start-Log })
$ui.GridSoftware.Add_SelectionChanged({ Update-SelectionButtons })
$ui.SearchBox.Add_TextChanged({ Apply-Filter })
$ui.LogName.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and -not $script:Busy) { Start-Log } })
foreach ($b in @($ui.BtnNotifyPolicy, $ui.BtnNotifyAppEval, $ui.BtnNotifySumEval, $ui.BtnNotifyHwInv, $ui.BtnNotifySwInv, $ui.BtnNotifyDdr, $ui.BtnNotifyCompliance)) {
    $b.Add_Click({ param($s, $e) Start-Notify -Action ([string]$s.Tag) })
}
foreach ($b in @($ui.BtnScriptPolicy, $ui.BtnScriptAppEval, $ui.BtnScriptAll, $ui.BtnScriptHwInv, $ui.BtnScriptSwInv, $ui.BtnScriptUpdScan)) {
    $b.Add_Click({ param($s, $e) Start-ClientScript -Action ([string]$s.Tag) })
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    if ($script:Job) { $ui.StatusElapsed.Text = "$([int]((Get-Date) - $script:Job.Started).TotalSeconds) s" }
    $null = Complete-TKJob
    if ($AutoCloseSeconds -gt 0 -and -not $script:Job -and ((Get-Date) - $script:WindowOpened).TotalSeconds -gt $AutoCloseSeconds) { $window.Close() }
})
$timer.Start()

$window.Add_Loaded({
    $script:WindowOpened = Get-Date
    Set-Busy $true "Connecting to $SmsProvider..."
    Invoke-TKJob -Name 'Connect' -Script $connectScript -Arguments @($DeviceName, $ResourceId) -OnDone {
        param($r)
        if (-not $r.Ok) { Set-Busy $false; Show-Error "Connection failed: $($r.Error)"; return }
        $script:Device = $r.Value
        $ui.HeaderDevice.Text = $script:Device.Name
        $window.Title = "AZITC Toolkit $toolVersion - $($script:Device.Name)$titleSite - $SmsProvider"
        $missing = @($script:Device.Scripts.GetEnumerator() | Where-Object { $_.Value -notlike '*approval=3' })
        if ($missing.Count -gt 0) {
            $ui.ClientText.Text = "Scripts not ready:`r`n" + (($missing | ForEach-Object { "    $($_.Key): $($_.Value)" }) -join "`r`n") + "`r`n"
        }
        Set-Busy $false
        Start-Refresh
    }
})
$window.Add_Closed({
    $timer.Stop()
    if ($AutoCloseSeconds -gt 0) {
        $rows = 0; if ($script:SoftwareTable) { $rows = $script:SoftwareTable.Rows.Count }
        $apps = 0; if ($script:AppsTable) { $apps = $script:AppsTable.Rows.Count }
        [Console]::Out.WriteLine("autoclose: status='$($ui.StatusText.Text)' rows=$rows apps=$apps matched=$($script:SoftwareTable.Select("CMApp <> ''").Count) handlerError='$($script:LastHandlerError)'")
    }
    if ($script:Job) { try { $script:Job.PowerShell.Stop() } catch { } }
    try { $script:Runspace.Close() } catch { }
})

$null = $window.ShowDialog()
