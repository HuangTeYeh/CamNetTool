#Requires -Version 5.1
<#
    CamNetTool -「最佳化設定」
    * 每個寫入動作：手動按鈕 → 確認視窗 → 寫入 → 讀回驗證 → 記錄事件（修改前、修改後、時間、執行者）
    * 修改前的值存在 CamNetToolData\backup\backup_*.json，可以「復原」
    * 相機寫入的前提：CCP = 0，而且沒有取像程式在執行。流程：CCP=2 取得控制 → 每秒 heartbeat → WRITEREG
      → 讀回驗證 → CCP=0 釋放（中途失敗也一定釋放）
#>

$script:NicClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$script:GigEFilterPattern = '(?i)GigE|Lucid|Arena|National Instruments|\bNI\b|IMAQ|SENTECH|Pylon|Basler|Teledyne|Dalsa|Spinnaker|FLIR|Matrox|Euresys|Allied'

function Get-ExecutorText { return "$env:USERDOMAIN\$env:USERNAME" }

function Get-BackupDir {
    $d = Join-Path (Get-CamDataDir) 'backup'
    if (-not (Test-Path -LiteralPath $d)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    return $d
}

function Save-OptimizeBackup([string]$Id, [string]$Item, $Before, $After) {
    $now = Get-Date
    $o = [ordered]@{ Id = $Id; Item = $Item; Time = $now.ToString('yyyy-MM-dd HH:mm:ss'); User = (Get-ExecutorText); Machine = $env:COMPUTERNAME; Before = $Before; After = $After; Restored = '' }
    $safe = ($Id -replace '[^\w\-]', '_')
    $p = Join-Path (Get-BackupDir) ('backup_{0}_{1}.json' -f $now.ToString('yyyyMMdd_HHmmss'), $safe)
    [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($true)))
    return $p
}

# 某個項目最新一筆還沒復原的備份
function Get-LatestBackup([string]$Id) {
    $safe = ($Id -replace '[^\w\-]', '_')
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-BackupDir) -Filter "backup_*_$safe.json" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        try {
            $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            if (-not $j.Restored) { return [pscustomobject]@{ Path = $f.FullName; Data = $j } }
        } catch { }
    }
    return $null
}

function Set-BackupRestored([string]$Path) {
    $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $j.Restored = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [IO.File]::WriteAllText($Path, ($j | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($true)))
}

function Get-AllBackups {
    return @(Get-ChildItem -LiteralPath (Get-BackupDir) -Filter 'backup_*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json; [pscustomobject]@{ Path = $_.FullName; Data = $j } } catch { } })
}

# ---------------------------------------------------------------------------
#  網卡設定讀取
# ---------------------------------------------------------------------------
function Get-NetAdapterByGuid([string]$Guid) {
    return (Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $Guid } | Select-Object -First 1)
}

function Get-NicClassKeyPath([string]$Guid) {
    foreach ($k in @(Get-ChildItem -LiteralPath $script:NicClassKey -ErrorAction SilentlyContinue)) {
        try { if ((Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop).NetCfgInstanceId -eq $Guid) { return $k.PSPath } } catch { }
    }
    return $null
}

function Get-AdvProp($Adv, [string[]]$Keywords) {
    foreach ($k in $Keywords) { $p = $Adv | Where-Object { $_.RegistryKeyword -eq $k } | Select-Object -First 1; if ($p) { return $p } }
    return $null
}

function Get-AdvMax($Prop) {
    if ($null -ne $Prop.NumericParameterMaxValue -and [string]$Prop.NumericParameterMaxValue -ne '') { return [long]$Prop.NumericParameterMaxValue }
    $vals = @($Prop.ValidRegistryValues | ForEach-Object { try { [long]$_ } catch { } })
    if ($vals.Count) { return ($vals | Measure-Object -Maximum).Maximum }
    return $null
}

function Get-AspmValues {
    $out = (powercfg /q SCHEME_CURRENT SUB_PCIEXPRESS ASPM) 2>&1 | Out-String
    $ac = [regex]::Match($out, '(?im)^\s*(?:目前的\s*)?(?:Current\s*)?AC.*?:\s*(0x[0-9a-f]+)')
    $dc = [regex]::Match($out, '(?im)^\s*(?:目前的\s*)?(?:Current\s*)?DC.*?:\s*(0x[0-9a-f]+)')
    $r = @{ AC = $null; DC = $null }
    if ($ac.Success) { $r.AC = [Convert]::ToInt32($ac.Groups[1].Value, 16) }
    if ($dc.Success) { $r.DC = [Convert]::ToInt32($dc.Groups[1].Value, 16) }
    return $r
}

function Get-AspmText($v) { switch ($v) { 0 { '關閉' } 1 { '中度省電' } 2 { '最大省電' } $null { '讀不到' } default { "未知($v)" } } }

# 網卡電源管理：「允許電腦關閉這個裝置以節省電源」。cmdlet 失敗時改讀登錄檔 PnPCapabilities（24 = 不允許）
function Get-NicPowerMgmt([string]$Guid, [string]$Name) {
    try {
        $pm = Get-NetAdapterPowerManagement -Name $Name -ErrorAction Stop
        return @{ Allowed = ([string]$pm.AllowComputerToTurnOffDevice -ne 'Disabled'); Source = 'cmdlet'; Text = [string]$pm.AllowComputerToTurnOffDevice }
    } catch { }
    $kp = Get-NicClassKeyPath $Guid
    if ($kp) {
        $v = (Get-ItemProperty -LiteralPath $kp -ErrorAction SilentlyContinue).PnPCapabilities
        if ($null -eq $v) { return @{ Allowed = $true; Source = 'registry'; Text = '允許（PnPCapabilities 未設定）'; KeyPath = $kp; Raw = $null } }
        $allowed = (([int]$v -band 0x18) -ne 0x18)
        return @{ Allowed = $allowed; Source = 'registry'; Text = $(if ($allowed) { "允許（PnPCapabilities=$v）" } else { "不允許（PnPCapabilities=$v）" }); KeyPath = $kp; Raw = $v }
    }
    return @{ Allowed = $null; Source = ''; Text = '讀不到' }
}

function Get-GigEBindings([string]$Name) {
    return @(Get-NetAdapterBinding -Name $Name -AllBindings -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $script:GigEFilterPattern -or $_.ComponentID -match $script:GigEFilterPattern })
}

function Get-BindingVendor($B) {
    $t = "$($B.DisplayName) $($B.ComponentID)"
    if ($t -match '(?i)National Instruments|\bNI\b|IMAQ|^ni_') { return 'NI' }
    if ($t -match '(?i)Lucid|Arena') { return 'Arena' }
    return 'Other'
}

# 相機網卡上「不是 GigE Vision、也不是 Windows 內建」的綁定元件分類。
# 回傳 $null = Windows 內建（ms_*，例如 TCP/IP、QoS、WFP 篩選器，不處理）；'GigE' = 由 GigE 過濾驅動那一項處理；其他 = 類別文字。
$script:NonGigEPatterns = [ordered]@{
    '虛擬機'    = '(?i)VirtualBox|VBox|VMware|vmnet|vmware_bridge|Hyper-V|\bvms_pp\b|Parallels|Docker|QEMU|KVM'
    'VPN'       = '(?i)VPN|AnyConnect|acsock|Cisco|Fortinet|FortiClient|GlobalProtect|PanGP|Juniper|Pulse Secure|Ivanti|WireGuard|OpenVPN|TAP-Windows|ZeroTier|Tailscale|SoftEther|Check Point|SonicWall|WatchGuard|NetExtender|Zscaler'
    '防火牆／防毒' = '(?i)Firewall|防火牆|Kaspersky|klim|ESET|epfw|Symantec|Norton|McAfee|Sophos|Trend ?Micro|Bitdefender|Avast|AVG|Comodo|ZoneAlarm|Panda|F-Secure|Webroot|CrowdStrike|SentinelOne|Carbon Black|Cylance|Deep Security'
    '封包擷取'  = '(?i)Npcap|WinPcap|\bnpf\b|npcap|Network Monitor|nm3|Wireshark|Packet Driver'
}

