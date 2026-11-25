#Requires -Version 5.1
# CamNetTool -「診斷快照」：啟動 lib\DiagRun.ps1（獨立行程，可單獨以系統管理員執行），分頁顯示進度

function Get-DiagRoot {
    $d = Join-Path $script:AppDir 'Diag'
    # 快照裡的檔名較長，資料夾路徑太長時改放 %LOCALAPPDATA%（Windows 路徑上限 260）
    if ($d.Length -gt 140 -or -not (Test-DirWritable $d)) { $d = Join-Path (Get-FallbackDir) 'Diag' }
    if (-not (Test-Path -LiteralPath $d)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    return $d
}

# 啟動診斷快照；回傳 @{ Process; ProgressFile; OutRoot }
function Start-DiagSnapshot([string]$Label, [datetime]$Incident, [int]$CaptureSec, [bool]$Elevate, [string]$AdapterGuid, [string]$CameraIp) {
    $root = Get-DiagRoot
    $prog = Join-Path $env:TEMP ('CamNetTool_diag_{0}.txt' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($prog, '')
    $script_ = Join-Path $script:LibDir 'DiagRun.ps1'
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script_`"",
        '-AppDir', "`"$($script:AppDir)`"", '-OutRoot', "`"$root`"", '-Label', "`"$Label`"",
        '-IncidentTime', "`"$($Incident.ToString('yyyy-MM-dd HH:mm:ss'))`"", '-CaptureSec', $CaptureSec, '-ProgressFile', "`"$prog`"")
    if ($AdapterGuid) { $args_ += @('-AdapterGuid', "`"$AdapterGuid`"") }
    if ($CameraIp) { $args_ += @('-CameraIp', $CameraIp) }
    $sp = @{ FilePath = 'powershell.exe'; ArgumentList = ($args_ -join ' '); PassThru = $true; WindowStyle = 'Hidden' }
    if ($Elevate) { $sp.Verb = 'RunAs' }
    $p = Start-Process @sp
    return @{ Process = $p; ProgressFile = $prog; OutRoot = $root; Started = Get-Date }
}

function Initialize-DiagTab($Page) {
    $warn = New-Ctl Label $Page 12 10 1120 26 '⚠ 執行前請注意：不要關 LabVIEW 程式、不要開 MAX、不要拔網路線。要在「卡住的狀態」下收集，資料才有用。'
    $warn.Font = $fBold; $warn.ForeColor = $cRed
    $desc = New-Ctl Label $Page 12 38 1120 40 ('會收集：網卡資訊與進階設定、PCIe、IP / ARP、電源設定、軟體版本、程式與 UDP 埠、事件記錄（evtx）、排程工作、' +
        '以相機 IP 過濾的封包擷取（有影像串流時只抓標頭 5 秒），以及相機的 Discovery、控制權（CCP 連續 5 秒）、所有監控暫存器 3 輪、GenICam XML。只讀取，不會改任何設定。約 1～2 分鐘。')
    $desc.ForeColor = $cGray

    [void](New-Ctl Label $Page 12 88 60 22 '標籤')
    $U.DiagLabel = New-Ctl ComboBox $Page 76 86 150 24
    [void]$U.DiagLabel.Items.AddRange(@('stuck', 'before_fw', 'after_fix', 'normal'))
    $U.DiagLabel.Text = 'stuck'
    [void](New-Ctl Label $Page 240 88 70 22 '事發時間')
    $U.DiagTime = New-Ctl DateTimePicker $Page 312 86 190 24
    $U.DiagTime.Format = 'Custom'; $U.DiagTime.CustomFormat = 'yyyy-MM-dd HH:mm:ss'
    [void](New-Ctl Label $Page 516 88 130 22 '封包擷取（秒）')
    $U.DiagCap = New-Ctl NumericUpDown $Page 646 86 60 24
    $U.DiagCap.Minimum = 5; $U.DiagCap.Maximum = 120; $U.DiagCap.Value = 30
    $U.DiagElev = New-Ctl CheckBox $Page 724 86 400 24 '以系統管理員執行（封包擷取與 evtx 需要，會跳出確認視窗）'
    $U.DiagElev.Checked = -not $script:IsAdmin
    $U.DiagElev.Visible = -not $script:IsAdmin

    $U.DiagRun = New-Ctl Button $Page 12 120 260 40 '出事了，收集資料'
    $U.DiagRun.Font = $fBig; $U.DiagRun.ForeColor = $cRed
    $U.DiagOpen = New-Ctl Button $Page 284 126 140 30 '開啟快照資料夾'
    $U.DiagState = New-Ctl Label $Page 436 130 700 24 ''
    $U.DiagState.Font = $fBold

    $U.DiagLog = New-Object System.Windows.Forms.TextBox
    $U.DiagLog.Multiline = $true; $U.DiagLog.ReadOnly = $true; $U.DiagLog.ScrollBars = 'Vertical'
    $U.DiagLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $U.DiagLog.Location = New-Object System.Drawing.Point(12, 170)
    $U.DiagLog.Size = New-Object System.Drawing.Size(1124, 590)
    $U.DiagLog.Anchor = 'Top,Bottom,Left'
    $U.DiagLog.BackColor = [System.Drawing.Color]::White
    $Page.Controls.Add($U.DiagLog)

    $script:DiagJob = $null
    $script:DiagTimer = New-Object System.Windows.Forms.Timer
    $script:DiagTimer.Interval = 1000
    $script:DiagTimer.Add_Tick({ try { Update-DiagProgress } catch { } })

    $U.DiagOpen.Add_Click({ Invoke-Safe { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Get-DiagRoot)`"" } })
    $U.DiagRun.Add_Click({ Invoke-Safe { Invoke-DiagFromUi } })
}

