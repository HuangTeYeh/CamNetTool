param([string]$AppDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'CamNetTool'))
# CamNetTool 核心測試。不開視窗，不寫入相機或網卡設定；記錄與設定都寫到 %TEMP% 的測試資料夾。
# 有接相機時會多做幾項唯讀的實機測試（Discovery、讀暫存器）。
$ErrorActionPreference = 'Stop'
. (Join-Path $AppDir 'CamNetTool.ps1') -CoreOnly
$ErrorActionPreference = 'Stop'

$work = Join-Path $env:TEMP ('cnt_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$realAppDir = $script:AppDir
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "PASS  $Name $Detail" } else { $script:fail++; Write-Host "FAIL  $Name $Detail" -ForegroundColor Red }
}
function New-Regs([hashtable]$H) { $d = New-Object 'System.Collections.Generic.Dictionary[uint64,uint32]'; foreach ($k in $H.Keys) { $d[[uint64]$k] = [uint32]$H[$k] }; return , $d }

try {
    # ---- 公式 ----
    $vars = New-Object 'System.Collections.Generic.Dictionary[string,double]'
    $vars['V1'] = 616
    Check 'SwissKnife V1 / 16（相機溫度 0x268 → 38.5）' ([GenFormula]::Eval('V1 / 16', $vars) -eq 38.5)
    $vars['V1'] = 160000
    Check 'V1 * 0.05 / 1000（功耗 0x27100 → 8.0）' ([GenFormula]::Eval('V1 * 0.05 / 1000', $vars) -eq 8.0)
    $vars['TO'] = 100000
    Check 'Converter 1e6/TO（10 fps）' ([GenFormula]::Eval('1e6/TO', $vars) -eq 10)
    Check '三元、比較、十六進位、次方、函式' (([GenFormula]::Eval('(0x10 >= 16) ? 2**3 : 0', $vars) -eq 8) -and ([GenFormula]::Eval('ROUND(2.5)+ABS(-1)', $vars) -eq 4) -and ([GenFormula]::Eval('(3 <> 4) && (5 = 5)', $vars) -eq 1))

    # ---- 丟棄計數修正 ----
    $p = $false
    $d1 = [NicMonNative]::DiscardDelta([uint64]630002982831624, [uint64]630015867723268, [ref]$p)
    Check 'AQtion 丟棄計數：取高 32 位元的差（實測 3×2^32 + 雜訊 → 3）' ($d1 -eq 3 -and $p)
    $d2 = [NicMonNative]::DiscardDelta([uint64]1000, [uint64]1012, [ref]$p)
    Check '一般驅動：照原本的差值' ($d2 -eq 12 -and -not $p)
    $d3 = [NicMonNative]::DiscardDelta([uint64]5000, [uint64]10, [ref]$p)
    Check '計數器歸零：當作 0' ($d3 -eq 0)
    # 2026-11-25 發現的漏洞：高 32 位元沒變、只有低 32 位元變了（實測 +27,776、+1,866,458,126），不能算成丟棄
    $base = [uint64]216052 * [uint64]4294967296 + [uint64]1000
    $d4 = [NicMonNative]::DiscardDelta($base, $base + 27776, $true, [ref]$p)
    $d5 = [NicMonNative]::DiscardDelta($base, $base + 1866458126, $true, [ref]$p)
    $d6 = [NicMonNative]::DiscardDelta($base, $base + [uint64]2 * [uint64]4294967296 - 900, $true, [ref]$p)
    Check 'AQtion 丟棄計數：低 32 位元自己變動時不算丟棄（+27,776 → 0、+1,866,458,126 → 0、2×2^32−900 → 2）' ($d4 -eq 0 -and $d5 -eq 0 -and $d6 -eq 2) "$d4 / $d5 / $d6"
    $d7 = [NicMonNative]::DiscardDelta([uint64]1000, [uint64]1012, $true, [ref]$p)
    Check 'AQtion 但計數值小於 2^32（例如新版驅動已修正）：照原本的差值' ($d7 -eq 12 -and -not $p)

    # ---- GenICam XML（用快取的相機 XML）----
    $xmlFile = @(Get-ChildItem -LiteralPath (Join-Path $realAppDir 'CamNetToolData\xml'), (Join-Path $env:LOCALAPPDATA 'CamNetTool\xml') -Filter '*.zip' -ErrorAction SilentlyContinue | Where-Object Name -match '72212acace' | Select-Object -First 1)
    if ($xmlFile) {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($xmlFile[0].FullName)
        $sr = New-Object IO.StreamReader(($z.Entries | Where-Object Name -match '\.xml$' | Select-Object -First 1).Open()); $xt = $sr.ReadToEnd(); $sr.Close(); $z.Dispose()
        $m = [GenApiModel]::Load($xt)
        $expect = [ordered]@{ DeviceTemperature = 0x10100030; DevicePower = 0x101002D4; DeviceUpTime = 0x101002E4; LinkUpTime = 0x101002E8; AcquisitionMode = 0x10300000
            AcquisitionFrameTime = 0x10300014; AcquisitionFrameRateEnable = 0x10300028; TransmissionFrameTime = 0x10300030; TriggerSelector = 0x10310000; TriggerMode = 0x10310004
            TriggerSource = 0x1031000C; TriggerActivation = 0x10310010; TriggerArmed = 0x10310020; ExposureTimeRaw = 0x10310110; PayloadSize = 0x10200000; GevSCFTD = 0x10201048
            DeviceLinkThroughputLimitMode = 0x101001F0; DeviceLinkThroughputLimit = 0x101001F4; ShortReachModeEnable = 0x10201864; TransferControlMode = 0x10600004
            TransferQueueMaxBlockCount = 0x10600010; TransferQueueCurrentBlockCount = 0x10600014; TransferStatusSelector = 0x1060002C; TransferStatus = 0x10600030
            ReceivedPacketResendCount = 0x10600034; ValidPacketResendCount = 0x10600038; UnavailablePacketResendCount = 0x1060003C; LineStatusAll = 0x11500010 }
        $bad = @()
        foreach ($k in $expect.Keys) { $fi = $m.Resolve($k); $got = if ($fi.Registers.Count) { [uint64]$fi.Registers[0].Address } else { 0 }; if ($got -ne [uint64]$expect[$k]) { $bad += ('{0}=0x{1:X}' -f $k, $got) } }
        Check "XML 解析出的 28 個位址與規格第 3.2 節一致" ($bad.Count -eq 0) ($bad -join ' ')
        Check 'TriggerMode 是 Enumeration（排除同名的 EnumEntry）' ($m.NodeType('TriggerMode') -eq 'Enumeration')
        Check 'GevSCFTD 位址含 selector 偏移（IntSwissKnife V1*4）' ([uint64]$m.Resolve('GevSCFTD').Registers[0].Address -eq 0x10201048)
        # 用規格附的 L5 卡住讀值計算
        $regs = New-Regs @{ 0x10100030 = 0x268; 0x101002D4 = 0x27100; 0x1060002C = 0; 0x10310004 = 0; 0x101001F0 = 0; 0x10300014 = 100000; 0x10600030 = 1 }
        $t = $m.Evaluate('DeviceTemperature', $regs); $pw = $m.Evaluate('DevicePower', $regs)
        Check 'L5 卡住讀值：溫度 38.50 °C、功耗 8.00 W' ($t.Value -eq 38.5 -and $pw.Value -eq 8.0) "$($t.Value) / $($pw.Value)"
        Check '列舉：Streaming / Off / Off' ($m.Evaluate('TransferStatusSelector', $regs).Text -eq 'Streaming' -and $m.Evaluate('TriggerMode', $regs).Text -eq 'Off' -and $m.Evaluate('DeviceLinkThroughputLimitMode', $regs).Text -eq 'Off')
        Check 'Float Converter：AcquisitionFrameRate = 10' ($m.Evaluate('AcquisitionFrameRate', $regs).Value -eq 10)
        Check '公式與預期相同（沒有「公式改變」）' ((($m.Resolve('DeviceTemperature').Formulas | ForEach-Object { [GenFormula]::Normalize(($_ -replace '^[^:]+:\s*', '')) }) -join ';') -eq 'V1/16')
        $fi = $m.Resolve('UserSetDefault')
        Check '可寫入的 feature 有直接位址（UserSetDefault）' ($fi.DirectAddress -eq 0x1070000C -and $fi.EnumValues.ContainsKey('UserSet1'))
    } else { Write-Host 'SKIP  沒有快取的相機 XML（先接相機開一次監控）' }

    # ---- 網段工具 ----
    Check '廣播位址 169.254.192.4/16' ((Get-BroadcastAddress '169.254.192.4' 16) -eq '169.254.255.255')
    Check '同網段判斷' ((Test-SameSubnet '169.254.23.146' '169.254.192.4' 16) -and -not (Test-SameSubnet '192.168.1.2' '169.254.192.4' 16))

    # ---- 指定來源 IP 的 ping（IcmpSendEcho2Ex，等同 ping -S）----
    $sp = New-Object SourcePing
    try {
        $r1 = $sp.Send('127.0.0.1', '127.0.0.1', 500)
        Check 'SourcePing：127.0.0.1 → 127.0.0.1 成功' ($r1.Ok -and $r1.StatusText -eq 'Success' -and $r1.ReplyFrom -eq '127.0.0.1')
        $r2 = $sp.Send('10.250.250.250', '127.0.0.1', 500)
        Check 'SourcePing：來源 IP 不是這台電腦的 → 失敗，不會改從別的 IP 送' (-not $r2.Ok -and $r2.Status -ne 0) "$($r2.Status) $($r2.StatusText)"
    } finally { $sp.Dispose() }
    Check 'SourcePing：狀態名稱與 .NET IPStatus 相同（舊記錄的 Fail:TimedOut 等格式不變）' (([SourcePing]::StatusName(11010) -eq 'TimedOut') -and ([SourcePing]::StatusName(11003) -eq 'DestinationHostUnreachable') -and ([SourcePing]::StatusName(11050) -eq 'GeneralFailure'))

    # ---- 設定檔：沿用 NicMonitor 的設定 ----
    $script:AppDir = $work
    $nm = [ordered]@{ AdapterGuid = '{11111111-2222-3333-4444-555555555555}'; AdapterName = '小FOV'; CameraIp = '169.254.1.2'; IntervalSec = 7; LogDir = 'X:\nope'; BeepOnAlarm = $false }
    [IO.File]::WriteAllText((Join-Path $work 'NicMonitor.config.json'), ($nm | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
    $c = Read-Config
    Check '第一次使用：沿用 NicMonitor 的網卡、相機 IP、間隔（記錄位置不沿用）' ($c.AdapterGuid -eq $nm.AdapterGuid -and $c.CameraIp -eq '169.254.1.2' -and $c.IntervalSec -eq 7 -and -not $c.LogDir -and $c.CameraIpAuto)
    $script:Cfg = $c
    $script:Cfg.LogDir = Join-Path $work 'log'
    Save-Config
    Check '設定檔存成 CamNetTool.config.json' (Test-Path (Join-Path $work 'CamNetTool.config.json'))

    # ---- 相機狀態機（假資料，不連相機）----
    [void](Initialize-LogDir)
    $script:S = New-MonitorState '{x}' 'test' '169.254.239.102'
    $script:S.Cam = New-CameraState
    $script:Cam = @{ Ip = '169.254.239.102'; Client = $null }
    $script:Cfg.StallSamples = 3; $script:Cfg.ResendWarn = 500; $script:Cfg.CamTempWarnC = 60
    $t0 = Get-Date '2026-11-23 10:00:00'
    $base = @{ Temp = 38.5; Power = 8.0; UpTime = 515010; LinkUp = 508147; AcqFT = 100000; TxFT = 0; XferStat = 1; QCur = 2; QMax = 37; Payload = 24472000; RsRecv = 123129; RsValid = 121985; RsUnavail = 1144; TL = 1250000000; TLRes = 8 }
    $baseT = @{ XferSel = 'Streaming'; TrigMode = 'Off'; TLMode = 'Off' }
    $boot = @{ CCP = 2; PrimIP = 0xA9FED86E; PrimPort = 57000; SCP0 = 57393; SCPD0 = 0 }
    function New-Smp([hashtable]$V = @{}, [hashtable]$T = @{}, [hashtable]$B = @{}, [string]$Status = 'Ok') {
        $vv = $base.Clone(); foreach ($k in $V.Keys) { $vv[$k] = $V[$k] }
        $tv = $baseT.Clone(); foreach ($k in $T.Keys) { $tv[$k] = $T[$k] }
        $bv = $boot.Clone(); foreach ($k in $B.Keys) { $bv[$k] = $B[$k] }
        return @{ Status = $Status; V = $vv; T = $tv; Boot = $bv; Ms = 1.2; Errors = @() }
    }
    function Get-Ev([int]$Id) { return , @($script:S.Events | Where-Object { $_.EventId -eq $Id }) }   # 逗號：只有一筆時也保持是陣列（PS 5.1 的 pscustomobject 沒有 .Count）
    $i = 0
    foreach ($rep in 1..3) { Invoke-CameraProcess (New-Smp) $t0.AddSeconds(10 * $i++) 0.0 }
    Check 'L5 卡住：有控制者、Streaming=1、沒有影像進來，連續 3 次 → 相機卡住（錯誤＋聲音）' ((Get-Ev 100).Count -eq 1 -and (Get-Ev 100)[0].Severity -eq 'Error' -and $script:S.AlarmPending -and $script:S.Cam.LastState -eq 'Stalled')
    Invoke-CameraProcess (New-Smp) $t0.AddSeconds(10 * $i++) 0.0
    Check '卡住只記一次' ((Get-Ev 100).Count -eq 1)
    Invoke-CameraProcess (New-Smp @{ QCur = 0; RsRecv = 123129 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '影像恢復 → 相機恢復送影像（資訊）' ((Get-Ev 101).Count -eq 1 -and $script:S.Cam.LastState -eq 'Streaming')
    Check '正常送影像時 TransmissionFrameTime = 0 也不算卡住（這台相機實測）' ($script:S.Cam.LastText -match '正常送影像' -and $script:S.Cam.StallRun -eq 0)
    Invoke-CameraProcess (New-Smp @{ XferStat = 0; QCur = 0 }) $t0.AddSeconds(10 * $i++) 0.0
    Check '沒有在傳送（Streaming=0）→ 未取像，不算卡住' ($script:S.Cam.LastState -eq 'Idle' -and $script:S.Cam.StallRun -eq 0)
    Invoke-CameraProcess (New-Smp @{ QCur = 0 } @{ TrigMode = 'On' }) $t0.AddSeconds(10 * $i++) 0.0
    Check 'TriggerMode On、沒有影像 → 等待觸發，不算卡住' ($script:S.Cam.LastState -eq 'WaitTrigger')
    Invoke-CameraProcess (New-Smp @{} @{} @{ CCP = 0 }) $t0.AddSeconds(10 * $i++) 0.0
    Check '控制權釋放（CCP 0）→ 警告；沒有控制者 → 未取像' (@((Get-Ev 106) | Where-Object Severity -eq 'Warning').Count -eq 1 -and $script:S.Cam.LastState -eq 'Idle')
    Invoke-CameraProcess (New-Smp) $t0.AddSeconds(10 * $i++) 246.0
    Check '控制權取得 → 資訊' (@((Get-Ev 106) | Where-Object Severity -eq 'Info').Count -eq 1)
    Invoke-CameraProcess (New-Smp @{ RsRecv = 123129 + 800; RsUnavail = 1150 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '重送暴增（+800 ≥ 500）與無法重送（+6）→ 警告' ((Get-Ev 107).Count -eq 1 -and (Get-Ev 108).Count -eq 1 -and $script:S.Cam.SumResend -eq 800)
    Invoke-CameraProcess (New-Smp @{ RsRecv = 123929; RsUnavail = 1150; Temp = 61.0 }) $t0.AddSeconds(10 * $i++) 246.0
    Invoke-CameraProcess (New-Smp @{ RsRecv = 123929; RsUnavail = 1150; Temp = 62.0 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '相機溫度 ≥ 60 °C → 警告一次' ((Get-Ev 109).Count -eq 1)
    Invoke-CameraProcess (New-Smp @{ RsRecv = 10; RsUnavail = 0; UpTime = 30; LinkUp = 25 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '開機時間變小 → 相機重開機；重送計數歸零不算負數' ((Get-Ev 104).Count -eq 1 -and $script:S.Cam.SumResend -eq 810)
    Invoke-CameraProcess (New-Smp @{ RsRecv = 10; RsUnavail = 0; UpTime = 40; LinkUp = 2 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '連線時間變小 → 連線重置' ((Get-Ev 105).Count -eq 1)
    Invoke-CameraProcess @{ Status = 'NoResponse'; V = @{}; T = @{}; Boot = @{}; Ms = 900; Errors = @() } $t0.AddSeconds(10 * $i++) 0.0
    Invoke-CameraProcess @{ Status = 'NoResponse'; V = @{}; T = @{}; Boot = @{}; Ms = 900; Errors = @() } $t0.AddSeconds(10 * $i++) 0.0
    Check '相機無回應 → 錯誤一次' ((Get-Ev 102).Count -eq 1 -and $script:S.Cam.LastState -eq 'NoResponse')
    Invoke-CameraProcess (New-Smp @{ RsRecv = 10; RsUnavail = 0; UpTime = 60; LinkUp = 20 }) $t0.AddSeconds(10 * $i++) 246.0
    Check '恢復回應 → 資訊' ((Get-Ev 103).Count -eq 1)
    [void](Invoke-FlushLogs)
    $camCsv = Get-ChildItem (Join-Path $work 'log') -Filter 'camstatus_*.csv' | Select-Object -First 1
    $lines = [IO.File]::ReadAllLines($camCsv.FullName)
    $n = $script:CamStatusHeader.Split(',').Count
    $badCols = @($lines | Select-Object -Skip 1 | Where-Object { ($_ -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)').Count -ne $n }).Count
    Check "camstatus 每一列都是 $n 欄（包含無回應的列）" ($badCols -eq 0 -and $lines.Count -eq $i + 1) "$($lines.Count - 1) 列"
    $nm17 = 'Time,LinkStatus,LinkSpeed,RxMBps,RxDiscardDelta,RxErrorDelta,TxDiscardDelta,TxErrorDelta,CameraPingMs,CpuPercent,AcpiTempC,RxDiscardDeltaDiv2p32,NicMacTempC,NicPhyTempC,AqRxPathReset,AqTxPathReset,AqTxWatchdog'
    Check 'status 保留 NicMonitor 1.1.0 的 17 欄，最後加 RxDiscardDeltaRaw' ($script:StatusHeader -eq "$nm17,RxDiscardDeltaRaw")

    # ---- ping 來源 IP 的快取與重查（以假的 Get-LocalIpForCamera 代替真的網卡）----
    $origLocal = ${function:Get-LocalIpForCamera}
    try {
        $script:fakeLocal = '169.254.1.10'; $script:fakeCalls = 0
        ${function:Get-LocalIpForCamera} = { param($Guid, $CameraIp) $script:fakeCalls++; return $script:fakeLocal }
        $keepS = $script:S
        $PS0 = New-MonitorState '{x}' 'test' '169.254.1.2'
        $script:S = $PS0                     # Add-MonitorEvent 寫到 $script:S.Events
        $tp = Get-Date '2026-11-26 09:00:00'
        $src1 = Update-PingSource $PS0 $tp
        $src2 = Update-PingSource $PS0 $tp.AddSeconds(5)
        Check 'ping 來源：第一次查到後快取，不會每次都查網卡' ($src1 -eq '169.254.1.10' -and $src2 -eq '169.254.1.10' -and $script:fakeCalls -eq 1)
        $script:fakeLocal = '169.254.1.11'; $PS0.LastPingOk = $false
        $src3 = Update-PingSource $PS0 $tp.AddSeconds(20)
        $src4 = Update-PingSource $PS0 $tp.AddSeconds(40)
        Check 'ping 來源：ping 失敗時每 30 秒重查一次，IP 改變就換來源' ($src3 -eq '169.254.1.10' -and $src4 -eq '169.254.1.11' -and $script:fakeCalls -eq 2)
        $PS0.LastPingOk = $true; $script:fakeLocal = $null; $PS0.CameraIp = '169.254.9.9'
        $src5 = Update-PingSource $PS0 $tp.AddSeconds(41)
        Check 'ping 來源：相機 IP 改變立刻重查；網卡沒有 IPv4 → 沒有來源（不改從別張網卡送）' ($src5 -eq '' -and $script:fakeCalls -eq 3)
        $ev22 = @($PS0.Events | Where-Object { $_.EventId -eq 22 })
        Check 'ping 來源改變 → 事件 22（2 次）' ($ev22.Count -eq 2 -and $ev22[0].Message -match '網卡沒有 IPv4') (($ev22 | ForEach-Object { $_.Message }) -join ' | ')
    } finally { ${function:Get-LocalIpForCamera} = $origLocal; $script:S = $keepS }

    # ---- 套用前後比較 ----
    $at = Get-Date '2026-11-20 12:00:00'
    $sl = @($script:StatusHeader); $cl = @($script:CamStatusHeader)
    for ($k = -6; $k -lt 6; $k++) {
        $tt = $at.AddMinutes(10 * $k).ToString('yyyy-MM-dd HH:mm:ss')
        $disc = if ($k -lt 0) { 30 } else { 0 }; $rs = if ($k -lt 0) { 200 } else { 1 }
        $sl += "$tt,Up,10 Gbps,246,$disc,0,0,0,1,5,40,0,,,,,,0"
        $f = @($tt, 'OK') + (@('') * 16) + @($rs) + (@('') * 11); $cl += ($f -join ',')
    }
    [IO.File]::WriteAllLines((Join-Path $script:ActiveLogDir 'status_20261120.csv'), $sl)
    [IO.File]::WriteAllLines((Join-Path $script:ActiveLogDir 'camstatus_20261120.csv'), $cl)
    $b = Get-WindowStats $at.AddHours(-1) $at; $a = Get-WindowStats $at $at.AddHours(1)
    Check '套用前後各 1 小時：丟棄 180 → 0、重送 1200 → 6' ($b.Discards -eq 180 -and $a.Discards -eq 0 -and $b.Resends -eq 1200 -and $a.Resends -eq 6) "$($b.Discards)/$($a.Discards) $($b.Resends)/$($a.Resends)"

    # ---- 版本比較 ----
    Check '版本：次版本號差 33' ((Get-VersionGap '1.21.0.0' '1.54.0.0').Text -eq '落後：1.21.0.0 → 1.54.0.0（次版本號差 33）')
    Check '版本：主版本差 1' ((Get-VersionGap '2.2.2.0' '3.1.11.0').Text -eq '落後：2.2.2.0 → 3.1.11.0（主版本差 1）')
    Check '版本：已是最新' (-not (Get-VersionGap '1.54.0.0' '1.54.0.0').Old)
    Check '取較新的版本' ((Get-MaxVersion @('1.0.65.17', '1.0.85.11')) -eq '1.0.85.11')

    # ---- 頻寬限制值符合 min / max / inc ----
    Check '頻寬限制目標符合 XML 範圍' ((Get-ValidLimit 300000000 44064544 1250000000 1) -eq 300000000 -and (Get-ValidLimit 2e9 44064544 1250000000 1) -eq 1250000000 -and (Get-ValidLimit 1000 44064544 1250000000 8) -eq 44064544)

    # ---- 備份與復原紀錄 ----
    $bk = Save-OptimizeBackup 'nic.rxbuffers' '網卡 Receive Buffers' 512 4096
    $lb = Get-LatestBackup 'nic.rxbuffers'
    Check '備份：修改前的值、執行者都有記錄' ($lb -and $lb.Data.Before -eq 512 -and $lb.Data.After -eq 4096 -and $lb.Data.User -match $env:USERNAME)
    Set-BackupRestored $lb.Path
    Check '復原後不會再被當成可復原' (-not (Get-LatestBackup 'nic.rxbuffers'))
    Check '突發速率：沒有擷取時用規格的 494 MB/s' ((Get-BurstRate).MBps -eq 494)

    # ---- 非 GigE 驅動分類、Flow Control 顯示 ----
    $bc = { param($n, $id) Get-BindingCategory ([pscustomobject]@{ DisplayName = $n; ComponentID = $id }) }
    $catOk = ($null -eq (& $bc 'Internet Protocol Version 4 (TCP/IPv4)' 'ms_tcpip')) -and ($null -eq (& $bc 'WFP 802.3 MAC Layer LightWeight Filter' 'ms_wfplwf_upper')) -and
        ((& $bc 'OMRON SENTECH GigE Vision Driver' 'StGigE') -eq 'GigE') -and ((& $bc 'Lucid Vision Labs Lightweight Filter Driver' 'Lucid_NdisLwf') -eq 'GigE') -and
        ((& $bc 'NI GigE Vision Adapter' 'ni_gige') -eq 'GigE') -and
        ((& $bc 'VirtualBox NDIS6 Bridged Networking Driver' 'oracle_VBoxNetLwf') -eq '虛擬機') -and ((& $bc 'VMware Bridge Protocol' 'vmware_bridge') -eq '虛擬機') -and
        ((& $bc 'Hyper-V Extensible Virtual Switch' 'vms_pp') -eq '虛擬機') -and
        ((& $bc 'Cisco AnyConnect Network Access Manager Filter Driver' 'cisco_acnamfd') -eq 'VPN') -and ((& $bc 'Fortinet NDIS 6.3 Packet Filter Driver' 'ft_fortindis') -eq 'VPN') -and
        ((& $bc 'Kaspersky Anti-Virus NDIS 6 Filter' 'kl_klim6') -eq '防火牆／防毒') -and ((& $bc 'ESET Personal Firewall' 'eset_epfwlwf') -eq '防火牆／防毒') -and
        ((& $bc 'Npcap Packet Driver (NPCAP)' 'insecure_npcap') -eq '封包擷取') -and ((& $bc 'Some Vendor Filter' 'acme_lwf') -eq '其他第三方')
    Check '非 GigE 驅動分類：Windows 內建略過、GigE 另外處理、VirtualBox／VMware／VPN／防火牆／Npcap 分類正確' $catOk
    $fcOk = ((Get-FlowControlText ([pscustomobject]@{ DisplayValue = 'Disabled'; RegistryKeyword = '*FlowControl'; RegistryValue = @('0') })) -eq 'Disabled（關閉）') -and
        ((Get-FlowControlText ([pscustomobject]@{ DisplayValue = 'Rx & Tx Enabled'; RegistryKeyword = '*FlowControl'; RegistryValue = @('3') })) -eq 'Rx & Tx Enabled（收送都開）') -and
        ((Get-FlowControlText $null) -eq '驅動沒有這個設定')
    Check 'Flow Control 顯示文字' $fcOk

    # ---- pcapng 分析（合成資料：一張影像缺 1 個封包 → PACKETRESEND → 之後才收到）----
    $cam = [byte[]](169, 254, 239, 102); $hst = [byte[]](169, 254, 216, 110)
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    function Write-Block([int]$Type, [byte[]]$Body) {
        $pad = (4 - ($Body.Length % 4)) % 4
        $len = 12 + $Body.Length + $pad
        $bw.Write([uint32]$Type); $bw.Write([uint32]$len); $bw.Write($Body); if ($pad) { $bw.Write((New-Object byte[] $pad)) }; $bw.Write([uint32]$len)
    }
    $shb = New-Object IO.MemoryStream; $w2 = New-Object IO.BinaryWriter($shb); $w2.Write([uint32]0x1A2B3C4D); $w2.Write([uint16]1); $w2.Write([uint16]0); $w2.Write([int64]-1)
    Write-Block 0x0A0D0D0A $shb.ToArray()
    $idb = New-Object IO.MemoryStream; $w3 = New-Object IO.BinaryWriter($idb); $w3.Write([uint16]1); $w3.Write([uint16]0); $w3.Write([uint32]0)
    Write-Block 1 $idb.ToArray()
    $script:ipid = 1
    function New-Udp([byte[]]$Src, [byte[]]$Dst, [int]$Sport, [int]$Dport, [byte[]]$Payload) {
        $p = New-Object byte[] (14 + 20 + 8 + $Payload.Length)
        $p[12] = 0x08; $p[13] = 0x00
        $p[14] = 0x45; $tot = 20 + 8 + $Payload.Length; $p[16] = [byte]($tot -shr 8); $p[17] = [byte]($tot -band 255)
        $p[18] = [byte]($script:ipid -shr 8); $p[19] = [byte]($script:ipid -band 255); $script:ipid++
        $p[22] = 64; $p[23] = 17
        [Array]::Copy($Src, 0, $p, 26, 4); [Array]::Copy($Dst, 0, $p, 30, 4)
        $p[34] = [byte]($Sport -shr 8); $p[35] = [byte]($Sport -band 255); $p[36] = [byte]($Dport -shr 8); $p[37] = [byte]($Dport -band 255)
        $ul = 8 + $Payload.Length; $p[38] = [byte]($ul -shr 8); $p[39] = [byte]($ul -band 255)
        [Array]::Copy($Payload, 0, $p, 42, $Payload.Length)
        return , $p
    }
    function Write-Pkt([double]$Ts, [byte[]]$Pkt) {
        $us = [uint64]($Ts * 1e6)
        $m2 = New-Object IO.MemoryStream; $w4 = New-Object IO.BinaryWriter($m2)
        $w4.Write([uint32]0); $w4.Write([uint32]($us -shr 32)); $w4.Write([uint32]($us -band [uint64]4294967295)); $w4.Write([uint32]$Pkt.Length); $w4.Write([uint32]$Pkt.Length); $w4.Write($Pkt)
        Write-Block 6 $m2.ToArray()
    }
    function New-Gvsp([int]$Block, [int]$PacketId) { $g = New-Object byte[] 64; $g[2] = [byte]($Block -shr 8); $g[3] = [byte]($Block -band 255); $g[4] = 3; $g[5] = [byte]($PacketId -shr 16); $g[6] = [byte](($PacketId -shr 8) -band 255); $g[7] = [byte]($PacketId -band 255); return , $g }
    $ts = 1000.0
    foreach ($blk in 5, 6, 7) {
        for ($pid2 = 0; $pid2 -le 20; $pid2++) {
            if ($blk -eq 6 -and $pid2 -eq 9) { continue }      # 第 6 張缺封包 9
            $pk = New-Udp $cam $hst 20000 57393 (New-Gvsp $blk $pid2)
            Write-Pkt $ts $pk; Write-Pkt $ts $pk          # pktmon 會在多個擷取點重複記錄
            $ts += 0.0005
        }
        if ($blk -eq 6) {
            $rq = New-Object byte[] 20
            $rq[0] = 0x42; $rq[1] = 0x01; $rq[3] = 0x40; $rq[5] = 12; $rq[7] = 99; $rq[11] = 6; $rq[15] = 9; $rq[19] = 9
            Write-Pkt $ts (New-Udp $hst $cam 50000 3956 $rq); $ts += 0.001
            Write-Pkt $ts (New-Udp $cam $hst 20000 57393 (New-Gvsp 6 9)); $ts += 0.001
        }
        $ts += 0.05
    }
    $bw.Flush()
    $pcap = Join-Path $work 'synthetic.pcapng'
    [IO.File]::WriteAllBytes($pcap, $ms.ToArray())
    $an = [PcapngAnalyzer]::Analyze($pcap, '169.254.239.102')
    Check 'pcapng：去除 pktmon 重複記錄' ($an.StreamPackets -eq 63 -and $an.RawPackets -gt $an.UniquePackets) "影像封包 $($an.StreamPackets)"
    Check 'pcapng：找到 PACKETRESEND（影像 6 封包 9）' ($an.Resends.Count -eq 1 -and $an.Resends[0].BlockId -eq 6 -and $an.Resends[0].First -eq 9)
    Check 'pcapng：被要求重送的封包原本沒出現、之後才出現（→ 在擷取點之前被丟掉）' ($an.ResendSeenBefore -eq 0 -and $an.ResendSeenAfter -eq 1)
    Check 'pcapng：每張影像 21 個封包、計算送完時間' ($an.CompleteBlocks -eq 1 -and $an.MedianPackets -eq 21 -and $an.MedianBlockMs -gt 9) "$($an.MedianBlockMs) ms"

    # ---- 實機（唯讀）----
    $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match $script:AutoNicPattern -and $_.Status -eq 'Up' } | Select-Object -First 1
    if ($nic) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $f = Find-CameraIpAuto ([string]$nic.InterfaceGuid)
        Check '實機：自動找到相機 IP（不用自己查）' ($null -ne $f -and (Test-IPv4 $f.Ip)) ("{0}（{1}，{2} ms）" -f $f.Ip, $f.Method, $sw.ElapsedMilliseconds)
        if ($f) {
            $script:AppDir = $realAppDir
            $script:Cam = Connect-Camera (Get-LocalIpForCamera ([string]$nic.InterfaceGuid) $f.Ip) $f.Ip
            $smp = Read-CameraSample
            Check '實機：一次讀完所有監控暫存器' ($smp.Status -eq 'Ok' -and $smp.V.ContainsKey('Temp') -and $smp.T.ContainsKey('XferSel')) ("{0} 個位址，{1} ms，溫度 {2:0.0} °C" -f $script:Cam.ReadAddrs.Count, $smp.Ms, $smp.V.Temp)
            Disconnect-Camera
            # ping 從相機網卡送出要通；硬從別張網卡的 IP 送出要不通（證明來源真的有綁定，不是路由表幫忙選）
            $camSrc = Get-LocalIpForCamera ([string]$nic.InterfaceGuid) $f.Ip
            $other = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -ne $nic.ifIndex -and $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^127\.' } | Select-Object -First 1
            $sp = New-Object SourcePing
            try {
                $rc = $sp.Send($camSrc, $f.Ip, 500)
                Check '實機：ping 從相機網卡的 IP 送出' $rc.Ok ("{0} → {1}，{2} ms" -f $camSrc, $f.Ip, $rc.RoundtripMs)
                if ($other) {
                    $ro = $sp.Send([string]$other.IPAddress, $f.Ip, 500)
                    Check '實機：從別張網卡的 IP 送出 → 不通（來源有綁定）' (-not $ro.Ok) ("{0}（{1}）→ {2}：{3}" -f $other.IPAddress, $other.InterfaceAlias, $f.Ip, $ro.StatusText)
                } else { Write-Host 'SKIP  沒有其他網卡可以對照' }
            } finally { $sp.Dispose() }
        }
        $nb = Get-NonGigEBindings $nic.Name
        $fcp = Get-AdvProp @(Get-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -ErrorAction SilentlyContinue) @('*FlowControl', 'FlowControl')
        Check '實機：讀取非 GigE 驅動與 Flow Control（只讀）' ($null -ne $nb) ("非 GigE 驅動 {0} 個；Flow Control {1}" -f $nb.Count, (Get-FlowControlText $fcp))
    } else { Write-Host 'SKIP  沒有連線中的相機網卡' }
} finally {
    $script:AppDir = $realAppDir
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ("結果：{0} 通過，{1} 失敗" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