function Get-BindingCategory($B) {
    $cid = [string]$B.ComponentID
    $t = "$($B.DisplayName) $cid"
    if ($cid -match '(?i)^ms_') { return $null }
    if ($t -match $script:GigEFilterPattern) { return 'GigE' }
    foreach ($k in $script:NonGigEPatterns.Keys) { if ($t -match $script:NonGigEPatterns[$k]) { return $k } }
    return '其他第三方'
}

function Get-NonGigEBindings([string]$Name) {
    $out = @()
    foreach ($b in @(Get-NetAdapterBinding -Name $Name -AllBindings -ErrorAction SilentlyContinue)) {
        $cat = Get-BindingCategory $b
        if ($cat -and $cat -ne 'GigE') { $out += [pscustomobject]@{ DisplayName = [string]$b.DisplayName; ComponentID = [string]$b.ComponentID; Enabled = [bool]$b.Enabled; Category = $cat } }
    }
    return , $out
}

# Flow Control（只顯示）
function Get-FlowControlText($Prop) {
    if (-not $Prop) { return '驅動沒有這個設定' }
    $txt = [string]$Prop.DisplayValue
    $rv = [string]$Prop.RegistryValue[0]
    if ($Prop.RegistryKeyword -eq '*FlowControl') {
        $std = switch ($rv) { '0' { '關閉' } '1' { '只送 PAUSE' } '2' { '只收 PAUSE' } '3' { '收送都開' } '4' { '自動協商' } default { '' } }
        if ($std) { $txt += "（$std）" }
    }
    return $txt
}

# ---------------------------------------------------------------------------
#  相機讀取／寫入
# ---------------------------------------------------------------------------
# 取得可用的相機連線：監控中用現有連線，否則暫時連線（回傳 @{ Cam; Temp = 是否要自行關閉 }）
function Get-CameraForOptimize([string]$Guid) {
    if ($script:Cam -and $script:Cam.GenApi) { return @{ Cam = $script:Cam; Temp = $false } }
    $ip = if ($script:S -and $script:S.CameraIp) { $script:S.CameraIp } else { [string]$script:Cfg.CameraIp }
    if (-not $ip -and $Guid) { $f = Find-CameraIpAuto $Guid $script:Cfg.CameraSerial; if ($f) { $ip = $f.Ip } }
    if (-not $ip) { return $null }
    $local = Get-LocalIpForCamera $Guid $ip
    if (-not $local) { return $null }
    return @{ Cam = (Connect-Camera $local $ip 400); Temp = $true }
}

function Read-CameraFeatures($Cam, [string[]]$Names) {
    $addrs = New-Object 'System.Collections.Generic.List[uint32]'
    foreach ($n in $Names) {
        $fi = $Cam.GenApi.Resolve($n)
        foreach ($r in @($fi.Registers) + @($Cam.GenApi.LimitRegisters($n))) {
            if ($r.AccessMode -eq 'WO') { continue }
            if (-not $addrs.Contains([uint32]$r.Address)) { $addrs.Add([uint32]$r.Address) }
        }
    }
    foreach ($a in 0x0A00, 0x0A04, 0x0A14, 0x0938) { if (-not $addrs.Contains([uint32]$a)) { $addrs.Add([uint32]$a) } }
    $res = $Cam.Client.ReadRegs($addrs.ToArray())
    $regs = New-Object 'System.Collections.Generic.Dictionary[uint64,uint32]'
    for ($i = 0; $i -lt $addrs.Count; $i++) { if ($res[$i].Ok) { $regs[[uint64]$addrs[$i]] = $res[$i].Value } }
    $out = @{ Regs = $regs; V = @{}; T = @{}; Min = @{}; Max = @{}; Inc = @{} }
    foreach ($n in $Names) {
        $e = $Cam.GenApi.Evaluate($n, $regs)
        if ($e.Ok) { $out.V[$n] = $e.Value; $out.T[$n] = $e.Text }
        try { $out.Min[$n] = $Cam.GenApi.Limit($n, 'Min', $regs); $out.Max[$n] = $Cam.GenApi.Limit($n, 'Max', $regs); $out.Inc[$n] = $Cam.GenApi.Limit($n, 'Inc', $regs) } catch { }
    }
    if ($regs.ContainsKey([uint64]0x0A00)) { $out.CCP = [uint32]$regs[[uint64]0x0A00] }
    if ($regs.ContainsKey([uint64]0x0A14)) { $out.Controller = '{0}:{1}' -f (ConvertTo-IPv4String $regs[[uint64]0x0A14]), ($regs[[uint64]0x0A04] -band 0xFFFF) }
    if ($regs.ContainsKey([uint64]0x0938)) { $out.Heartbeat = [uint32]$regs[[uint64]0x0938] }
    return $out
}

# 相機能不能寫入：回傳 @{ Ok; Reason }
function Test-CameraWritable($Cam) {
    $acq = @(Get-AcquisitionProcesses | Where-Object { $_.Name -notmatch '(?i)ArenaView' })
    if ($acq.Count) { return @{ Ok = $false; Reason = ('偵測到取像程式在執行（{0}），請先關閉 LabVIEW 程式' -f (($acq | ForEach-Object { "$($_.Name) PID $($_.Id)" }) -join '、')) } }
    if (-not $Cam) { return @{ Ok = $false; Reason = '找不到相機' } }
    $r = $Cam.Client.ReadReg(0x0A00)
    if (-not $r.Ok) { return @{ Ok = $false; Reason = "讀不到相機控制權（$($r.Note)）" } }
    if (($r.Value -band 3) -ne 0) {
        $ip = $Cam.Client.ReadReg(0x0A14); $pt = $Cam.Client.ReadReg(0x0A04)
        $who = if ($ip.Ok) { '{0}:{1}' -f (ConvertTo-IPv4String $ip.Value), ($pt.Value -band 0xFFFF) } else { '?' }
        return @{ Ok = $false; Reason = ('相機正被其他程式控制（CCP 0x{0:X}，控制者 {1}），請先關閉 LabVIEW 程式' -f $r.Value, $who) }
    }
    return @{ Ok = $true; Reason = '' }
}