function Invoke-DiagFromUi {
    if ($script:DiagJob -and -not (Test-DiagExited $script:DiagJob)) { Set-StatusMessage '診斷快照還在執行中。' -Sticky; return }
    $r = [System.Windows.Forms.MessageBox]::Show("要開始收集診斷資料嗎？`n`n請確認：不要關 LabVIEW、不要開 MAX、不要拔線。`n約 1～2 分鐘，期間監控照常進行。", '診斷快照', 'OKCancel', 'Warning')
    if ($r -ne 'OK') { return }
    $a = Get-SelectedAdapter
    $ip = if ($script:S -and $script:S.CameraIp) { $script:S.CameraIp } else { $U.TxtIp.Text.Trim() }
    $U.DiagLog.Clear()
    try {
        $script:DiagJob = Start-DiagSnapshot $U.DiagLabel.Text $U.DiagTime.Value ([int]$U.DiagCap.Value) ($U.DiagElev.Visible -and $U.DiagElev.Checked) $(if ($a) { $a.Guid } else { '' }) $ip
    } catch {
        if ($_.Exception.Message -match '取消|cancel') { $U.DiagState.Text = '已取消（沒有同意系統管理員權限）。可取消勾選「以系統管理員執行」後再試。'; $U.DiagState.ForeColor = $cOrange; return }
        throw
    }
    $script:DiagJob.Read = 0
    $U.DiagRun.Enabled = $false
    $U.DiagState.Text = '收集中…'; $U.DiagState.ForeColor = $cOrange
    $script:DiagTimer.Start()
    Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 50 -Severity Info -Message "開始診斷快照（標籤 $($U.DiagLabel.Text)）"
}

# 以系統管理員啟動的行程，一般權限可能讀不到結束狀態：讀不到就看是否超過 10 分鐘
function Test-DiagExited($Job) {
    try { return $Job.Process.HasExited } catch { return ((Get-Date) - $Job.Started).TotalMinutes -gt 10 }
}

function Update-DiagProgress {
    $j = $script:DiagJob
    if (-not $j) { $script:DiagTimer.Stop(); return }
    $text = ''
    try {
        $fs = New-Object IO.FileStream($j.ProgressFile, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $text = $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { }
    if ($text.Length -gt $j.Read) {
        $new = $text.Substring($j.Read); $j.Read = $text.Length
        $U.DiagLog.AppendText(($new -replace '(?m)^DONE\|.*\r?\n?', ''))
    }
    $done = [regex]::Match($text, '(?m)^DONE\|(.+?)\s*$')
    $sec = [int]((Get-Date) - $j.Started).TotalSeconds
    if ($done.Success) {
        $script:DiagTimer.Stop()
        $zip = $done.Groups[1].Value
        $U.DiagState.Text = "完成（$sec 秒）：$zip"; $U.DiagState.ForeColor = $cGreen
        $U.DiagRun.Enabled = $true
        Add-MonitorEvent -Time (Get-Date) -Source $script:AppName -EventId 51 -Severity Info -Message "診斷快照完成：$zip"
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$zip`"" } catch { }
        [void][System.Windows.Forms.MessageBox]::Show("診斷快照完成。`n`n請把這個檔案上傳：`n$zip", '診斷快照', 'OK', 'Information')
        try { Remove-Item -LiteralPath $j.ProgressFile -Force } catch { }
        $script:DiagJob = $null
    } elseif ((Test-DiagExited $j) -and $sec -gt 5) {
        $script:DiagTimer.Stop()
        $U.DiagState.Text = "診斷快照中途結束（結束碼 $($j.Process.ExitCode)），請看上方訊息。"; $U.DiagState.ForeColor = $cRed
        $U.DiagRun.Enabled = $true
        $script:DiagJob = $null
    } else {
        $U.DiagState.Text = "收集中…（$sec 秒）"
    }
}
