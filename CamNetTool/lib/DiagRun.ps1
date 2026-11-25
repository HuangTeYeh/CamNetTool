#Requires -Version 5.1
<#
    CamNetTool 診斷快照（獨立行程執行；由「診斷快照」分頁啟動，也可以手動執行）
    只讀取：網卡、系統、事件、封包擷取（pktmon，需系統管理員）、相機 GVCP 唯讀探測。
    不會對相機寫入任何東西，也不會改變 Windows 設定（pktmon 結束後會清掉過濾條件）。

    手動執行範例：
      powershell -ExecutionPolicy Bypass -File lib\DiagRun.ps1 -AppDir .. -OutRoot D:\diag -AdapterGuid {…}
#>
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [string]$AdapterGuid = '',
    [string]$CameraIp = '',
    [string]$Label = 'stuck',
    [string]$IncidentTime = '',
    [int]$CaptureSec = 30,
    [string]$ProgressFile = '',
    [switch]$NoCapture,
    [string]$AnalyzePcap = ''
)

$ErrorActionPreference = 'Continue'
$startedAt = Get-Date
. (Join-Path $AppDir 'CamNetTool.ps1') -CoreOnly
$ErrorActionPreference = 'Continue'
$script:Cfg = Read-Config

$stamp = $startedAt.ToString('yyyyMMdd_HHmmss')
$safeLabel = ($Label -replace '[^\w\-]', '_')
$out = Join-Path $OutRoot ("CamDiag_{0}_{1}" -f $safeLabel, $stamp)
New-Item -ItemType Directory -Force -Path $out | Out-Null