# 相機寫入工作階段：取得控制 → 執行 → 一定釋放。$Body 收到 $session（有 Write / Read / Heartbeat）
function Invoke-CameraWriteSession($Cam, [scriptblock]$Body) {
    $chk = Test-CameraWritable $Cam
    if (-not $chk.Ok) { throw $chk.Reason }
    $client = New-Object GvcpClient($Cam.LocalIp, $Cam.Ip)
    $client.TimeoutMs = 800; $client.Retries = 3
    $session = @{ Client = $client; Cam = $Cam; LastHb = [DateTime]::UtcNow; Log = New-Object System.Collections.Generic.List[string] }
    $wasTimer = $false
    if (Get-Variable -Name timer -Scope Script -ErrorAction SilentlyContinue) { $wasTimer = $script:timer.Enabled; $script:timer.Stop() }
    try {
        $r = $client.WriteReg(0x0A00, 2)
        if (-not $r.Ok) { throw "無法取得相機控制權（$($r.Note)）" }
        $session.Log.Add('取得控制權（CCP = 2）')
        & $Body $session
    } finally {
        $released = $false
        for ($i = 0; $i -lt 3 -and -not $released; $i++) { $rr = $client.WriteReg(0x0A00, 0); $released = $rr.Ok }
        $session.Log.Add($(if ($released) { '已釋放控制權（CCP = 0）' } else { '⚠ 釋放控制權失敗（heartbeat 逾時後相機會自動釋放）' }))
        $client.Dispose()
        if ($wasTimer) { $script:timer.Start() }
        $script:LastCameraSessionLog = $session.Log
    }
}

function Invoke-CamHeartbeat($Session) {
    if (([DateTime]::UtcNow - $Session.LastHb).TotalMilliseconds -ge 1000) {
        [void]$Session.Client.ReadReg(0x0A00)
        $Session.LastHb = [DateTime]::UtcNow
    }
}

# 寫入一個 feature（只支援直接對應到暫存器的 Integer / Enumeration / Boolean / Command），寫完讀回驗證
function Set-CameraFeature($Session, [string]$Name, $Value) {
    Invoke-CamHeartbeat $Session
    $fi = $Session.Cam.GenApi.Resolve($Name)
    if (-not $fi.Found) { throw "XML 中找不到 $Name" }
    $reg = $fi.DirectRegister
    if (-not $reg) { throw "$Name 不是直接對應到暫存器（$($fi.Error)），不支援寫入" }
    if ($reg.AccessMode -eq 'RO') { throw "$Name 是唯讀" }
    if ($reg.Length -ne 4) { throw "$Name 的暫存器長度 $($reg.Length) 目前不支援寫入" }
    $raw = $null
    switch ($fi.Type) {
        'Enumeration' {
            if ($Value -is [string]) { if (-not $fi.EnumValues.ContainsKey($Value)) { throw "$Name 沒有選項 $Value" }; $raw = [long]$fi.EnumValues[$Value] }
            else { $raw = [long]$Value }
        }
        'Command' { $raw = [long]$fi.CommandValue }
        default { $raw = [long]$Value }
    }
    $addr = [uint32]$reg.Address
    $full = [uint64]4294967295          # 注意：PowerShell 的 0xFFFFFFFF 是 int 的 -1，不能拿來當遮罩
    if ($raw -lt 0) { $raw = [long]([uint64]($raw + 4294967296)) }
    $word = [uint32]([uint64]$raw -band $full)
    if ($reg.Lsb -ge 0) {
        $cur = $Session.Client.ReadReg($addr)
        if (-not $cur.Ok) { throw "讀取 $Name 失敗（$($cur.Note)）" }
        $shift = if ($reg.BigEndian) { 31 - $reg.Lsb } else { $reg.Lsb }
        $width = if ($reg.BigEndian) { $reg.Lsb - $reg.Msb + 1 } else { $reg.Msb - $reg.Lsb + 1 }
        $mask = ((([uint64]1 -shl $width) - 1) -shl $shift) -band $full
        $word = [uint32]((([uint64]$cur.Value) -band ($full - $mask)) -bor ((([uint64]$raw) -shl $shift) -band $mask))
    }
    $w = $Session.Client.WriteReg($addr, $word)
    if (-not $w.Ok) { throw "寫入 $Name 失敗（$($w.Note)）" }
    $Session.Log.Add(('寫入 {0} = {1}（0x{2:X8} ← 0x{3:X8}）' -f $Name, $Value, $addr, $word))
    if ($fi.Type -eq 'Command' -or $reg.AccessMode -eq 'WO') { Start-Sleep -Milliseconds 300; return }
    $rb = $Session.Client.ReadReg($addr)
    if (-not $rb.Ok) { throw "讀回 $Name 失敗（$($rb.Note)）" }
    $regs = New-Object 'System.Collections.Generic.Dictionary[uint64,uint32]'
    $regs[[uint64]$addr] = $rb.Value
    $e = $Session.Cam.GenApi.Evaluate($Name, $regs)
    if (-not $e.Ok -or [long]$e.Raw -ne $raw) { throw "讀回驗證失敗：$Name 寫入 $Value，讀回 $($e.Text)" }
    $Session.Log.Add("讀回 $Name = $($e.Text)（正確）")
}

# 頻寬限制目標值：符合 XML 的 min / max / inc
function Get-ValidLimit([double]$Target, $Min, $Max, $Inc) {
    $v = $Target
    if ($null -ne $Max -and $v -gt $Max) { $v = $Max }
    if ($null -ne $Min -and $v -lt $Min) { $v = $Min }
    if ($null -ne $Inc -and $Inc -gt 1) { $base = if ($null -ne $Min) { $Min } else { 0 }; $v = $base + [math]::Floor(($v - $base) / $Inc) * $Inc }
    return [long]$v
}

# ---------------------------------------------------------------------------
#  檢查清單
# ---------------------------------------------------------------------------
# 相機突發速率：最近一次診斷快照的封包擷取實測值；沒有就用規格的 L5 實測值 494 MB/s
function Get-BurstRate {
    $p = Join-Path (Get-CamDataDir) 'last_capture.json'
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            if ([double]$j.MedianBurstMBps -gt 10) { return @{ MBps = [math]::Round([double]$j.MedianBurstMBps); Source = "$($j.Time) 封包擷取實測" } }
        } catch { }
    }
    return @{ MBps = 494; Source = '規格 L5 實測值，還沒有這台的封包擷取' }
}

# 最近 1 小時相機的重送次數（監控中的累計，或 camstatus 記錄）
function Get-RecentResends {
    try {
        $now = Get-Date
        $w = Get-WindowStats $now.AddHours(-1) $now
        if ($w.CamSamples -gt 0) { return @{ Resends = $w.Resends; Source = "camstatus 記錄 $($w.CamSamples) 筆" } }
    } catch { }
    if ($script:S -and $script:S.Cam) { return @{ Resends = $script:S.Cam.SumResend; Source = '本次監控' } }
    return @{ Resends = 0; Source = '沒有監控記錄' }
}

function New-Check([string]$Id, [string]$Item, $Current, $Recommended, [string]$State, [string]$Note = '') {
    return [pscustomobject]@{ Id = $Id; Item = $Item; Current = [string]$Current; Recommended = [string]$Recommended; State = $State; Note = $Note
        Kind = 'Nic'; CanFix = $false; FixReason = ''; NeedsAdmin = $false; Data = @{} }
}

