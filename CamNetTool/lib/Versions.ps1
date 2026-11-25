#Requires -Version 5.1
# CamNetTool -「版本與更新」：相機韌體、網卡驅動、Arena、IMAQdx 版本，線上查詢最新版，協助安裝網卡驅動

# 線上來源（LUCID 網站）：韌體用網站搜尋 API 找 release notes 標題；Arena SDK 看下載頁說明裡的版本
$script:LucidFwSearchUrl = 'https://thinklucid.com/wp-json/wp/v2/search?per_page=50&search=Atlas10%20Firmware%20Release%20Notes'
$script:LucidFwPattern   = 'Atlas10 v([\d.]+) Firmware Release Notes'
$script:LucidSdkPageUrl  = 'https://thinklucid.com/document/arena-sdk-with-arenaview/'
$script:LucidSdkPattern  = 'v(\d+\.\d+\.\d+\.\d+)\s*\(Release Date:\s*(\d{4}-\d\d-\d\d)\)'

function Get-InstalledSoftwareList {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)NI |National Instruments|IMAQ|Vision|LabVIEW|Marvell|Aquantia|AQtion|LUCID|Arena|GigE|SENTECH' } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object DisplayName -Unique)
}

function ConvertTo-VersionObj([string]$Text) {
    $t = ($Text -replace '[^0-9\.]', '').Trim('.')
    if (-not $t) { return $null }
    $parts = @($t.Split('.') | Where-Object { $_ -ne '' } | Select-Object -First 4)
    while ($parts.Count -lt 2) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

# 「落後：1.21.0.0 → 1.54.0.0（次版本號差 33）」
function Get-VersionGap([string]$Current, [string]$Latest) {
    $c = ConvertTo-VersionObj $Current; $l = ConvertTo-VersionObj $Latest
    if (-not $c -or -not $l) { return @{ Text = '無法比較'; Old = $false } }
    if ($c -ge $l) { return @{ Text = "已是最新（已知最新 $Latest）"; Old = $false } }
    if ($c.Major -lt $l.Major) { return @{ Text = ('落後：{0} → {1}（主版本差 {2}）' -f $Current, $Latest, ($l.Major - $c.Major)); Old = $true } }
    if ($c.Minor -lt $l.Minor) { return @{ Text = ('落後：{0} → {1}（次版本號差 {2}）' -f $Current, $Latest, ($l.Minor - $c.Minor)); Old = $true } }
    return @{ Text = ('落後：{0} → {1}' -f $Current, $Latest); Old = $true }
}

function Get-MaxVersion([string[]]$List) {
    $best = $null; $bestV = $null
    foreach ($s in $List) { $v = ConvertTo-VersionObj $s; if ($v -and (-not $bestV -or $v -gt $bestV)) { $best = $s; $bestV = $v } }
    return $best
}

function Get-WebText([string]$Url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) CamNetTool/$($script:AppVersion)"
    return [string]$r.Content
}