$summary = New-Object System.Collections.Generic.List[string]
$verdicts = New-Object System.Collections.Generic.List[string]
function Write-Progress2([string]$s) {
    if ($ProgressFile) { try { [IO.File]::AppendAllText($ProgressFile, $s + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch { } }
}
function Log([string]$s) {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $s
    $summary.Add($line)
    Write-Host $line
    Write-Progress2 $line
}
function Save-Text([string]$name, $obj) {
    try { $obj | Out-String -Width 500 | Set-Content -LiteralPath (Join-Path $out $name) -Encoding UTF8 } catch { Log "  寫入 $name 失敗：$($_.Exception.Message)" }
}
function Save-Csv([string]$name, $obj) {
    try { if ($obj) { $obj | Export-Csv -LiteralPath (Join-Path $out $name) -NoTypeInformation -Encoding UTF8 } } catch { Log "  寫入 $name 失敗：$($_.Exception.Message)" }
}

$incident = $startedAt
if ($IncidentTime) { try { $incident = [datetime]::ParseExact($IncidentTime, 'yyyy-MM-dd HH:mm:ss', $null) } catch { } }
$isAdmin = Test-IsAdmin
Log "CamNetTool $($script:AppVersion) 診斷快照開始。標籤=$Label  系統管理員=$isAdmin  事發時間=$($incident.ToString('yyyy-MM-dd HH:mm:ss'))"
if (-not $isAdmin) { Log '未以系統管理員執行：封包擷取與 evtx 匯出會略過。' }

$ctx = @{ Nic = $null; LocalIp = ''; Prefix = 16; CamIp = $CameraIp; Guid = $AdapterGuid }

# ---------------------------------------------------------------------------
Log '== 1. 網卡資訊'
try {
    $nic = $null
    if ($AdapterGuid) { $nic = Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $AdapterGuid } | Select-Object -First 1 }
    if (-not $nic) { $nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match $script:AutoNicPattern } | Select-Object -First 1 }
    if (-not $nic) {
        Log '  找不到相機網卡，列出全部網卡'
        Save-Text 'nic_all.txt' (Get-NetAdapter -IncludeHidden | Format-Table Name, InterfaceDescription, Status, LinkSpeed, ifIndex -AutoSize)
    } else {
        $ctx.Nic = $nic; $ctx.Guid = [string]$nic.InterfaceGuid
        Log ("  網卡：{0}（{1}） 狀態={2} 速度={3} 驅動={4} {5}" -f $nic.Name, $nic.InterfaceDescription, $nic.Status, $nic.LinkSpeed, $nic.DriverVersion, $nic.DriverDate)
        $ipObj = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipObj) { $ctx.LocalIp = [string]$ipObj.IPAddress; $ctx.Prefix = [int]$ipObj.PrefixLength }
        Log ("  電腦端 IP：{0}/{1}" -f $ctx.LocalIp, $ctx.Prefix)
        Save-Text 'nic_adapter.txt' ($nic | Format-List *)
        $adv = Get-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -ErrorAction SilentlyContinue
        Save-Text 'nic_advanced.txt' ($adv | Format-Table DisplayName, DisplayValue, RegistryKeyword, RegistryValue, NumericParameterMinValue, NumericParameterMaxValue -AutoSize)
        $rb = $adv | Where-Object RegistryKeyword -eq '*ReceiveBuffers' | Select-Object -First 1
        if ($rb) { Log ("  Receive Buffers：{0}（最大 {1}）" -f $rb.DisplayValue, $rb.NumericParameterMaxValue) }
        Save-Text 'nic_statistics.txt' (Get-NetAdapterStatistics -Name $nic.Name -ErrorAction SilentlyContinue | Format-List *)
        Save-Text 'nic_power.txt' (Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue | Format-List *)
        Save-Text 'nic_ip.txt' (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue | Format-List *)
        Save-Text 'nic_neighbors.txt' (Get-NetNeighbor -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue | Format-Table -AutoSize)
        $bind = Get-NetAdapterBinding -Name $nic.Name -AllBindings -ErrorAction SilentlyContinue
        Save-Text 'nic_bindings.txt' ($bind | Format-Table DisplayName, ComponentID, Enabled -AutoSize)
        foreach ($b in ($bind | Where-Object { $_.DisplayName -match '(?i)GigE|Lucid|Arena|National|NI |IMAQ|SENTECH|Pylon|Basler|Teledyne|Spinnaker|FLIR' -and $_.Enabled })) {
            Log ("  GigE 過濾驅動：{0}（{1}）已啟用" -f $b.DisplayName, $b.ComponentID)
        }
        $nonG = @(Get-NonGigEBindings $nic.Name | Where-Object Enabled)
        if ($nonG.Count) { foreach ($b in $nonG) { Log ("  非 GigE 驅動（{0}）：{1}（{2}）已啟用 → 建議在相機網卡上取消" -f $b.Category, $b.DisplayName, $b.ComponentID) } }
        else { Log '  非 GigE 驅動（VirtualBox、VMware、VPN、防火牆等）：沒有' }
        Log ("  Flow Control：{0}" -f (Get-FlowControlText (Get-AdvProp $adv @('*FlowControl', 'FlowControl'))))
        $hw = Get-NetAdapterHardwareInfo -Name $nic.Name -ErrorAction SilentlyContinue
        Save-Text 'nic_hardware.txt' ($hw | Format-List *)
        if ($hw) { Log ("  PCIe：目前 {0} x{1}，最大 {2} x{3}" -f $hw.PcieLinkSpeed, $hw.PcieLinkWidth, $hw.PcieMaxLinkSpeed, $hw.PcieMaxLinkWidth) }
    }
} catch { Log "  失敗：$($_.Exception.Message)" }
try { Save-Text 'ipconfig.txt' (ipconfig /all); Save-Text 'arp.txt' (arp -a); Save-Text 'route.txt' (route print) } catch { }

# ---------------------------------------------------------------------------
Log '== 2. 系統、電源與軟體版本'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Log ("  {0} {1}，開機時間 {2}" -f $os.Caption, $os.Version, $os.LastBootUpTime)
    Save-Text 'os.txt' ($os | Format-List Caption, Version, BuildNumber, LastBootUpTime, LocalDateTime, FreePhysicalMemory, TotalVisibleMemorySize)
    $aspm = (powercfg /q SCHEME_CURRENT SUB_PCIEXPRESS ASPM) 2>&1
    Save-Text 'power_aspm.txt' $aspm
    $ac = $aspm | Select-String -Pattern '(?i)(AC|交流電).*?(0x[0-9a-f]+)' | Select-Object -First 1
    if ($ac) {
        $v = [Convert]::ToInt32($ac.Matches[0].Groups[2].Value, 16)
        Log ("  PCIe 連結狀態電源管理（插電）：{0}" -f $(switch ($v) { 0 { '關閉' } 1 { '中度省電' } 2 { '最大省電' } default { "未知($v)" } }))
    }
    Save-Text 'power_all.txt' ((powercfg /q) 2>&1)
    Save-Text 'power_active.txt' ((powercfg /getactivescheme) 2>&1)
    Save-Text 'power_lastwake.txt' ((powercfg /lastwake) 2>&1)
    if ($isAdmin) { Save-Text 'power_requests.txt' ((powercfg /requests) 2>&1) }
    $sw = @(Get-InstalledSoftwareList)
    Save-Csv 'software.csv' $sw
    foreach ($s in ($sw | Where-Object { $_.DisplayName -match '(?i)IMAQdx|Vision Acquisition|Arena|LabVIEW.*Run-Time|Marvell|AQtion' } | Select-Object -First 12)) { Log "  $($s.DisplayName) $($s.DisplayVersion)" }
} catch { Log "  失敗：$($_.Exception.Message)" }