function Get-OptimizeChecks([string]$Guid) {
    $list = New-Object System.Collections.Generic.List[object]
    $cfg = $script:Cfg
    $na = Get-NetAdapterByGuid $Guid
    $desired = $cfg.DesiredNicSettings
    if ($na) {
        $adv = @(Get-NetAdapterAdvancedProperty -Name $na.Name -AllProperties -ErrorAction SilentlyContinue)
        # 1 Receive Buffers（最優先）：封包是在網卡接收環就被丟掉（2026-11-23 封包擷取確認）
        $p = Get-AdvProp $adv @('*ReceiveBuffers')
        if ($p) {
            $max = Get-AdvMax $p
            $cur = [long]$p.RegistryValue[0]
            $burst = Get-BurstRate
            $ms = { param($n) [math]::Round($n * 9014 / ($burst.MBps * 1e6) * 1000, 1) }
            $curTxt = '{0}（約 {1} ms 緩衝）' -f $cur, (& $ms $cur)
            $recTxt = if ($max) { '{0}（驅動允許的最大值，約 {1} ms）' -f $max, (& $ms $max) } else { '最大值' }
            $c = New-Check 'nic.rxbuffers' '網卡 Receive Buffers（最優先）' $curTxt $recTxt $(if ($max -and $cur -ge $max) { 'OK' } else { 'Bad' })
            $c.CanFix = ($max -and $cur -lt $max); $c.NeedsAdmin = $true; $c.Data = @{ Keyword = '*ReceiveBuffers'; Value = $max; Old = $cur }
            $c.Note = "緩衝時間 = 數量 × 9 KB ÷ 相機突發速率（{0:N0} MB/s，{1}）。封包是在網卡接收環就被丟掉，這一項最優先" -f $burst.MBps, $burst.Source
            $list.Add($c)
        }
        # 2 Jumbo
        $p = Get-AdvProp $adv @('*JumboPacket')
        if ($p) { $cur = [long]$p.RegistryValue[0]; $list.Add((New-Check 'nic.jumbo' 'Jumbo Packet' $p.DisplayValue '9014 Bytes（維持）' $(if ($cur -ge 9014) { 'OK' } else { 'Bad' }) '只檢查')) }
        # 3 Interrupt Moderation
        $im = Get-AdvProp $adv @('*InterruptModeration'); $itr = Get-AdvProp $adv @('ITR', '*InterruptModerationRate')
        if ($im) {
            $txt = $im.DisplayValue + $(if ($itr) { " / $($itr.DisplayValue)" } else { '' })
            $ok = ([string]$im.RegistryValue[0] -eq '1')
            $list.Add((New-Check 'nic.intmod' 'Interrupt Moderation' $txt 'Enabled / Adaptive（維持）' $(if ($ok) { 'OK' } else { 'Warn' }) '只檢查'))
        }
        # 4 EEE
        $p = Get-AdvProp $adv @('*EEE', 'EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'GreenEthernet')
        if ($p) {
            $cur = [string]$p.RegistryValue[0]
            $c = New-Check 'nic.eee' "EEE / Green Ethernet（$($p.RegistryKeyword)）" $p.DisplayValue 'Disabled' $(if ($cur -eq '0') { 'OK' } else { 'Bad' })
            $c.CanFix = ($cur -ne '0'); $c.NeedsAdmin = $true; $c.Data = @{ Keyword = $p.RegistryKeyword; Value = 0; Old = $cur }
            $list.Add($c)
        }
        # Flow Control：先只顯示目前的值
        $fc = Get-AdvProp $adv @('*FlowControl', 'FlowControl')
        $c = New-Check 'nic.flowcontrol' 'Flow Control（流量控制）' (Get-FlowControlText $fc) '（先只顯示，不建議值）' 'Show'
        $c.Note = if ($fc) { "RegistryKeyword $($fc.RegistryKeyword) = $($fc.RegistryValue[0])；可選：$((@($fc.ValidDisplayValues)) -join ' / ')。只顯示目前的值，不提供修正" } else { '只顯示目前的值' }
        $list.Add($c)
        # 被驅動更新重設的設定
        foreach ($c in $list) {
            if ($c.Data.Keyword -and $desired -and $desired.ContainsKey($c.Data.Keyword) -and [string]$desired[$c.Data.Keyword] -ne [string]$c.Data.Old) {
                $c.State = 'Reset'; $c.Note = "之前套用過 $($desired[$c.Data.Keyword])，現在是 $($c.Data.Old)：可能被驅動更新重設，請再套用一次"
            }
        }
        # 5 電源管理
        $pm = Get-NicPowerMgmt $Guid $na.Name
        $c = New-Check 'nic.power' '網卡電源管理（允許電腦關閉此裝置）' $pm.Text '不允許' $(if ($null -eq $pm.Allowed) { 'Unknown' } elseif ($pm.Allowed) { 'Bad' } else { 'OK' })
        $c.CanFix = [bool]$pm.Allowed; $c.NeedsAdmin = $true; $c.Data = @{ Source = $pm.Source; KeyPath = $pm.KeyPath; Old = $pm.Raw }
        if ($pm.Source -eq 'registry') { $c.Note = '（Get-NetAdapterPowerManagement 在這台無法使用，改讀登錄檔）修正後需重新啟用網卡或重新開機才生效' }
        $list.Add($c)
        # 7 GigE 過濾驅動
        $soft = if ($cfg.AcquisitionSoftware -eq 'Arena') { 'Arena' } else { 'NI' }
        foreach ($b in (Get-GigEBindings $na.Name)) {
            $vendor = Get-BindingVendor $b
            $want = ($vendor -eq $soft)
            $c = New-Check ("bind.$($b.ComponentID)") "GigE 過濾驅動：$($b.DisplayName)" $(if ($b.Enabled) { '啟用' } else { '停用' }) $(if ($want) { '啟用（取像軟體需要）' } else { '停用' }) $(if ([bool]$b.Enabled -eq $want) { 'OK' } else { 'Bad' })
            $c.Kind = 'Binding'; $c.CanFix = ([bool]$b.Enabled -ne $want); $c.NeedsAdmin = $true
            $c.Data = @{ ComponentID = [string]$b.ComponentID; Want = $want; Old = [bool]$b.Enabled }
            $c.Note = "取像軟體設定為 $($cfg.AcquisitionSoftware)：相機網卡只保留它需要的過濾驅動（ComponentID $($b.ComponentID)）"
            $list.Add($c)
        }
        # 非 GigE Vision 的第三方驅動（VirtualBox、VMware、VPN、防火牆等）：建議在相機網卡上取消勾選
        $other = Get-NonGigEBindings $na.Name
        foreach ($b in $other) {
            $c = New-Check ("bind.$($b.ComponentID)") "非 GigE 驅動（$($b.Category)）：$($b.DisplayName)" $(if ($b.Enabled) { '啟用' } else { '停用' }) '停用（在相機網卡上取消勾選）' $(if ($b.Enabled) { 'Bad' } else { 'OK' })
            $c.Kind = 'Binding'; $c.CanFix = $b.Enabled; $c.NeedsAdmin = $true
            $c.Data = @{ ComponentID = $b.ComponentID; Want = $false; Old = $b.Enabled }
            $c.Note = "相機網卡只接相機，這個元件會經手每個影像封包，增加延遲與 CPU 負擔（ComponentID $($b.ComponentID)）。只會取消這張網卡上的勾選，該軟體在其他網卡照常運作"
            $list.Add($c)
        }
        if ($other.Count -eq 0) {
            $list.Add((New-Check 'nic.otherbind' '非 GigE 驅動（VirtualBox、VMware、VPN、防火牆等）' '沒有' '沒有' 'OK' '相機網卡上除了 Windows 內建元件與 GigE 過濾驅動，沒有其他第三方驅動'))
        }
    } else {
        $list.Add((New-Check 'nic' '相機網卡' '找不到' '—' 'Unknown'))
    }
    # 6 PCIe ASPM
    $a = Get-AspmValues
    $c = New-Check 'power.aspm' 'PCIe ASPM（目前電源計畫，插電）' ("{0}（電池：{1}）" -f (Get-AspmText $a.AC), (Get-AspmText $a.DC)) '關閉' $(if ($null -eq $a.AC) { 'Unknown' } elseif ($a.AC -eq 0) { 'OK' } else { 'Bad' })
    $c.Kind = 'Power'; $c.CanFix = ($null -ne $a.AC -and $a.AC -ne 0); $c.NeedsAdmin = $true; $c.Data = @{ AC = $a.AC; DC = $a.DC }
    $list.Add($c)

    # 8~10 相機
    $camInfo = $null
    try { $camInfo = Get-CameraForOptimize $Guid } catch { }
    if ($camInfo -and $camInfo.Cam.GenApi) {
        $cam = $camInfo.Cam
        try {
            $r = Read-CameraFeatures $cam @('DeviceLinkThroughputLimitMode', 'DeviceLinkThroughputLimit', 'DeviceLinkThroughputReserve', 'UserSetSelector', 'UserSetDefault', 'PayloadSize')
            $w = Test-CameraWritable $cam
            $target = [double]$cfg.ThroughputLimitTarget
            $lim = Get-ValidLimit $target $r.Min.DeviceLinkThroughputLimit $r.Max.DeviceLinkThroughputLimit $r.Inc.DeviceLinkThroughputLimit
            # 8 頻寬限制（次要）：Receive Buffers 調大後仍有重送才做
            $mode = $r.T.DeviceLinkThroughputLimitMode
            $burst = Get-BurstRate
            $curTxt = '{0}，{1:N0} MB/s（開機預設 {2}；實測突發約 {3:N0} MB/s）' -f $mode, ($r.V.DeviceLinkThroughputLimit / 1e6), $r.T.UserSetDefault, $burst.MBps
            $ok = ($mode -eq 'On' -and [math]::Abs($r.V.DeviceLinkThroughputLimit - $lim) -le [math]::Max(1, $lim * 0.02))
            $rxDone = [bool]($list | Where-Object { $_.Id -eq 'nic.rxbuffers' -and $_.State -eq 'OK' })
            $recent = Get-RecentResends
            $state = if ($ok) { 'OK' } elseif ($rxDone -and $recent.Resends -gt 0) { 'Warn' } else { 'Info' }
            $payload = if ($r.V.PayloadSize -gt 0) { [double]$r.V.PayloadSize } else { 24472000.0 }
            $frameMs = [math]::Round($payload / $lim * 1000)
            $rec = '先不改（次要）。Receive Buffers 調大後仍有重送，再試 On、約 {0:N0} MB/s（每張約 {1} ms），存到 UserSet1' -f ($lim / 1e6), $frameMs
            $c = New-Check 'cam.limit' '相機頻寬限制（次要）' $curTxt $rec $state
            $c.Kind = 'Camera'; $c.CanFix = (-not $ok -and $w.Ok); $c.FixReason = $w.Reason
            $c.Data = @{ Target = $lim; Old = @{ Mode = $mode; Limit = [long]$r.V.DeviceLinkThroughputLimit; UserSetDefault = $r.T.UserSetDefault; UserSetSelector = $r.T.UserSetSelector } }
            $c.Note = if ($state -eq 'Warn') { "Receive Buffers 已是最大值，但最近 1 小時相機仍收到 $($recent.Resends) 次重送要求：可以試這一項" }
                      elseif (-not $rxDone) { '請先處理 Receive Buffers；之後仍有重送才需要這一項' }
                      else { "最近 1 小時重送 $($recent.Resends) 次（$($recent.Source)），目前不需要" }
            $list.Add($c)
            $res = [double]$r.V.DeviceLinkThroughputReserve
            $c = New-Check 'cam.reserve' '相機 DeviceLinkThroughputReserve' ("{0}%" -f $res) '10% 以上' $(if ($res -ge 10) { 'OK' } else { 'Bad' })
            $c.Kind = 'Camera'; $c.CanFix = ($res -lt 10 -and $w.Ok); $c.FixReason = $w.Reason
            $c.Data = @{ Target = 10; Old = @{ Reserve = $res; UserSetDefault = $r.T.UserSetDefault } }
            $list.Add($c)
            $hb = $r.Heartbeat
            $list.Add((New-Check 'cam.heartbeat' '相機 Heartbeat 逾時' $(if ($null -ne $hb) { "$hb ms" } else { '讀不到' }) '維持（3000 ms 以上）' $(if ($null -eq $hb) { 'Unknown' } elseif ($hb -ge 3000) { 'OK' } else { 'Warn' }) '只檢查'))
            $script:CameraWritable = $w
        } finally { if ($camInfo.Temp) { try { $cam.Client.Dispose() } catch { } } }
    } else {
        $c = New-Check 'cam' '相機設定' '找不到相機或讀不到 XML' '—' 'Unknown'
        $c.Kind = 'Camera'
        $list.Add($c)
        $script:CameraWritable = @{ Ok = $false; Reason = '找不到相機' }
    }
    return , $list.ToArray()
}

# ---------------------------------------------------------------------------
#  修正與復原
# ---------------------------------------------------------------------------
function Invoke-OptimizeFix($Check, [string]$Guid) {
    $cfg = $script:Cfg
    $na = Get-NetAdapterByGuid $Guid
    $before = $null; $after = $null
    switch -Wildcard ($Check.Id) {
        'nic.rxbuffers' { $before = $Check.Data.Old; Set-NetAdapterAdvancedProperty -Name $na.Name -RegistryKeyword $Check.Data.Keyword -RegistryValue ([string]$Check.Data.Value) -ErrorAction Stop; $after = $Check.Data.Value; $cfg.DesiredNicSettings[$Check.Data.Keyword] = [string]$after }
        'nic.eee' { $before = $Check.Data.Old; Set-NetAdapterAdvancedProperty -Name $na.Name -RegistryKeyword $Check.Data.Keyword -RegistryValue '0' -ErrorAction Stop; $after = 0; $cfg.DesiredNicSettings[$Check.Data.Keyword] = '0' }
        'nic.power' {
            if ($Check.Data.Source -eq 'cmdlet') {
                $before = 'Enabled'; Set-NetAdapterPowerManagement -Name $na.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; $after = 'Disabled'
            } else {
                $before = $Check.Data.Old; Set-ItemProperty -LiteralPath $Check.Data.KeyPath -Name 'PnPCapabilities' -Value 24 -Type DWord -ErrorAction Stop; $after = 24
            }
        }
        'bind.*' {
            $before = $Check.Data.Old
            if ($Check.Data.Want) { Enable-NetAdapterBinding -Name $na.Name -ComponentID $Check.Data.ComponentID -ErrorAction Stop } else { Disable-NetAdapterBinding -Name $na.Name -ComponentID $Check.Data.ComponentID -ErrorAction Stop }
            $after = $Check.Data.Want
        }
        'power.aspm' {
            $before = @{ AC = $Check.Data.AC; DC = $Check.Data.DC }
            foreach ($cmd in @('/setacvalueindex', '/setdcvalueindex')) {
                $o = (powercfg $cmd SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0) 2>&1
                if ($LASTEXITCODE -ne 0) { throw "powercfg $cmd 失敗：$o" }
            }
            [void]((powercfg /setactive SCHEME_CURRENT) 2>&1)
            $after = @{ AC = 0; DC = 0 }
        }
        'cam.limit' {
            $before = $Check.Data.Old
            $camInfo = Get-CameraForOptimize $Guid
            try {
                Invoke-CameraWriteSession $camInfo.Cam {
                    param($s)
                    Set-CameraFeature $s 'DeviceLinkThroughputLimitMode' 'On'
                    Set-CameraFeature $s 'DeviceLinkThroughputLimit' $Check.Data.Target
                    Set-CameraFeature $s 'UserSetSelector' 'UserSet1'
                    Set-CameraFeature $s 'UserSetSave' 1
                    Set-CameraFeature $s 'UserSetDefault' 'UserSet1'
                }
            } finally { if ($camInfo.Temp) { try { $camInfo.Cam.Client.Dispose() } catch { } } }
            $after = @{ Mode = 'On'; Limit = $Check.Data.Target; UserSetDefault = 'UserSet1' }
            $cfg.ThroughputLimitApplied = $true
        }
        'cam.reserve' {
            $before = $Check.Data.Old
            $camInfo = Get-CameraForOptimize $Guid
            try {
                Invoke-CameraWriteSession $camInfo.Cam {
                    param($s)
                    Set-CameraFeature $s 'DeviceLinkThroughputReserve' $Check.Data.Target
                    Set-CameraFeature $s 'UserSetSelector' 'UserSet1'
                    Set-CameraFeature $s 'UserSetSave' 1
                    Set-CameraFeature $s 'UserSetDefault' 'UserSet1'
                }
            } finally { if ($camInfo.Temp) { try { $camInfo.Cam.Client.Dispose() } catch { } } }
            $after = @{ Reserve = $Check.Data.Target; UserSetDefault = 'UserSet1' }
        }
        default { throw "這個項目沒有自動修正：$($Check.Item)" }
    }
    $bk = Save-OptimizeBackup $Check.Id $Check.Item $before $after
    Save-Config
    $detail = if ($script:LastCameraSessionLog -and $Check.Kind -eq 'Camera') { '；' + ($script:LastCameraSessionLog -join '，') } else { '' }
    Add-MonitorEvent -Time (Get-Date) -Source 'Optimize' -EventId 200 -Severity Warning -Message ("已套用：{0}。修改前 {1} → 修改後 {2}（執行者 {3}，備份 {4}）{5}" -f $Check.Item, (ConvertTo-Json $before -Compress), (ConvertTo-Json $after -Compress), (Get-ExecutorText), [IO.Path]::GetFileName($bk), $detail) -NoAlarm
    return $bk
}

function Invoke-OptimizeRestore([string]$Id, [string]$Guid) {
    $b = Get-LatestBackup $Id
    if (-not $b) { throw '找不到可以復原的備份（這個項目還沒有用本工具修改過，或已經復原過）' }
    $d = $b.Data
    $na = Get-NetAdapterByGuid $Guid
    $cfg = $script:Cfg
    switch -Wildcard ($Id) {
        'nic.rxbuffers' { Set-NetAdapterAdvancedProperty -Name $na.Name -RegistryKeyword '*ReceiveBuffers' -RegistryValue ([string]$d.Before) -ErrorAction Stop; [void]$cfg.DesiredNicSettings.Remove('*ReceiveBuffers') }
        'nic.eee' {
            $kw = (Get-AdvProp @(Get-NetAdapterAdvancedProperty -Name $na.Name -AllProperties) @('*EEE', 'EEE', 'EEELinkAdvertisement', '*GreenEthernet', 'GreenEthernet')).RegistryKeyword
            Set-NetAdapterAdvancedProperty -Name $na.Name -RegistryKeyword $kw -RegistryValue ([string]$d.Before) -ErrorAction Stop; [void]$cfg.DesiredNicSettings.Remove($kw)
        }
        'nic.power' {
            if ($d.Before -eq 'Enabled') { Set-NetAdapterPowerManagement -Name $na.Name -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop }
            else {
                $kp = Get-NicClassKeyPath $Guid
                if ($null -eq $d.Before -or [string]$d.Before -eq '') { Remove-ItemProperty -LiteralPath $kp -Name 'PnPCapabilities' -ErrorAction Stop }
                else { Set-ItemProperty -LiteralPath $kp -Name 'PnPCapabilities' -Value ([int]$d.Before) -Type DWord -ErrorAction Stop }
            }
        }
        'bind.*' {
            $cid = $Id.Substring(5)
            if ([bool]$d.Before) { Enable-NetAdapterBinding -Name $na.Name -ComponentID $cid -ErrorAction Stop } else { Disable-NetAdapterBinding -Name $na.Name -ComponentID $cid -ErrorAction Stop }
        }
        'power.aspm' {
            if ($null -ne $d.Before.AC) { [void]((powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM ([int]$d.Before.AC)) 2>&1) }
            if ($null -ne $d.Before.DC) { [void]((powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM ([int]$d.Before.DC)) 2>&1) }
            [void]((powercfg /setactive SCHEME_CURRENT) 2>&1)
        }
        'cam.limit' {
            $camInfo = Get-CameraForOptimize $Guid
            try {
                Invoke-CameraWriteSession $camInfo.Cam {
                    param($s)
                    Set-CameraFeature $s 'DeviceLinkThroughputLimitMode' ([string]$d.Before.Mode)
                    if ([string]$d.Before.Mode -eq 'On' -or $d.Before.Limit) { Set-CameraFeature $s 'DeviceLinkThroughputLimit' ([long]$d.Before.Limit) }
                    if ($d.Before.UserSetDefault) { Set-CameraFeature $s 'UserSetDefault' ([string]$d.Before.UserSetDefault) }
                }
            } finally { if ($camInfo.Temp) { try { $camInfo.Cam.Client.Dispose() } catch { } } }
            $cfg.ThroughputLimitApplied = $false
        }
        'cam.reserve' {
            $camInfo = Get-CameraForOptimize $Guid
            try {
                Invoke-CameraWriteSession $camInfo.Cam {
                    param($s)
                    Set-CameraFeature $s 'DeviceLinkThroughputReserve' ([long]$d.Before.Reserve)
                    if ($d.Before.UserSetDefault) { Set-CameraFeature $s 'UserSetDefault' ([string]$d.Before.UserSetDefault) }
                }
            } finally { if ($camInfo.Temp) { try { $camInfo.Cam.Client.Dispose() } catch { } } }
        }
        default { throw "不支援復原：$Id" }
    }
    Set-BackupRestored $b.Path
    Save-Config
    Add-MonitorEvent -Time (Get-Date) -Source 'Optimize' -EventId 201 -Severity Warning -Message ("已復原：{0}。寫回修改前的值 {1}（目前值 {2}；原修改時間 {3}，執行者 {4}）" -f $d.Item, (ConvertTo-Json $d.Before -Compress), (ConvertTo-Json $d.After -Compress), $d.Time, (Get-ExecutorText)) -NoAlarm
}

# ---------------------------------------------------------------------------
#  套用前後各 1 小時的比較（網卡丟棄、相機重送）
# ---------------------------------------------------------------------------
function Get-LogRowsBetween([string]$Kind, [datetime]$From, [datetime]$To) {
    $dir = if ($script:ActiveLogDir) { $script:ActiveLogDir } else { Get-LogDir }
    $rows = @()
    for ($d = $From.Date; $d -le $To.Date; $d = $d.AddDays(1)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter ('{0}_{1}*.csv' -f $Kind, $d.ToString('yyyyMMdd')) -ErrorAction SilentlyContinue)) {
            try {
                $tmp = Join-Path $env:TEMP ('CamNetTool_cmp_' + $f.Name)
                Copy-FileShared $f.FullName $tmp
                $rows += @(Import-Csv -LiteralPath $tmp -Encoding UTF8 | Where-Object { $t = [datetime]$_.Time; $t -ge $From -and $t -lt $To })
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    return $rows
}

function Get-WindowStats([datetime]$From, [datetime]$To) {
    $st = @(Get-LogRowsBetween 'status' $From $To)
    $cs = @(Get-LogRowsBetween 'camstatus' $From $To)
    $disc = 0L; foreach ($r in $st) { if ($r.RxDiscardDelta -match '^\d+$') { $disc += [long]$r.RxDiscardDelta } }
    $rs = 0L; $un = 0L
    foreach ($r in $cs) { if ($r.ResendRecvDelta -match '^\d+$') { $rs += [long]$r.ResendRecvDelta }; if ($r.ResendUnavailDelta -match '^\d+$') { $un += [long]$r.ResendUnavailDelta } }
    $mins = if ($st.Count -ge 2) { ([datetime]$st[-1].Time - [datetime]$st[0].Time).TotalMinutes } else { 0 }
    return [pscustomobject]@{ From = $From; To = $To; Samples = $st.Count; CamSamples = $cs.Count; Discards = $disc; Resends = $rs; Unavailable = $un; Minutes = [math]::Round($mins) }
}

function Get-BeforeAfterText([datetime]$At) {
    $now = Get-Date
    $b = Get-WindowStats $At.AddHours(-1) $At
    $aTo = if ($At.AddHours(1) -gt $now) { $now } else { $At.AddHours(1) }
    $a = Get-WindowStats $At $aTo
    $fmt = { param($x) '網卡丟棄 {0:N0}、相機重送 {1:N0}、無法重送 {2:N0}（{3} 筆，約 {4} 分鐘）' -f $x.Discards, $x.Resends, $x.Unavailable, $x.Samples, $x.Minutes }
    return "套用前 1 小時：$(& $fmt $b)`r`n套用後 1 小時：$(& $fmt $a)$(if ($aTo -lt $At.AddHours(1)) { '　← 還沒滿 1 小時' })"
}

# ---------------------------------------------------------------------------
#  分頁
# ---------------------------------------------------------------------------
function Initialize-OptimizeTab($Page) {
    $U.OptReload = New-Ctl Button $Page 10 8 120 28 '重新檢查'
    $U.OptFix = New-Ctl Button $Page 140 8 160 28 '修正選取的項目'
    $U.OptFix.Font = $fBold
    $U.OptRestore = New-Ctl Button $Page 306 8 160 28 '復原選取的項目'
    $U.OptReason = New-Ctl Label $Page 476 12 660 22 '選取一列後按「修正」或「復原」。'
    $U.OptReason.AutoEllipsis = $true
    $U.OptCamState = New-Ctl Label $Page 10 40 1126 22 ''
    $U.OptCamState.Font = $fBold; $U.OptCamState.AutoEllipsis = $true

    $U.OptList = New-Object System.Windows.Forms.ListView
    $U.OptList.View = 'Details'; $U.OptList.FullRowSelect = $true; $U.OptList.GridLines = $true; $U.OptList.MultiSelect = $false; $U.OptList.HideSelection = $false
    $U.OptList.ShowItemToolTips = $true
    $U.OptList.Location = New-Object System.Drawing.Point(10, 66)
    $U.OptList.Size = New-Object System.Drawing.Size(1126, 330)
    foreach ($c in @(@('狀態', 60), @('項目', 300), @('目前值', 250), @('建議值', 300), @('修正', 70), @('復原', 70), @('說明', 600))) { [void]$U.OptList.Columns.Add($c[0], $c[1]) }
    $Page.Controls.Add($U.OptList)

    $gCmp = New-Ctl GroupBox $Page 10 402 560 150 '效果比較（套用前後各 1 小時：網卡丟棄、相機重送應該接近 0）'
    $U.OptCmpPick = New-Ctl ComboBox $gCmp 12 24 420 24
    $U.OptCmpPick.DropDownStyle = 'DropDownList'
    $U.OptCmpRun = New-Ctl Button $gCmp 440 23 108 26 '計算'
    $U.OptCmpText = New-Ctl Label $gCmp 12 56 536 86 ''

    $gNote = New-Ctl GroupBox $Page 580 402 556 150 '處理順序與頻寬限制（給 LabVIEW 程式負責人）'
    $note = New-Object System.Windows.Forms.TextBox
    $note.Multiline = $true; $note.ReadOnly = $true; $note.ScrollBars = 'Vertical'
    $note.Location = New-Object System.Drawing.Point(10, 20); $note.Size = New-Object System.Drawing.Size(536, 122)
    $note.Text = ("處理順序：先調 Receive Buffers（封包是在網卡接收環被丟掉），再處理 GigE 過濾驅動。觀察 3～7 天，重送次數應該接近 0；沒有的話再考慮頻寬限制。`r`n`r`n" +
        "頻寬限制（次要）：L5 實測每張影像約 49.5 ms 送完（突發約 494 MB/s），限制的效果有限。真的需要時，因為程式每次開相機可能覆寫設定，請在開始取像前用 IMAQdx 屬性節點設定：`r`n" +
        "  DeviceLinkThroughputLimitMode = On`r`n  DeviceLinkThroughputLimit = 300000000（約 300 MB/s，每張約 82 ms，仍在 100 ms 週期內）`r`n" +
        "另外：程式畫面上的 DesiredPeakBandwidth = 1000，但相機的 SCPD = 0、頻寬限制 Off，看起來沒有生效，請一併確認。`r`n" +
        "本工具的「修正」只能在 LabVIEW 關閉時用，並把設定存到 UserSet1（開機預設），作為保險。")
    $gNote.Controls.Add($note)

    $script:OptChecks = @()
    $U.OptReload.Add_Click({ Invoke-Safe { Update-OptimizeTab } })
    $U.OptList.Add_SelectedIndexChanged({ try { Update-OptimizeButtons } catch { } })
    $U.OptFix.Add_Click({ Invoke-Safe { Invoke-OptimizeFromUi 'Fix' } })
    $U.OptRestore.Add_Click({ Invoke-Safe { Invoke-OptimizeFromUi 'Restore' } })
    $U.OptCmpRun.Add_Click({ Invoke-Safe {
        $i = $U.OptCmpPick.SelectedIndex
        if ($i -lt 0 -or -not $script:OptCmpTimes -or $i -ge $script:OptCmpTimes.Count) { return }
        $form.Cursor = 'WaitCursor'
        try { $U.OptCmpText.Text = Get-BeforeAfterText $script:OptCmpTimes[$i] } finally { $form.Cursor = 'Default' }
    } })
    $tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabOpt -and -not $script:OptLoaded) { Invoke-Safe { Update-OptimizeTab } } })
    $script:OnSettingsSaved = { if ($script:OptLoaded) { Update-OptimizeTab } }
}

