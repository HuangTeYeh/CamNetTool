#Requires -Version 5.1
<#
    CamNetTool - 相機（GigE Vision / GVCP）核心
    * 自動找相機 IP：GVCP Discovery（廣播）→ 找不到再看 ARP 表
    * 從相機下載 GenICam XML（快取在 CamNetToolData\xml），暫存器位址一律由 XML 解析
    * 監控時只送 READREG / READMEM（唯讀），不影響取像程式的控制權
    * 本檔不含視窗程式碼；由 CamNetTool.ps1 dot-source
#>

$script:CamStatusHeader = 'Time,Gvcp,GvcpMs,CameraIp,TempC,PowerW,UpTimeS,LinkUpTimeS,AcqFps,TxFrameTimeUs,EstFps,RxMBps,TriggerMode,TransferStatusSel,Streaming,QueueCur,QueueMax,ResendRecv,ResendRecvDelta,ResendValid,ResendUnavail,ResendUnavailDelta,ThroughputLimitMode,ThroughputLimitBps,ThroughputReserve,CCP,Controller,SCP0Port,SCPD0,CamState'

# 監控要讀的 feature（名稱以 XML 為準，位址啟動時解析）
$script:CamFeatureMap = [ordered]@{
    Temp = 'DeviceTemperature'; Power = 'DevicePower'; UpTime = 'DeviceUpTime'; LinkUp = 'LinkUpTime'
    AcqMode = 'AcquisitionMode'; AcqFT = 'AcquisitionFrameTime'; AcqFREn = 'AcquisitionFrameRateEnable'; TxFT = 'TransmissionFrameTime'
    TrigSel = 'TriggerSelector'; TrigMode = 'TriggerMode'; TrigSrc = 'TriggerSource'; TrigAct = 'TriggerActivation'; TrigArmed = 'TriggerArmed'
    ExpRaw = 'ExposureTimeRaw'; Payload = 'PayloadSize'; SCFTD = 'GevSCFTD'
    TLMode = 'DeviceLinkThroughputLimitMode'; TL = 'DeviceLinkThroughputLimit'; TLRes = 'DeviceLinkThroughputReserve'; ShortReach = 'ShortReachModeEnable'
    XferCtl = 'TransferControlMode'; QMax = 'TransferQueueMaxBlockCount'; QCur = 'TransferQueueCurrentBlockCount'
    XferSel = 'TransferStatusSelector'; XferStat = 'TransferStatus'
    RsRecv = 'ReceivedPacketResendCount'; RsValid = 'ValidPacketResendCount'; RsUnavail = 'UnavailablePacketResendCount'
    Lines = 'LineStatusAll'
}
# GigE Vision 標準 bootstrap 暫存器（規格固定，不需 XML）
$script:CamBootstrap = [ordered]@{
    CCP = 0x0A00; PrimPort = 0x0A04; PrimIP = 0x0A14; Heartbeat = 0x0938
    SCP0 = 0x0D00; SCPS0 = 0x0D04; SCPD0 = 0x0D08; SCDA0 = 0x0D18
}
# 已知的換算公式（XML 72212acace…）。XML 的公式與此不同時提示「公式改變，請確認」，並以 XML 的公式計算
$script:CamExpectedFormulas = @{ DeviceTemperature = 'V1/16'; DevicePower = 'V1*0.05/1000' }

function ConvertTo-IPv4String([int64]$V) {
    $V = $V -band [int64]4294967295        # 接受 uint32，也接受被當成負數的 int32
    return '{0}.{1}.{2}.{3}' -f (($V -shr 24) -band 255), (($V -shr 16) -band 255), (($V -shr 8) -band 255), ($V -band 255)
}

function ConvertTo-UInt32IP([string]$Ip) {
    $b = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return [uint32](([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3])
}

function Get-BroadcastAddress([string]$Ip, [int]$Prefix) {
    $v = [uint64](ConvertTo-UInt32IP $Ip)
    $hostBits = 32 - $Prefix
    $mask = if ($hostBits -ge 32) { [uint64]4294967295 } else { [uint64]([math]::Pow(2, $hostBits) - 1) }
    return ConvertTo-IPv4String ([uint32](($v -bor $mask) -band [uint64]4294967295))
}

function Test-SameSubnet([string]$A, [string]$B, [int]$Prefix) {
    if ($Prefix -le 0) { return $true }
    $m = [uint64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix))
    return (([uint64](ConvertTo-UInt32IP $A) -band $m) -eq ([uint64](ConvertTo-UInt32IP $B) -band $m))
}

