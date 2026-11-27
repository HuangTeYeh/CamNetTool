#Requires -Version 5.1
<#
    CamNetTool.ps1 - 10GigE 相機整合工具（監控、診斷快照、最佳化設定、版本與更新）
    以 NicMonitor 1.1.0 為基礎擴充，保留原有功能與 CSV 欄位。

    * 只用 Windows 內建的 PowerShell 5.1 + .NET Framework (WinForms)，不需安裝任何東西。
    * 監控只做讀取：網卡計數器、ICMP ping、系統事件、GigE Vision READREG/READMEM（唯讀）。
    * 會寫入的功能（最佳化設定、驅動安裝）只在使用者按下按鈕並確認後才執行。
    * 本檔與 lib\*.ps1 必須存成 UTF-8 with BOM。

    啟動：Start_CamNetTool.bat（無命令視窗）或 CamNetTool_debug.bat（保留命令視窗）
    測試：. .\CamNetTool.ps1 -CoreOnly   只載入核心函式，不開視窗
#>
param(
    [switch]$CoreOnly
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'CamNetTool'
$script:AppVersion = '2.0.2'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:AppDir     = Split-Path -Parent $script:ScriptPath
$script:LibDir     = Join-Path $script:AppDir 'lib'

# status_*.csv：NicMonitor 1.1.0 的 17 欄全部保留，最後加 RxDiscardDeltaRaw
$script:StatusHeader = 'Time,LinkStatus,LinkSpeed,RxMBps,RxDiscardDelta,RxErrorDelta,TxDiscardDelta,TxErrorDelta,CameraPingMs,CpuPercent,AcpiTempC,RxDiscardDeltaDiv2p32,NicMacTempC,NicPhyTempC,AqRxPathReset,AqTxPathReset,AqTxWatchdog,RxDiscardDeltaRaw'
$script:EventsHeader = 'Time,Source,EventId,Level,Message'
$script:EventProviders = @('aqnic650', 'Microsoft-Windows-Kernel-Power')
$script:OverheatPattern = '(?i)temperature|overheat|溫度|過熱'
$script:AutoNicPattern  = '(?i)AQtion|Aquantia|Marvell'
$script:PingTimeoutMs   = 500
$script:MaxUiEvents     = 500
$script:MaxPendingLines = 200000
$script:Two32           = 4294967296.0

# ---------------------------------------------------------------------------
#  原生元件（GetIfEntry2、GVCP、GenICam XML）
# ---------------------------------------------------------------------------
if (-not ('GvcpClient' -as [type])) {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:LibDir 'CamNetNative.cs'))) -ReferencedAssemblies System.Xml
}

# ---------------------------------------------------------------------------
#  通用小工具
# ---------------------------------------------------------------------------
function Test-DirWritable([string]$Dir) {
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { [IO.Directory]::CreateDirectory($Dir) | Out-Null }
        $probe = Join-Path $Dir ('.write_test_' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x')
        [IO.File]::Delete($probe)
        return $true
    } catch { return $false }
}

function Get-FallbackDir { return (Join-Path $env:LOCALAPPDATA $script:AppName) }

function Test-IsAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Test-IPv4([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $t = $Text.Trim()
    if ($t -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($p in $t.Split('.')) { if ([int]$p -gt 255) { return $false } }
    return $true
}

function Format-Speed([long]$Bps) {
    if ($Bps -le 0) { return '0 bps' }
    if ($Bps -ge 1000000000) { return ('{0:0.#} Gbps' -f ($Bps / 1e9)) }
    if ($Bps -ge 1000000)    { return ('{0:0.#} Mbps' -f ($Bps / 1e6)) }
    return ('{0} Kbps' -f [math]::Round($Bps / 1e3))
}

function Format-Duration([TimeSpan]$Span) {
    $s = '{0:00}:{1:00}:{2:00}' -f [math]::Floor($Span.TotalHours % 24), $Span.Minutes, $Span.Seconds
    if ($Span.TotalDays -ge 1) { $s = ('{0} 天 ' -f [math]::Floor($Span.TotalDays)) + $s }
    return $s
}

function ConvertTo-CsvField($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [double] -or $Value -is [single]) { $s = ([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    else { $s = [string]$Value }
    $s = ($s -replace '[\r\n]+', ' ')
    if ($s -match '[",]' -or $s -ne $s.Trim()) { $s = '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Join-CsvLine([object[]]$Fields) {
    return (($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
}

# ---------------------------------------------------------------------------
#  設定檔
# ---------------------------------------------------------------------------
function New-DefaultConfig {
    return [ordered]@{
        AdapterGuid         = ''
        AdapterName         = ''
        CameraIp            = ''
        CameraIpAuto        = $true
        CameraSerial        = ''
        CameraXmlFile       = ''
        IntervalSec         = 10
        BeepOnAlarm         = $true
        AutoStartMonitoring = $false
        LogDir              = ''
        LastRecordIds       = @{}
        # 相機事件門檻
        StallSamples        = 3
        ResendWarn          = 500
        CamTempWarnC        = 60
        # 最佳化設定
        AcquisitionSoftware = 'IMAQdx'
        ThroughputLimitTarget = 300000000
        ThroughputLimitApplied = $false
        DesiredNicSettings  = @{}
        # 版本（離線時使用；線上查詢成功會更新）
        LatestCameraFw      = '1.54.0.0'
        LatestCameraFwDate  = '2025-08-06'
        LatestNicDriver     = '3.1.11.0'
        LatestArenaSdk      = '1.0.85.11'
        LatestArenaSdkDate  = '2026-08-05'
        LatestOnlineAt      = ''
        LucidProductUrl     = 'https://thinklucid.com/product/atlas10-24-5-mp-imx530/'
        LucidSoftwareUrl    = 'https://thinklucid.com/downloads-hub/'
        DriverFolder        = ''
    }
}

function Get-ConfigPath {
    if (Test-DirWritable $script:AppDir) { return (Join-Path $script:AppDir 'CamNetTool.config.json') }
    return (Join-Path (Get-FallbackDir) 'CamNetTool.config.json')
}

function Read-Config {
    $cfg = New-DefaultConfig
    $path = Get-ConfigPath
    $script:ConfigPath = $path
    $src = $path
    if (-not (Test-Path -LiteralPath $path)) {
        # 第一次使用：沿用同資料夾或上一層資料夾 NicMonitor 的設定（網卡、相機 IP、間隔）
        $nm = Join-Path $script:AppDir 'NicMonitor.config.json'
        if (-not (Test-Path -LiteralPath $nm)) {
            $parent = Split-Path -Parent $script:AppDir
            if ($parent) { $nm = Join-Path $parent 'NicMonitor.config.json' }
        }
        if (Test-Path -LiteralPath $nm) { $src = $nm } else { return $cfg }
    }
    try {
        $j = [IO.File]::ReadAllText($src) | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($src -ne $path -and $k -notin 'AdapterGuid', 'AdapterName', 'CameraIp', 'IntervalSec', 'BeepOnAlarm') { continue }
            $p = $j.PSObject.Properties[$k]
            if ($null -eq $p -or $null -eq $p.Value) { continue }
            $def = $cfg[$k]
            if ($def -is [hashtable]) {
                $h = @{}
                foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
                $cfg[$k] = $h
            } elseif ($def -is [bool]) { $cfg[$k] = [bool]$p.Value }
            elseif ($def -is [int]) { $cfg[$k] = [int]$p.Value }
            else { $cfg[$k] = [string]$p.Value }
        }
    } catch {
        $script:StartupWarning = "設定檔讀取失敗，改用預設值：$($_.Exception.Message)"
    }
    if ($cfg.IntervalSec -lt 2)   { $cfg.IntervalSec = 2 }
    if ($cfg.IntervalSec -gt 300) { $cfg.IntervalSec = 300 }
    if ($cfg.StallSamples -lt 1)  { $cfg.StallSamples = 1 }
    return $cfg
}

function Save-Config {
    try {
        $path = $script:ConfigPath
        if (-not $path) { $path = Get-ConfigPath; $script:ConfigPath = $path }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        $json = $script:Cfg | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($true)))
    } catch {
        Set-StatusMessage "設定檔寫入失敗：$($_.Exception.Message)" -IsError -Sticky
    }
}

function Get-LogDir {
    $d = $script:Cfg.LogDir
    if ([string]::IsNullOrWhiteSpace($d)) { $d = Join-Path $script:AppDir 'CamNetToolLog' }
    return $d
}

function Initialize-LogDir {
    $d = Get-LogDir
    if (Test-DirWritable $d) { $script:ActiveLogDir = $d; return $true }
    $fb = Join-Path (Get-FallbackDir) 'CamNetToolLog'
    if (Test-DirWritable $fb) {
        $script:ActiveLogDir = $fb
        Set-StatusMessage "記錄資料夾無法寫入（$d），改存到 $fb" -IsError -Sticky
        return $true
    }
    $script:ActiveLogDir = $d
    return $false
}

function Get-LogPath([string]$Kind, [datetime]$Time) {
    $dir = $script:ActiveLogDir
    if (-not $dir) { $dir = Get-LogDir }
    return (Join-Path $dir ('{0}_{1}.csv' -f $Kind, $Time.ToString('yyyyMMdd')))
}

# ---------------------------------------------------------------------------
#  記錄檔寫入（被 Excel 鎖住時先暫存在記憶體，下個週期補寫）
# ---------------------------------------------------------------------------
$script:Pending = New-Object System.Collections.Generic.List[object]
$script:LastWriteError = ''
$script:PathMap = @{}

function Get-LogHeader([string]$Kind) {
    switch ($Kind) {
        'status'    { return $script:StatusHeader }
        'camstatus' { return $script:CamStatusHeader }
        default     { return $script:EventsHeader }
    }
}

# 同一天的檔案如果是舊版程式寫的（表頭欄位不同），改寫到 _2、_3… 避免同一個檔案混兩種格式
function Get-CompatibleLogPath([string]$Path, [string]$Header) {
    if ($script:PathMap.ContainsKey($Path)) { return $script:PathMap[$Path] }
    $cand = $Path; $n = 1
    while ($true) {
        $first = $null
        if (Test-Path -LiteralPath $cand) {
            try {
                $fs = New-Object IO.FileStream($cand, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true); $first = $sr.ReadLine() } finally { $fs.Dispose() }
            } catch { $first = $Header }
        }
        if ($null -eq $first -or $first -eq $Header) { break }
        $n++
        $cand = Join-Path (Split-Path -Parent $Path) ('{0}_{1}.csv' -f [IO.Path]::GetFileNameWithoutExtension($Path), $n)
    }
    $script:PathMap[$Path] = $cand
    return $cand
}

function Add-LogLine([string]$Kind, [datetime]$Time, [string]$Line) {
    $header = Get-LogHeader $Kind
    $path = Get-CompatibleLogPath (Get-LogPath $Kind $Time) $header
    $script:Pending.Add([pscustomobject]@{ Path = $path; Header = $header; Line = $Line })
    if ($script:Pending.Count -gt $script:MaxPendingLines) {
        $script:Pending.RemoveRange(0, $script:Pending.Count - $script:MaxPendingLines)
        $script:PendingDropped = $true
    }
}

function Write-FileLines([string]$Path, [string]$Header, $Lines) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $sw = $null
    try {
        $sw = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding($true)))
        if ($fs.Length -eq 0) { $sw.WriteLine($Header) }
        foreach ($l in $Lines) { $sw.WriteLine($l) }
        $sw.Flush()
    } finally {
        if ($sw) { $sw.Dispose() } else { $fs.Dispose() }
    }
}