function Get-StateText([string]$S) { switch ($S) { 'OK' { '● 正常' } 'Bad' { '● 建議修正' } 'Warn' { '● 可以試' } 'Info' { '● 次要' } 'Show' { '● 只顯示' } 'Reset' { '● 被重設' } default { '● 未知' } } }

function Update-OptimizeTab {
    $a = Get-SelectedAdapter
    if (-not $a) { return }
    $form.Cursor = 'WaitCursor'
    try { $script:OptChecks = Get-OptimizeChecks $a.Guid } finally { $form.Cursor = 'Default' }
    $U.OptList.BeginUpdate()
    $U.OptList.Items.Clear()
    foreach ($c in $script:OptChecks) {
        $it = New-Object System.Windows.Forms.ListViewItem((Get-StateText $c.State))
        $it.UseItemStyleForSubItems = $false
        $it.ForeColor = switch ($c.State) { 'OK' { $cGreen } 'Bad' { $cRed } 'Reset' { $cRed } 'Warn' { $cOrange } 'Info' { [System.Drawing.Color]::SteelBlue } 'Show' { [System.Drawing.Color]::SteelBlue } default { $cGray } }
        $fixTxt = if ($c.CanFix) { '可修正' } elseif ($c.State -eq 'OK') { '—' } elseif ($c.FixReason) { '不可用' } else { '—' }
        $hasBk = [bool](Get-LatestBackup $c.Id)
        foreach ($x in $c.Item, $c.Current, $c.Recommended, $fixTxt, $(if ($hasBk) { '可復原' } else { '—' }), $(if ($c.FixReason -and -not $c.CanFix -and $c.State -ne 'OK') { "$($c.FixReason)。$($c.Note)" } else { $c.Note })) { [void]$it.SubItems.Add([string]$x) }
        if ($c.State -eq 'Bad' -or $c.State -eq 'Reset') { $it.BackColor = $cWarnBg; foreach ($s in $it.SubItems) { $s.BackColor = $cWarnBg } }
        $it.Tag = $c
        $it.ToolTipText = "$($c.Item)`n目前：$($c.Current)`n建議：$($c.Recommended)`n$($it.SubItems[6].Text)"
        [void]$U.OptList.Items.Add($it)
    }
    $U.OptList.EndUpdate()
    $w = $script:CameraWritable
    if ($w -and $w.Ok) { $U.OptCamState.Text = '相機寫入：可以（沒有程式控制相機，也沒有取像程式在執行）'; $U.OptCamState.ForeColor = $cGreen }
    elseif ($w) { $U.OptCamState.Text = "相機寫入：不可用 — $($w.Reason)"; $U.OptCamState.ForeColor = $cRed }
    if (-not $script:IsAdmin) { $U.OptCamState.Text += '　｜　網卡與電源設定需要系統管理員權限' }
    # 效果比較：可選的時間點 = 每次套用的時間
    $script:OptCmpTimes = @()
    $U.OptCmpPick.Items.Clear()
    foreach ($b in (Get-AllBackups | Select-Object -First 30)) {
        try { $t = [datetime]::ParseExact($b.Data.Time, 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
        $script:OptCmpTimes += $t
        [void]$U.OptCmpPick.Items.Add(('{0}  {1}{2}' -f $b.Data.Time, $b.Data.Item, $(if ($b.Data.Restored) { '（已復原）' } else { '' })))
    }
    if ($U.OptCmpPick.Items.Count) { $U.OptCmpPick.SelectedIndex = 0; $U.OptCmpText.Text = '選一個套用時間後按「計算」。' }
    else { $U.OptCmpText.Text = '還沒有用本工具套用過任何設定。' }
    $script:OptLoaded = $true
    Update-OptimizeButtons
}

function Get-SelectedCheck {
    if ($U.OptList.SelectedItems.Count -eq 0) { return $null }
    return $U.OptList.SelectedItems[0].Tag
}

function Update-OptimizeButtons {
    $c = Get-SelectedCheck
    if (-not $c) { $U.OptFix.Enabled = $false; $U.OptRestore.Enabled = $false; $U.OptReason.Text = '選取一列後按「修正」或「復原」。'; $U.OptReason.ForeColor = $cText; return }
    $hasBk = [bool](Get-LatestBackup $c.Id)
    $U.OptFix.Enabled = [bool]$c.CanFix
    $U.OptRestore.Enabled = $hasBk -and -not ($c.Kind -eq 'Camera' -and -not $script:CameraWritable.Ok)
    $reason = @()
    if (-not $c.CanFix) {
        if ($c.State -eq 'OK') { $reason += '已是建議值' }
        elseif ($c.State -eq 'Show') { $reason += '只顯示目前的值，沒有修正' }
        elseif ($c.FixReason) { $reason += "不能修正：$($c.FixReason)" }
        else { $reason += '只檢查，沒有自動修正' }
    }
    if ($c.CanFix -and $c.NeedsAdmin -and -not $script:IsAdmin) { $reason += '需要系統管理員權限（按下修正時可以重新開啟）' }
    if ($hasBk -and -not $U.OptRestore.Enabled) { $reason += "不能復原：$($script:CameraWritable.Reason)" }
    $U.OptReason.Text = if ($reason.Count) { $reason -join '　｜　' } else { "可以修正：$($c.Item)" }
    $U.OptReason.ForeColor = if ($U.OptFix.Enabled) { $cText } else { $cOrange }
    $tip.SetToolTip($U.OptReason, $U.OptReason.Text)
}

function Invoke-OptimizeFromUi([string]$Action) {
    $c = Get-SelectedCheck
    if (-not $c) { return }
    $a = Get-SelectedAdapter
    if ($c.Kind -ne 'Camera' -and -not $script:IsAdmin) {
        $r = [System.Windows.Forms.MessageBox]::Show('這個動作需要系統管理員權限。要以系統管理員身分重新開啟本工具嗎？', 'CamNetTool', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Restart-AsAdmin }
        return
    }
    $warn = switch ($c.Kind) {
        'Camera' { "會暫時取得相機控制權寫入設定，完成後釋放。`n請確認 LabVIEW 程式已關閉。" }
        'Power' { '會修改目前電源計畫的設定。' }
        default { "網卡設定變更會讓網卡重新啟動，連線中斷約 5～10 秒。`n請確認現在沒有在取像。" }
    }
    if ($Action -eq 'Fix') {
        $msg = "要修正這個項目嗎？`n`n{0}`n目前：{1}`n改為：{2}`n`n{3}`n修改前的值會存成備份，可以復原。" -f $c.Item, $c.Current, $c.Recommended, $warn
    } else {
        $b = Get-LatestBackup $c.Id
        $msg = "要復原這個項目嗎？`n`n{0}`n寫回修改前的值：{1}`n（{2} 由 {3} 修改）`n`n{4}" -f $c.Item, (ConvertTo-Json $b.Data.Before -Compress), $b.Data.Time, $b.Data.User, $warn
    }
    if ([System.Windows.Forms.MessageBox]::Show($msg, '最佳化設定', 'OKCancel', 'Warning', 'Button2') -ne 'OK') { return }
    $form.Cursor = 'WaitCursor'
    try {
        if ($Action -eq 'Fix') { [void](Invoke-OptimizeFix $c $a.Guid); Set-StatusMessage "已套用：$($c.Item)" -Sticky }
        else { Invoke-OptimizeRestore $c.Id $a.Guid; Set-StatusMessage "已復原：$($c.Item)" -Sticky }
    } catch {
        $why = $_.Exception.Message
        Add-MonitorEvent -Time (Get-Date) -Source 'Optimize' -EventId 202 -Severity Warning -Message ("{0}失敗：{1}。原因：{2}（執行者 {3}）{4}" -f $(if ($Action -eq 'Fix') { '套用' } else { '復原' }), $c.Item, $why, (Get-ExecutorText), $(if ($script:LastCameraSessionLog) { '；' + ($script:LastCameraSessionLog -join '，') } else { '' })) -NoAlarm
        [void][System.Windows.Forms.MessageBox]::Show("沒有完成：$why", '最佳化設定', 'OK', 'Error')
    } finally { $form.Cursor = 'Default'; $script:LastCameraSessionLog = $null }
    Start-Sleep -Milliseconds 500
    Update-OptimizeTab
}