# 線上查詢最新版本。成功時更新設定檔的「最新版」（取線上與設定檔中較新的）並記錄時間。
function Invoke-OnlineVersionCheck {
    $cfg = $script:Cfg
    $res = [ordered]@{ Ok = $false; Fw = $null; Sdk = $null; SdkDate = $null; Notes = @() }
    try {
        $t = Get-WebText $script:LucidFwSearchUrl
        $vs = @([regex]::Matches($t, $script:LucidFwPattern) | ForEach-Object { $_.Groups[1].Value })
        if ($vs.Count) { $res.Fw = Get-MaxVersion $vs; $res.Ok = $true } else { $res.Notes += '相機韌體：網頁上找不到版本' }
    } catch { $res.Notes += "相機韌體：$($_.Exception.Message)" }
    try {
        $t = Get-WebText $script:LucidSdkPageUrl
        $ms = @([regex]::Matches($t, $script:LucidSdkPattern))
        if ($ms.Count) {
            $best = Get-MaxVersion @($ms | ForEach-Object { $_.Groups[1].Value })
            $res.Sdk = $best
            $res.SdkDate = ($ms | Where-Object { $_.Groups[1].Value -eq $best } | Select-Object -First 1).Groups[2].Value
            $res.Ok = $true
        } else { $res.Notes += 'Arena SDK：網頁上找不到版本' }
    } catch { $res.Notes += "Arena SDK：$($_.Exception.Message)" }
    if ($res.Fw) {
        $m = Get-MaxVersion @($res.Fw, $cfg.LatestCameraFw)
        if ($m -ne $cfg.LatestCameraFw) { $cfg.LatestCameraFw = $m; $cfg.LatestCameraFwDate = '' }
    }
    if ($res.Sdk) {
        $m = Get-MaxVersion @($res.Sdk, $cfg.LatestArenaSdk)
        if ($m -ne $cfg.LatestArenaSdk) { $cfg.LatestArenaSdk = $m; $cfg.LatestArenaSdkDate = $res.SdkDate }
        elseif ($res.Sdk -ne $cfg.LatestArenaSdk) { $res.Notes += "Arena SDK：線上下載頁是 $($res.Sdk)（$($res.SdkDate)），設定檔已知 $($cfg.LatestArenaSdk) 較新，以設定檔為準" }
    }
    if ($res.Ok) { $cfg.LatestOnlineAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Save-Config }
    return $res
}

# 相機版本：監控中用現有連線；否則用 Discovery（不需要 XML）
function Get-CameraVersionInfo([string]$Guid) {
    if ($script:Cam -and $script:Cam.Model) { return @{ Model = $script:Cam.Model; Serial = $script:Cam.Serial; Version = $script:Cam.Version; Ip = $script:Cam.Ip; Vendor = $script:Cam.Vendor } }
    if (-not $Guid) { return $null }
    $f = @(Find-GigECameras $Guid 800)
    if (-not $f.Count) { return $null }
    $d = $f[0].Device
    return @{ Model = $d.Model; Serial = $d.Serial; Version = $d.Version; Ip = $d.Ip; Vendor = $d.Manufacturer }
}

function Get-NicFirmwareText([string]$Description) {
    try {
        $fw = @(Get-CimInstance -Namespace root/wmi -ClassName Aq_FirmwareVersion -ErrorAction Stop) | Where-Object { $_.InstanceName -like "$Description*" } | Select-Object -First 1
        if ($fw) { return ('{0}.{1}.{2}（由 AQtion 驅動讀取）' -f $fw.major, $fw.minor, $fw.revision) }
    } catch { }
    return 'Windows 讀不到，需用 Marvell 工具'
}