function Invoke-FlushLogs {
    if ($script:Pending.Count -eq 0) { $script:LastWriteError = ''; return $true }
    $groups = [ordered]@{}
    foreach ($p in $script:Pending) {
        if (-not $groups.Contains($p.Path)) { $groups[$p.Path] = New-Object System.Collections.Generic.List[object] }
        $groups[$p.Path].Add($p)
    }
    $remaining = New-Object System.Collections.Generic.List[object]
    $err = ''
    foreach ($path in $groups.Keys) {
        $items = $groups[$path]
        try {
            Write-FileLines $path $items[0].Header ($items | ForEach-Object { $_.Line })
        } catch {
            foreach ($i in $items) { $remaining.Add($i) }
            $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
            $why = if ($ex -is [IO.IOException]) { '被其他程式使用中' } else { $ex.Message }
            $err = "$([IO.Path]::GetFileName($path)) $why"
        }
    }
    $script:Pending = $remaining
    $script:LastWriteError = $err
    return ($remaining.Count -eq 0)
}

function Save-UnflushedLines {
    if ($script:Pending.Count -eq 0) { return }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    foreach ($g in ($script:Pending | Group-Object Path)) {
        $name = 'unsaved_{0}_{1}.csv' -f [IO.Path]::GetFileNameWithoutExtension($g.Name), $stamp
        $alt = Join-Path (Split-Path -Parent $g.Name) $name
        try { Write-FileLines $alt $g.Group[0].Header ($g.Group | ForEach-Object { $_.Line }) } catch { }
    }
    $script:Pending.Clear()
}

# ---------------------------------------------------------------------------
#  取樣：網卡、ping、CPU、主機板溫度、網卡晶片溫度
# ---------------------------------------------------------------------------
function Get-AdapterList {
    $list = @()
    foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $list += [pscustomobject]@{ Name = [string]$a.Name; Description = [string]$a.InterfaceDescription; Status = [string]$a.Status; Guid = [string]$a.InterfaceGuid }
    }
    return $list
}

$script:UseNativeIf = ([NicMonNative]::RowSize -eq 1352)

function Find-NetworkInterface([string]$Guid) {
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ([string]::Equals($ni.Id, $Guid, [StringComparison]::OrdinalIgnoreCase)) { return $ni }
    }
    return $null
}

function Get-CpuPercent {
    $idle = 0L; $kernel = 0L; $user = 0L
    if (-not [NicMonNative]::GetSystemTimes([ref]$idle, [ref]$kernel, [ref]$user)) { return $null }
    $prev = $script:CpuPrev
    $script:CpuPrev = @($idle, $kernel, $user)
    if ($null -eq $prev) { return $null }
    $total = ($kernel - $prev[1]) + ($user - $prev[2])
    if ($total -le 0) { return $null }
    $busy = $total - ($idle - $prev[0])
    return [math]::Round([math]::Max(0, [math]::Min(100, 100.0 * $busy / $total)), 1)
}

# 主機板（ACPI 溫度區域）溫度：效能計數器每次都會重新量測，不需要系統管理員權限
function Get-AcpiTemperature {
    $best = $null
    try {
        foreach ($z in @(Get-CimInstance -ClassName 'Win32_PerfRawData_Counters_ThermalZoneInformation' -ErrorAction Stop)) {
            $k = [double]$z.HighPrecisionTemperature / 10.0
            if ($k -le 0) { $k = [double]$z.Temperature }
            if ($k -le 0) { continue }
            $c = $k - 273.15
            if ($null -eq $best -or $c -gt $best.C) { $best = @{ C = [math]::Round($c, 1); Zone = ([string]$z.Name -replace '^\\_TZ\.', '') } }
        }
    } catch { }
    if ($best) { return $best }
    foreach ($z in @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)) {
        if ($z.CurrentTemperature -le 0) { continue }
        $c = $z.CurrentTemperature / 10.0 - 273.15
        if ($null -eq $best -or $c -gt $best.C) { $best = @{ C = [math]::Round($c, 1); Zone = ([string]$z.InstanceName -replace '^ACPI\\ThermalZone\\', '') + '（MSAcpi）' } }
    }
    if (-not $best) { throw '系統沒有提供可用的 ACPI 溫度區域' }
    return $best
}

# 網卡晶片溫度與驅動內部的重置計數（AQtion WMI Aq_DiagnosticsData，只讀屬性）。需要系統管理員權限。
function Get-AqDiagnostics([string]$Description) {
    $all = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'Aq_DiagnosticsData' -ErrorAction Stop)
    $d = $all | Where-Object { $_.InstanceName -eq $Description } | Select-Object -First 1
    if (-not $d) { $d = $all | Where-Object { $_.InstanceName -like "$Description*" } | Select-Object -First 1 }
    if (-not $d) { return $null }
    $ti = $d.thermalInfo
    $mac = $null; $phy = $null
    if ($ti) {
        if ([int]$ti.macTemperature -gt 0) { $mac = [math]::Round([int]$ti.macTemperature / 100.0, 1) }
        if ([int]$ti.phyTemperature -gt 0) { $phy = [math]::Round([int]$ti.phyTemperature / 100.0, 1) }
    }
    return @{ MacC = $mac; PhyC = $phy; RxReset = [long]$d.rxPathResetCount; TxReset = [long]$d.txPathResetCount; TxWatchdog = [long]$d.txWatchdogEventCount }
}

# 相機 ping 的來源 IP：所選網卡上與相機同網段的 IPv4（等同 ping -S）。
# 查一次就快取；相機 IP 改變時立刻重查，沒有來源或 ping 失敗時每 30 秒重查一次（網卡 IP 可能改變）。
function Update-PingSource($S, [datetime]$Now) {
    $stale = (-not $S.PingSrc -or $S.LastPingOk -eq $false) -and ($Now - $S.PingSrcAt).TotalSeconds -ge 30
    if ($S.PingSrcFor -eq $S.CameraIp -and -not $stale) { return $S.PingSrc }
    $S.PingSrcAt = $Now
    $new = ''
    try { $new = [string](Get-LocalIpForCamera $S.Guid $S.CameraIp) } catch { }
    if ($S.PingSrcFor -and $new -ne $S.PingSrc) {
        $from = if ($S.PingSrc) { $S.PingSrc } else { '（無）' }
        $to = if ($new) { $new } else { '（網卡沒有 IPv4）' }
        Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 22 -Severity Info -Message "相機 ping 來源改變：$from → $to（相機 $($S.CameraIp)）"
    }
    $S.PingSrc = $new; $S.PingSrcFor = $S.CameraIp
    return $new
}

function Get-MonitorSample {
    $S = $script:S
    $smp = @{
        Ts = [Diagnostics.Stopwatch]::GetTimestamp(); LinkStatus = 'Missing'; SpeedBps = 0L; Stats = $null
        PingOk = $null; PingMs = $null; PingStatus = ''; Cpu = $null; TempC = $null; TempZone = ''; Aq = $null; Errors = @()
    }
    try {
        $ni = $null; $row = New-Object 'NicMonNative+MIB_IF_ROW2'; $rc = -1
        if ($script:UseNativeIf) { $rc = [NicMonNative]::QueryInterface($S.Guid, [ref]$row) }
        if ($script:UseNativeIf -and $rc -eq 0 -and ($row.OperStatus -eq 1 -or $row.OperStatus -eq 2)) {
            $smp.LinkStatus = if ($row.OperStatus -eq 1) { 'Up' } else { 'Disconnected' }
            $smp.SpeedBps = [long]$row.ReceiveLinkSpeed
            $smp.Stats = @{ RxBytes = [uint64]$row.InOctets; RxDisc = [uint64]$row.InDiscards; RxErr = [uint64]$row.InErrors; TxDisc = [uint64]$row.OutDiscards; TxErr = [uint64]$row.OutErrors }
        } elseif ($script:UseNativeIf) {
            $a = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $S.Guid } | Select-Object -First 1
            if ($a) { $smp.LinkStatus = if ([string]$a.Status -eq 'Up') { 'Up' } else { [string]$a.Status } } else { $smp.LinkStatus = 'Missing' }
        } elseif (($ni = Find-NetworkInterface $S.Guid)) {
            $op = $ni.OperationalStatus
            $smp.LinkStatus = switch ([string]$op) { 'Up' { 'Up' } 'Down' { 'Disconnected' } 'NotPresent' { 'Missing' } default { [string]$op } }
            $smp.SpeedBps = [long]$ni.Speed
            $st = $ni.GetIPStatistics()
            $smp.Stats = @{ RxBytes = [uint64]$st.BytesReceived; RxDisc = [uint64]$st.IncomingPacketsDiscarded; RxErr = [uint64]$st.IncomingPacketsWithErrors; TxDisc = [uint64]$st.OutgoingPacketsDiscarded; TxErr = [uint64]$st.OutgoingPacketsWithErrors }
        } else {
            $a = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $S.Guid } | Select-Object -First 1
            if ($a) { $smp.LinkStatus = [string]$a.Status } else { $smp.LinkStatus = 'Missing' }
        }
    } catch { $smp.Errors += "網卡：$($_.Exception.Message)" }

    if ($S.CameraIp) {
        $src = Update-PingSource $S (Get-Date)
        if (-not $src) {
            $smp.PingOk = $false
            $smp.PingStatus = 'NoSourceIp'          # 所選網卡沒有 IPv4：不送 ping，也不改從別張網卡送
        } else {
            try {
                $r = $script:Pinger.Send($src, $S.CameraIp, $script:PingTimeoutMs)
                $smp.PingStatus = $r.StatusText
                $smp.PingOk = $r.Ok
                if ($smp.PingOk) { $smp.PingMs = [long]$r.RoundtripMs }
            } catch {
                $smp.PingOk = $false
                $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
                $smp.PingStatus = 'Error: ' + $inner.Message
            }
        }
    }

    try { $smp.Cpu = Get-CpuPercent } catch { $smp.Errors += "CPU：$($_.Exception.Message)" }

    if ($S.ThermalEnabled) {
        try { $t = Get-AcpiTemperature; $smp.TempC = $t.C; $smp.TempZone = $t.Zone }
        catch {
            $S.ThermalEnabled = $false
            $msg = $_.Exception.Message
            if ($msg -match '拒絕存取|Access is denied|Access denied') { $msg = '需要系統管理員權限' }
            $S.ThermalNote = "無法讀取（$msg），已停用"
            Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 90 -Severity Info -Message "主機板溫度無法讀取（$msg），此欄位已停用"
        }
    }

    if ($S.AqEnabled) {
        $nowTs = $smp.Ts
        if ($S.AqLastTs -eq 0 -or ($nowTs - $S.AqLastTs) / [double][Diagnostics.Stopwatch]::Frequency -ge 9.5) {
            try {
                $S.AqLastTs = $nowTs
                $aq = Get-AqDiagnostics $S.AdapterDescription
                if ($aq) { $smp.Aq = $aq; $S.AqLast = $aq; $S.AqMissCount = 0 }
                else {
                    $S.AqMissCount = $S.AqMissCount + 1
                    if ($S.AqMissCount -ge 3) { throw '驅動沒有提供這張網卡的診斷資料' }
                }
            } catch {
                $S.AqEnabled = $false
                $msg = $_.Exception.Message
                if ($msg -match '拒絕存取|Access is denied|Access denied') { $msg = '需要以系統管理員身分執行' }
                elseif ($msg -match '無效的類別|Invalid class|類別無效') { $msg = '網卡驅動沒有提供 Aq_DiagnosticsData' }
                $S.AqNote = "無法讀取（$msg）"
                Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 91 -Severity Info -Message "網卡晶片溫度無法讀取（$msg），此欄位已停用"
            }
        } else {
            $smp.Aq = $S.AqLast
        }
    }
    return $smp
}

