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
    FQDN of the SMS Provider (##SUB:__Server##). Empty: the console's connection history decides.
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
    [string]$SmsProvider = '',
    [string]$SiteCode = '',
    [switch]$SkipCertificateCheck,
    [switch]$SelfTest,
    [int]$AutoCloseSeconds = 0          # smoke tests: close the window after n seconds
)

$ErrorActionPreference = 'Stop'
# The version lives in VERSION next to this file; a pre-commit hook raises it with every commit.
$toolVersion = '0.0'
$versionFile = Join-Path -Path $PSScriptRoot -ChildPath 'VERSION'
if (Test-Path -LiteralPath $versionFile) { $fileVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim(); if ($fileVersion) { $toolVersion = $fileVersion } }
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
    foreach ($n in 'AZITC-TK-Software-Get', 'AZITC-TK-Software-Action', 'AZITC-TK-Log-Get', 'AZITC-TK-Client-Action', 'AZITC-TK-CMApp-Action', 'AZITC-TK-Client-Get', 'AZITC-TK-Client-Manage', 'AZITC-TK-CMApp-Troubleshoot') {
        try { $s = Get-TKScript -Name $n -WarningAction SilentlyContinue; $scripts[$n] = "$($s.ScriptGuid) v$($s.ScriptVersion) approval=$($s.ApprovalState)" } catch { $scripts[$n] = "missing: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        Provider      = [string]$script:TKSmsProvider
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
    $sw = Get-TKSoftware -DeviceName $DeviceName
    # The client knows only the Software Center title; the console name and the superseded
    # flag come from the site, keyed by ModelName = CCM_Application.Id.
    $site = @{}
    try { $site = Get-TKSiteApplications } catch { }
    foreach ($a in $sw.Apps) {
        $info = $null
        if ($site.ContainsKey([string]$a.Id)) { $info = $site[[string]$a.Id] }
        $cn = ''; $sup = $false; $dep = 0
        if ($info) { $cn = $info.ConsoleName; $sup = $info.IsSuperseded; $dep = $info.Deployments }
        $a | Add-Member -NotePropertyName ConsoleName -NotePropertyValue $cn -Force
        $a | Add-Member -NotePropertyName Superseded -NotePropertyValue $sup -Force
        $a | Add-Member -NotePropertyName Deployments -NotePropertyValue $dep -Force
    }
    $sw
}

$actionScript = {
    param($DeviceName, $Action, $Key, $ExtraArgs, $KillRunning, $ReEvaluate)
    Invoke-TKSoftwareAction -DeviceName $DeviceName -Action $Action -Key $Key -ExtraArgs $ExtraArgs -KillRunning:$KillRunning -ReEvaluate:$ReEvaluate
}

$logScript = {
    param($DeviceName, $LogName, $Lines, $Pattern, $Mode)
    Get-TKLog -DeviceName $DeviceName -LogName $LogName -Lines $Lines -Pattern $Pattern -Mode $Mode
}

$policyEvalScript = {
    param($ResourceId)
    # Machine policy first, then the evaluation of it - with the pauses the client needs.
    $a = Send-TKClientNotification -ResourceId $ResourceId -Action MachinePolicy
    Start-Sleep -Seconds 20
    $b = Send-TKClientNotification -ResourceId $ResourceId -Action AppDeploymentEval
    Start-Sleep -Seconds 15
    [pscustomobject]@{ PolicyOperationId = $a.OperationId; EvalOperationId = $b.OperationId }
}

$notifyScript = {
    param($ResourceId, $Action)
    Send-TKClientNotification -ResourceId $ResourceId -Action $Action
}

$cmAppScript = {
    param($DeviceName, $Action, $AppId, $Revision)
    Invoke-TKCMAppAction -DeviceName $DeviceName -Action $Action -AppId $AppId -Revision $Revision -TimeoutMin 10
}

$troubleshootScript = {
    param($DeviceName, $AppId)
    $r = Invoke-TKCMAppTroubleshoot -DeviceName $DeviceName -AppId $AppId
    [pscustomobject]@{ Result = $r; Text = (Format-TKTroubleshoot -Result $r) }
}

$clientGetScript = {
    param($DeviceName)
    Get-TKClient -DeviceName $DeviceName
}

$clientManageScript = {
    param($DeviceName, $Target, $Action, $Name)
    Invoke-TKClientManage -DeviceName $DeviceName -Target $Target -Action $Action -Name $Name
}

$clientActionScript = {
    param($ResourceId, $Action)
    $scr = Get-TKScript -Name 'AZITC-TK-Client-Action'
    $res = Invoke-TKScript -ResourceId $ResourceId -Script $scr -Parameters @{ Action = $Action } -TimeoutSec 240
    $parsed = $null
    try { $parsed = $res.Output | ConvertFrom-Json } catch { }
    $code = $res.ExitCode; if ($parsed -and $parsed.PSObject.Properties['ScriptExit']) { $code = [int]$parsed.ScriptExit }
    [pscustomobject]@{ OperationId = $res.OperationId; State = $res.State; ExitCode = $code; Result = $parsed; Raw = $res.Output }
}

# ============================================================================
# Self test: no window.
# ============================================================================

if ($SelfTest) {
    $ps = [powershell]::Create(); $ps.Runspace = $script:Runspace
    $null = $ps.AddScript($connectScript.ToString(), $false).AddArgument($DeviceName).AddArgument($ResourceId)
    $dev = $ps.Invoke()[0]; $ps.Dispose()
    "provider: $($dev.Provider)"
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
            <Button x:Name="BtnRemoveEntry" Content="Remove orphaned entry" IsEnabled="False" ToolTip="Deletes the Add/Remove Programs key of an entry whose product Windows Installer no longer knows or whose uninstaller is gone - the leftover that keeps a registry detection true. Refused for a real installation. The key's values are saved to the toolkit log folder first."/>
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
              <DataGridTextColumn Header="ConfigMgr application (best guess)" Binding="{Binding CMApp}" Width="2*"/>
            </DataGrid.Columns>
          </DataGrid>
          <GridSplitter Grid.Row="2" Height="5" HorizontalAlignment="Stretch" Background="#DDDDDD"/>
          <TabControl Grid.Row="3" x:Name="LowerTabs">
            <TabItem Header="Action result">
              <TextBox x:Name="ActionResult" Style="{StaticResource Mono}" Text=""/>
            </TabItem>
            <TabItem Header="ConfigMgr applications on this device">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,4,0,4">
                  <Button x:Name="BtnAppInstall" Content="Install" IsEnabled="False"/>
                  <Button x:Name="BtnAppUninstall" Content="Uninstall" IsEnabled="False"/>
                  <Button x:Name="BtnAppRepair" Content="Repair" IsEnabled="False"/>
                  <Button x:Name="BtnAppTroubleshoot" Content="Troubleshoot" IsEnabled="False" Margin="12,0,0,0" ToolTip="Why is this application not where the deployment wants it? Read on the client: the detection method of the deployment type evaluated clause by clause against the device (file, registry, MSI, or the detection script run as the client runs it), every enforcement attempt with exit code and post-install detection, when the client last evaluated and when it will again, what Add/Remove Programs really holds - and a verdict drawn from all of that. About 20 s. Runs the detection script of the deployment type; changes nothing else."/>
                  <Button x:Name="BtnPolicyEval" Content="Policy + evaluate, then refresh" ToolTip="Client notification: machine policy, 20 s, application deployment evaluation, 15 s, then the software list is read again. What the grid shows is the client's last finding; this makes it a fresh one."/>
                  <TextBlock Text="through the ConfigMgr client, watched until the state changes; what the client offers is in the Possible actions column" Foreground="#555555" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </DockPanel>
                <DataGrid x:Name="GridApps" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" CanUserSortColumns="True"
                          HeadersVisibility="Column" GridLinesVisibility="Horizontal" AlternatingRowBackground="#FAFAFA" RowHeight="22">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Application (console)" Binding="{Binding ConsoleName}" Width="3*"/>
                    <DataGridTextColumn Header="Software Center title" Binding="{Binding Name}" Width="2*"/>
                    <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="120"/>
                    <DataGridTextColumn Header="Target reached" Binding="{Binding Verdict}" Width="105">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                          <Setter Property="ToolTip" Value="{Binding VerdictTip}"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding Verdict}" Value="OK">
                              <Setter Property="Foreground" Value="#1B7F2E"/><Setter Property="FontWeight" Value="Bold"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Verdict}" Value="Pending">
                              <Setter Property="Foreground" Value="#B36B00"/><Setter Property="FontWeight" Value="Bold"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Verdict}" Value="Failed">
                              <Setter Property="Foreground" Value="#C62828"/><Setter Property="FontWeight" Value="Bold"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Verdict}" Value="offered">
                              <Setter Property="Foreground" Value="#808080"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Verdict}" Value="not targeted">
                              <Setter Property="Foreground" Value="#808080"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="On the device" Binding="{Binding InstallText}" Width="100">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding InstallTip}"/></Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="Deployment" Binding="{Binding TargetText}" Width="110">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding TargetTip}"/></Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="Status" Binding="{Binding EvaluationText}" Width="215">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock"><Setter Property="ToolTip" Value="{Binding EvaluationTip}"/></Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="Rev" Binding="{Binding Revision}" Width="45"/>
                    <DataGridTextColumn Header="Deadline (UTC)" Binding="{Binding Deadline}" Width="140"/>
                    <DataGridTextColumn Header="Possible actions" Binding="{Binding AllowedActions}" Width="140"/>
                    <DataGridTextColumn Header="Superseded" Binding="{Binding Superseded}" Width="85"/>
                    <DataGridTextColumn Header="Deployments" Binding="{Binding Deployments}" Width="90"/>
                    <DataGridTextColumn Header="Publisher" Binding="{Binding Publisher}" Width="2*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
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
            <Button x:Name="BtnLogList" Content="List files" ToolTip="Lists the files of the folder named in the box (a folder such as PSADT, or a mask such as PSADT\*.log) and puts them into the list to pick from"/>
            <TextBlock x:Name="LogInfo" VerticalAlignment="Center" Foreground="#555555" Margin="12,0,0,0"/>
          </DockPanel>
          <TextBox Grid.Row="1" x:Name="LogText" Style="{StaticResource Mono}" Text=""/>
        </Grid>
      </TabItem>
      <!-- ================= Client ================= -->
      <TabItem Header="Client">
        <DockPanel Margin="6">
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
            <Button x:Name="BtnClientRefresh" Content="Read client"/>
            <TextBlock x:Name="ClientInfo" VerticalAlignment="Center" Foreground="#555555" Text="Services, processes, cache, pending reboot - one Run Script, about half a minute."/>
          </DockPanel>
          <TabControl x:Name="ClientTabs">
            <TabItem Header="Overview">
              <TextBox x:Name="ClientOverview" Style="{StaticResource Mono}" Text=""/>
            </TabItem>
            <TabItem Header="Services">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,4,0,4">
                  <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBox x:Name="SvcSearch" Width="200" VerticalContentAlignment="Center" Margin="0,0,12,0"/>
                  <Button x:Name="BtnSvcStart" Content="Start" IsEnabled="False"/>
                  <Button x:Name="BtnSvcStop" Content="Stop" IsEnabled="False"/>
                  <Button x:Name="BtnSvcRestart" Content="Restart" IsEnabled="False"/>
                </DockPanel>
                <DataGrid x:Name="GridServices" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" CanUserSortColumns="True"
                          HeadersVisibility="Column" GridLinesVisibility="Horizontal" AlternatingRowBackground="#FAFAFA" RowHeight="22">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="180"/>
                    <DataGridTextColumn Header="Display name" Binding="{Binding DisplayName}" Width="3*"/>
                    <DataGridTextColumn Header="State" Binding="{Binding State}" Width="80"/>
                    <DataGridTextColumn Header="Start" Binding="{Binding StartMode}" Width="70"/>
                    <DataGridTextColumn Header="Account" Binding="{Binding Account}" Width="2*"/>
                    <DataGridTextColumn Header="PID" Binding="{Binding ProcessId}" Width="60"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
            <TabItem Header="Processes">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,4,0,4">
                  <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBox x:Name="ProcSearch" Width="200" VerticalContentAlignment="Center" Margin="0,0,12,0"/>
                  <Button x:Name="BtnProcKill" Content="End process" IsEnabled="False"/>
                  <TextBlock Text="sorted by working set; the ConfigMgr client and core system processes are protected on the client side" Foreground="#555555" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </DockPanel>
                <DataGrid x:Name="GridProcesses" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" CanUserSortColumns="True"
                          HeadersVisibility="Column" GridLinesVisibility="Horizontal" AlternatingRowBackground="#FAFAFA" RowHeight="22">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="180"/>
                    <DataGridTextColumn Header="PID" Binding="{Binding Id}" Width="60"/>
                    <DataGridTextColumn Header="Session" Binding="{Binding Session}" Width="55"/>
                    <DataGridTextColumn Header="User" Binding="{Binding User}" Width="160"/>
                    <DataGridTextColumn Header="WS MB" Binding="{Binding WorkingSetMB}" Width="70"/>
                    <DataGridTextColumn Header="CPU s" Binding="{Binding CpuSeconds}" Width="70"/>
                    <DataGridTextColumn Header="Started (UTC)" Binding="{Binding Started}" Width="130"/>
                    <DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="3*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
            <TabItem Header="Cache">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,4,0,4">
                  <Button x:Name="BtnCacheDelete" Content="Delete selected" IsEnabled="False"/>
                  <Button x:Name="BtnCacheClear" Content="Clear unused" IsEnabled="False"/>
                  <TextBlock x:Name="CacheInfo" Foreground="#555555" VerticalAlignment="Center" Margin="6,0,0,0" Text=""/>
                </DockPanel>
                <DataGrid x:Name="GridCache" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" CanUserSortColumns="True"
                          HeadersVisibility="Column" GridLinesVisibility="Horizontal" AlternatingRowBackground="#FAFAFA" RowHeight="22">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Content" Binding="{Binding ContentId}" Width="3*"/>
                    <DataGridTextColumn Header="Ver" Binding="{Binding Version}" Width="45"/>
                    <DataGridTextColumn Header="MB" Binding="{Binding SizeMB}" Width="80"/>
                    <DataGridTextColumn Header="Refs" Binding="{Binding References}" Width="50"/>
                    <DataGridTextColumn Header="Persist" Binding="{Binding Persist}" Width="60"/>
                    <DataGridTextColumn Header="Last referenced (UTC)" Binding="{Binding LastReferenced}" Width="140"/>
                    <DataGridTextColumn Header="Folder" Binding="{Binding Folder}" Width="2*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
            <TabItem Header="Actions">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <GroupBox Grid.Row="0" Header="Client notification (push over the notification channel, seconds, no result beyond the operation)" Padding="6" Margin="0,4,0,8">
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
foreach ($n in 'AppEnforce.log', 'AppDiscovery.log', 'AppIntentEval.log', 'CAS.log', 'ContentTransferManager.log', 'DataTransferService.log', 'PolicyAgent.log', 'CcmExec.log', 'ClientIDManagerStartup.log', 'ccmnotificationagent.log', 'Scripts.log', 'UpdatesDeployment.log', 'WUAHandler.log', 'AZITC-Toolkit\AZITC-Toolkit.log', 'AZITC-Toolkit\*.log', 'C:\Windows\Logs\Software\*') { $null = $ui.LogName.Items.Add($n) }
$ui.LogName.SelectedIndex = 0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:Device = $null
$script:SoftwareTable = $null
$script:AppsTable = $null
$script:Busy = $true
$script:ServicesTable = $null
$script:ProcessesTable = $null
$script:CacheTable = $null
$script:Actionable = @($ui.BtnRefresh, $ui.BtnInspect, $ui.BtnUninstall, $ui.BtnUninstallReEval, $ui.BtnRepair, $ui.BtnRemoveEntry, $ui.BtnLog, $ui.BtnLogList,
    $ui.BtnAppInstall, $ui.BtnAppUninstall, $ui.BtnAppRepair, $ui.BtnAppTroubleshoot, $ui.BtnPolicyEval,
    $ui.BtnClientRefresh, $ui.BtnSvcStart, $ui.BtnSvcStop, $ui.BtnSvcRestart, $ui.BtnProcKill, $ui.BtnCacheDelete, $ui.BtnCacheClear,
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
    foreach ($b in @($ui.BtnUninstall, $ui.BtnUninstallReEval, $ui.BtnRepair, $ui.BtnRemoveEntry)) {
        $b.IsEnabled = $has -and $machine
        $b.ToolTip = $tip
    }
    if ($has -and $machine -and -not [bool]$row.Row['RepairPossible']) { $ui.BtnRepair.ToolTip = 'The entry has NoRepair or NoModify set; Repair works for MSI products only.' }

    # CM applications: what the client says it allows.
    $app = $ui.GridApps.SelectedItem
    $allowed = ''
    if ($app -and -not $script:Busy) { $allowed = [string]$app.Row['AllowedActions'] }
    $ui.BtnAppInstall.IsEnabled   = ($allowed -match '\bInstall\b')
    $ui.BtnAppUninstall.IsEnabled = ($allowed -match '\bUninstall\b')
    $ui.BtnAppRepair.IsEnabled    = ($allowed -match '\bRepair\b')
    $ui.BtnAppTroubleshoot.IsEnabled = ($null -ne $app) -and (-not $script:Busy)

    # Client tab
    $svc = $ui.GridServices.SelectedItem
    $hasSvc = ($null -ne $svc) -and (-not $script:Busy)
    $state = ''; if ($hasSvc) { $state = [string]$svc.Row['State'] }
    $ui.BtnSvcStart.IsEnabled   = $hasSvc -and ($state -ne 'Running')
    $ui.BtnSvcStop.IsEnabled    = $hasSvc -and ($state -eq 'Running')
    $ui.BtnSvcRestart.IsEnabled = $hasSvc -and ($state -eq 'Running')
    $ui.BtnProcKill.IsEnabled   = ($null -ne $ui.GridProcesses.SelectedItem) -and (-not $script:Busy)
    $ui.BtnCacheDelete.IsEnabled = ($null -ne $ui.GridCache.SelectedItem) -and (-not $script:Busy)
    $ui.BtnCacheClear.IsEnabled  = ($null -ne $script:CacheTable) -and (-not $script:Busy)
}