# ---------------------------------------------------------------------------
Log '== 3. 程式與 UDP 連接埠'
$udpEps = @()
try {
    $procs = Get-Process -ErrorAction SilentlyContinue | Select-Object Name, Id,
        @{ n = 'StartTime'; e = { try { $_.StartTime } catch { $null } } },
        @{ n = 'CPUsec'; e = { try { [math]::Round($_.CPU, 1) } catch { $null } } },
        @{ n = 'WorkingSetMB'; e = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }, Handles,
        @{ n = 'Responding'; e = { try { $_.Responding } catch { $null } } },
        @{ n = 'Path'; e = { try { $_.Path } catch { $null } } }
    Save-Csv 'processes.csv' $procs
    foreach ($p in ($procs | Where-Object { $_.Name -match '(?i)^Application$|LabVIEW|lvrt|NIMax|ArenaView|IMAQ' })) {
        Log ("  程式 {0}（PID {1}）啟動 {2}，回應中={3}" -f $p.Name, $p.Id, $p.StartTime, $p.Responding)
    }
    $udpEps = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; OwningProcess = $_.OwningProcess; Process = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName; CreationTime = $_.CreationTime } })
    Save-Csv 'udp_endpoints.csv' $udpEps
    if ($ctx.LocalIp) {
        foreach ($u in ($udpEps | Where-Object { $_.LocalAddress -eq $ctx.LocalIp })) {
            Log ("  綁在相機網卡上的 UDP 埠：{0}:{1}  程式={2}（PID {3}）建立於 {4}" -f $u.LocalAddress, $u.LocalPort, $u.Process, $u.OwningProcess, $u.CreationTime)
        }
    }
} catch { Log "  失敗：$($_.Exception.Message)" }

# ---------------------------------------------------------------------------
Log '== 4. 事件記錄與排程工作'
try {
    $from = $incident.AddMinutes(-60); $to = $incident.AddMinutes(60)
    $evs = Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); StartTime = $from; EndTime = $to } -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, LogName, ProviderName, Id, Level, LevelDisplayName, @{ n = 'Message'; e = { ($_.Message -replace "[\r\n]+", ' ') } }
    Save-Csv 'events_incident_window.csv' $evs
    Log "  事發前後 1 小時的系統 / 應用程式事件：$(@($evs).Count) 筆"
    foreach ($e in ($evs | Where-Object { [math]::Abs(($_.TimeCreated - $incident).TotalMinutes) -le 10 } | Sort-Object TimeCreated | Select-Object -First 30)) {
        $m = if ($e.Message.Length -gt 120) { $e.Message.Substring(0, 120) + '…' } else { $e.Message }
        Log ("    {0:MM/dd HH:mm:ss} {1} {2} {3}" -f $e.TimeCreated, $e.ProviderName, $e.Id, $m)
    }
    $recent = Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); StartTime = $incident.AddDays(-3); Level = @(1, 2, 3) } -MaxEvents 5000 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, LogName, ProviderName, Id, LevelDisplayName, @{ n = 'Message'; e = { ($_.Message -replace "[\r\n]+", ' ') } }
    Save-Csv 'events_warnings_recent.csv' $recent
    if ($isAdmin) {
        $utc = $incident.AddDays(-3).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z')
        $q = "*[System[TimeCreated[@SystemTime>='$utc']]]"
        foreach ($lg in @('System', 'Application', 'Microsoft-Windows-WindowsUpdateClient/Operational', 'Microsoft-Windows-TaskScheduler/Operational', 'Microsoft-Windows-Kernel-PnP/Configuration')) {
            $f = Join-Path $out ('evt_' + ($lg -replace '[\\/ ]', '_') + '.evtx')
            wevtutil epl "$lg" "$f" "/q:$q" 2>&1 | Out-Null
        }
        Log '  已匯出 evtx（最近 3 天）'
    }
    # CamNetTool 自己的記錄（今天與昨天）
    $logDir = Get-LogDir
    if (Test-Path -LiteralPath $logDir) {
        $dst = Join-Path $out 'CamNetToolLog'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        foreach ($f in Get-ChildItem -LiteralPath $logDir -Filter '*.csv' | Where-Object { $_.LastWriteTime -ge $incident.Date.AddDays(-1) }) {
            try { Copy-FileShared $f.FullName (Join-Path $dst $f.Name) } catch { }
        }
    }
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            $i = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            [pscustomobject]@{ TaskPath = $_.TaskPath; TaskName = $_.TaskName; State = $_.State; LastRunTime = $i.LastRunTime; LastTaskResult = $i.LastTaskResult; NextRunTime = $i.NextRunTime } })
    Save-Csv 'scheduled_tasks.csv' $tasks
    $tod = $incident.TimeOfDay
    foreach ($t in $tasks) {
        foreach ($when in @($t.LastRunTime, $t.NextRunTime)) {
            if ($when -and $when.Year -gt 2000 -and [math]::Abs(($when.TimeOfDay - $tod).TotalMinutes) -le 20) {
                Log ("  排程工作時間接近事發時刻：{0}{1}  上次 {2}  下次 {3}" -f $t.TaskPath, $t.TaskName, $t.LastRunTime, $t.NextRunTime); break
            }
        }
    }
} catch { Log "  失敗：$($_.Exception.Message)" }