# ---------------------------------------------------------------------------
#  事件
# ---------------------------------------------------------------------------
function Add-MonitorEvent {
    param(
        [datetime]$Time, [string]$Source, $EventId,
        [ValidateSet('Info', 'Warning', 'Error', 'Overheat')][string]$Severity,
        [string]$Message, [switch]$NoAlarm
    )
    $S = $script:S
    $levelText = @{ Info = '資訊'; Warning = '警告'; Error = '錯誤'; Overheat = '過熱' }[$Severity]
    $msg = ($Message -replace '[\r\n]+', ' ' -replace '\s{2,}', ' ').Trim()
    $ev = [pscustomobject]@{ Time = $Time; Source = $Source; EventId = $EventId; Severity = $Severity; Level = $levelText; Message = $msg }
    Add-LogLine 'events' $Time (Join-CsvLine @($Time.ToString('yyyy-MM-dd HH:mm:ss'), $Source, $EventId, $levelText, $msg))
    if ($S) {
        $S.Events.Insert(0, $ev)
        if ($S.Events.Count -gt $script:MaxUiEvents) { $S.Events.RemoveAt($S.Events.Count - 1) }
        if ($Severity -ne 'Info' -and -not $NoAlarm) {
            $S.LastAnomalyTime = $Time
            $S.LastAnomalySource = "$Source（$EventId）$msg"
            $S.AlarmPending = $true
        }
    }
    if ($script:OnEvent) { try { & $script:OnEvent $ev } catch { } }
}

function Read-NewSystemEvents([string]$Provider, [long]$AfterRecordId, [int]$Max = 200) {
    $xpath = "*[System[Provider[@Name='$Provider'] and (EventRecordID > $AfterRecordId)]]"
    $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)
    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
    $list = New-Object System.Collections.Generic.List[object]
    try {
        while ($list.Count -lt $Max) {
            $r = $reader.ReadEvent()
            if ($null -eq $r) { break }
            try {
                $msg = $null
                try { $msg = $r.FormatDescription() } catch { }
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = (@($r.Properties | ForEach-Object { [string]$_.Value }) -join ' ') }
                $lvl = 0; if ($null -ne $r.Level) { $lvl = [int]$r.Level }
                $list.Add([pscustomobject]@{ RecordId = [long]$r.RecordId; Id = [int]$r.Id; Level = $lvl; Time = $r.TimeCreated; Provider = $Provider; Message = [string]$msg })
            } finally { $r.Dispose() }
        }
    } finally { $reader.Dispose() }
    return , $list
}

function Get-LatestRecordId([string]$Provider) {
    $xpath = "*[System[Provider[@Name='$Provider']]]"
    $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)
    $q.ReverseDirection = $true
    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
    try {
        $r = $reader.ReadEvent()
        if ($null -eq $r) { return 0L }
        try { return [long]$r.RecordId } finally { $r.Dispose() }
    } finally { $reader.Dispose() }
}

function Get-EventSeverity($Ev) {
    if ($Ev.Message -match $script:OverheatPattern) { return 'Overheat' }
    if ($Ev.Level -eq 1 -or $Ev.Level -eq 2) { return 'Error' }
    if ($Ev.Level -eq 3) { return 'Warning' }
    return 'Info'
}

function Get-EventLabel([string]$Provider, [int]$Id) {
    if ($Provider -eq 'aqnic650') {
        switch ($Id) { 14 { return '驅動回報 link down' } 15 { return '驅動回報 link up' } }
    } elseif ($Provider -eq 'Microsoft-Windows-Kernel-Power') {
        switch ($Id) { 41 { return '異常斷電／未正常關機' } 42 { return '進入睡眠' } 107 { return '從睡眠喚醒' } 109 { return '開始關機' } 506 { return '進入新式待命' } 507 { return '離開新式待命' } }
    }
    return ''
}

function Add-SystemEventRecord($Ev, [switch]$Historic) {
    $S = $script:S
    $sev = Get-EventSeverity $Ev
    $label = Get-EventLabel $Ev.Provider $Ev.Id
    $msg = $Ev.Message
    if ($label) { $msg = "$label：$msg" }
    if ($Historic) { $msg = "[監控停止期間] $msg" }
    else {
        if ($sev -eq 'Overheat') { $S.OverheatCount++ }
        elseif ($Ev.Provider -eq 'aqnic650' -and ($sev -eq 'Warning' -or $sev -eq 'Error')) { $S.DriverWarnCount++ }
    }
    $t = if ($Ev.Time) { [datetime]$Ev.Time } else { Get-Date }
    Add-MonitorEvent -Time $t -Source $Ev.Provider -EventId $Ev.Id -Severity $sev -Message $msg -NoAlarm:$Historic
}

function Get-SystemLatestRecordId {
    $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, '*')
    $q.ReverseDirection = $true
    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
    try {
        $r = $reader.ReadEvent()
        if ($null -eq $r) { return 0L }
        try { return [long]$r.RecordId } finally { $r.Dispose() }
    } finally { $reader.Dispose() }
}

function Invoke-PollSystemEvents {
    $S = $script:S
    $sysLatest = -1L
    try { $sysLatest = Get-SystemLatestRecordId } catch { $sysLatest = -1L }
    if ($sysLatest -ge 0 -and $S.ContainsKey('SystemLatestSeen') -and $S.SystemLatestSeen -eq $sysLatest) { return }
    $complete = $true
    foreach ($p in $script:EventProviders) {
        try {
            $after = 0L
            if ($S.LastRecordIds.ContainsKey($p)) { $after = [long]$S.LastRecordIds[$p] }
            $evs = Read-NewSystemEvents $p $after
            if ($evs.Count -ge 200) { $complete = $false }
            foreach ($e in $evs) {
                if ($e.RecordId -le $after) { continue }
                Add-SystemEventRecord $e
                $after = $e.RecordId
                $S.LastRecordIds[$p] = $after
                $S.RecordIdsDirty = $true
            }
        } catch {
            $complete = $false
            $S.TickErrors += "事件記錄（$p）：$($_.Exception.Message)"
        }
    }
    if ($complete -and $sysLatest -ge 0) { $S.SystemLatestSeen = $sysLatest }
}

function Initialize-EventBaseline {
    $S = $script:S
    $saved = $script:Cfg.LastRecordIds
    foreach ($p in $script:EventProviders) {
        try {
            $latest = Get-LatestRecordId $p
            if ($saved -and $saved.ContainsKey($p)) {
                $old = [long]$saved[$p]
                if ($old -gt 0 -and $old -le $latest) {
                    $missed = Read-NewSystemEvents $p $old 100
                    foreach ($e in $missed) { Add-SystemEventRecord $e -Historic }
                }
            }
            $S.LastRecordIds[$p] = $latest
        } catch {
            $S.LastRecordIds[$p] = 0L
            Set-StatusMessage "事件來源 $p 讀取失敗：$($_.Exception.Message)" -IsError -Sticky
        }
    }
    $script:Cfg.LastRecordIds = @{} + $S.LastRecordIds
}

# ---------------------------------------------------------------------------
#  相機核心（lib\Camera.ps1）
# ---------------------------------------------------------------------------
. (Join-Path $script:LibDir 'Camera.ps1')

# ---------------------------------------------------------------------------
#  監控狀態機
# ---------------------------------------------------------------------------
function New-MonitorState([string]$Guid, [string]$AdapterName, [string]$CameraIp) {
    return @{
        Running = $false; StartTime = $null
        Guid = $Guid; AdapterName = $AdapterName; CameraIp = $CameraIp
        LastLink = $null; LastUpSpeed = 0L; LinkDownSince = $null
        LastPingOk = $null; PingDownSince = $null
        PingSrc = ''; PingSrcFor = ''; PingSrcAt = [datetime]::MinValue
        PrevStats = $null; PrevTs = 0L
        Cum = @{ RxDisc = 0L; RxErr = 0L; TxDisc = 0L; TxErr = 0L; RxDiscRaw = 0.0 }
        DiscardPacked = $false
        LinkDownCount = 0; PingFailCount = 0; DriverWarnCount = 0; OverheatCount = 0
        LastAnomalyTime = $null; LastAnomalySource = ''
        LastRecordIds = @{}; RecordIdsDirty = $false
        ThermalEnabled = $true; ThermalNote = ''; MaxBoardC = $null
        AdapterDescription = ''
        AqEnabled = $true; AqNote = ''; AqLastTs = 0L; AqLast = $null; AqMissCount = 0; AqPrev = $null
        NicResetCount = 0; MaxMacC = $null; MaxPhyC = $null
        Cam = $null; CamNote = ''
        Events = New-Object System.Collections.Generic.List[object]
        AlarmPending = $false; Last = $null; TickErrors = @(); LastSampleTime = $null
    }
}