function Show-Error {
    param([string]$Text)
    $ui.StatusText.Text = 'Error'
    [System.Windows.MessageBox]::Show($window, $Text, 'AZITC Toolkit', 'OK', 'Error') | Out-Null
}

# ---------------------------------------------------------------------------
# Plain words for the client's state values
#
# What the client reports is an enum: ResolvedState "Installed", InstallState
# "NotInstalled", EvaluationState 8. Put in a grid cell as it stands, none of
# that says what it means - "Installed/Installed" reads like a contradiction
# and "8" like nothing at all. So the window shows the meaning and keeps the
# raw value in the cell's tooltip, because that is what a log line or a web
# search is keyed on.
#
# The client scripts keep their own copies of these tables: they run on the
# client, where nothing of this file exists.
# ---------------------------------------------------------------------------

# CCM_Application.EvaluationState, phrased the way the console phrases the same
# situations.
#
# 0-12 were read from the client SDK documentation when this window was built.
# 13 and above have never been seen on a site: 14-28 are the published SDK list,
# and the tooltip of such a cell says so, because a plain number told the reader
# nothing at all and an unconfirmed sentence at least points somewhere.
#
# 13 is the one value this repo and that list disagree on - the list reads
# "enforced, soft reboot pending", a finished installation, while this table and
# the watch loop of AZITC-TK-CMApp-Action call it a failure. The repo's own
# reading stands until a client reports a 13, because flipping it would also
# flip a red light to amber and end the watch loop later. See CHANGELOG.
$script:EvalText = @{
    0  = 'No state reported'
    1  = 'In the wanted state'
    2  = 'Not required on this device'
    3  = 'Ready to run, not started'
    4  = 'Last attempt failed'
    5  = 'Waiting for content to download'
    6  = 'Waiting for content to download'
    7  = 'Waiting for dependencies to download'
    8  = 'Waiting for a maintenance window'
    9  = 'Waiting for a pending reboot'
    10 = 'Waiting its turn'
    11 = 'Installing dependencies'
    12 = 'Installing'
    13 = 'Ran and failed'
    # --- from here down: the published list, not seen on a site ---
    14 = 'Ran, reboot required'
    15 = 'An update is waiting to be installed'
    16 = 'Evaluation failed'
    17 = 'Waiting for a user to be logged on'
    18 = 'Waiting for all users to log off'
    19 = 'Waiting for a user to log on'
    20 = 'Waiting to try again'
    21 = 'Waiting for presentation mode to end'
    22 = 'Downloading content in advance'
    23 = 'Downloading dependencies in advance'
    24 = 'Content download failed'
    25 = 'Downloading in advance failed'
    26 = 'Content downloaded'
    27 = 'Checking after the run'
    28 = 'Waiting for a network connection'
}