# 版本表格的每一列
function Get-VersionRows([string]$Guid) {
    $cfg = $script:Cfg
    $rows = New-Object System.Collections.Generic.List[object]
    $sw = Get-InstalledSoftwareList
    $cam = Get-CameraVersionInfo $Guid
    if ($cam) {
        $g = Get-VersionGap $cam.Version $cfg.LatestCameraFw
        $rows.Add([pscustomobject]@{ Item = '相機韌體'; Current = "$($cam.Model)  序號 $($cam.Serial)  $($cam.Version)"; Latest = "$($cfg.LatestCameraFw) $($cfg.LatestCameraFwDate)"; Gap = $g.Text; Old = $g.Old })
    } else {
        $rows.Add([pscustomobject]@{ Item = '相機韌體'; Current = '找不到相機'; Latest = $cfg.LatestCameraFw; Gap = '—'; Old = $false })
    }
    $na = if ($Guid) { Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $Guid } | Select-Object -First 1 }
    if ($na) {
        $g = Get-VersionGap ([string]$na.DriverVersion) $cfg.LatestNicDriver
        $rows.Add([pscustomobject]@{ Item = '網卡驅動'; Current = "$($na.InterfaceDescription)  $($na.DriverVersion)（$($na.DriverDate)）"; Latest = $cfg.LatestNicDriver; Gap = $g.Text; Old = $g.Old })
        $rows.Add([pscustomobject]@{ Item = '網卡韌體'; Current = (Get-NicFirmwareText ([string]$na.InterfaceDescription)); Latest = '—'; Gap = '不建議主動更新（見下方說明）'; Old = $false })
    }
    $arena = $sw | Where-Object { $_.DisplayName -match '(?i)Arena SDK' -or ($_.DisplayName -match '(?i)^Arena' -and $_.DisplayName -notmatch '(?i)lwf|filter') } | Select-Object -First 1
    if ($arena) {
        $g = Get-VersionGap ([string]$arena.DisplayVersion) $cfg.LatestArenaSdk
        $rows.Add([pscustomobject]@{ Item = 'Arena SDK'; Current = "$($arena.DisplayName)  $($arena.DisplayVersion)"; Latest = "$($cfg.LatestArenaSdk) $($cfg.LatestArenaSdkDate)"; Gap = $g.Text; Old = $g.Old })
    } else { $rows.Add([pscustomobject]@{ Item = 'Arena SDK'; Current = '沒有安裝'; Latest = $cfg.LatestArenaSdk; Gap = '—'; Old = $false }) }
    $lwf = $sw | Where-Object { $_.DisplayName -match '(?i)lwf|Lightweight Filter' } | Select-Object -First 1
    $lwfBind = if ($na) { Get-NetAdapterBinding -Name $na.Name -AllBindings -ErrorAction SilentlyContinue | Where-Object { $_.ComponentID -match '(?i)lucid|arena' } | Select-Object -First 1 }
    $lwfText = if ($lwf) { "$($lwf.DisplayName)  $($lwf.DisplayVersion)" } elseif ($lwfBind) { "$($lwfBind.DisplayName)（$($lwfBind.ComponentID)）" } else { '沒有安裝' }
    if ($lwfBind) { $lwfText += $(if ($lwfBind.Enabled) { '　相機網卡上：啟用' } else { '　相機網卡上：停用' }) }
    $rows.Add([pscustomobject]@{ Item = 'Arena GigE Lwf'; Current = $lwfText; Latest = '隨 Arena SDK'; Gap = '—'; Old = $false })
    $imaq = $sw | Where-Object { $_.DisplayName -match '(?i)IMAQdx|Vision Acquisition Software' } |
        Sort-Object @{ Expression = { if ($_.DisplayName -match '(?i)\.NET|Support|Runtime|Driver') { 1 } else { 0 } } }, @{ Expression = { $_.DisplayName.Length } } | Select-Object -First 1
    $rows.Add([pscustomobject]@{ Item = 'NI-IMAQdx'; Current = $(if ($imaq) { "$($imaq.DisplayName)  $($imaq.DisplayVersion)" } else { '沒有安裝' }); Latest = '只顯示，不比較'; Gap = '—'; Old = $false })
    return , $rows.ToArray()
}

# 取像程式是否在執行（寫入類動作的前提）
function Get-AcquisitionProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^Application$|^LabVIEW$|^lvrt|^NIMax$|^ArenaView' } | Select-Object Name, Id)
}