function Invoke-ProcessSample($Smp, [datetime]$Now) {
    $S = $script:S
    $status = $Smp.LinkStatus
    $speedText = Format-Speed $Smp.SpeedBps

    if ($null -eq $S.LastLink) {
        if ($status -ne 'Up') {
            $S.LinkDownCount++; $S.LinkDownSince = $Now
            Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 10 -Severity Warning -Message "連線中斷（開始監控時網卡狀態：$status）"
        }
    } elseif ($S.LastLink -eq 'Up' -and $status -ne 'Up') {
        $S.LinkDownCount++; $S.LinkDownSince = $Now
        Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 10 -Severity Warning -Message "連線中斷（Up → $status）"
    } elseif ($S.LastLink -ne 'Up' -and $status -eq 'Up') {
        $dur = ''
        if ($S.LinkDownSince) { $dur = '，約中斷 ' + (Format-Duration ($Now - $S.LinkDownSince)) }
        Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 11 -Severity Info -Message "連線恢復（$($S.LastLink) → Up，$speedText$dur）"
        $S.LinkDownSince = $null
    } elseif ($S.LastLink -ne $status) {
        Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 12 -Severity Warning -Message "網卡狀態改變（$($S.LastLink) → $status）"
    }
    if ($status -eq 'Up') {
        if ($S.LastUpSpeed -gt 0 -and $Smp.SpeedBps -ne $S.LastUpSpeed) {
            $sev = if ($Smp.SpeedBps -lt $S.LastUpSpeed) { 'Warning' } else { 'Info' }
            Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 13 -Severity $sev -Message "連線速度改變（$(Format-Speed $S.LastUpSpeed) → $speedText）"
        }
        $S.LastUpSpeed = $Smp.SpeedBps
    }
    $S.LastLink = $status

    # --- 計數器增量（變小 = 驅動重載/歸零，當作 0）---
    # 接收丟棄：AQtion 驅動把真正的計數放在 64 位元的高 32 位元（低 32 位元不相干），
    # AQtion 網卡（或已偵測到這種格式）一律取高 32 位元的差；原始差值另存在 RxDiscardDeltaRaw。
    $d = @{ RxDisc = $null; RxErr = $null; TxDisc = $null; TxErr = $null; RxDiscRaw = $null }
    $rxMBps = $null
    if ($Smp.Stats) {
        if ($S.PrevStats) {
            $packed = $false
            $hint = [bool]$S.DiscardPacked -or ($S.AdapterDescription -match $script:AutoNicPattern)
            $d.RxDisc = [NicMonNative]::DiscardDelta([uint64]$S.PrevStats.RxDisc, [uint64]$Smp.Stats.RxDisc, $hint, [ref]$packed)
            if ($packed) { $S.DiscardPacked = $true }
            $raw = if ([uint64]$Smp.Stats.RxDisc -ge [uint64]$S.PrevStats.RxDisc) { [decimal][uint64]$Smp.Stats.RxDisc - [decimal][uint64]$S.PrevStats.RxDisc } else { [decimal]0 }
            $d.RxDiscRaw = $raw
            $S.Cum.RxDisc += $d.RxDisc
            $S.Cum.RxDiscRaw += [double]$raw
            foreach ($k in @('RxErr', 'TxDisc', 'TxErr')) {
                $v = [decimal][uint64]$Smp.Stats[$k] - [decimal][uint64]$S.PrevStats[$k]
                if ($v -lt 0) { $v = 0 }
                $d[$k] = [long]$v
                $S.Cum[$k] += [long]$v
            }
            $bytes = [decimal][uint64]$Smp.Stats.RxBytes - [decimal][uint64]$S.PrevStats.RxBytes
            if ($bytes -lt 0) {
                $bytes = 0
                Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 30 -Severity Info -Message '網卡計數器歸零（可能是驅動重新載入），本次增量以 0 計'
            }
            $sec = ($Smp.Ts - $S.PrevTs) / [double][Diagnostics.Stopwatch]::Frequency
            if ($sec -gt 0) { $rxMBps = [math]::Round([double]$bytes / $sec / 1e6, 2) }
        } else {
            foreach ($k in @('RxDisc', 'RxErr', 'TxDisc', 'TxErr')) { $d[$k] = 0L }
            $d.RxDiscRaw = 0
        }
        $S.PrevStats = $Smp.Stats
        $S.PrevTs = $Smp.Ts
    } else {
        $S.PrevStats = $null
    }

    $pingField = ''
    if ($S.CameraIp) {
        $ok = [bool]$Smp.PingOk
        if ($ok) { $pingField = $Smp.PingMs } else { $pingField = 'Fail:' + $Smp.PingStatus; $S.PingFailCount++ }
        if ($null -eq $S.LastPingOk) {
            if (-not $ok) {
                $S.PingDownSince = $Now
                Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 20 -Severity Warning -Message "相機 ping 失敗（$($S.CameraIp)，$($Smp.PingStatus)）"
            }
        } elseif ($S.LastPingOk -and -not $ok) {
            $S.PingDownSince = $Now
            Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 20 -Severity Warning -Message "相機 ping 失敗（$($S.CameraIp)，$($Smp.PingStatus)）"
        } elseif (-not $S.LastPingOk -and $ok) {
            $dur = ''
            if ($S.PingDownSince) { $dur = '，約中斷 ' + (Format-Duration ($Now - $S.PingDownSince)) }
            Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 21 -Severity Info -Message "相機 ping 恢復（$($S.CameraIp)，$($Smp.PingMs) ms$dur）"
            $S.PingDownSince = $null
        }
        $S.LastPingOk = $ok
    }

    if ($null -ne $Smp.TempC -and ($null -eq $S.MaxBoardC -or $Smp.TempC -gt $S.MaxBoardC)) { $S.MaxBoardC = $Smp.TempC }

    $aq = $Smp.Aq
    if ($aq) {
        if ($null -ne $aq.MacC -and ($null -eq $S.MaxMacC -or $aq.MacC -gt $S.MaxMacC)) { $S.MaxMacC = $aq.MacC }
        if ($null -ne $aq.PhyC -and ($null -eq $S.MaxPhyC -or $aq.PhyC -gt $S.MaxPhyC)) { $S.MaxPhyC = $aq.PhyC }
        $p = $S.AqPrev
        if ($p -and -not [object]::ReferenceEquals($p, $aq)) {
            $names = [ordered]@{ RxReset = '接收路徑重置（rxPathReset）'; TxReset = '傳送路徑重置（txPathReset）'; TxWatchdog = '傳送逾時 watchdog（txWatchdogEvent）' }
            foreach ($k in $names.Keys) {
                $inc = [long]$aq[$k] - [long]$p[$k]
                if ($inc -gt 0) {
                    $S.NicResetCount += $inc
                    $S.DriverWarnCount++
                    Add-MonitorEvent -Time $Now -Source $script:AppName -EventId 40 -Severity Warning -Message ("網卡驅動{0} +{1}（累計 {2}）" -f $names[$k], $inc, $aq[$k])
                }
            }
        }
        $S.AqPrev = $aq
    }

    $hi32 = $null
    if ($null -ne $d.RxDiscRaw) { $hi32 = [math]::Round([double]$d.RxDiscRaw / $script:Two32, 2) }
    $speedField = if ($Smp.SpeedBps -gt 0 -and $status -eq 'Up') { $speedText } else { '' }
    $aqF = if ($aq) { @($aq.MacC, $aq.PhyC, $aq.RxReset, $aq.TxReset, $aq.TxWatchdog) } else { @($null, $null, $null, $null, $null) }
    Add-LogLine 'status' $Now (Join-CsvLine (@(
        $Now.ToString('yyyy-MM-dd HH:mm:ss'), $status, $speedField, $rxMBps,
        $d.RxDisc, $d.RxErr, $d.TxDisc, $d.TxErr, $pingField, $Smp.Cpu, $Smp.TempC, $hi32) + $aqF + @($d.RxDiscRaw)))

    $S.Last = @{ Smp = $Smp; Delta = $d; RxMBps = $rxMBps; Hi32 = $hi32; Time = $Now }
    $S.LastSampleTime = $Now
}

function Start-Monitoring {
    $cfg = $script:Cfg
    $script:S = New-MonitorState $cfg.AdapterGuid $cfg.AdapterName ($cfg.CameraIp.Trim())
    $S = $script:S
    $script:CpuPrev = $null
    $script:Pinger = New-Object SourcePing
    [void](Initialize-LogDir)
    try {
        $na = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $S.Guid } | Select-Object -First 1
        if ($na) { $S.AdapterDescription = [string]$na.InterfaceDescription }
    } catch { }
    if ($S.AdapterDescription -notmatch $script:AutoNicPattern) { $S.AqEnabled = $false; $S.AqNote = '這張網卡不支援' }
    Initialize-EventBaseline
    $S.Running = $true
    $S.StartTime = Get-Date
    $S.Cam = New-CameraState
    $camOk = $false
    try { $camOk = Start-CameraMonitoring } catch { $S.CamNote = "相機連線失敗：$($_.Exception.Message)" }
    $mode = if ($cfg.CameraIpAuto) { '自動偵測' } else { '手動' }
    if ($S.CameraIp) {
        $src = Update-PingSource $S $S.StartTime
        $srcText = if ($src) { "，ping 從 $src 送出" } else { '，網卡沒有 IPv4，ping 暫停' }
        $ipText = "$($S.CameraIp)（$mode$srcText）"
    } else { $ipText = "（找不到，不 ping）（$mode）" }
    Add-MonitorEvent -Time $S.StartTime -Source $script:AppName -EventId 1 -Severity Info -Message ("監控開始（網卡：{0}，相機 IP：{1}，取樣間隔 {2} 秒，{3} {4}）" -f $S.AdapterName, $ipText, $cfg.IntervalSec, $script:AppName, $script:AppVersion)
    if (-not $camOk -and $S.CamNote) {
        Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 102 -Severity Warning -Message "相機監控暫時無法開始：$($S.CamNote)。之後每分鐘自動重試" -NoAlarm
    }
    [void](Invoke-FlushLogs)
    Save-Config
}

function Stop-Monitoring([string]$Reason = '使用者按下停止') {
    $S = $script:S
    if (-not $S -or -not $S.Running) { return }
    $S.Running = $false
    $now = Get-Date
    $span = Format-Duration ($now - $S.StartTime)
    $tmax = @()
    if ($null -ne $S.MaxBoardC) { $tmax += "主機板最高 $($S.MaxBoardC) °C" }
    if ($null -ne $S.MaxMacC) { $tmax += "網卡 MAC 最高 $($S.MaxMacC) °C" }
    if ($null -ne $S.MaxPhyC) { $tmax += "網卡 PHY 最高 $($S.MaxPhyC) °C" }
    $C = $S.Cam
    if ($C -and $null -ne $C.MaxTempC) { $tmax += "相機最高 $($C.MaxTempC) °C" }
    $tmaxText = if ($tmax.Count) { '；' + ($tmax -join '、') } else { '' }
    $camText = ''
    if ($C) { $camText = "；相機卡住 {0} 次、無回應 {1} 次、重開機 {2} 次、連線重置 {3} 次、重送累計 {4:N0}、無法重送累計 {5:N0}" -f $C.CntStall, $C.CntNoResp, $C.CntReboot, $C.CntLinkReset, $C.SumResend, $C.SumUnavail }
    Add-MonitorEvent -Time $now -Source $script:AppName -EventId 2 -Severity Info -Message ("監控結束（{0}，已監控 {1}；斷線 {2} 次、ping 失敗 {3} 次、驅動警告 {4} 次、過熱警告 {5} 次、網卡重置 {6} 次、接收丟棄累計 {7:N0}{8}{9}）" -f $Reason, $span, $S.LinkDownCount, $S.PingFailCount, $S.DriverWarnCount, $S.OverheatCount, $S.NicResetCount, $S.Cum.RxDisc, $camText, $tmaxText)
    [void](Invoke-FlushLogs)
    $script:Cfg.LastRecordIds = @{} + $S.LastRecordIds
    Save-Config
    Disconnect-Camera
    if ($script:Pinger) { $script:Pinger.Dispose(); $script:Pinger = $null }
}

function Invoke-MonitorTick {
    $S = $script:S
    if (-not $S -or -not $S.Running) { return }
    $S.TickErrors = @()
    $now = Get-Date
    $smp = Get-MonitorSample
    $S.TickErrors += $smp.Errors
    Invoke-ProcessSample $smp $now
    try { Invoke-CameraTick $now $S.Last.RxMBps } catch { $S.TickErrors += "相機：$($_.Exception.Message)" }
    Invoke-PollSystemEvents
    [void](Invoke-FlushLogs)
    if ($S.RecordIdsDirty) {
        $S.RecordIdsDirty = $false
        $script:Cfg.LastRecordIds = @{} + $S.LastRecordIds
        Save-Config
    }
}

function Set-StatusMessage([string]$Text, [switch]$IsError, [switch]$Sticky) {
    $script:LastStatusMessage = $Text
    if ($Sticky) { $script:StickyUntil = (Get-Date).AddSeconds(15) }
    if ($script:UiSetStatus) { try { & $script:UiSetStatus $Text $IsError.IsPresent } catch { } }
    else { Write-Verbose $Text }
}

# ---------------------------------------------------------------------------
#  開機自動執行（使用者「啟動」資料夾捷徑）
# ---------------------------------------------------------------------------
function Get-StartupShortcutPath { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'CamNetTool.lnk') }