# Nobody here has watched a client report one of these; the tooltip says so.
$script:EvalUnverified = 14..28

function Get-TKEvalText {
    param([int]$State)
    if ($script:EvalText.ContainsKey($State)) { return $script:EvalText[$State] }
    return "State $State"
}

# The tooltip of a status cell: the sentence again, because the column is
# narrower than some of them, then where the value came from.
function Get-TKEvalTip {
    param([int]$State)
    $tip = '{0} - CCM_Application.EvaluationState = {1}' -f (Get-TKEvalText -State $State), $State
    if ($State -eq 13) { $tip += ' - never seen on a site, and the published SDK list reads it as a finished run waiting for a reboot instead' }
    elseif ($script:EvalUnverified -contains $State) { $tip += ' - meaning taken from the published SDK list, never seen on a site' }
    elseif (-not $script:EvalText.ContainsKey($State)) { $tip += ' - no meaning known for this value' }
    return $tip
}

# CCM_Application.InstallState - what is on the device.
function Get-TKInstallText {
    param([string]$State)
    switch -Regex ($State) {
        '^Installed$'    { return 'Installed' }
        '^NotInstalled$' { return 'Not installed' }
        '^Error$'        { return 'Error' }
        '^\s*$'          { return 'Unknown' }
        default          { return $State }
    }
}

