#Requires -Version 5.1
# CamNetTool -「設定」分頁（由 CamNetTool.ps1 在建立視窗後 dot-source）

$gS1 = New-Ctl GroupBox $tabSet 10 10 560 190 '相機事件門檻'
[void](New-Ctl Label $gS1 14 28 300 22 '連續幾次沒有影像進來才判定「相機卡住」')
$U.SetStall = New-Ctl NumericUpDown $gS1 330 26 70 24
$U.SetStall.Minimum = 1; $U.SetStall.Maximum = 60
[void](New-Ctl Label $gS1 14 60 300 22 '單次取樣重送次數達到多少就警告')
$U.SetResend = New-Ctl NumericUpDown $gS1 330 58 90 24
$U.SetResend.Minimum = 1; $U.SetResend.Maximum = 1000000
[void](New-Ctl Label $gS1 14 92 300 22 '相機溫度警告值（°C）')
$U.SetTemp = New-Ctl NumericUpDown $gS1 330 90 70 24
$U.SetTemp.Minimum = 30; $U.SetTemp.Maximum = 100
$noteS1 = New-Ctl Label $gS1 14 124 530 56 '「卡住」的判斷：有程式控制相機（CCP ≠ 0）、相機自認在傳送（TransferStatus Streaming = 1），但相機網卡幾乎沒有收到資料。這台相機韌體的 TransmissionFrameTime 在正常送影像時也是 0，所以改用網卡流量判斷。'
$noteS1.ForeColor = $cGray

$gS2 = New-Ctl GroupBox $tabSet 10 206 560 150 '最佳化設定'
[void](New-Ctl Label $gS2 14 28 200 22 '取像軟體')
$U.SetSoft = New-Ctl ComboBox $gS2 220 26 200 24
$U.SetSoft.DropDownStyle = 'DropDownList'
[void]$U.SetSoft.Items.AddRange(@('IMAQdx', 'Arena'))
[void](New-Ctl Label $gS2 14 60 200 22 '相機頻寬限制目標（MB/s）')
$U.SetLimit = New-Ctl NumericUpDown $gS2 220 58 90 24
$U.SetLimit.Minimum = 50; $U.SetLimit.Maximum = 1250
$noteS2 = New-Ctl Label $gS2 14 90 530 50 '取像軟體決定要保留哪一個 GigE 過濾驅動（用 IMAQdx 就保留 NI 的）。頻寬限制是次要項目，預設 300 MB/s（每張約 82 ms，仍在 100 ms 週期內）。'
$noteS2.ForeColor = $cGray

$gS3 = New-Ctl GroupBox $tabSet 580 10 560 346 '版本（沒有網路時使用這些值）'
$gS3.Anchor = 'Top,Left,Right'
$y = 28
foreach ($row in @(
        @{ K = 'LatestCameraFw'; T = '相機韌體最新版' }, @{ K = 'LatestCameraFwDate'; T = '　發布日期' },
        @{ K = 'LatestNicDriver'; T = '網卡驅動最新版' }, @{ K = 'LatestArenaSdk'; T = 'Arena SDK 最新版' }, @{ K = 'LatestArenaSdkDate'; T = '　發布日期' },
        @{ K = 'LucidProductUrl'; T = 'LUCID 產品頁' })) {
    [void](New-Ctl Label $gS3 14 $y 130 22 $row.T)
    $U["Set_$($row.K)"] = New-Ctl TextBox $gS3 150 ($y - 2) 396 24
    $U["Set_$($row.K)"].Anchor = 'Top,Left,Right'
    $y += 32
}
[void](New-Ctl Label $gS3 14 $y 130 22 '網卡驅動資料夾')
$U.SetDrvDir = New-Ctl TextBox $gS3 150 ($y - 2) 316 24
$U.SetDrvDir.Anchor = 'Top,Left,Right'
$U.SetDrvBrowse = New-Ctl Button $gS3 472 ($y - 3) 74 26 '選擇…'
$U.SetDrvBrowse.Anchor = 'Top,Right'

$U.SetSave = New-Ctl Button $tabSet 10 368 140 32 '儲存設定'
$U.SetSave.Font = $fBold
$U.SetCfgPath = New-Ctl Label $tabSet 160 374 900 22 ''
$U.SetCfgPath.ForeColor = $cGray

function Update-SettingsTab {
    $c = $script:Cfg
    $U.SetStall.Value = [math]::Max(1, [math]::Min(60, [int]$c.StallSamples))
    $U.SetResend.Value = [math]::Max(1, [int]$c.ResendWarn)
    $U.SetTemp.Value = [math]::Max(30, [math]::Min(100, [int]$c.CamTempWarnC))
    $U.SetSoft.SelectedItem = if ($c.AcquisitionSoftware -eq 'Arena') { 'Arena' } else { 'IMAQdx' }
    $U.SetLimit.Value = [math]::Max(50, [math]::Min(1250, [int]([double]$c.ThroughputLimitTarget / 1e6)))
    foreach ($k in 'LatestCameraFw', 'LatestCameraFwDate', 'LatestNicDriver', 'LatestArenaSdk', 'LatestArenaSdkDate', 'LucidProductUrl') { $U["Set_$k"].Text = [string]$c[$k] }
    $U.SetDrvDir.Text = [string]$c.DriverFolder
    $U.SetCfgPath.Text = "設定檔：$($script:ConfigPath)"
}

$U.SetDrvBrowse.Add_Click({ Invoke-Safe {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇已解壓縮的 Marvell AQtion Windows 驅動資料夾（裡面有 .inf）'
    if ($U.SetDrvDir.Text) { $dlg.SelectedPath = $U.SetDrvDir.Text }
    if ($dlg.ShowDialog($form) -eq 'OK') { $U.SetDrvDir.Text = $dlg.SelectedPath }
    $dlg.Dispose()
} })

$U.SetSave.Add_Click({ Invoke-Safe {
    $c = $script:Cfg
    $c.StallSamples = [int]$U.SetStall.Value
    $c.ResendWarn = [int]$U.SetResend.Value
    $c.CamTempWarnC = [int]$U.SetTemp.Value
    $c.AcquisitionSoftware = [string]$U.SetSoft.SelectedItem
    $c.ThroughputLimitTarget = [int]$U.SetLimit.Value * 1000000
    foreach ($k in 'LatestCameraFw', 'LatestCameraFwDate', 'LatestNicDriver', 'LatestArenaSdk', 'LatestArenaSdkDate', 'LucidProductUrl') { $c[$k] = $U["Set_$k"].Text.Trim() }
    $c.DriverFolder = $U.SetDrvDir.Text.Trim()
    Save-Config
    Set-StatusMessage '設定已儲存。' -Sticky
    if ($script:OnSettingsSaved) { try { & $script:OnSettingsSaved } catch { } }
} })

Update-SettingsTab