function Add-StartupShortcut {
    $sh = New-Object -ComObject WScript.Shell
    try {
        $lnk = $sh.CreateShortcut((Get-StartupShortcutPath))
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$($script:ScriptPath)`""
        $lnk.WorkingDirectory = $script:AppDir
        $lnk.WindowStyle = 7
        $lnk.Description = 'CamNetTool 相機與網卡監控'
        $lnk.Save()
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
}

function Remove-StartupShortcut {
    $p = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# ---------------------------------------------------------------------------
#  用 Excel 開啟今日記錄（複製到 %TEMP% 再開，不鎖原始檔）
# ---------------------------------------------------------------------------
function Copy-FileShared([string]$Src, [string]$Dst) {
    $in = New-Object IO.FileStream($Src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $out = New-Object IO.FileStream($Dst, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

function Find-SpreadsheetApp {
    foreach ($exe in 'excel.exe', 'scalc.exe') {
        foreach ($root in 'HKCU:', 'HKLM:') {
            $k = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
            try {
                $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)'
                if ($v -and (Test-Path -LiteralPath $v.Trim('"'))) { return [pscustomobject]@{ Exe = $exe; Path = $v.Trim('"') } }
            } catch { }
        }
    }
    return $null
}

function Open-TodayLogCopy {
    [void](Invoke-FlushLogs)
    $today = Get-Date
    $files = @(foreach ($k in 'status', 'camstatus', 'events') { Get-CompatibleLogPath (Get-LogPath $k $today) (Get-LogHeader $k) }) | Where-Object { Test-Path -LiteralPath $_ }
    if (@($files).Count -eq 0) { Set-StatusMessage '今天還沒有記錄檔。' -IsError -Sticky; return }
    try {
        Get-ChildItem -LiteralPath $env:TEMP -Filter 'CamNetTool_*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
    } catch { }
    $stamp = $today.ToString('HHmmss')
    $app = Find-SpreadsheetApp
    $opened = @()
    foreach ($f in $files) {
        $dst = Join-Path $env:TEMP ('CamNetTool_{0}_{1}.csv' -f [IO.Path]::GetFileNameWithoutExtension($f), $stamp)
        Copy-FileShared $f $dst
        if ($app) { Start-Process -FilePath $app.Path -ArgumentList "`"$dst`"" }
        else { try { Start-Process -FilePath $dst } catch { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$dst`"" } }
        $opened += $dst
    }
    $how = if ($app -and $app.Exe -eq 'excel.exe') { 'Excel' } elseif ($app) { 'LibreOffice Calc（找不到 Excel）' } else { '預設程式' }
    Set-StatusMessage ("已用 {0} 開啟副本：{1}" -f $how, (($opened | ForEach-Object { [IO.Path]::GetFileName($_) }) -join '、')) -Sticky
}

# ---------------------------------------------------------------------------
#  其他模組（診斷快照、最佳化設定、版本與更新）
# ---------------------------------------------------------------------------
foreach ($m in 'Diag.ps1', 'Optimize.ps1', 'Versions.ps1') {
    $p = Join-Path $script:LibDir $m
    if (Test-Path -LiteralPath $p) { . $p }
}

# ===========================================================================
if ($CoreOnly) { return }
# ===========================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- 只能同時執行一個 ---
$script:MutexCreated = $false
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\CamNetTool_SingleInstance', [ref]$script:MutexCreated)
} catch {
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\CamNetTool_SingleInstance', [ref]$script:MutexCreated)
}
if (-not $script:MutexCreated) {
    # 以系統管理員重新開啟時，舊視窗可能還在關閉中：等幾秒再判斷
    try { $script:MutexCreated = $script:Mutex.WaitOne(4000) } catch [System.Threading.AbandonedMutexException] { $script:MutexCreated = $true }
}
if (-not $script:MutexCreated) {
    [void][System.Windows.Forms.MessageBox]::Show('CamNetTool 已經在執行中。' + [Environment]::NewLine + '請到工作列找到已開啟的視窗。', 'CamNetTool', 'OK', 'Information')
    exit 1
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$script:Cfg = Read-Config
$script:AdapterItems = @()
$script:IsAdmin = Test-IsAdmin

# ---------------- 外觀 ----------------
$fontName = 'Microsoft JhengHei UI'
$fNormal = New-Object System.Drawing.Font($fontName, 9)
$fBold   = New-Object System.Drawing.Font($fontName, 9, [System.Drawing.FontStyle]::Bold)
$fBig    = New-Object System.Drawing.Font($fontName, 15, [System.Drawing.FontStyle]::Bold)
$cGreen  = [System.Drawing.Color]::FromArgb(0, 140, 60)
$cRed    = [System.Drawing.Color]::FromArgb(210, 0, 0)
$cOrange = [System.Drawing.Color]::FromArgb(220, 120, 0)
$cGray   = [System.Drawing.Color]::Gray
$cWarnBg = [System.Drawing.Color]::FromArgb(255, 243, 150)
$cErrBg  = [System.Drawing.Color]::FromArgb(255, 170, 170)
$cText   = [System.Drawing.SystemColors]::ControlText
$script:ColorOf = @{ Green = $cGreen; Red = $cRed; Orange = $cOrange; Gray = $cGray }

function New-DotIcon([System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $b = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($b, 2, 2, 28, 28)
    $b.Dispose(); $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icoGreen = New-DotIcon $cGreen; $icoRed = New-DotIcon $cRed; $icoOrange = New-DotIcon $cOrange; $icoGray = New-DotIcon $cGray

function New-Ctl([string]$Type, $Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '') {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($Text) { $c.Text = $Text }
    $Parent.Controls.Add($c)
    return $c
}

function New-Pair($Parent, [string]$Caption, [int]$X, [int]$Y, [int]$CapW, [int]$ValW) {
    $l = New-Ctl Label $Parent $X $Y $CapW 22 $Caption
    $l.TextAlign = 'MiddleLeft'
    $v = New-Ctl Label $Parent ($X + $CapW) $Y $ValW 22 '—'
    $v.TextAlign = 'MiddleLeft'
    $v.AutoEllipsis = $true
    return $v
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'CamNetTool - 未監控'
$form.Font = $fNormal
$form.Size = New-Object System.Drawing.Size(1180, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.Icon = $icoGray

$U = @{}
$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000

# ---------------- 分頁 ----------------
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(14, 5)
$tabMon  = New-Object System.Windows.Forms.TabPage('監控')
$tabDiag = New-Object System.Windows.Forms.TabPage('診斷快照')
$tabOpt  = New-Object System.Windows.Forms.TabPage('最佳化設定')
$tabVer  = New-Object System.Windows.Forms.TabPage('版本與更新')
$tabSet  = New-Object System.Windows.Forms.TabPage('設定')
foreach ($t in $tabMon, $tabDiag, $tabOpt, $tabVer, $tabSet) { $t.UseVisualStyleBackColor = $true; $tabs.TabPages.Add($t) }

# ---------------- 監控頁：上方設定 ----------------
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 450
$tabMon.Controls.Add($top)

$gSet = New-Ctl GroupBox $top 6 2 1138 112 '設定'
[void](New-Ctl Label $gSet 12 24 60 22 '網卡：')
$U.Combo = New-Ctl ComboBox $gSet 76 22 600 24
$U.Combo.DropDownStyle = 'DropDownList'
$U.BtnRefresh = New-Ctl Button $gSet 684 21 90 26 '重新整理'
$U.BtnAdmin = New-Ctl Button $gSet 784 21 250 26 '以系統管理員重新開啟（讀網卡溫度）'
$U.BtnAdmin.ForeColor = [System.Drawing.Color]::DarkRed
$U.BtnAdmin.Visible = -not $script:IsAdmin

[void](New-Ctl Label $gSet 12 54 60 22 '相機 IP：')
$U.TxtIp = New-Ctl TextBox $gSet 76 52 130 24
$U.ChkIpAuto = New-Ctl CheckBox $gSet 214 52 82 24 '自動偵測'
$U.BtnFind = New-Ctl Button $gSet 298 51 90 26 '偵測相機'
$U.FindInfo = New-Ctl Label $gSet 396 54 730 22 ''
$U.FindInfo.AutoEllipsis = $true; $U.FindInfo.ForeColor = $cGray

$U.BtnStart = New-Ctl Button $gSet 12 80 120 28 '開始監控'
$U.BtnStop  = New-Ctl Button $gSet 140 80 120 28 '停止監控'
$U.BtnStart.Font = $fBold
[void](New-Ctl Label $gSet 276 84 110 22 '取樣間隔（秒）：')
$U.NumInterval = New-Ctl NumericUpDown $gSet 386 82 60 24
$U.NumInterval.Minimum = 2; $U.NumInterval.Maximum = 300
$U.ChkBeep = New-Ctl CheckBox $gSet 462 82 130 24 '異常時發出聲音'
$U.ChkAuto = New-Ctl CheckBox $gSet 596 82 200 24 '開啟程式時自動開始監控'
$U.BtnStartup = New-Ctl Button $gSet 800 80 160 28 '加入開機自動執行'

# ---------------- 監控頁：網卡狀態 ----------------
$gNic = New-Ctl GroupBox $top 6 118 566 328 '網卡'
$U.NicBig = New-Ctl Label $gNic 10 18 546 34 '● 未監控'
$U.NicBig.Font = $fBig; $U.NicBig.ForeColor = $cGray; $U.NicBig.AutoEllipsis = $true
$y0 = 56; $dy = 23
$U.Adapter = New-Pair $gNic '網卡'          10 ($y0 + 0 * $dy) 96 450
$U.Ping    = New-Pair $gNic '相機 ping'     10 ($y0 + 1 * $dy) 96 450
$U.Rx      = New-Pair $gNic '接收流量'      10 ($y0 + 2 * $dy) 96 450
$U.RxDisc  = New-Pair $gNic '接收丟棄'      10 ($y0 + 3 * $dy) 96 450
$U.RxRaw   = New-Pair $gNic '  原始值'      10 ($y0 + 4 * $dy) 96 450
$U.RxErr   = New-Pair $gNic '接收錯誤'      10 ($y0 + 5 * $dy) 96 450
$U.Tx      = New-Pair $gNic '送出丟棄/錯誤' 10 ($y0 + 6 * $dy) 96 450
$U.Cpu     = New-Pair $gNic 'CPU'           10 ($y0 + 7 * $dy) 96 170
$U.Temp    = New-Pair $gNic '主機板溫度'    10 ($y0 + 8 * $dy) 96 170
$U.NicTemp = New-Pair $gNic '網卡晶片溫度'  10 ($y0 + 9 * $dy) 96 170
$U.NicTemp.Width = 300
$U.CntLink  = New-Pair $gNic '斷線次數'      300 ($y0 + 7 * $dy) 92 40
$U.CntPing  = New-Pair $gNic 'ping 失敗次數'  300 ($y0 + 8 * $dy) 92 40
$U.CntDrv   = New-Pair $gNic '驅動警告次數'  432 ($y0 + 7 * $dy) 84 40
$U.CntHeat  = New-Pair $gNic '過熱警告次數'  432 ($y0 + 8 * $dy) 84 40
$U.CntReset = New-Pair $gNic '網卡重置次數'  432 ($y0 + 9 * $dy) 84 40
foreach ($k in 'CntLink', 'CntPing', 'CntDrv', 'CntHeat', 'CntReset') { $U[$k].Font = $fBold; $U[$k].Text = '0' }

# ---------------- 監控頁：相機狀態 ----------------
$gCam = New-Ctl GroupBox $top 578 118 566 328 '相機'
$U.CamBig = New-Ctl Label $gCam 10 18 546 34 '● 未監控'
$U.CamBig.Font = $fBig; $U.CamBig.ForeColor = $cGray; $U.CamBig.AutoEllipsis = $true
$U.CamId    = New-Pair $gCam '相機'          10 ($y0 + 0 * $dy) 96 452
$U.CamTemp  = New-Pair $gCam '溫度 / 功耗'   10 ($y0 + 1 * $dy) 96 452
$U.CamUp    = New-Pair $gCam '開機 / 連線'   10 ($y0 + 2 * $dy) 96 452
$U.CamFps   = New-Pair $gCam '送影像'        10 ($y0 + 3 * $dy) 96 452
$U.CamXfer  = New-Pair $gCam '傳送 / 佇列'   10 ($y0 + 4 * $dy) 96 452
$U.CamCtrl  = New-Pair $gCam '控制者'        10 ($y0 + 5 * $dy) 96 452
$U.CamRs    = New-Pair $gCam '重送'          10 ($y0 + 6 * $dy) 96 452
$U.CamLimit = New-Pair $gCam '頻寬限制'      10 ($y0 + 7 * $dy) 96 452
$U.CamGvcp  = New-Pair $gCam 'GVCP'          10 ($y0 + 8 * $dy) 96 452
$U.CntStall  = New-Pair $gCam '卡住'          10 ($y0 + 9 * $dy) 40 40
$U.CntNoResp = New-Pair $gCam '無回應'        100 ($y0 + 9 * $dy) 52 40
$U.CntReboot = New-Pair $gCam '相機重開機'    204 ($y0 + 9 * $dy) 74 40
$U.CntLinkRs = New-Pair $gCam '連線重置'      330 ($y0 + 9 * $dy) 62 40
foreach ($k in 'CntStall', 'CntNoResp', 'CntReboot', 'CntLinkRs') { $U[$k].Font = $fBold; $U[$k].Text = '0' }

# ---------------- 監控頁：共同資訊 + 事件清單 ----------------
$info = New-Object System.Windows.Forms.Panel
$info.Dock = 'Top'; $info.Height = 30
$U.Start   = New-Pair $info '開始時間' 12 4 64 150
$U.Elapsed = New-Pair $info '已監控' 236 4 50 120
$U.Anomaly = New-Pair $info '最近異常' 420 4 64 660

$U.List = New-Object System.Windows.Forms.ListView
$U.List.Dock = 'Fill'
$U.List.View = 'Details'; $U.List.FullRowSelect = $true; $U.List.GridLines = $true; $U.List.HideSelection = $false
[void]$U.List.Columns.Add('時間', 140)
[void]$U.List.Columns.Add('來源', 170)
[void]$U.List.Columns.Add('事件', 50)
[void]$U.List.Columns.Add('等級', 50)
[void]$U.List.Columns.Add('訊息', 1000)
$tabMon.Controls.Add($U.List)
$tabMon.Controls.Add($info)
$tabMon.Controls.Add($top)
$U.List.BringToFront()

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = 40
$tabMon.Controls.Add($bottom)
$U.BtnOpenDir   = New-Ctl Button $bottom 6 6 140 28 '開啟記錄資料夾'
$U.BtnOpenExcel = New-Ctl Button $bottom 152 6 170 28 '用 Excel 開啟今日記錄'
$U.BtnLogDir    = New-Ctl Button $bottom 328 6 130 28 '變更記錄位置'

# ---------------- 狀態列（整個視窗共用） ----------------
$strip = New-Object System.Windows.Forms.Panel
$strip.Dock = 'Bottom'; $strip.Height = 24; $strip.BorderStyle = 'FixedSingle'
$U.StMsg = New-Object System.Windows.Forms.Label
$U.StMsg.Dock = 'Fill'; $U.StMsg.AutoEllipsis = $true; $U.StMsg.TextAlign = 'MiddleLeft'
$U.StSep = New-Object System.Windows.Forms.Label
$U.StSep.Dock = 'Left'; $U.StSep.Width = 12; $U.StSep.Text = '|'; $U.StSep.TextAlign = 'MiddleCenter'; $U.StSep.ForeColor = $cGray
$U.StLog = New-Object System.Windows.Forms.Label
$U.StLog.Dock = 'Left'; $U.StLog.Width = 420; $U.StLog.AutoEllipsis = $true; $U.StLog.TextAlign = 'MiddleLeft'
$strip.Controls.Add($U.StMsg); $strip.Controls.Add($U.StSep); $strip.Controls.Add($U.StLog)
$form.Controls.Add($tabs)
$form.Controls.Add($strip)
$tabs.BringToFront()

$tip.SetToolTip($U.RxDisc, "AQtion 驅動回報的「接收丟棄」是把真正的計數放在 64 位元的高 32 位元。`n這裡顯示修正後的數字（CSV 欄位 RxDiscardDelta）。")
$tip.SetToolTip($U.RxRaw, "驅動回報的原始 64 位元差值（CSV 欄位 RxDiscardDeltaRaw），只供對照。")
$tip.SetToolTip($U.ChkIpAuto, "勾選後，每次開始監控都會用 GigE Vision Discovery 找相機（找不到再看 ARP 表），`n相機重開機換了 IP 也會自動跟上，不用自己查。")
$tip.SetToolTip($U.CamFps, "「約 x fps」由相機網卡的接收流量 ÷ 每張影像大小（PayloadSize）推算。`n這台相機韌體的 TransmissionFrameTime 在正常送影像時也是 0，所以不用它判斷。")
$tip.SetToolTip($U.BtnOpenExcel, '先把今天的 status / camstatus / events 複製到 %TEMP% 再開啟，原始檔不會被鎖住')

# ---------------- UI 函式 ----------------
$script:UiSetStatus = {
    param($Text, $IsError)
    if ($U.StMsg.Text -ne $Text) { $U.StMsg.Text = $Text; $tip.SetToolTip($U.StMsg, $Text) }
    $U.StMsg.ForeColor = if ($IsError) { $cRed } else { $cText }
}

function Add-EventToList($Ev) {
    $it = New-Object System.Windows.Forms.ListViewItem($Ev.Time.ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$it.SubItems.Add([string]$Ev.Source)
    [void]$it.SubItems.Add([string]$Ev.EventId)
    [void]$it.SubItems.Add([string]$Ev.Level)
    [void]$it.SubItems.Add([string]$Ev.Message)
    switch ($Ev.Severity) {
        'Warning'  { $it.BackColor = $cWarnBg }
        'Error'    { $it.BackColor = $cErrBg }
        'Overheat' { $it.BackColor = $cErrBg; $it.Font = $fBold }
    }
    $U.List.BeginUpdate()
    try {
        $U.List.Items.Insert(0, $it) | Out-Null
        while ($U.List.Items.Count -gt $script:MaxUiEvents) { $U.List.Items.RemoveAt($U.List.Items.Count - 1) }
    } finally { $U.List.EndUpdate() }
}
$script:OnEvent = { param($ev) Add-EventToList $ev }

function Set-CounterLabel($Label, [long]$N) {
    $Label.Text = [string]$N
    $Label.ForeColor = if ($N -gt 0) { $cRed } else { $cText }
}

function Update-LogLabel {
    $d = if ($script:ActiveLogDir) { $script:ActiveLogDir } else { Get-LogDir }
    $U.StLog.Text = "記錄位置：$d"
    $tip.SetToolTip($U.StLog, $d)
}

function Format-Uptime($Sec) {
    if ($null -eq $Sec) { return '—' }
    return Format-Duration ([TimeSpan]::FromSeconds([double]$Sec))
}

function Update-CameraView {
    $S = $script:S
    $C = $S.Cam
    $cam = $script:Cam
    if (-not $C -or -not $C.Last) {
        $U.CamBig.Text = if ($S.CamNote) { "● $($S.CamNote)" } else { '● 等待第一次讀取' }
        $U.CamBig.ForeColor = $cGray
        return
    }
    $smp = $C.Last.Smp; $d = $C.Last.D; $v = $smp.V; $t = $smp.T
    $U.CamBig.Text = $C.LastText
    $U.CamBig.ForeColor = $script:ColorOf[$C.LastColor]
    if ($cam) {
        $U.CamId.Text = '{0} {1}　序號 {2}　韌體 {3}　{4}' -f $cam.Vendor, $cam.Model, $cam.Serial, $cam.Version, $cam.Ip
        $tip.SetToolTip($U.CamId, "XML：$($cam.XmlFile)`n本機 IP：$($cam.LocalIp)")
    }
    if ($smp.Status -ne 'Ok') {
        $U.CamGvcp.Text = switch ($smp.Status) { 'NoResponse' { '無回應（重試 3 次）' } 'Denied' { 'ACCESS_DENIED（獨占控制）' } default { '讀取錯誤' } }
        $U.CamGvcp.ForeColor = $cRed
    } else {
        $U.CamGvcp.Text = '正常（{0} 個暫存器 {1} ms）{2}' -f $cam.ReadAddrs.Count, $smp.Ms, $(if ($cam.FormulaWarnings.Count) { '　⚠ 公式改變，請確認' } else { '' })
        $U.CamGvcp.ForeColor = if ($cam.FormulaWarnings.Count) { $cOrange } else { $cText }
        $tip.SetToolTip($U.CamGvcp, (@($cam.FormulaWarnings) + @($cam.Missing) + @($smp.Errors)) -join "`n")
        $U.CamTemp.Text = '{0}　/　{1}{2}' -f $(if ($v.ContainsKey('Temp')) { '{0:0.0} °C' -f $v.Temp } else { '—' }), $(if ($v.ContainsKey('Power')) { '{0:0.00} W' -f $v.Power } else { '—' }), $(if ($null -ne $C.MaxTempC) { "（本次最高 $($C.MaxTempC) °C）" } else { '' })
        $U.CamTemp.ForeColor = if ($v.ContainsKey('Temp') -and $v.Temp -ge [double]$script:Cfg.CamTempWarnC) { $cRed } else { $cText }
        $U.CamUp.Text = '相機開機 {0}　/　連線 {1}' -f (Format-Uptime $v.UpTime), (Format-Uptime $v.LinkUp)
        $fps = @()
        if ($null -ne $d.EstFps) { $fps += ('實測約 {0:0.0} fps（{1:N1} MB/s）' -f $d.EstFps, $C.Last.RxMBps) }
        if ($null -ne $d.AcqFps) { $fps += ('設定 {0:0.##} fps' -f $d.AcqFps) }
        $fps += ('觸發 {0}' -f $t.TrigMode)
        $U.CamFps.Text = $fps -join '　'
        $U.CamXfer.Text = '{0} = {1}　佇列 {2} / {3}　TransmissionFrameTime {4}' -f $t.XferSel, $(if ($v.XferStat -eq 1) { '1（傳送中）' } else { [string]$v.XferStat }), $v.QCur, $v.QMax, $v.TxFT
        $U.CamXfer.ForeColor = if ($v.QCur -gt 0 -and -not $d.DataFlowing) { $cOrange } else { $cText }
        $scp = if ($smp.Boot.ContainsKey('SCP0')) { $smp.Boot.SCP0 -band 0xFFFF } else { '?' }
        $U.CamCtrl.Text = '{0}　CCP 0x{1:X}　串流埠 {2}　SCPD {3}' -f $d.Ctrl, $smp.Boot.CCP, $scp, $smp.Boot.SCPD0
        $U.CamRs.Text = '本次 {0}　監控累計 {1:N0}　相機累計 {2:N0}　無法重送累計 {3:N0}' -f $(if ($null -ne $d.DRs) { '{0:N0}' -f $d.DRs } else { '—' }), $C.SumResend, $v.RsRecv, $C.SumUnavail
        $U.CamRs.ForeColor = if ($C.SumUnavail -gt 0 -or ($d.DRs -ge [int]$script:Cfg.ResendWarn)) { $cOrange } else { $cText }
        $lim = '{0}　{1:N0} MB/s　保留 {2}%' -f $t.TLMode, ($v.TL / 1e6), $v.TLRes
        # 頻寬限制是次要項目：只有用本工具套用過，取像中又讀到 Off，才表示被覆寫
        if ($d.Streaming -and $t.TLMode -eq 'Off' -and $script:Cfg.ThroughputLimitApplied) { $lim += '　⚠ 頻寬限制未生效（可能被取像程式覆寫）'; $U.CamLimit.ForeColor = $cOrange }
        else { $U.CamLimit.ForeColor = $cText }
        $U.CamLimit.Text = $lim
    }
    Set-CounterLabel $U.CntStall $C.CntStall
    Set-CounterLabel $U.CntNoResp $C.CntNoResp
    Set-CounterLabel $U.CntReboot $C.CntReboot
    Set-CounterLabel $U.CntLinkRs $C.CntLinkReset
}

function Update-StatusView {
    $S = $script:S
    if (-not $S -or -not $S.Running -or -not $S.Last) { return }
    $smp = $S.Last.Smp; $d = $S.Last.Delta
    $status = $smp.LinkStatus
    $pingBad = ($S.CameraIp -and -not $smp.PingOk)
    $nicColor = 'Green'
    if ($status -eq 'Up') {
        $sp = Format-Speed $smp.SpeedBps
        if ($pingBad) { $U.NicBig.Text = "● 連線正常 $sp，但相機 ping 不通"; $nicColor = 'Orange' }
        else { $U.NicBig.Text = "● 連線正常 $sp" }
    } else { $U.NicBig.Text = "● 斷線（$status）"; $nicColor = 'Red' }
    $U.NicBig.ForeColor = $script:ColorOf[$nicColor]

    $U.Adapter.Text = $S.AdapterName
    if (-not $S.CameraIp) { $U.Ping.Text = '（沒有相機 IP）'; $U.Ping.ForeColor = $cGray }
    else {
        $route = if ($S.PingSrc) { "$($S.PingSrc) → $($S.CameraIp)" } else { "網卡沒有 IPv4 → $($S.CameraIp)" }
        if ($smp.PingOk) { $U.Ping.Text = "$($smp.PingMs) ms（$route）"; $U.Ping.ForeColor = $cText }
        else { $U.Ping.Text = "失敗：$($smp.PingStatus)（$route）"; $U.Ping.ForeColor = $cRed }
    }
    $U.Rx.Text = if ($null -ne $S.Last.RxMBps) { '{0:N2} MB/s' -f $S.Last.RxMBps } else { '—（下一次取樣起計算）' }
    $fmt = { param($a, $b) if ($null -eq $a) { "— / 累計 {0:N0}" -f $b } else { "本次 {0:N0} / 累計 {1:N0}" -f $a, $b } }
    $U.RxDisc.Text = (& $fmt $d.RxDisc $S.Cum.RxDisc) + $(if ($S.DiscardPacked) { '（已修正高 32 位元）' } else { '' })
    $U.RxDisc.ForeColor = if ($d.RxDisc -gt 0) { $cOrange } else { $cText }
    $U.RxRaw.Text = if ($null -ne $d.RxDiscRaw) { '本次 {0:N0}' -f $d.RxDiscRaw } else { '—' }
    $U.RxRaw.ForeColor = $cGray
    $U.RxErr.Text = & $fmt $d.RxErr $S.Cum.RxErr
    $U.RxErr.ForeColor = if ($d.RxErr -gt 0) { $cRed } else { $cText }
    $U.Tx.Text = if ($null -eq $d.TxDisc) { '—' } else { "本次 {0:N0} / {1:N0}，累計 {2:N0} / {3:N0}" -f $d.TxDisc, $d.TxErr, $S.Cum.TxDisc, $S.Cum.TxErr }
    $U.Cpu.Text = if ($null -ne $smp.Cpu) { '{0:0.0} %' -f $smp.Cpu } else { '—' }
    $U.Temp.Text = if ($null -ne $smp.TempC) { '{0:0.0} °C（{1}）' -f $smp.TempC, $smp.TempZone } elseif ($S.ThermalNote) { $S.ThermalNote } else { '—' }
    $tip.SetToolTip($U.Temp, "$($U.Temp.Text)$(if ($null -ne $S.MaxBoardC) { "，本次最高 $($S.MaxBoardC) °C" })`nACPI 溫度區域，靠近 CPU，CPU 忙時會馬上升高；不是網卡周圍的溫度。")
    $aq = $smp.Aq
    if ($aq -and ($null -ne $aq.MacC -or $null -ne $aq.PhyC)) {
        $U.NicTemp.Text = 'MAC {0:0.0} / PHY {1:0.0} °C' -f $aq.MacC, $aq.PhyC
        $U.NicTemp.ForeColor = $cText
        $tip.SetToolTip($U.NicTemp, ("MAC {0:0.0} °C（本次最高 {1:0.0}）`nPHY {2:0.0} °C（本次最高 {3:0.0}）" -f $aq.MacC, $S.MaxMacC, $aq.PhyC, $S.MaxPhyC))
    } else {
        $U.NicTemp.Text = if ($S.AqNote) { $S.AqNote } else { '—' }
        $U.NicTemp.ForeColor = $cGray
    }
    Set-CounterLabel $U.CntReset $S.NicResetCount
    Set-CounterLabel $U.CntLink $S.LinkDownCount
    Set-CounterLabel $U.CntPing $S.PingFailCount
    Set-CounterLabel $U.CntDrv $S.DriverWarnCount
    Set-CounterLabel $U.CntHeat $S.OverheatCount
    if ($S.LastAnomalyTime) {
        $U.Anomaly.Text = "{0}  {1}" -f $S.LastAnomalyTime.ToString('MM-dd HH:mm:ss'), $S.LastAnomalySource
        $U.Anomaly.ForeColor = $cRed
    } else { $U.Anomaly.Text = '無'; $U.Anomaly.ForeColor = $cText }
    $tip.SetToolTip($U.Anomaly, $U.Anomaly.Text)

    Update-CameraView

    # 視窗標題與圖示：網卡與相機中比較嚴重的那一個
    $camColor = if ($S.Cam) { $S.Cam.LastColor } else { 'Gray' }
    $rank = @{ Red = 3; Orange = 2; Green = 1; Gray = 0 }
    $worst = if ($rank[$nicColor] -ge $rank[$camColor]) { $nicColor } else { $camColor }
    if ($nicColor -eq 'Red') { $title = "✖ $($U.NicBig.Text.TrimStart('● '))" }
    elseif ($camColor -eq 'Red') { $title = "✖ $($U.CamBig.Text.TrimStart('● '))" }
    elseif ($worst -eq 'Orange') { $title = '⚠ ' + $(if ($nicColor -eq 'Orange') { $U.NicBig.Text.TrimStart('● ') } else { $U.CamBig.Text.TrimStart('● ') }) }
    else { $title = "● 網卡 $(Format-Speed $smp.SpeedBps)，" + $U.CamBig.Text.TrimStart('● ') }
    $form.Text = "$title - CamNetTool"
    $form.Icon = switch ($worst) { 'Red' { $icoRed } 'Orange' { $icoOrange } 'Green' { $icoGreen } default { $icoGray } }

    if ($script:Pending.Count -gt 0) {
        Set-StatusMessage ("⚠ 記錄檔被其他程式鎖住（可能是 Excel 開著），{0} 筆暫存在記憶體，解除後自動補寫。{1}" -f $script:Pending.Count, $script:LastWriteError) -IsError
    } elseif (@($S.TickErrors).Count -gt 0) {
        Set-StatusMessage ("取樣錯誤：" + (@($S.TickErrors) -join '；')) -IsError
    } elseif (-not $script:StickyUntil -or (Get-Date) -gt $script:StickyUntil) {
        Set-StatusMessage ("最後取樣 {0}" -f $S.LastSampleTime.ToString('HH:mm:ss'))
    }
}

function Update-Elapsed {
    $S = $script:S
    if ($S -and $S.Running) {
        $U.Start.Text = $S.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        $U.Elapsed.Text = Format-Duration ((Get-Date) - $S.StartTime)
    }
}

function Set-RunningUi([bool]$Running) {
    $U.Combo.Enabled = -not $Running
    $U.BtnRefresh.Enabled = -not $Running
    $U.TxtIp.ReadOnly = $Running
    $U.ChkIpAuto.Enabled = -not $Running
    $U.BtnFind.Enabled = -not $Running
    $U.NumInterval.Enabled = -not $Running
    $U.BtnStart.Enabled = -not $Running
    $U.BtnStop.Enabled = $Running
    $U.BtnLogDir.Enabled = -not $Running
    if (-not $Running) {
        $U.NicBig.Text = '● 未監控'; $U.NicBig.ForeColor = $cGray
        $U.CamBig.Text = '● 未監控'; $U.CamBig.ForeColor = $cGray
        $form.Text = 'CamNetTool - 未監控'; $form.Icon = $icoGray
    }
}

function Update-StartupButton {
    $U.BtnStartup.Text = if (Test-Path -LiteralPath (Get-StartupShortcutPath)) { '移除開機自動執行' } else { '加入開機自動執行' }
}

function Update-AdapterCombo {
    $prevGuid = $script:Cfg.AdapterGuid
    if ($U.Combo.SelectedIndex -ge 0 -and $U.Combo.SelectedIndex -lt $script:AdapterItems.Count) { $prevGuid = $script:AdapterItems[$U.Combo.SelectedIndex].Guid }
    $items = @(Get-AdapterList)
    if ($prevGuid -and -not ($items | Where-Object { $_.Guid -eq $prevGuid })) {
        $items += [pscustomobject]@{ Name = $script:Cfg.AdapterName; Description = '（目前找不到這張網卡）'; Status = 'Missing'; Guid = $prevGuid }
    }
    $script:AdapterItems = $items
    $U.Combo.BeginUpdate()
    $U.Combo.Items.Clear()
    foreach ($a in $items) { [void]$U.Combo.Items.Add(("{0}  —  {1}  [{2}]" -f $a.Name, $a.Description, $a.Status)) }
    $U.Combo.EndUpdate()
    $idx = -1
    if ($prevGuid) { for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Guid -eq $prevGuid) { $idx = $i; break } } }
    if ($idx -lt 0) { for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Description -match $script:AutoNicPattern) { $idx = $i; break } } }
    if ($idx -lt 0 -and $items.Count -gt 0) { $idx = 0 }
    $U.Combo.SelectedIndex = $idx
}

function Get-SelectedAdapter {
    if ($U.Combo.SelectedIndex -lt 0 -or $U.Combo.SelectedIndex -ge $script:AdapterItems.Count) { return $null }
    return $script:AdapterItems[$U.Combo.SelectedIndex]
}

function Invoke-Safe([scriptblock]$Block) {
    try { & $Block } catch { Set-StatusMessage "錯誤：$($_.Exception.Message)" -IsError -Sticky }
}

# 「偵測相機」：Discovery → ARP，把 IP 填進欄位
function Invoke-FindCameraFromUi([switch]$Quiet) {
    $a = Get-SelectedAdapter
    if (-not $a) { return }
    $form.Cursor = 'WaitCursor'
    try {
        $r = Find-CameraIpAuto $a.Guid $script:Cfg.CameraSerial
    } finally { $form.Cursor = 'Default' }
    if ($r) {
        $U.TxtIp.Text = $r.Ip
        $more = if ($r.Count -gt 1) { "（共找到 $($r.Count) 台，用第一台）" } else { '' }
        $U.FindInfo.Text = "找到：$($r.Text)，方式 $($r.Method)$more"
        $U.FindInfo.ForeColor = $cGreen
        if ($r.Serial) { $script:Cfg.CameraSerial = $r.Serial }
    } else {
        $U.FindInfo.Text = '找不到相機（Discovery 與 ARP 都沒有結果）。請確認相機有供電、網路線有接好。'
        $U.FindInfo.ForeColor = $cRed
        if (-not $Quiet) { Set-StatusMessage '找不到相機。' -IsError -Sticky }
    }
}

function Start-FromUi {
    $a = Get-SelectedAdapter
    if (-not $a) { [void][System.Windows.Forms.MessageBox]::Show('請先選擇網卡。', 'CamNetTool'); return $false }
    $ip = $U.TxtIp.Text.Trim()
    if (-not (Test-IPv4 $ip)) {
        [void][System.Windows.Forms.MessageBox]::Show("相機 IP 格式不正確：$ip`n請輸入像 169.254.1.10 的格式，或勾選「自動偵測」。", 'CamNetTool', 'OK', 'Warning')
        $U.TxtIp.Focus(); return $false
    }
    $script:Cfg.AdapterGuid = $a.Guid
    $script:Cfg.AdapterName = $a.Name
    $script:Cfg.CameraIp = $ip
    $script:Cfg.CameraIpAuto = $U.ChkIpAuto.Checked
    $script:Cfg.IntervalSec = [int]$U.NumInterval.Value
    $script:Cfg.BeepOnAlarm = $U.ChkBeep.Checked
    $script:Cfg.AutoStartMonitoring = $U.ChkAuto.Checked
    $U.List.Items.Clear()
    $form.Cursor = 'WaitCursor'
    try { Start-Monitoring } finally { $form.Cursor = 'Default' }
    $script:S.AdapterName = "$($a.Name)（$($a.Description)）"
    if ($script:S.CameraIp -and $U.TxtIp.Text -ne $script:S.CameraIp) { $U.TxtIp.Text = $script:S.CameraIp }
    if ($script:Cam) {
        $U.FindInfo.Text = "監控中：$($script:Cam.Vendor) $($script:Cam.Model)（序號 $($script:Cam.Serial)，韌體 $($script:Cam.Version)）"
        $U.FindInfo.ForeColor = $cGreen
    }
    Update-LogLabel
    Set-RunningUi $true
    $timer.Interval = $script:Cfg.IntervalSec * 1000
    Invoke-TickFromUi
    $timer.Start(); $clock.Start()
    if ($script:OnMonitoringChanged) { try { & $script:OnMonitoringChanged } catch { } }
    return $true
}

function Stop-FromUi([string]$Reason) {
    $timer.Stop(); $clock.Stop()
    Stop-Monitoring $Reason
    Set-RunningUi $false
    Set-StatusMessage '已停止監控。'
    if ($script:OnMonitoringChanged) { try { & $script:OnMonitoringChanged } catch { } }
}

function Invoke-TickFromUi {
    try {
        Invoke-MonitorTick
    } catch {
        if ($script:S) { $script:S.TickErrors += $_.Exception.Message }
        Set-StatusMessage "取樣錯誤：$($_.Exception.Message)" -IsError
    }
    try { Update-StatusView; Update-Elapsed } catch { Set-StatusMessage "畫面更新錯誤：$($_.Exception.Message)" -IsError }
    try {
        if ($script:S -and $script:S.AlarmPending) {
            $script:S.AlarmPending = $false
            if ($script:Cfg.BeepOnAlarm) { [System.Media.SystemSounds]::Hand.Play() }
            if (-not $form.ContainsFocus) { [NicMonNative]::Flash($form.Handle) }
        }
    } catch { }
    # 長時間執行：偶爾把用不到的記憶體還給系統
    if ($script:S -and ($script:TickCount++ % 360) -eq 5) { [NicMonNative]::TrimWorkingSet() }
}

# 以系統管理員重新開啟（讀網卡溫度、最佳化設定需要）
function Restart-AsAdmin {
    $r = [System.Windows.Forms.MessageBox]::Show("要以系統管理員身分重新開啟 CamNetTool 嗎？`n`n目前的監控會先停止，重新開啟後再自動開始。", 'CamNetTool', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $wasRunning = ($script:S -and $script:S.Running)
    if ($wasRunning) { $script:Cfg.AutoStartMonitoring = $true }
    if ($wasRunning) { Stop-FromUi '以系統管理員重新開啟' }
    Save-Config
    try {
        $script:Mutex.ReleaseMutex()
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$($script:ScriptPath)`"" -ErrorAction Stop | Out-Null
        $script:NoConfirmClose = $true
        $form.Close()
    } catch {
        try { [void]$script:Mutex.WaitOne(0) } catch { }
        Set-StatusMessage '已取消以系統管理員身分重新開啟。' -Sticky
        if ($wasRunning) { [void](Start-FromUi) }
    }
}

# ---------------- 計時器 ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Add_Tick({ Invoke-TickFromUi })
$clock = New-Object System.Windows.Forms.Timer
$clock.Interval = 1000
$clock.Add_Tick({ try { Update-Elapsed } catch { } })
$script:TickCount = 0

# ---------------- 事件處理 ----------------
$U.BtnRefresh.Add_Click({ Invoke-Safe { Update-AdapterCombo; Set-StatusMessage '網卡清單已更新。' } })
$U.BtnAdmin.Add_Click({ Invoke-Safe { Restart-AsAdmin } })
$U.BtnFind.Add_Click({ Invoke-Safe { Invoke-FindCameraFromUi } })
$U.BtnStart.Add_Click({ Invoke-Safe { [void](Start-FromUi) } })
$U.BtnStop.Add_Click({ Invoke-Safe { Stop-FromUi '使用者按下停止' } })
$U.TxtIp.Add_TextChanged({
    $U.TxtIp.BackColor = if (Test-IPv4 $U.TxtIp.Text) { [System.Drawing.SystemColors]::Window } else { [System.Drawing.Color]::FromArgb(255, 200, 200) }
})
$U.ChkIpAuto.Add_CheckedChanged({ $script:Cfg.CameraIpAuto = $U.ChkIpAuto.Checked; Save-Config })
$U.ChkBeep.Add_CheckedChanged({ $script:Cfg.BeepOnAlarm = $U.ChkBeep.Checked; Save-Config })
$U.ChkAuto.Add_CheckedChanged({ $script:Cfg.AutoStartMonitoring = $U.ChkAuto.Checked; Save-Config })
$U.BtnStartup.Add_Click({ Invoke-Safe {
    if (Test-Path -LiteralPath (Get-StartupShortcutPath)) {
        Remove-StartupShortcut
        Set-StatusMessage '已移除開機自動執行。' -Sticky
    } else {
        Add-StartupShortcut
        $U.ChkAuto.Checked = $true
        $script:Cfg.AutoStartMonitoring = $true
        $a = Get-SelectedAdapter
        if ($a) { $script:Cfg.AdapterGuid = $a.Guid; $script:Cfg.AdapterName = $a.Name }
        if (Test-IPv4 $U.TxtIp.Text) { $script:Cfg.CameraIp = $U.TxtIp.Text.Trim() }
        $script:Cfg.IntervalSec = [int]$U.NumInterval.Value
        Save-Config
        Set-StatusMessage "已加入開機自動執行（$(Get-StartupShortcutPath)），並勾選「開啟程式時自動開始監控」。" -Sticky
    }
    Update-StartupButton
} })
$U.BtnOpenDir.Add_Click({ Invoke-Safe {
    $d = if ($script:ActiveLogDir) { $script:ActiveLogDir } else { Get-LogDir }
    if (-not (Test-Path -LiteralPath $d)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$d`""
} })
$U.BtnOpenExcel.Add_Click({ Invoke-Safe { Open-TodayLogCopy } })
$U.BtnLogDir.Add_Click({ Invoke-Safe {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇記錄檔要存放的資料夾'
    $dlg.SelectedPath = Get-LogDir
    if ($dlg.ShowDialog($form) -eq 'OK') {
        if (Test-DirWritable $dlg.SelectedPath) {
            $script:Cfg.LogDir = $dlg.SelectedPath
            $script:ActiveLogDir = $dlg.SelectedPath
            $script:PathMap = @{}
            Save-Config; Update-LogLabel
            Set-StatusMessage '記錄位置已變更。' -Sticky
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("這個資料夾無法寫入：`n$($dlg.SelectedPath)", 'CamNetTool', 'OK', 'Warning')
        }
    }
    $dlg.Dispose()
} })

# ---------------- 其他分頁 ----------------
. (Join-Path $script:LibDir 'SettingsTab.ps1')
foreach ($fn in 'Initialize-DiagTab', 'Initialize-OptimizeTab', 'Initialize-VersionsTab') {
    $page = switch ($fn) { 'Initialize-DiagTab' { $tabDiag } 'Initialize-OptimizeTab' { $tabOpt } default { $tabVer } }
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        try { & $fn $page } catch { [void](New-Ctl Label $page 12 12 900 40 "這個分頁載入失敗：$($_.Exception.Message)") }
    } else {
        [void](New-Ctl Label $page 12 12 900 40 '（這個分頁的模組檔案不存在）')
    }
}