function Find-ArenaView {
    $cands = @()
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ($base -and (Test-Path -LiteralPath (Join-Path $base 'Lucid Vision Labs'))) {
            $cands += @(Get-ChildItem -LiteralPath (Join-Path $base 'Lucid Vision Labs') -Recurse -Filter 'ArenaView*.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
    }
    return ($cands | Sort-Object { $_ -notmatch 'x64' } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
#  分頁
# ---------------------------------------------------------------------------
function Initialize-VersionsTab($Page) {
    $U.VerList = New-Object System.Windows.Forms.ListView
    $U.VerList.View = 'Details'; $U.VerList.FullRowSelect = $true; $U.VerList.GridLines = $true
    $U.VerList.Location = New-Object System.Drawing.Point(10, 10)
    $U.VerList.Size = New-Object System.Drawing.Size(1126, 200)
    foreach ($c in @(@('項目', 120), @('目前版本', 430), @('最新版本', 170), @('比較', 390))) { [void]$U.VerList.Columns.Add($c[0], $c[1]) }
    $Page.Controls.Add($U.VerList)
    $U.VerReload = New-Ctl Button $Page 10 216 120 28 '重新讀取'
    $U.VerOnline = New-Ctl Button $Page 136 216 160 28 '線上查詢最新版本'
    $U.VerOnlineAt = New-Ctl Label $Page 306 220 830 22 ''
    $U.VerOnlineAt.AutoEllipsis = $true

    $gDrv = New-Ctl GroupBox $Page 10 252 560 290 '網卡驅動更新（建議；風險低、可以回復）'
    [void](New-Ctl Label $gDrv 12 26 120 22 '驅動資料夾')
    $U.VerDrvDir = New-Ctl TextBox $gDrv 12 50 450 24
    $U.VerDrvPick = New-Ctl Button $gDrv 468 49 80 26 '選擇…'
    $U.VerDrvInstall = New-Ctl Button $gDrv 12 82 160 30 '安裝驅動'
    $U.VerDrvInstall.Font = $fBold
    $U.VerDrvState = New-Ctl Label $gDrv 180 88 370 22 ''
    $U.VerDrvState.AutoEllipsis = $true
    $drvNote = New-Ctl Label $gDrv 12 120 536 160 ("1. 從 Marvell 官網下載 AQtion Windows 驅動並解壓縮，在上面選擇那個資料夾。`n" +
        "2. 關閉 LabVIEW 程式，並以系統管理員身分執行本工具。`n" +
        "3. 按「安裝驅動」（pnputil /add-driver …\*.inf /subdirs /install）。安裝時網卡會重新啟動。`n" +
        "4. 安裝後工具會重新檢查「最佳化設定」：新驅動可能把 Receive Buffers 等設定重設回預設值，要再套用一次。`n" +
        "回復方法：裝置管理員 → 網路介面卡 → 這張網卡 → 內容 → 驅動程式 → 回復驅動程式。")
    $drvNote.ForeColor = $cGray

    $gFw = New-Ctl GroupBox $Page 580 252 556 290 '相機韌體（建議先在一台機台試）'
    $U.VerArena = New-Ctl Button $gFw 12 24 140 30 '開啟 ArenaView'
    $U.VerSnap = New-Ctl Button $gFw 160 24 200 30 '更新前先做診斷快照'
    $fwNote = New-Ctl Label $gFw 12 62 534 220 ("本工具不直接燒錄韌體。步驟：`n" +
        "1. 先更新 Arena SDK（舊版可能不支援新韌體）。`n" +
        "2. 關閉 LabVIEW 程式。`n" +
        "3. 下載韌體與 release notes，確認有沒有與串流、重送相關的修正。`n" +
        "4. 用 ArenaView 更新；過程中不可斷電、不可拔線。`n" +
        "5. 更新後重新開啟本工具，確認版本；工具會自動重新解析 XML 與暫存器位址。`n" +
        "6. 觀察數天，與其他機台比較卡住次數和重送次數。`n`n" +
        "網卡韌體：不建議主動更新。只有在 IOI 或 Marvell 明確建議時，才用廠商提供的工具更新。")
    $fwNote.ForeColor = $cGray

    $U.VerReload.Add_Click({ Invoke-Safe { Update-VersionsTab } })
    $U.VerOnline.Add_Click({ Invoke-Safe {
        $form.Cursor = 'WaitCursor'
        try { $r = Invoke-OnlineVersionCheck } finally { $form.Cursor = 'Default' }
        if ($r.Ok) {
            $msg = "線上查詢成功：相機韌體最新 $($r.Fw)、Arena SDK 下載頁 $($r.Sdk)（$($r.SdkDate)）"
            if ($r.Notes.Count) { $msg += '。' + ($r.Notes -join '；') }
            Set-StatusMessage $msg -Sticky
            Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 60 -Severity Info -Message $msg
        } else {
            Set-StatusMessage ('線上查詢失敗（離線）：' + ($r.Notes -join '；')) -IsError -Sticky
        }
        $script:LastOnlineResult = $r
        Update-VersionsTab
    } })
    $U.VerDrvPick.Add_Click({ Invoke-Safe {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '選擇已解壓縮的 Marvell AQtion Windows 驅動資料夾（裡面有 .inf）'
        if ($U.VerDrvDir.Text) { $dlg.SelectedPath = $U.VerDrvDir.Text }
        if ($dlg.ShowDialog($form) -eq 'OK') { $U.VerDrvDir.Text = $dlg.SelectedPath; $script:Cfg.DriverFolder = $dlg.SelectedPath; Save-Config }
        $dlg.Dispose()
    } })
    $U.VerDrvInstall.Add_Click({ Invoke-Safe { Invoke-DriverInstallFromUi } })
    $U.VerArena.Add_Click({ Invoke-Safe {
        $p = Find-ArenaView
        if ($p) { Start-Process -FilePath $p } else { [void][System.Windows.Forms.MessageBox]::Show('找不到 ArenaView（Arena SDK 沒有安裝在預設位置）。', 'CamNetTool', 'OK', 'Warning') }
    } })
    $U.VerSnap.Add_Click({ Invoke-Safe {
        $tabs.SelectedTab = $tabDiag
        $U.DiagLabel.Text = 'before_fw'
        Invoke-DiagFromUi
    } })
    $tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabVer -and -not $script:VersionsLoaded) { Invoke-Safe { Update-VersionsTab } } })
    $U.VerDrvDir.Text = [string]$script:Cfg.DriverFolder
}