# 網卡的 IPv4（可能不只一個）
function Get-AdapterIPv4([string]$Guid) {
    $na = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $Guid } | Select-Object -First 1
    if (-not $na) { return @() }
    return @(Get-NetIPAddress -InterfaceIndex $na.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -ne 'Invalid' } |
        ForEach-Object { [pscustomobject]@{ IP = [string]$_.IPAddress; Prefix = [int]$_.PrefixLength; IfIndex = [int]$na.ifIndex } })
}

# ARP 表裡、與網卡同網段的 unicast 鄰居（相機直連時通常只有一個）
function Get-ArpCameraCandidates([string]$Guid) {
    $ips = Get-AdapterIPv4 $Guid
    if (-not $ips) { return @() }
    $list = @()
    foreach ($n in @(Get-NetNeighbor -InterfaceIndex $ips[0].IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $a = [string]$n.IPAddress
        if ($n.State -in 'Unreachable', 'Permanent', 'Incomplete') { continue }
        if ($a -match '^(22[4-9]|23\d|24\d|25[0-5])\.' -or $a -match '\.255$') { continue }
        if ([string]$n.LinkLayerAddress -match '^(00-){5}00$|^(FF-){5}FF$') { continue }
        $ok = $false
        foreach ($l in $ips) { if ($a -ne $l.IP -and (Test-SameSubnet $a $l.IP $l.Prefix)) { $ok = $true } }
        if ($ok) { $list += [pscustomobject]@{ IP = $a; Mac = [string]$n.LinkLayerAddress; State = [string]$n.State } }
    }
    return $list
}

# GVCP Discovery：從相機網卡的每個 IP 送廣播
function Find-GigECameras([string]$Guid, [int]$TimeoutMs = 1000) {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($l in (Get-AdapterIPv4 $Guid)) {
        $targets = @('255.255.255.255', (Get-BroadcastAddress $l.IP $l.Prefix))
        try {
            foreach ($d in [GvcpClient]::Discover($l.IP, [string[]]($targets | Select-Object -Unique), $TimeoutMs)) {
                if (-not ($found | Where-Object { $_.Device.Mac -eq $d.Mac })) {
                    $found.Add([pscustomobject]@{ Device = $d; LocalIp = $l.IP; Prefix = $l.Prefix })
                }
            }
        } catch { }
    }
    return , $found.ToArray()
}

# 自動決定相機 IP：先 Discovery（優先選上次的序號），找不到再用 ARP 表
function Find-CameraIpAuto([string]$Guid, [string]$PreferSerial = '') {
    $cams = Find-GigECameras $Guid
    if ($cams.Count -gt 0) {
        $pick = $null
        if ($PreferSerial) { $pick = $cams | Where-Object { $_.Device.Serial -eq $PreferSerial } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cams[0] }
        $d = $pick.Device
        return [pscustomobject]@{
            Ip = $d.Ip; LocalIp = $pick.LocalIp; Method = 'Discovery'; Count = $cams.Count
            Text = '{0} {1}（序號 {2}，韌體 {3}）' -f $d.Manufacturer, $d.Model, $d.Serial, $d.Version
            Serial = $d.Serial; Model = $d.Model; Version = $d.Version; All = $cams
        }
    }
    $arp = @(Get-ArpCameraCandidates $Guid)
    if ($arp.Count -gt 0) {
        $a = $arp | Sort-Object @{ Expression = { if ($_.State -eq 'Reachable') { 0 } else { 1 } } } | Select-Object -First 1
        $local = (Get-AdapterIPv4 $Guid | Select-Object -First 1).IP
        return [pscustomobject]@{ Ip = $a.IP; LocalIp = $local; Method = 'ARP'; Count = $arp.Count; Text = "ARP 表（MAC $($a.Mac)，$($a.State)）"; Serial = ''; Model = ''; Version = ''; All = $arp }
    }
    return $null
}

# 相機 IP 對應到哪一個本機 IP（同網段優先）
function Get-LocalIpForCamera([string]$Guid, [string]$CameraIp) {
    $ips = @(Get-AdapterIPv4 $Guid)
    foreach ($l in $ips) { if (Test-SameSubnet $CameraIp $l.IP $l.Prefix) { return $l.IP } }
    if ($ips.Count) { return $ips[0].IP }
    return $null
}

function Get-CamDataDir {
    $d = Join-Path $script:AppDir 'CamNetToolData'
    if (-not (Test-DirWritable $d)) { $d = Join-Path (Get-FallbackDir) 'CamNetToolData' }
    return $d
}

# 讀 XML URL → 有快取就用快取，沒有就從相機下載（zip 會解壓）
function Get-CameraXml($Client) {
    $url = $Client.ReadString(0x0200, 512)
    if (-not $url) { throw '讀取 XML URL（0x0200）失敗' }
    $m = [regex]::Match($url, '(?i)local:(?:///)?([^;]+);(?:0x)?([0-9a-f]+);(?:0x)?([0-9a-f]+)')
    if (-not $m.Success) { throw "XML 不在相機內（$url），目前不支援" }
    $fname = [IO.Path]::GetFileName($m.Groups[1].Value)
    $addr = [Convert]::ToUInt32($m.Groups[2].Value, 16)
    $len = [Convert]::ToInt32($m.Groups[3].Value, 16)
    $dir = Join-Path (Get-CamDataDir) 'xml'
    $raw = Join-Path $dir $fname
    if ($raw.Length -ge 250) {      # 超過 Windows 路徑長度限制（260）：改存到 %LOCALAPPDATA%
        $dir = Join-Path (Get-FallbackDir) 'xml'
        $raw = Join-Path $dir $fname
    }
    if (-not (Test-Path -LiteralPath $dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $fromCache = $true
    if (-not (Test-Path -LiteralPath $raw) -or (Get-Item -LiteralPath $raw).Length -ne $len) {
        $bytes = $Client.ReadBlock($addr, $len)
        [IO.File]::WriteAllBytes($raw, $bytes)
        $fromCache = $false
    }
    $text = $null
    if ($fname -match '\.zip$') {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($raw)
        try {
            $entry = $z.Entries | Where-Object { $_.Name -match '\.xml$' } | Select-Object -First 1
            if (-not $entry) { throw "XML zip 裡沒有 .xml：$fname" }
            $sr = New-Object IO.StreamReader($entry.Open())
            try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $z.Dispose() }
    } else {
        $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($raw))
    }
    return [pscustomobject]@{ Url = $url; FileName = $fname; Path = $raw; Text = $text; FromCache = $fromCache }
}

# 建立相機連線狀態：版本字串、XML、feature → 暫存器
function Connect-Camera([string]$LocalIp, [string]$CameraIp, [int]$TimeoutMs = 300) {
    $c = New-Object GvcpClient($LocalIp, $CameraIp)
    $c.TimeoutMs = $TimeoutMs; $c.Retries = 3
    $cam = @{
        Client = $c; LocalIp = $LocalIp; Ip = $CameraIp
        Model = ''; Serial = ''; Version = ''; Vendor = ''
        Xml = $null; XmlFile = ''; XmlError = ''; GenApi = $null
        Features = @{}; Missing = @(); FormulaWarnings = @(); ReadAddrs = @()
    }
    try {
        $cam.Vendor = [string]$c.ReadString(0x0048, 32)
        $cam.Model = [string]$c.ReadString(0x0068, 32)
        $cam.Version = [string]$c.ReadString(0x0088, 32)
        $cam.Serial = [string]$c.ReadString(0x00D8, 16)
    } catch { }
    try {
        $x = Get-CameraXml $c
        $cam.Xml = $x; $cam.XmlFile = $x.FileName
        $cam.GenApi = [GenApiModel]::Load($x.Text)
    } catch { $cam.XmlError = $_.Exception.Message }
    $addrs = New-Object 'System.Collections.Generic.List[uint32]'
    foreach ($a in $script:CamBootstrap.Values) { $addrs.Add([uint32]$a) }
    if ($cam.GenApi) {
        foreach ($k in $script:CamFeatureMap.Keys) {
            $name = $script:CamFeatureMap[$k]
            $fi = $cam.GenApi.Resolve($name)
            if (-not $fi.Found -or $fi.Error) { $cam.Missing += $(if ($fi.Error) { $fi.Error } else { "XML 沒有 $name" }); if (-not $fi.Found) { continue } }
            $cam.Features[$k] = $fi
            foreach ($r in $fi.Registers) {
                if ($r.AccessMode -eq 'WO') { continue }
                if (-not $addrs.Contains([uint32]$r.Address)) { $addrs.Add([uint32]$r.Address) }
                if ($r.Length -eq 8 -and -not $addrs.Contains([uint32]($r.Address + 4))) { $addrs.Add([uint32]($r.Address + 4)) }
            }
        }
        foreach ($n in $script:CamExpectedFormulas.Keys) {
            $fi = $cam.GenApi.Resolve($n)
            if (-not $fi.Found) { continue }
            $got = ($fi.Formulas | ForEach-Object { [GenFormula]::Normalize(($_ -replace '^[^:]+:\s*', '')) }) -join ';'
            if ($got -ne $script:CamExpectedFormulas[$n]) {
                $cam.FormulaWarnings += "$n 的公式是「$got」，與已知的「$($script:CamExpectedFormulas[$n])」不同，請確認（以 XML 的公式計算）"
            }
        }
    }
    $cam.ReadAddrs = $addrs.ToArray()
    return $cam
}

function Disconnect-Camera {
    if ($script:Cam -and $script:Cam.Client) { try { $script:Cam.Client.Dispose() } catch { } }
    $script:Cam = $null
}

# 讀一次所有暫存器並換算。回傳 @{ Status = Ok/NoResponse/Denied/Error; V = feature 值; T = 文字; Boot = bootstrap; Ms }
function Read-CameraSample {
    $cam = $script:Cam
    $smp = @{ Status = 'Error'; V = @{}; T = @{}; Boot = @{}; Ms = $null; Note = ''; Errors = @() }
    if (-not $cam) { $smp.Note = '尚未連線'; return $smp }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $res = $cam.Client.ReadRegs([uint32[]]$cam.ReadAddrs)
    $sw.Stop()
    $smp.Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    $regs = New-Object 'System.Collections.Generic.Dictionary[uint64,uint32]'
    $noResp = 0; $denied = 0; $ok = 0
    for ($i = 0; $i -lt $res.Length; $i++) {
        if ($res[$i].Ok) { $regs[[uint64]$cam.ReadAddrs[$i]] = $res[$i].Value; $ok++ }
        elseif ($res[$i].Status -eq -1) { $noResp++ }
        elseif ($res[$i].Status -eq 0x8006) { $denied++ }
    }
    if ($ok -eq 0) {
        $smp.Status = if ($denied -gt 0) { 'Denied' } elseif ($noResp -gt 0) { 'NoResponse' } else { 'Error' }
        return $smp
    }
    $smp.Status = 'Ok'
    foreach ($k in $script:CamBootstrap.Keys) {
        $a = [uint64]$script:CamBootstrap[$k]
        if ($regs.ContainsKey($a)) { $smp.Boot[$k] = [uint32]$regs[$a] }
    }
    foreach ($k in $cam.Features.Keys) {
        $r = $cam.GenApi.Evaluate($script:CamFeatureMap[$k], $regs)
        if ($r.Ok) { $smp.V[$k] = $r.Value; $smp.T[$k] = $r.Text } else { $smp.Errors += "$k：$($r.Error)" }
    }
    $smp.Regs = $regs
    return $smp
}

function New-CameraState {
    return @{
        Prev = $null; PrevStatus = $null; StallRun = 0; Stalled = $false
        CntStall = 0; CntNoResp = 0; CntReboot = 0; CntLinkReset = 0
        SumResend = 0L; SumUnavail = 0L; TempWarned = $false
        NoRespRun = 0; LastRediscover = [datetime]::MinValue
        LastState = ''; LastText = ''; LastColor = 'Gray'; Last = $null; LimitWarned = $false
        MaxTempC = $null
    }
}

# 相機目前狀態的文字與顏色（給畫面與 CSV）
function Get-CameraStateText($Smp, $C, $Derived) {
    switch ($Smp.Status) {
        'NoResponse' { return @{ State = 'NoResponse'; Text = '● 相機無回應'; Color = 'Red' } }
        'Denied' { return @{ State = 'Denied'; Text = '● 相機被其他程式獨占，無法讀取狀態'; Color = 'Orange' } }
        'Error' { return @{ State = 'Error'; Text = '● 相機讀取錯誤'; Color = 'Orange' } }
    }
    if ($C.Stalled) { return @{ State = 'Stalled'; Text = '● 相機卡住（自認在傳送，但沒有影像進來）'; Color = 'Red' } }
    if ($Derived.StallSuspect) { return @{ State = 'Watching'; Text = ('● 沒有影像進來（觀察中 {0}/{1}）' -f $C.StallRun, $script:Cfg.StallSamples); Color = 'Orange' } }
    if ($Derived.Streaming -and $Derived.DataFlowing) {
        $t = '● 正常送影像'
        if ($null -ne $Derived.EstFps) { $t += ('  約 {0:0.0} fps' -f $Derived.EstFps) }
        if ($null -ne $Derived.AcqFps) { $t += ('（設定 {0:0.##} fps）' -f $Derived.AcqFps) }
        return @{ State = 'Streaming'; Text = $t; Color = 'Green' }
    }
    if ($Derived.Streaming -and $Derived.TriggerOn) { return @{ State = 'WaitTrigger'; Text = '● 等待觸發（TriggerMode = On）'; Color = 'Gray' } }
    if (-not $Derived.HasCtrl) { return @{ State = 'Idle'; Text = '● 未取像（沒有程式控制相機）'; Color = 'Gray' } }
    return @{ State = 'Idle'; Text = '● 未取像'; Color = 'Gray' }
}

# 處理一次相機取樣：事件、計數、CSV
function Invoke-CameraProcess($Smp, [datetime]$Now, $RxMBps) {
    $S = $script:S; $C = $S.Cam; $cfg = $script:Cfg
    $cam = $script:Cam
    $src = 'Camera'
    $ipText = if ($cam) { $cam.Ip } else { '' }

    # --- 無回應 / 恢復 ---
    if ($Smp.Status -eq 'NoResponse') {
        $C.NoRespRun++
        if ($C.PrevStatus -ne 'NoResponse') {
            $C.CntNoResp++
            Add-MonitorEvent -Time $Now -Source $src -EventId 102 -Severity Error -Message "相機 $ipText 對 GVCP 讀取沒有回應（重試 3 次）。可能是相機韌體卡死、斷電或網路不通"
        }
    } elseif ($C.PrevStatus -eq 'NoResponse') {
        Add-MonitorEvent -Time $Now -Source $src -EventId 103 -Severity Info -Message "相機恢復回應（$ipText）"
    }
    if ($Smp.Status -ne 'NoResponse') { $C.NoRespRun = 0 }
    if ($Smp.Status -eq 'Denied' -and $C.PrevStatus -ne 'Denied') {
        Add-MonitorEvent -Time $Now -Source $src -EventId 116 -Severity Warning -Message '相機回應 ACCESS_DENIED：有程式以獨占模式控制相機，無法讀取狀態'
    }

    $v = $Smp.V; $b = $Smp.Boot
    $d = @{ HasCtrl = $false; Streaming = $false; DataFlowing = $false; StallSuspect = $false; TriggerOn = $false; EstFps = $null; AcqFps = $null; DRs = $null; DUn = $null; Ctrl = '' }
    if ($Smp.Status -eq 'Ok') {
        $p = $C.Prev
        if ($b.ContainsKey('CCP')) {
            $d.HasCtrl = (($b.CCP -band 3) -ne 0)
            $d.Ctrl = if ($d.HasCtrl -and $b.ContainsKey('PrimIP')) { '{0}:{1}' -f (ConvertTo-IPv4String $b.PrimIP), ($b.PrimPort -band 0xFFFF) } else { '無' }
        }
        $d.Streaming = ($Smp.T.XferSel -eq 'Streaming' -and $v.XferStat -eq 1)
        $d.TriggerOn = ($Smp.T.TrigMode -eq 'On')
        if ($v.AcqFT -gt 0) { $d.AcqFps = [math]::Round(1e6 / $v.AcqFT, 3) }
        if ($null -ne $RxMBps -and $v.Payload -gt 0) { $d.EstFps = [math]::Round($RxMBps * 1e6 / $v.Payload, 2) }
        # 有沒有影像進來：以相機網卡的接收流量判斷（相機直連，流量就是影像）。
        # 注意：這台相機韌體的 TransmissionFrameTime 在正常送影像時也是 0，不能單獨拿來判斷。
        if ($null -ne $RxMBps) {
            $expect = if ($v.Payload -gt 0 -and $d.AcqFps) { $v.Payload * $d.AcqFps / 1e6 } else { 0 }
            $d.DataFlowing = ($RxMBps -ge [math]::Max(1.0, $expect * 0.05))
        } else {
            $d.DataFlowing = ($v.TxFT -gt 0) -or ($v.QCur -eq 0)
        }
        $d.StallSuspect = $d.HasCtrl -and $d.Streaming -and -not $d.DataFlowing -and -not $d.TriggerOn

        if ($p) {
            if ($p.V.ContainsKey('UpTime') -and $v.ContainsKey('UpTime') -and $v.UpTime -lt $p.V.UpTime) {
                $C.CntReboot++
                Add-MonitorEvent -Time $Now -Source $src -EventId 104 -Severity Warning -Message ("相機曾經重新開機（開機時間 {0:N0} → {1:N0} 秒）" -f $p.V.UpTime, $v.UpTime)
            } elseif ($p.V.ContainsKey('LinkUp') -and $v.ContainsKey('LinkUp') -and $v.LinkUp -lt $p.V.LinkUp) {
                $C.CntLinkReset++
                Add-MonitorEvent -Time $Now -Source $src -EventId 105 -Severity Warning -Message ("相機端網路連線曾經重置（連線時間 {0:N0} → {1:N0} 秒）" -f $p.V.LinkUp, $v.LinkUp)
            }
            if ($p.Boot.ContainsKey('CCP') -and $b.ContainsKey('CCP') -and $p.Boot.CCP -ne $b.CCP) {
                if ($d.HasCtrl) { Add-MonitorEvent -Time $Now -Source $src -EventId 106 -Severity Info -Message ("控制權取得：{0}（CCP 0x{1:X} → 0x{2:X}）" -f $d.Ctrl, $p.Boot.CCP, $b.CCP) }
                else { Add-MonitorEvent -Time $Now -Source $src -EventId 106 -Severity Warning -Message ("控制權釋放：目前沒有程式控制相機（CCP 0x{0:X} → 0）" -f $p.Boot.CCP) }
            }
            if ($p.V.ContainsKey('RsRecv') -and $v.ContainsKey('RsRecv')) {
                $x = [long]$v.RsRecv - [long]$p.V.RsRecv
                if ($x -lt 0) { $x = [long]$v.RsRecv }      # 計數器歸零（相機重開或重新開始取像）
                $d.DRs = $x; $C.SumResend += $x
                if ($x -ge [int]$cfg.ResendWarn) { Add-MonitorEvent -Time $Now -Source $src -EventId 107 -Severity Warning -Message ("重送暴增：這次取樣期間相機收到 {0:N0} 次重送要求（門檻 {1}）" -f $x, $cfg.ResendWarn) }
            }
            if ($p.V.ContainsKey('RsUnavail') -and $v.ContainsKey('RsUnavail')) {
                $x = [long]$v.RsUnavail - [long]$p.V.RsUnavail
                if ($x -lt 0) { $x = [long]$v.RsUnavail }
                $d.DUn = $x; $C.SumUnavail += $x
                if ($x -gt 0) { Add-MonitorEvent -Time $Now -Source $src -EventId 108 -Severity Warning -Message ("無法重送：{0:N0} 個封包已無法重送（電腦端會缺封包或整張影像）" -f $x) }
            }
        }
        if ($v.ContainsKey('Temp')) {
            if ($null -eq $C.MaxTempC -or $v.Temp -gt $C.MaxTempC) { $C.MaxTempC = [math]::Round($v.Temp, 2) }
            if (-not $C.TempWarned -and $v.Temp -ge [double]$cfg.CamTempWarnC) {
                $C.TempWarned = $true
                Add-MonitorEvent -Time $Now -Source $src -EventId 109 -Severity Warning -Message ("相機溫度 {0:0.0} °C，超過警告值 {1} °C" -f $v.Temp, $cfg.CamTempWarnC)
            } elseif ($C.TempWarned -and $v.Temp -lt ([double]$cfg.CamTempWarnC - 2)) { $C.TempWarned = $false }
        }
        # 卡住：連續 N 次
        if ($d.StallSuspect) { $C.StallRun++ } else { $C.StallRun = 0 }
        if (-not $C.Stalled -and $C.StallRun -ge [int]$cfg.StallSamples) {
            $C.Stalled = $true; $C.CntStall++
            Add-MonitorEvent -Time $Now -Source $src -EventId 100 -Severity Error -Message ("相機卡住：有程式控制（{0}）、相機自認正在傳送（Streaming），但連續 {1} 次沒有影像進來（網卡接收 {2} MB/s，相機內佇列 {3}/{4}，TransmissionFrameTime {5}）" -f $d.Ctrl, $C.StallRun, $RxMBps, $v.QCur, $v.QMax, $v.TxFT)
        } elseif ($C.Stalled -and -not $d.StallSuspect) {
            $C.Stalled = $false
            $how = if ($d.DataFlowing) { "恢復送影像（網卡接收 $RxMBps MB/s）" } elseif (-not $d.Streaming) { '已停止傳送（Streaming = 0）' } else { '控制權已釋放' }
            Add-MonitorEvent -Time $Now -Source $src -EventId 101 -Severity Info -Message "相機卡住狀態結束：$how"
        }
        # 頻寬限制：取像中讀到 Off
        if ($d.Streaming -and $Smp.T.TLMode -eq 'Off' -and $cfg.ThroughputLimitApplied -and -not $C.LimitWarned) {
            $C.LimitWarned = $true
            Add-MonitorEvent -Time $Now -Source $src -EventId 112 -Severity Warning -Message '頻寬限制未生效：取像中讀到 DeviceLinkThroughputLimitMode = Off（可能被取像程式覆寫）' -NoAlarm
        }
        $C.Prev = @{ V = $v.Clone(); Boot = $b.Clone() }
    }
    $C.PrevStatus = $Smp.Status

    $st = Get-CameraStateText $Smp $C $d
    $C.LastState = $st.State; $C.LastText = $st.Text; $C.LastColor = $st.Color
    $C.Last = @{ Smp = $Smp; D = $d; Time = $Now; RxMBps = $RxMBps }

    # --- CSV（欄位固定；讀不到的留空）---
    $f = { param($k) if ($Smp.Status -eq 'Ok' -and $v.ContainsKey($k)) { $v[$k] } else { $null } }
    $ft = { param($k) if ($Smp.Status -eq 'Ok' -and $Smp.T.ContainsKey($k)) { $Smp.T[$k] } else { $null } }
    $gv = switch ($Smp.Status) { 'Ok' { 'OK' } 'NoResponse' { 'NoResponse' } 'Denied' { 'AccessDenied' } default { 'Error' } }
    $temp = & $f 'Temp'; if ($null -ne $temp) { $temp = [math]::Round($temp, 2) }
    $pw = & $f 'Power'; if ($null -ne $pw) { $pw = [math]::Round($pw, 2) }
    $ccp = if ($b.ContainsKey('CCP')) { '0x{0:X}' -f $b.CCP } else { $null }
    $scp = if ($b.ContainsKey('SCP0')) { $b.SCP0 -band 0xFFFF } else { $null }
    $scpd = if ($b.ContainsKey('SCPD0')) { $b.SCPD0 } else { $null }
    $line = Join-CsvLine @(
        $Now.ToString('yyyy-MM-dd HH:mm:ss'), $gv, $Smp.Ms, $ipText, $temp, $pw, (& $f 'UpTime'), (& $f 'LinkUp'),
        $d.AcqFps, (& $f 'TxFT'), $d.EstFps, $RxMBps, (& $ft 'TrigMode'), (& $ft 'XferSel'), $(if ($Smp.Status -eq 'Ok') { [int]$d.Streaming } else { $null }),
        (& $f 'QCur'), (& $f 'QMax'), (& $f 'RsRecv'), $d.DRs, (& $f 'RsValid'), (& $f 'RsUnavail'), $d.DUn,
        (& $ft 'TLMode'), (& $f 'TL'), (& $f 'TLRes'), $ccp, $(if ($Smp.Status -eq 'Ok') { $d.Ctrl } else { $null }), $scp, $scpd, $st.State)
    Add-LogLine 'camstatus' $Now $line
}

# 監控開始時連線相機（自動找 IP、下載 XML），並記錄版本與 XML 事件
function Start-CameraMonitoring {
    $S = $script:S; $cfg = $script:Cfg
    if (-not $S.Cam) { $S.Cam = New-CameraState }     # 重新連線時沿用原本的計數
    Disconnect-Camera
    $ip = $S.CameraIp
    $auto = $null
    if ($cfg.CameraIpAuto -or -not $ip) {
        $auto = Find-CameraIpAuto $S.Guid $cfg.CameraSerial
        if ($auto) {
            if ($ip -and $ip -ne $auto.Ip) {
                Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 111 -Severity Warning -Message "相機 IP 改變：$ip → $($auto.Ip)（$($auto.Method)：$($auto.Text)）" -NoAlarm
            }
            $ip = $auto.Ip
            $S.CameraIp = $ip; $cfg.CameraIp = $ip
        }
    }
    if (-not $ip) { $S.CamNote = '找不到相機（Discovery 與 ARP 都沒有結果）'; return $false }
    $local = Get-LocalIpForCamera $S.Guid $ip
    if (-not $local) { $S.CamNote = '相機網卡沒有 IPv4 位址'; return $false }
    try { $script:Cam = Connect-Camera $local $ip }
    catch { $S.CamNote = "無法連線相機：$($_.Exception.Message)"; return $false }
    $cam = $script:Cam
    $how = if ($auto) { "自動偵測（$($auto.Method)）" } else { '手動輸入' }
    $verText = if ($cam.Model) { "$($cam.Vendor) $($cam.Model)，序號 $($cam.Serial)，韌體 $($cam.Version)" } else { '（讀不到型號，相機可能沒有回應）' }
    Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 114 -Severity Info -Message "相機：$ip（$how），本機 $local；$verText；XML $($cam.XmlFile)"
    if ($cam.Serial) { $cfg.CameraSerial = $cam.Serial }
    if ($cam.XmlError) {
        Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 110 -Severity Warning -Message "無法取得相機 XML：$($cam.XmlError)。只能讀取標準暫存器（CCP、串流通道）" -NoAlarm
    } elseif ($cfg.CameraXmlFile -and $cfg.CameraXmlFile -ne $cam.XmlFile) {
        Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 110 -Severity Warning -Message "相機 XML 與上次不同（$($cfg.CameraXmlFile) → $($cam.XmlFile)），可能更新過韌體；已重新解析暫存器位址" -NoAlarm
    }
    if ($cam.XmlFile) { $cfg.CameraXmlFile = $cam.XmlFile }
    foreach ($w in $cam.FormulaWarnings) { Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 113 -Severity Warning -Message "公式改變，請確認：$w" -NoAlarm }
    if ($cam.Missing.Count) { Add-MonitorEvent -Time (Get-Date) -Source 'Camera' -EventId 115 -Severity Info -Message ('XML 中無法使用的項目：' + ($cam.Missing -join '；')) }
    $S.CamNote = ''
    return $true
}

# 每個週期：讀相機；連續沒回應時，自動模式下每分鐘重新偵測一次 IP（相機重開機後 LLA 位址可能改變）
function Invoke-CameraTick([datetime]$Now, $RxMBps) {
    $S = $script:S
    if (-not $S.Cam) { return }
    if (-not $script:Cam) {
        if (($Now - $S.Cam.LastRediscover).TotalSeconds -ge 60) {
            $S.Cam.LastRediscover = $Now
            [void](Start-CameraMonitoring)
        }
        if (-not $script:Cam) { return }
    }
    $smp = Read-CameraSample
    Invoke-CameraProcess $smp $Now $RxMBps
    if ($smp.Status -eq 'NoResponse' -and $script:Cfg.CameraIpAuto -and $S.Cam.NoRespRun -ge 3 -and ($Now - $S.Cam.LastRediscover).TotalSeconds -ge 60) {
        $S.Cam.LastRediscover = $Now
        $found = Find-CameraIpAuto $S.Guid $script:Cfg.CameraSerial
        if ($found -and $found.Ip -ne $script:Cam.Ip) {
            Add-MonitorEvent -Time $Now -Source 'Camera' -EventId 111 -Severity Warning -Message "相機 IP 改變：$($script:Cam.Ip) → $($found.Ip)（$($found.Text)），改用新位址" -NoAlarm
            $S.CameraIp = $found.Ip; $script:Cfg.CameraIp = $found.Ip
            $keep = $S.Cam
            Disconnect-Camera
            try { $script:Cam = Connect-Camera (Get-LocalIpForCamera $S.Guid $found.Ip) $found.Ip } catch { }
            $S.Cam = $keep
            Save-Config
        }
    }
}