$form.Add_FormClosing({
    param($sender, $e)
    try {
        if ($script:S -and $script:S.Running) {
            if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:NoConfirmClose) {
                $r = [System.Windows.Forms.MessageBox]::Show('目前正在監控中，確定要停止監控並關閉嗎？', 'CamNetTool', 'YesNo', 'Warning', 'Button2')
                if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
                Stop-FromUi '使用者關閉程式'
            } else {
                $why = switch ([string]$e.CloseReason) { 'WindowsShutDown' { 'Windows 關機或登出' } 'TaskManagerClosing' { '被工作管理員結束' } default { "程式結束：$($e.CloseReason)" } }
                $timer.Stop(); $clock.Stop()
                Stop-Monitoring $why
            }
        }
        if ($script:OnClosing) { try { & $script:OnClosing } catch { } }
        [void](Invoke-FlushLogs)
        Save-UnflushedLines
    } catch { }
})

$form.Add_Shown({ Invoke-Safe {
    if ($script:StartupWarning) { Set-StatusMessage $script:StartupWarning -IsError -Sticky }
    if ($script:Cfg.AutoStartMonitoring) { [void](Start-FromUi) }
    elseif ($U.ChkIpAuto.Checked -or -not $U.TxtIp.Text.Trim()) { Invoke-FindCameraFromUi -Quiet }
    [NicMonNative]::TrimWorkingSet()
} })

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try { Set-StatusMessage "未預期的錯誤：$($e.Exception.Message)" -IsError -Sticky } catch { }
})

# ---------------- 初始值 ----------------
$U.TxtIp.Text = $script:Cfg.CameraIp
$U.ChkIpAuto.Checked = $script:Cfg.CameraIpAuto
$U.NumInterval.Value = $script:Cfg.IntervalSec
$U.ChkBeep.Checked = $script:Cfg.BeepOnAlarm
$U.ChkAuto.Checked = $script:Cfg.AutoStartMonitoring
Update-AdapterCombo
Update-StartupButton
[void](Initialize-LogDir)
Update-LogLabel
Set-RunningUi $false
$adminText = if ($script:IsAdmin) { '（系統管理員）' } else { '' }
Set-StatusMessage "就緒$adminText。選好網卡後按「開始監控」。"

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    try { [void](Invoke-FlushLogs); Save-UnflushedLines } catch { }
    foreach ($i in $icoGreen, $icoRed, $icoOrange, $icoGray) { try { $i.Dispose() } catch { } }
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Mutex.Dispose() } catch { }
}