# CCM_Application.ResolvedState - what the deployment wants, which is a
# different question from what is there. "Installed" here means "a required
# deployment targets this device", not "it is installed".
function Get-TKTargetText {
    param([string]$State)
    switch -Regex ($State) {
        '^Installed$'   { return 'required' }
        '^Available$'   { return 'optional' }
        '^Uninstalled$' { return 'removal required' }
        '^None$'        { return 'not targeted' }
        '^\s*$'         { return 'not targeted' }
        default         { return $State }
    }
}

# Has the deployment got what it wanted? One word, for the column that is read
# at a glance and nowhere else.
#
#   OK           the device is in the state the deployment asks for
#   Pending      on its way, waiting, or asked for and not there yet
#   Failed       the client's last attempt failed
#   offered      an available deployment nobody has installed - not a fault
#   not targeted no deployment asks anything of this device
#
# The client's own EvaluationState decides before the pair of states does: it
# is the only one of the three that knows about a failure or a wait.
function Get-TKDeploymentVerdict {
    param([string]$InstallState, [string]$ResolvedState, [int]$EvaluationState)

    $installed = ($InstallState -eq 'Installed')
    if ($ResolvedState -eq 'None' -or [string]::IsNullOrWhiteSpace($ResolvedState)) { return 'not targeted' }
    if ($ResolvedState -eq 'Available' -and -not $installed) { return 'offered' }
    # Display only, so the states that were never observed may be used here: a
    # colour that turns out wrong costs a glance. The watch loop on the client
    # keeps to the two values this site has actually seen.
    if ($EvaluationState -in @(4, 13, 16, 24, 25)) { return 'Failed' }
    if ($EvaluationState -in @(3, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 17, 18, 19, 20, 21, 22, 23, 26, 27, 28)) { return 'Pending' }

    $reached = switch ($ResolvedState) {
        'Uninstalled' { -not $installed }
        default       { $installed }
    }
    if ($reached) { return 'OK' }
    return 'Pending'
}