function Update-VersionsTab {
    $a = Get-SelectedAdapter
    $form.Cursor = 'WaitCursor'
    try { $rows = Get-VersionRows $(if ($a) { $a.Guid } else { '' }) } finally { $form.Cursor = 'Default' }
    $U.VerList.BeginUpdate()
    $U.VerList.Items.Clear()
    foreach ($r in $rows) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Item)
        foreach ($x in $r.Current, $r.Latest, $r.Gap) { [void]$it.SubItems.Add([string]$x) }
        if ($r.Old) { $it.BackColor = $cWarnBg }
        [void]$U.VerList.Items.Add($it)
    }
    $U.VerList.EndUpdate()
    $at = $script:Cfg.LatestOnlineAt
    if ($at) {
        $U.VerOnlineAt.Text = "最後一次成功查詢線上版本：$at"
        $U.VerOnlineAt.ForeColor = $cText
    } else {
        $U.VerOnlineAt.Text = '離線：還沒有成功查詢過線上版本，「最新版本」使用設定檔的值（可在「設定」分頁修改）'
        $U.VerOnlineAt.ForeColor = $cOrange
    }
    if ($script:LastOnlineResult -and -not $script:LastOnlineResult.Ok) {
        $U.VerOnlineAt.Text = "離線（剛才查詢失敗）。$($U.VerOnlineAt.Text)"; $U.VerOnlineAt.ForeColor = $cOrange
    }
    $script:VersionsLoaded = $true
}