# ---------------------------------------------------------------------------
# 接收速率（GetIfEntry2，2 秒）
function Get-RxRateMBps([string]$Guid, [int]$Sec) {
    if (-not $Guid -or -not $script:UseNativeIf) { return $null }
    $r1 = New-Object 'NicMonNative+MIB_IF_ROW2'; $r2 = New-Object 'NicMonNative+MIB_IF_ROW2'
    if ([NicMonNative]::QueryInterface($Guid, [ref]$r1) -ne 0) { return $null }
    Start-Sleep -Seconds $Sec
    if ([NicMonNative]::QueryInterface($Guid, [ref]$r2) -ne 0) { return $null }
    return [math]::Round(([double]$r2.InOctets - [double]$r1.InOctets) / $Sec / 1e6, 2)
}

# 相機 IP：參數 > Discovery > ARP
if (-not $ctx.CamIp -and $ctx.Guid) {
    $f = Find-CameraIpAuto $ctx.Guid
    if ($f) { $ctx.CamIp = $f.Ip; Log "  自動找到相機 IP：$($f.Ip)（$($f.Method)）" }
}

Log "== 5. 封包擷取（$CaptureSec 秒）"
$rxBefore = Get-RxRateMBps $ctx.Guid 2
if ($null -ne $rxBefore) { Log "  目前相機網卡接收 $rxBefore MB/s" }
if ($NoCapture) { Log '  依設定略過' }
elseif (-not $isAdmin) { Log '  需要系統管理員，略過' }
elseif (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) { Log '  這台 Windows 沒有 pktmon，略過' }
else {
    try {
        $etl = Join-Path $out 'capture.etl'
        $pktSize = 0; $capSec = $CaptureSec
        if ($null -ne $rxBefore -and $rxBefore -gt 1) { $pktSize = 128; $capSec = [math]::Min($CaptureSec, 5); Log "  有影像串流，改為只抓標頭 $capSec 秒" }
        $oldEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }    # pktmon 的輸出是 UTF-8
        pktmon filter remove 2>&1 | Out-Null
        if ($ctx.CamIp) { pktmon filter add CAM -i $ctx.CamIp 2>&1 | Out-Null; Log "  過濾條件：IP $($ctx.CamIp)" }
        else { pktmon filter add GVCP -t UDP -p 3956 2>&1 | Out-Null; Log '  過濾條件：UDP 3956（GVCP）' }
        $r = pktmon start --capture --pkt-size $pktSize --file-name "$etl" 2>&1
        if ($LASTEXITCODE -ne 0) { $r = pktmon start --etw -p $pktSize -f "$etl" 2>&1 }
        Save-Text 'pktmon_start.txt' $r
        Start-Sleep -Seconds $capSec
        Save-Text 'pktmon_stop.txt' (pktmon stop 2>&1)
        Save-Text 'pktmon_etl2pcap.txt' (pktmon etl2pcap "$etl" --out (Join-Path $out 'capture.pcapng') 2>&1)
        pktmon filter remove 2>&1 | Out-Null
        try { [Console]::OutputEncoding = $oldEnc } catch { }
        Log '  擷取完成（capture.etl / capture.pcapng）'
    } catch {
        Log "  失敗：$($_.Exception.Message)"
        try { pktmon stop 2>&1 | Out-Null; pktmon filter remove 2>&1 | Out-Null } catch { }
    }
}