# Why the verdict reads the way it does - the tooltip of that cell.
function Get-TKDeploymentVerdictTip {
    param([string]$InstallState, [string]$ResolvedState, [int]$EvaluationState)
    return '{0} deployment, {1} on the device. Client state: {2}.' -f
        (Get-TKTargetText -State $ResolvedState),
        (Get-TKInstallText -State $InstallState).ToLower(),
        (Get-TKEvalText -State $EvaluationState)
}

# The two together, for the one-line label in the software list.
function Get-TKAppStateText {
    param([string]$InstallState, [string]$ResolvedState)
    return '{0}, {1}' -f (Get-TKTargetText -State $ResolvedState), (Get-TKInstallText -State $InstallState).ToLower()
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
        # Heuristic: the ARP name starts with the application's Software Center title (or the
        # other way round). Among several candidates the score decides: version agreement 4,
        # installed on the client 2, has a deadline 1, not superseded 1; ties go to the higher
        # version. Labelled as heuristic in the column header.
        $best = $null; $bestScore = -1
        foreach ($a in $apps) {
            $an = [string]$a.N
            if (-not $an) { continue }
            $n = [string]$i.Name
            if (-not ($n.StartsWith($an, [System.StringComparison]::OrdinalIgnoreCase) -or $an.StartsWith($n, [System.StringComparison]::OrdinalIgnoreCase))) { continue }
            $score = $an.Length / 1000.0
            $sv = [string]$a.SV; $iv = [string]$i.Version
            if ($sv -and $iv -and ($iv.StartsWith($sv, [System.StringComparison]::OrdinalIgnoreCase) -or $sv.StartsWith($iv, [System.StringComparison]::OrdinalIgnoreCase))) { $score += 4 }
            if ([string]$a.IS -eq 'Installed') { $score += 2 }
            if ([string]$a.DL) { $score += 1 }
            if (-not [bool]$a.Superseded) { $score += 1 }
            if ($score -gt $bestScore) { $best = $a; $bestScore = $score }
        }        if ($best) { $label = [string]$best.ConsoleName; if (-not $label) { $label = '{0} {1}' -f $best.N, $best.SV }; $r['CMApp'] = '{0} ({1})' -f $label, (Get-TKAppStateText -InstallState $best.IS -ResolvedState $best.RS) } else { $r['CMApp'] = '' }
        $t.Rows.Add($r)
    }

    $a2 = New-Object System.Data.DataTable 'Apps'
    foreach ($c in 'Name', 'ConsoleName', 'Version', 'InstallState', 'ResolvedState', 'Deadline', 'AllowedActions', 'Publisher', 'Id') { $null = $a2.Columns.Add($c, [string]) }
    # What the grid shows, and what the tooltip keeps of the value behind it.
    foreach ($c in 'InstallText', 'InstallTip', 'TargetText', 'TargetTip', 'EvaluationText', 'EvaluationTip', 'Verdict', 'VerdictTip') { $null = $a2.Columns.Add($c, [string]) }
    $null = $a2.Columns.Add('Superseded', [bool]); $null = $a2.Columns.Add('Deployments', [int])
    $null = $a2.Columns.Add('EvaluationState', [int])
    $null = $a2.Columns.Add('Revision', [int])
    foreach ($a in $apps) {
        $r = $a2.NewRow()
        $r['Name'] = [string]$a.N; $r['Version'] = [string]$a.SV; $r['InstallState'] = [string]$a.IS; $r['ResolvedState'] = [string]$a.RS
        $r['Deadline'] = [string]$a.DL; $r['AllowedActions'] = (@($a.AA) -join ', '); $r['Publisher'] = [string]$a.Pub; $r['Id'] = [string]$a.Id
        $r['EvaluationState'] = [int]$a.ES; $r['Revision'] = [int]$a.Rev
        $r['InstallText']    = Get-TKInstallText -State ([string]$a.IS)
        $r['InstallTip']     = 'CCM_Application.InstallState = {0}' -f $a.IS
        $r['TargetText']     = Get-TKTargetText -State ([string]$a.RS)
        $r['TargetTip']      = 'CCM_Application.ResolvedState = {0} - the state the deployment wants, not what is installed' -f $a.RS
        $r['EvaluationText'] = Get-TKEvalText -State ([int]$a.ES)
        $r['EvaluationTip']  = Get-TKEvalTip -State ([int]$a.ES)
        $r['Verdict']        = Get-TKDeploymentVerdict    -InstallState ([string]$a.IS) -ResolvedState ([string]$a.RS) -EvaluationState ([int]$a.ES)
        $r['VerdictTip']     = Get-TKDeploymentVerdictTip -InstallState ([string]$a.IS) -ResolvedState ([string]$a.RS) -EvaluationState ([int]$a.ES)
        $r['ConsoleName'] = [string]$a.ConsoleName; $r['Superseded'] = [bool]$a.Superseded; $r['Deployments'] = [int]$a.Deployments
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
        if ($AutoCloseSeconds -gt 0 -and -not $script:SmokeClientDone) { $script:SmokeClientDone = $true; Start-ClientRefresh }
    }
}