function Invoke-DriverInstallFromUi {
    $dir = $U.VerDrvDir.Text.Trim()
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { [void][System.Windows.Forms.MessageBox]::Show('請先選擇驅動資料夾。', 'CamNetTool', 'OK', 'Warning'); return }
    $infs = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)
    if (-not $infs.Count) { [void][System.Windows.Forms.MessageBox]::Show("這個資料夾裡沒有 .inf 檔：`n$dir", 'CamNetTool', 'OK', 'Warning'); return }
    if (-not $script:IsAdmin) {
        $r = [System.Windows.Forms.MessageBox]::Show('安裝驅動需要系統管理員權限。要以系統管理員身分重新開啟本工具嗎？', 'CamNetTool', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Restart-AsAdmin }
        return
    }
    $acq = Get-AcquisitionProcesses
    if ($acq.Count) {
        [void][System.Windows.Forms.MessageBox]::Show(("請先關閉取像程式再安裝驅動：`n" + (($acq | ForEach-Object { "$($_.Name)（PID $($_.Id)）" }) -join "`n")), 'CamNetTool', 'OK', 'Warning'); return
    }
    $a = Get-SelectedAdapter
    $na = if ($a) { Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $a.Guid } | Select-Object -First 1 }
    $old = if ($na) { "$($na.DriverVersion)（$($na.DriverDate)）" } else { '?' }
    $r = [System.Windows.Forms.MessageBox]::Show(("要安裝這個資料夾裡的驅動嗎？`n$dir`n（$($infs.Count) 個 .inf）`n`n目前版本：$old`n安裝時網卡會重新啟動，連線中斷約 5～10 秒。`n回復方法：裝置管理員 → 網卡 → 驅動程式 → 回復驅動程式。"), '安裝網卡驅動', 'OKCancel', 'Warning', 'Button2')
    if ($r -ne 'OK') { return }
    $before = @{}
    if (Get-Command Get-OptimizeChecks -ErrorAction SilentlyContinue) { try { foreach ($c in (Get-OptimizeChecks $a.Guid)) { $before[$c.Id] = $c.Current } } catch { } }
    Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 61 -Severity Warning -Message "開始安裝網卡驅動：$dir（目前 $old，執行者 $env:USERDOMAIN\$env:USERNAME）" -NoAlarm
    $U.VerDrvState.Text = '安裝中…（可能需要 1 分鐘）'; $U.VerDrvState.ForeColor = $cOrange
    $form.Cursor = 'WaitCursor'
    $outFile = Join-Path $env:TEMP 'CamNetTool_pnputil.txt'
    try {
        $p = Start-Process -FilePath 'pnputil.exe' -ArgumentList "/add-driver `"$dir\*.inf`" /subdirs /install" -NoNewWindow -PassThru -RedirectStandardOutput $outFile
        while (-not $p.HasExited) { Start-Sleep -Milliseconds 200; [System.Windows.Forms.Application]::DoEvents() }
    } finally { $form.Cursor = 'Default' }
    $outText = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
    Start-Sleep -Seconds 5
    $na2 = if ($a) { Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $a.Guid } | Select-Object -First 1 }
    $new = if ($na2) { "$($na2.DriverVersion)（$($na2.DriverDate)）" } else { '?' }
    $sev = if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { 'Info' } else { 'Warning' }
    Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 62 -Severity $sev -Message ("網卡驅動安裝結束（pnputil 結束碼 {0}）：{1} → {2}。{3}" -f $p.ExitCode, $old, $new, (($outText -replace '\s+', ' ').Trim() | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ } })) -NoAlarm
    $U.VerDrvState.Text = "結束碼 $($p.ExitCode)：$old → $new"
    $U.VerDrvState.ForeColor = if ($sev -eq 'Info') { $cGreen } else { $cRed }
    # 重新檢查最佳化設定，找出被新驅動重設的項目
    if (Get-Command Update-OptimizeTab -ErrorAction SilentlyContinue) { Update-OptimizeTab }
    Update-VersionsTab
    [void][System.Windows.Forms.MessageBox]::Show("驅動安裝結束：$old → $new`n`n請到「最佳化設定」分頁確認設定有沒有被重設（被重設的項目會標示出來）。", 'CamNetTool', 'OK', 'Information')
}