# ---------------------------------------------------------------------------
# 5b. 分析封包擷取：每張影像的封包數、送完時間、突發速率、缺漏、PACKETRESEND 與重送封包原本有沒有收到
$pcap = Join-Path $out 'capture.pcapng'
if ($AnalyzePcap -and -not (Test-Path -LiteralPath $pcap)) { $pcap = $AnalyzePcap }     # 分析既有的擷取檔（例如別台機台的）
$capInfo = $null
if ((Test-Path -LiteralPath $pcap) -and $ctx.CamIp) {
    Log '== 5b. 分析封包擷取'
    try {
        $an = [PcapngAnalyzer]::Analyze($pcap, $ctx.CamIp)
        if ($an.Error) { Log "  分析中斷：$($an.Error)" }
        Log ("  擷取 {0:0.0} 秒：相機影像封包 {1:N0} 個、GVCP 指令 {2} 個（pktmon 重複記錄 {3:N0} 筆已去除）" -f $an.DurationSec, $an.StreamPackets, $an.GvcpCmds, ($an.RawPackets - $an.UniquePackets))
        $miss = ($an.Blocks | Select-Object -Skip 1 | Select-Object -SkipLast 1 | Measure-Object -Property Missing -Sum).Sum
        if ($an.CompleteBlocks -gt 0) {
            Log ("  完整的影像 {0} 張：每張 {1:N0} 個封包，約 {2:0.0} ms 送完（突發約 {3:N0} MB/s）；擷取中缺漏的封包 {4:N0} 個" -f $an.CompleteBlocks, $an.MedianPackets, $an.MedianBlockMs, $an.MedianBurstMBps, $miss)
            $capInfo = [ordered]@{ Time = $startedAt.ToString('yyyy-MM-dd HH:mm'); MedianBurstMBps = [math]::Round($an.MedianBurstMBps); MedianBlockMs = [math]::Round($an.MedianBlockMs, 1); PacketsPerBlock = $an.MedianPackets; Blocks = $an.CompleteBlocks; Missing = $miss; ResendCmds = $an.Resends.Count }
            try { [IO.File]::WriteAllText((Join-Path (Get-CamDataDir) 'last_capture.json'), ($capInfo | ConvertTo-Json), (New-Object Text.UTF8Encoding($true))) } catch { }
        } elseif ($an.StreamPackets -eq 0) {
            Log '  擷取中沒有任何相機影像封包（GVSP）'
        }
        Log ("  電腦送出 PACKETRESEND（0x0040）{0} 次，共要求重送 {1:N0} 個封包：原本（重送要求之前）有出現在擷取中的 {2:N0} 個，之後出現的 {3:N0} 個" -f $an.Resends.Count, $an.ResendPacketsRequested, $an.ResendSeenBefore, $an.ResendSeenAfter)
        foreach ($r in ($an.Resends | Select-Object -First 10)) { Log ("    重送要求：影像 {0} 封包 {1}～{2}（原本有收到 {3}，之後收到 {4}）" -f $r.BlockId, $r.First, $r.Last, $r.SeenBefore, $r.SeenAfter) }
        $script:CapAnalysis = $an
    } catch { Log "  分析失敗：$($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
Log '== 6. 相機 GigE Vision 探測（只讀不寫）'
$gv = @{ Discovery = $null; CCP = $null; SCP0 = $null; Streaming = $null; TxFT = $null; QCur = $null }
$client = $null
try {
    if (-not $ctx.LocalIp) { throw '沒有電腦端 IP，無法探測' }
    if ($ctx.CamIp) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $okCnt = 0
        for ($i = 0; $i -lt 4; $i++) { try { if (($ping.Send($ctx.CamIp, 500)).Status -eq 'Success') { $okCnt++ } } catch { } }
        Log "  Ping $($ctx.CamIp)：4 次成功 $okCnt 次"
    }
    $found = @(Find-GigECameras $ctx.Guid 1500)
    $gv.Discovery = $found.Count
    Save-Csv 'gev_discovery.csv' ($found | ForEach-Object { $_.Device })
    if ($found.Count -eq 0) { Log '  Discovery：相機沒有回應' }
    foreach ($f in $found) { $d = $f.Device; Log ("  Discovery 回應：{0} {1} 序號 {2} 韌體 {3} IP {4} MAC {5}" -f $d.Manufacturer, $d.Model, $d.Serial, $d.Version, $d.Ip, $d.Mac) }
    if (-not $ctx.CamIp -and $found.Count) { $ctx.CamIp = $found[0].Device.Ip }

    if ($ctx.CamIp) {
        $local = Get-LocalIpForCamera $ctx.Guid $ctx.CamIp
        $script:Cam = Connect-Camera $local $ctx.CamIp 500
        $cam = $script:Cam; $client = $cam.Client
        Log ("  相機：{0} {1} 序號 {2} 韌體 {3}；XML {4}{5}" -f $cam.Vendor, $cam.Model, $cam.Serial, $cam.Version, $cam.XmlFile, $(if ($cam.XmlError) { "（XML 錯誤：$($cam.XmlError)）" } else { '' }))
        if ($cam.Xml) {
            try { Copy-Item -LiteralPath $cam.Xml.Path -Destination (Join-Path $out ('genicam_' + $cam.XmlFile)) -Force; [IO.File]::WriteAllText((Join-Path $out 'genicam.xml'), $cam.Xml.Text) } catch { }
        }
        foreach ($w in $cam.FormulaWarnings) { Log "  ⚠ 公式改變：$w" }

        # bootstrap 暫存器
        $boot = [ordered]@{ Version = 0x0000; DeviceMode = 0x0004; CurrentIPConfig = 0x0014; CurrentIP = 0x0024; NumStreamChannels = 0x0904; GVCPCapability = 0x0934; HeartbeatTimeout_ms = 0x0938
            TimestampFreqHigh = 0x093C; TimestampFreqLow = 0x0940; GVCPConfig = 0x0954; PendingTimeout = 0x0958; CCP = 0x0A00; PrimaryAppPort = 0x0A04; PrimaryAppIP = 0x0A14
            MCP = 0x0B00; MCDA = 0x0B10; SCP0 = 0x0D00; SCPS0 = 0x0D04; SCPD0 = 0x0D08; SCDA0 = 0x0D18; SCSP0 = 0x0D1C; SCC0 = 0x0D20; SCCFG0 = 0x0D24 }
        $rows = @(); $val = @{}
        foreach ($k in $boot.Keys) {
            $r = $client.ReadReg([uint32]$boot[$k])
            $rows += [pscustomobject]@{ Name = $k; Address = ('0x{0:X4}' -f $boot[$k]); Value = $(if ($r.Ok) { '0x{0:X8}' -f $r.Value } else { '' }); Decimal = $(if ($r.Ok) { $r.Value } else { '' }); Note = $r.Note }
            if ($r.Ok) { $val[$k] = $r.Value }
        }
        Save-Csv 'gev_bootstrap.csv' $rows
        if ($val.ContainsKey('CCP')) {
            $gv.CCP = $val.CCP
            $who = if (($val.CCP -band 1) -eq 1) { '獨占控制（exclusive）' } elseif (($val.CCP -band 2) -eq 2) { '一般控制（control）' } else { '沒有任何程式持有控制權' }
            Log ("  控制權 CCP = 0x{0:X} → {1}；控制者 {2}:{3}" -f $val.CCP, $who, (ConvertTo-IPv4String $val.PrimaryAppIP), ($val.PrimaryAppPort -band 0xFFFF))
        } else { Log "  CCP 讀取失敗：$(($rows | Where-Object Name -eq 'CCP').Note)" }
        if ($val.ContainsKey('HeartbeatTimeout_ms')) { Log "  Heartbeat 逾時：$($val.HeartbeatTimeout_ms) ms" }
        if ($val.ContainsKey('SCP0')) {
            $port = $val.SCP0 -band 0xFFFF; $gv.SCP0 = $port
            if ($port -eq 0) { Log '  串流通道 SCP0：已關閉（host port = 0）' }
            else {
                Log ("  串流通道 SCP0：開啟，影像送往 {0}:{1}；封包大小 {2}，封包間隔 SCPD {3}" -f (ConvertTo-IPv4String $val.SCDA0), $port, ($val.SCPS0 -band 0xFFFF), $val.SCPD0)
                $owner = $udpEps | Where-Object { $_.LocalPort -eq $port } | Select-Object -First 1
                if ($owner) { Log "    電腦上 UDP $port 由 $($owner.Process)（PID $($owner.OwningProcess)）開著" }
                else { Log "    電腦上找不到開著 UDP $port 的程式（可能由 GigE 過濾驅動接收，或接收端已關閉）" }
            }
        }
        $series = @()
        for ($i = 0; $i -lt 5; $i++) { $r = $client.ReadReg(0x0A00); $series += $(if ($r.Ok) { '0x{0:X}' -f $r.Value } else { $r.Note }); Start-Sleep -Milliseconds 1000 }
        Log ("  CCP 連續 5 秒：{0}" -f ($series -join ', '))

        # 第 3.2 節所有暫存器讀 3 輪
        if ($cam.GenApi) {
            $regRows = @()
            for ($round = 1; $round -le 3; $round++) {
                $smp = Read-CameraSample
                foreach ($k in $script:CamFeatureMap.Keys) {
                    $fi = $cam.Features[$k]
                    $addr = if ($fi -and $fi.Registers.Count) { ($fi.Registers | ForEach-Object { '0x{0:X8}' -f $_.Address }) -join ' ' } else { '' }
                    $regRows += [pscustomobject]@{ Round = $round; Time = (Get-Date).ToString('HH:mm:ss'); Feature = $script:CamFeatureMap[$k]; Address = $addr
                        Value = $(if ($smp.T.ContainsKey($k)) { $smp.T[$k] } else { '' }); Formula = $(if ($fi) { $fi.FormulaText } else { '' }); Status = $smp.Status }
                }
                if ($round -eq 3) {
                    $v = $smp.V; $t = $smp.T
                    $gv.Streaming = ($t.XferSel -eq 'Streaming' -and $v.XferStat -eq 1); $gv.TxFT = $v.TxFT; $gv.QCur = $v.QCur
                    Log ("  溫度 {0:0.0} °C，功耗 {1:0.00} W，開機 {2:N0} 秒，連線 {3:N0} 秒" -f $v.Temp, $v.Power, $v.UpTime, $v.LinkUp)
                    Log ("  取像模式 {0}，設定 {1:0.##} fps，觸發 {2}，Transfer {3}={4}，佇列 {5}/{6}，TransmissionFrameTime {7}" -f $t.AcqMode, $(if ($v.AcqFT) { 1e6 / $v.AcqFT } else { 0 }), $t.TrigMode, $t.XferSel, $v.XferStat, $v.QCur, $v.QMax, $v.TxFT)
                    Log ("  重送：收到 {0:N0}、有效 {1:N0}、無法重送 {2:N0}；頻寬限制 {3} {4:N0} MB/s，保留 {5}%" -f $v.RsRecv, $v.RsValid, $v.RsUnavail, $t.TLMode, ($v.TL / 1e6), $v.TLRes)
                } else { Start-Sleep -Seconds 2 }
            }
            Save-Csv 'gev_registers_3rounds.csv' $regRows
        }
    }
} catch {
    Log "  探測失敗：$($_.Exception.Message)"
} finally { if ($client) { $client.Dispose() } }

# ---------------------------------------------------------------------------
$rxAfter = Get-RxRateMBps $ctx.Guid 5
if ($null -ne $rxAfter) { Log "== 7. 5 秒內相機網卡接收 $rxAfter MB/s" }

# ---------------------------------------------------------------------------
Log '== 自動判斷'
if ($null -ne $gv.Discovery -and $gv.Discovery -eq 0) { $verdicts.Add('Discovery 無回應 → 相機韌體可能卡死，或網路不通（請看網卡是否 Up、ping 是否成功）') }
if ($null -ne $gv.CCP) {
    if (($gv.CCP -band 3) -eq 0) { $verdicts.Add('CCP = 0 → 沒有程式控制相機（heartbeat 逾時，或主機已釋放控制權）') }
    elseif ($gv.Streaming) {
        $noData = if ($null -ne $rxAfter) { $rxAfter -lt 1 } else { $gv.TxFT -eq 0 -and $gv.QCur -gt 0 }
        if ($noData) { $verdicts.Add("CCP ≠ 0、Streaming = 1、但沒有影像進來（網卡接收 $rxAfter MB/s，佇列 $($gv.QCur)） → 相機內部傳送卡死") }
        else { $verdicts.Add("相機正常送影像（網卡接收 $rxAfter MB/s）") }
    } else { $verdicts.Add('有程式控制相機，但相機沒有在傳送（Streaming = 0）→ 取像程式沒有開始取像') }
}
if ($null -ne $gv.SCP0 -and $gv.SCP0 -eq 0) { $verdicts.Add('SCP0 = 0 → 串流通道已關閉') }
# 封包擷取：丟封包發生在哪一層
$an = $script:CapAnalysis
if ($an -and $an.ResendPacketsRequested -gt 0) {
    if ($an.ResendSeenBefore -lt $an.ResendPacketsRequested * 0.5) {
        $verdicts.Add(("被要求重送的封包 {0} 個中有 {1} 個原本沒有出現在擷取中 → 封包在 pktmon 擷取點之前（網卡驅動的接收環，Receive Buffers）就被丟掉，請先調大 Receive Buffers" -f $an.ResendPacketsRequested, ($an.ResendPacketsRequested - $an.ResendSeenBefore)))
    } else {
        $verdicts.Add(("被要求重送的封包 {0} 個中有 {1} 個原本有到達擷取點 → 遺失發生在 Windows 網路堆疊或取像程式（CPU 負載、GigE 過濾驅動）" -f $an.ResendPacketsRequested, $an.ResendSeenBefore))
    }
} elseif ($an -and $an.CompleteBlocks -gt 0) {
    $verdicts.Add(("封包擷取 {0:0.0} 秒內沒有 PACKETRESEND，每張影像 {1:N0} 個封包完整（約 {2:0.0} ms 送完，突發約 {3:N0} MB/s）" -f $an.DurationSec, $an.MedianPackets, $an.MedianBlockMs, $an.MedianBurstMBps))
}
if ($an -and $an.CompleteBlocks -gt 0 -and $rb) {
    $bufMs = [double]$rb.RegistryValue[0] * 9014 / ($an.MedianBurstMBps * 1e6) * 1000
    $msg = "Receive Buffers {0} 以突發 {1:N0} MB/s 計約可緩衝 {2:0.0} ms" -f $rb.RegistryValue[0], $an.MedianBurstMBps, $bufMs
    if ($bufMs -lt 20) { $verdicts.Add("$msg → 太短，系統只要稍微延遲處理中斷就會丟封包，請調到驅動允許的最大值") } else { Log "  $msg" }
}
if ($verdicts.Count -eq 0) { $verdicts.Add('無法自動判斷（相機沒有回應或沒有讀到 CCP）') }
foreach ($v in $verdicts) { Log "  ● $v" }

$summaryFile = Join-Path $out 'summary.txt'
$head = @("CamNetTool 診斷快照  $($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))  標籤 $Label", '', '自動判斷：') + ($verdicts | ForEach-Object { "  ● $_" }) + @('', '詳細過程：')
($head + $summary) | Set-Content -LiteralPath $summaryFile -Encoding UTF8
$zipPath = "$out.zip"
try {
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zipPath -Force
    Log ("完成（{0:0} 秒）。請上傳：{1}" -f ((Get-Date) - $startedAt).TotalSeconds, $zipPath)
    # zip 已包含全部內容：刪掉解壓後的資料夾（封包擷取可能有上百 MB），只留 summary.txt 方便直接看
    try {
        Copy-Item -LiteralPath $summaryFile -Destination ("$out" + '_summary.txt') -Force
        Remove-Item -LiteralPath $out -Recurse -Force
    } catch { }
    Write-Progress2 "DONE|$zipPath"
} catch {
    Log "壓縮失敗，請直接上傳資料夾：$out"
    Write-Progress2 "DONE|$out"
}