function Start-Action {
    param([string]$Action, [bool]$ReEvaluate)
    $row = $ui.GridSoftware.SelectedItem
    if (-not $row) { return }
    $name = [string]$row.Row['Name']; $key = [string]$row.Row['Key']
    if ($Action -ne 'Inspect') {
        $q = "$Action '$name' on $($script:Device.Name)?"
        if ($Action -eq 'RemoveEntry') { $q = "Remove the Add/Remove Programs entry '$name' on $($script:Device.Name)?`n`nOnly an orphaned entry is removed - one whose product Windows Installer no longer knows, or whose uninstaller is gone. A real installation is refused; use Uninstall for that. The key's values are saved to the toolkit log folder first." }
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
    param([string]$Mode = 'Tail')
    $lines = 100
    if (-not [int]::TryParse($ui.LogLines.Text, [ref]$lines)) { $lines = 100 }
    $log = [string]$ui.LogName.Text
    if (-not $log) { return }
    if ($Mode -eq 'List') { $lines = 500 }
    Set-Busy $true "Reading $log on $($script:Device.Name)..."
    Invoke-TKJob -Name 'Log' -Script $logScript -Arguments @($script:Device.Name, $log, $lines, [string]$ui.LogPattern.Text, $Mode) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { $ui.LogText.Text = $r.Error; Show-Error "Log failed: $($r.Error)"; return }
        $v = $r.Value
        if ($v.Error) { $ui.LogText.Text = $v.Error; $ui.LogInfo.Text = ''; $ui.StatusText.Text = 'Log: ' + $v.Error; return }
        $ui.LogText.Text = (@($v.Lines) -join "`r`n")
        if (@($v.Files).Count -gt 0) {
            # A listing: the files go into the box to pick from, newest first, the mask stays on top.
            $mask = [string]$ui.LogName.Text
            $ui.LogName.Items.Clear()
            $null = $ui.LogName.Items.Add($mask)
            foreach ($f in $v.Files) { $null = $ui.LogName.Items.Add([string]$f.P) }
            $ui.LogName.Text = $mask
            $ui.LogInfo.Text = "$($v.Path)  -  $(@($v.Files).Count) of $($v.Matched) files, newest first; pick one and press Get log"
            $ui.LogText.ScrollToHome()
        } else {
            $ui.LogInfo.Text = "$($v.Path)  -  $($v.Lines.Count) of $($v.Matched) lines"
            $ui.LogText.ScrollToEnd()
        }
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
# ConfigMgr application actions (CCM_Application on the client)
# ---------------------------------------------------------------------------

function Start-CMAppAction {
    param([string]$Action)
    $row = $ui.GridApps.SelectedItem
    if (-not $row) { return }
    $name = [string]$row.Row['Name']; $ver = [string]$row.Row['Version']; $id = [string]$row.Row['Id']
    $q = "$Action '$name $ver' on $($script:Device.Name) through the ConfigMgr client?`n`nThe client runs the deployment type; the window watches the state for up to 10 minutes."
    if ([System.Windows.MessageBox]::Show($window, $q, 'AZITC Toolkit', 'YesNo', 'Question') -ne 'Yes') { return }
    $ui.LowerTabs.SelectedIndex = 0
    $ui.ActionResult.Text = "$Action '$name' via CCM_Application ..."
    Set-Busy $true "$Action '$name' via CCM_Application on $($script:Device.Name)..."
    Invoke-TKJob -Name "CMApp $Action" -Script $cmAppScript -Arguments @($script:Device.Name, $Action, $id, 0) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { $ui.ActionResult.Text = $r.Error; Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $v = $r.Value
        $text = Format-Result -Object $v -Skip @('Schema', 'Kind', 'Before', 'After', 'Course')
        $text += "`nBefore: " + ($v.Before | ConvertTo-Json -Compress) + "`nCourse:`n"
        foreach ($c in @($v.Course)) { $text += "    {0}  {1,-14} {2}  {3}%`n" -f $c.TimeUtc, (Get-TKInstallText -State ([string]$c.InstallState)), (Get-TKEvalText -State ([int]$c.EvaluationState)), $c.PercentComplete }
        $text += "After:  " + ($v.After | ConvertTo-Json -Compress)
        $ui.ActionResult.Text = $text
        $ui.StatusText.Text = "$($r.Name): " + $(if ($v.Reached) { 'reached the wanted state' } elseif ($v.TimedOut) { 'still running when the wait ran out' } else { 'did not reach the wanted state' }) + ", $($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
        Start-Refresh
    }
}

function Start-CMAppTroubleshoot {
    $row = $ui.GridApps.SelectedItem
    if (-not $row) { return }
    $name = [string]$row.Row['Name']; $ver = [string]$row.Row['Version']; $id = [string]$row.Row['Id']
    $ui.LowerTabs.SelectedIndex = 0
    $ui.ActionResult.Text = "Troubleshoot '$name $ver' ... (detection evaluated on the client, logs read, about 20 s)"
    Set-Busy $true "Troubleshoot '$name' on $($script:Device.Name)..."
    Invoke-TKJob -Name 'Troubleshoot' -Script $troubleshootScript -Arguments @($script:Device.Name, $id) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { $ui.ActionResult.Text = $r.Error; Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $v = $r.Value
        $ui.ActionResult.Text = $v.Text
        $top = @($v.Result.Verdicts | Where-Object { $_.Level -in 'Fail', 'Warn' } | Select-Object -First 1)
        if ($top.Count -eq 0) { $top = @($v.Result.Verdicts | Select-Object -First 1) }
        $line = 'no verdict'; if ($top.Count -gt 0) { $line = '[' + $top[0].Level + '] ' + $top[0].Text }
        if ($line.Length -gt 160) { $line = $line.Substring(0, 157) + '...' }
        $ui.StatusText.Text = "Troubleshoot: $line ($($r.Seconds) s)"
        $ui.StatusOperation.Text = "OperationId $($v.Result.OperationId)"
    }
}

# ---------------------------------------------------------------------------
# Client tab: overview, services, processes, cache
# ---------------------------------------------------------------------------

function ConvertTo-ClientTables {
    param($Client)
    $s = New-Object System.Data.DataTable 'Services'
    foreach ($c in 'Name', 'DisplayName', 'State', 'StartMode', 'Account') { $null = $s.Columns.Add($c, [string]) }
    $null = $s.Columns.Add('ProcessId', [int])
    foreach ($x in $Client.Services) { $r = $s.NewRow(); $r['Name'] = [string]$x.N; $r['DisplayName'] = [string]$x.D; $r['State'] = [string]$x.S; $r['StartMode'] = [string]$x.M; $r['Account'] = [string]$x.A; $r['ProcessId'] = [int]$x.P; $s.Rows.Add($r) }

    $p = New-Object System.Data.DataTable 'Processes'
    foreach ($c in 'Name', 'User', 'Started', 'Path', 'CommandLine') { $null = $p.Columns.Add($c, [string]) }
    foreach ($c in 'Id', 'Session') { $null = $p.Columns.Add($c, [int]) }
    foreach ($c in 'WorkingSetMB', 'CpuSeconds') { $null = $p.Columns.Add($c, [double]) }
    foreach ($x in $Client.Processes) { $r = $p.NewRow(); $r['Name'] = [string]$x.N; $r['Id'] = [int]$x.I; $r['Session'] = [int]$x.SE; $r['User'] = [string]$x.U; $r['Started'] = [string]$x.T; $r['WorkingSetMB'] = [double]$x.W; $r['CpuSeconds'] = [double]$x.C; $r['Path'] = [string]$x.E; $r['CommandLine'] = [string]$x.L; $p.Rows.Add($r) }

    $c2 = New-Object System.Data.DataTable 'Cache'
    foreach ($c in 'ContentId', 'Version', 'LastReferenced', 'Folder', 'CacheId') { $null = $c2.Columns.Add($c, [string]) }
    $null = $c2.Columns.Add('SizeMB', [double]); $null = $c2.Columns.Add('References', [int]); $null = $c2.Columns.Add('Persist', [bool])
    foreach ($x in $Client.Cache) { $r = $c2.NewRow(); $r['ContentId'] = [string]$x.ID; $r['Version'] = [string]$x.V; $r['SizeMB'] = [double]$x.MB; $r['References'] = [int]$x.R; $r['Persist'] = [bool]$x.P; $r['LastReferenced'] = [string]$x.L; $r['Folder'] = [string]$x.DIR; $r['CacheId'] = [string]$x.CID; $c2.Rows.Add($r) }
    return @{ Services = $s; Processes = $p; Cache = $c2 }
}

function Apply-ClientFilters {
    if ($script:ServicesTable) {
        $t = $ui.SvcSearch.Text
        if ([string]::IsNullOrWhiteSpace($t)) { $script:ServicesTable.DefaultView.RowFilter = '' }
        else { $e = $t.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]'); $script:ServicesTable.DefaultView.RowFilter = "Name LIKE '%$e%' OR DisplayName LIKE '%$e%' OR Account LIKE '%$e%'" }
    }
    if ($script:ProcessesTable) {
        $t = $ui.ProcSearch.Text
        if ([string]::IsNullOrWhiteSpace($t)) { $script:ProcessesTable.DefaultView.RowFilter = '' }
        else { $e = $t.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]'); $script:ProcessesTable.DefaultView.RowFilter = "Name LIKE '%$e%' OR User LIKE '%$e%' OR Path LIKE '%$e%' OR CommandLine LIKE '%$e%'" }
    }
}

function Start-ClientRefresh {
    Set-Busy $true "Reading client state of $($script:Device.Name) (Run Script)..."
    Invoke-TKJob -Name 'Client' -Script $clientGetScript -Arguments @($script:Device.Name) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "Client read failed: $($r.Error)"; return }
        $v = $r.Value
        $t = ConvertTo-ClientTables -Client $v
        $script:ServicesTable = $t.Services; $script:ProcessesTable = $t.Processes; $script:CacheTable = $t.Cache
        $ui.GridServices.ItemsSource = $script:ServicesTable.DefaultView
        $ui.GridProcesses.ItemsSource = $script:ProcessesTable.DefaultView
        $ui.GridCache.ItemsSource = $script:CacheTable.DefaultView
        Apply-ClientFilters
        $ov = "Read $(Get-Date -Format 'HH:mm:ss') from $($v.Host)`r`n`r`n"
        $ov += (Format-Result -Object $v.Client) + "`r`n"
        $ov += "Reboot pending:      " + $(if ([bool]$v.Reboot.Pending) { 'yes' } else { 'no' }) + "`r`n"
        foreach ($reason in @($v.Reboot.Reasons)) { $ov += "    $reason`r`n" }
        # The client keeps its own answer, and it is not always the same as Windows' -
        # "hard" means it will not let the user postpone it.
        $ccm = $(if ([bool]$v.Reboot.CcmRebootPending) { 'the ConfigMgr client wants a reboot' } else { 'the ConfigMgr client wants no reboot' })
        if ([bool]$v.Reboot.CcmIsHardRebootPending) { $ccm += ', and it cannot be postponed' }
        if ($v.Reboot.CcmRebootDeadlineUtc) { $ccm += " (deadline $($v.Reboot.CcmRebootDeadlineUtc) UTC)" }
        $ov += "ConfigMgr client:    $ccm`r`n"
        if ($v.Error) { $ov += "`r`nErrors on the client: $($v.Error)`r`n" }
        $ui.ClientOverview.Text = $ov
        $used = 0.0; foreach ($x in $v.Cache) { $used += [double]$x.MB }
        $ui.CacheInfo.Text = "$($v.Cache.Count) items, $([math]::Round($used, 1)) MB used of $($v.Client.CacheSizeMB) MB in $($v.Client.CacheLocation)"
        $ui.ClientInfo.Text = "$($v.Services.Count) services, $($v.Processes.Count) processes, $($v.Cache.Count) cache items - read $(Get-Date -Format 'HH:mm:ss') ($($r.Seconds) s)"
        $ui.StatusText.Text = "Client state read in $($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
        Update-SelectionButtons
    }
}

function Start-ClientManage {
    param([string]$Target, [string]$Action, [string]$Name, [string]$Label)
    $q = "$Action $Target '$Label' on $($script:Device.Name)?"
    if ([System.Windows.MessageBox]::Show($window, $q, 'AZITC Toolkit', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-Busy $true "$Target $Action '$Label' on $($script:Device.Name)..."
    Invoke-TKJob -Name "$Target $Action" -Script $clientManageScript -Arguments @($script:Device.Name, $Target, $Action, $Name) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "$($r.Name) failed: $($r.Error)"; return }
        $v = $r.Value
        $line = "{0}  {1} {2} '{3}': exit {4}, before [{5}], after [{6}]" -f (Get-Date -Format 'HH:mm:ss'), $v.Target, $v.Action, $v.Name, $v.ScriptExitCode, $v.Before, $v.After
        if (@($v.Done).Count) { $line += "`r`n    done: " + (@($v.Done) -join '; ') }
        if (@($v.Skipped).Count) { $line += "`r`n    skipped: " + (@($v.Skipped) -join '; ') }
        if ($v.Error) { $line += "`r`n    error: $($v.Error)" }
        $ui.ClientText.Text = ($ui.ClientText.Text + $line + "`r`n").TrimStart()
        $ui.StatusText.Text = "$($r.Name): exit $($v.ScriptExitCode), $($r.Seconds) s"
        $ui.StatusOperation.Text = "OperationId $($v.OperationId)"
        if ($v.Error) { Show-Error "$($r.Name): $($v.Error)" }
        Start-ClientRefresh
    }
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

$ui.BtnPolicyEval.Add_Click({
    Set-Busy $true "Machine policy, then application deployment evaluation on $($script:Device.Name) (about 40 s)..."
    Invoke-TKJob -Name 'Policy + evaluate' -Script $policyEvalScript -Arguments @($script:Device.ResourceId) -OnDone {
        param($r)
        Set-Busy $false
        if (-not $r.Ok) { Show-Error "Policy + evaluate failed: $($r.Error)"; return }
        $ui.StatusText.Text = "Policy (op $($r.Value.PolicyOperationId)) and evaluation (op $($r.Value.EvalOperationId)) sent - reading the list again"
        Start-Refresh
    }
})
$ui.BtnAppInstall.Add_Click({ Start-CMAppAction -Action 'Install' })
$ui.BtnAppUninstall.Add_Click({ Start-CMAppAction -Action 'Uninstall' })
$ui.BtnAppRepair.Add_Click({ Start-CMAppAction -Action 'Repair' })
$ui.BtnAppTroubleshoot.Add_Click({ Start-CMAppTroubleshoot })
$ui.GridApps.Add_SelectionChanged({ Update-SelectionButtons })
$ui.BtnClientRefresh.Add_Click({ Start-ClientRefresh })
$ui.SvcSearch.Add_TextChanged({ Apply-ClientFilters })
$ui.ProcSearch.Add_TextChanged({ Apply-ClientFilters })
$ui.GridServices.Add_SelectionChanged({ Update-SelectionButtons })
$ui.GridProcesses.Add_SelectionChanged({ Update-SelectionButtons })
$ui.GridCache.Add_SelectionChanged({ Update-SelectionButtons })
$ui.BtnSvcStart.Add_Click({ $r = $ui.GridServices.SelectedItem; if ($r) { Start-ClientManage -Target 'Service' -Action 'Start' -Name ([string]$r.Row['Name']) -Label ([string]$r.Row['DisplayName']) } })
$ui.BtnSvcStop.Add_Click({ $r = $ui.GridServices.SelectedItem; if ($r) { Start-ClientManage -Target 'Service' -Action 'Stop' -Name ([string]$r.Row['Name']) -Label ([string]$r.Row['DisplayName']) } })
$ui.BtnSvcRestart.Add_Click({ $r = $ui.GridServices.SelectedItem; if ($r) { Start-ClientManage -Target 'Service' -Action 'Restart' -Name ([string]$r.Row['Name']) -Label ([string]$r.Row['DisplayName']) } })
$ui.BtnProcKill.Add_Click({ $r = $ui.GridProcesses.SelectedItem; if ($r) { Start-ClientManage -Target 'Process' -Action 'Kill' -Name ([string]$r.Row['Id']) -Label ("$($r.Row['Name']) ($($r.Row['Id']))") } })
$ui.BtnCacheDelete.Add_Click({ $r = $ui.GridCache.SelectedItem; if ($r) { Start-ClientManage -Target 'Cache' -Action 'Delete' -Name ([string]$r.Row['CacheId']) -Label ("$($r.Row['ContentId']) v$($r.Row['Version']), $($r.Row['SizeMB']) MB") } })
$ui.BtnCacheClear.Add_Click({ Start-ClientManage -Target 'Cache' -Action 'Clear' -Name '' -Label 'every item that is not persisted and not in use' })

$ui.BtnRefresh.Add_Click({ Start-Refresh })
$ui.BtnInspect.Add_Click({ Start-Action -Action 'Inspect' -ReEvaluate $false })
$ui.BtnUninstall.Add_Click({ Start-Action -Action 'Uninstall' -ReEvaluate $false })
$ui.BtnUninstallReEval.Add_Click({ Start-Action -Action 'Uninstall' -ReEvaluate $true })
$ui.BtnRepair.Add_Click({ Start-Action -Action 'Repair' -ReEvaluate $false })
$ui.BtnRemoveEntry.Add_Click({ Start-Action -Action 'RemoveEntry' -ReEvaluate $true })
$ui.BtnLog.Add_Click({ Start-Log -Mode 'Tail' })
$ui.BtnLogList.Add_Click({ Start-Log -Mode 'List' })
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
        $window.Title = "AZITC Toolkit $toolVersion - $($script:Device.Name)$titleSite - $($script:Device.Provider)"
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
        [Console]::Out.WriteLine("autoclose: status='$($ui.StatusText.Text)' rows=$rows apps=$apps matched=$($script:SoftwareTable.Select("CMApp <> ''").Count) sevenzip='$((($script:SoftwareTable.Select("Name LIKE '7-Zip%'") | ForEach-Object { $_["CMApp"] }) -join " ; "))' services=$(if ($script:ServicesTable) { $script:ServicesTable.Rows.Count } else { 0 }) processes=$(if ($script:ProcessesTable) { $script:ProcessesTable.Rows.Count } else { 0 }) handlerError='$($script:LastHandlerError)'")
    }
    if ($script:Job) { try { $script:Job.PowerShell.Stop() } catch { } }
    try { $script:Runspace.Close() } catch { }
})

$null = $window.ShowDialog()
