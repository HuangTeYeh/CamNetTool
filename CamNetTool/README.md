# CamNetTool 使用說明

10GigE 相機整合工具，以 NicMonitor 1.1.0 為基礎擴充，分成五個分頁：

- **監控**：網卡與相機。
- **診斷快照**
- **最佳化設定**
- **版本與更新**
- **設定**

只用 Windows 內建的 PowerShell 5.1，不需要安裝任何東西。

## 檔案

| 檔案 | 用途 |
|---|---|
| `Start_CamNetTool.bat` | **平常用這個**。雙擊開啟，不會出現命令視窗 |
| `CamNetTool_debug.bat` | 出問題時用，會保留命令視窗並 `pause` |
| `CamNetTool.ps1` | 主程式（UTF-8 with BOM） |
| `lib\CamNetNative.cs` | GigE Vision 通訊、GenICam XML 解析、封包擷取分析（啟動時自動編譯） |
| `lib\Camera.ps1` | 相機監控 |
| `lib\DiagRun.ps1`、`lib\Diag.ps1` | 診斷快照（獨立行程執行） |
| `lib\Optimize.ps1` | 最佳化設定 |
| `lib\Versions.ps1` | 版本與更新 |
| `lib\SettingsTab.ps1` | 設定分頁 |
| `CamNetTool_LOG解讀指南.md` | 記錄檔欄位與事件的說明（可以給其他 AI 讀） |

下面這些是**執行後自動產生**的，複製到新電腦時不需要帶：

| 檔案 | 用途 |
|---|---|
| `CamNetTool.config.json` | 設定檔。第一次使用時會沿用同資料夾或上一層資料夾 NicMonitor 的網卡、相機 IP、間隔；都沒有時自動選 AQtion 網卡 |
| `CamNetToolLog\` | 記錄檔 |
| `CamNetToolData\` | 相機 XML 快取、最佳化設定的備份（`backup\backup_*.json`）、最近一次封包擷取的實測值 |
| `Diag\` | 診斷快照的 zip |

整個資料夾複製到其他電腦就能用。相機 IP、序號、韌體不同都沒關係：暫存器位址一律從相機的 XML 解析。

> 不要把一台電腦的 `CamNetTool.config.json` 複製到另一台：裡面有那台的網卡 GUID、相機序號與事件記錄位置。

## 相機 IP 不用自己查

「相機 IP」旁邊的 **自動偵測** 預設是勾選的。

- 開啟程式時會自動找相機，找到的 IP 直接填進欄位，ping 和相機監控都用它。
- 找相機的順序：先用 GigE Vision Discovery（從相機網卡廣播），找不到再看 ARP 表。
- 監控中如果相機連續沒有回應，每分鐘會重新偵測一次。相機重開機後 169.254.x.x 位址換了，也會自動跟上，並記一筆事件 111。
- 隨時可以按「偵測相機」重新找。

## ping 從相機網卡送出

相機 ping 一律從**所選網卡**上與相機同網段的 IP 送出，效果等同 `ping -S <網卡 IP> <相機 IP>`（Windows API `IcmpSendEcho2Ex`）。

- **為什麼**：一般的 ping 由路由表決定從哪張網卡出去。機台有多張網卡、網段設定不理想（例如兩張都是 169.254.x.x）時，ping 可能從別張網卡送出，結果不可信。
- **畫面**：顯示「0 ms（169.254.192.4 → 169.254.23.146）」，箭頭前是送出的網卡 IP。
- **網卡沒有 IPv4 時**：不送 ping，記為 `Fail:NoSourceIp`，**不會**改從別張網卡送。
- **來源 IP 改變**（例如 DHCP、重新設定 IP）：ping 失敗時每 30 秒重新查一次網卡 IP，改變時記一筆事件 22。
- 診斷快照的 ping 也是從相機網卡送出。

## 監控

上方左邊是網卡，右邊是相機。大字的顏色：

| 顏色 | 意思 |
|---|---|
| 綠 | 正常 |
| 紅 | 斷線、相機卡住、相機無回應 |
| 橘 | 觀察中、ping 不通、被獨占控制 |
| 灰 | 未取像、等待觸發 |

相機狀態會顯示：

- 溫度、功耗
- 開機時間、連線時間
- **送影像速率**：由網卡流量推算，以及設定值
- 傳送狀態、相機內佇列
- 控制者（IP:port）、串流埠
- 重送次數（本次、監控累計、相機累計）、無法重送次數
- 頻寬限制

### 「相機卡住」的判斷（與規格不同的地方）

規格的條件是「有控制者 + Streaming = 1 + TransmissionFrameTime = 0」。

但這台相機（ATX245S-C，韌體 1.21.0.0）實測時，**TransmissionFrameTime 在正常送影像（10 fps、約 246 MB/s）時也一直是 0**。照規格的條件，正常取像時也會誤判成卡住。

所以改成：

> **有控制者（CCP ≠ 0）+ Streaming = 1 + 相機網卡幾乎沒有收到資料**，連續 N 次（預設 3）

相機是直連的，網卡流量就是影像流量。另外：

- **TriggerMode = On** 時，沒有影像就顯示「等待觸發」，不算卡住。
- **Streaming = 0** 或沒有控制者時，顯示「未取像」。

### 「接收丟棄」修正（規格 3.1）

AQtion 驅動回報的 64 位元計數：

- **高 32 位元**才是真正的丟棄數。實測 45 小時共 66,479 個，約每小時 1,500 個，和規格「每小時約 1,100～1,200 個」同一個量級。
- **低 32 位元**是不相干的值，而且會自己變動（實測一次 +12,794、+27,776，甚至 +1,866,458,126）。

修正方式：

- AQtion 網卡，或這次監控已經偵測到這種格式時，**一律取高 32 位元的差**，放在 `RxDiscardDelta`。
- 原始差值另存在最後一欄 `RxDiscardDeltaRaw`。
- 一般驅動，或計數值小於 2³²（例如新版驅動已經修正），照原值計算。

> 2.0.0 版（2026-11-23～25，事件 1 會寫版本）只在差值 ≥ 2³¹ 時才取高 32 位元，2.0.1 已修正。高 32 位元沒變、只有低 32 位元變了的那幾次，會被誤算成大量丟棄：45 小時累計被算成 261 億，實際約 6.6 萬。舊記錄請改用 `round(RxDiscardDeltaRaw ÷ 2³²)`。

### 記錄檔（CSV 欄位固定）

- **`status_yyyyMMdd.csv`**：NicMonitor 1.1.0 的 17 欄全部保留，最後加 `RxDiscardDeltaRaw`。
- **`camstatus_yyyyMMdd.csv`**：相機，30 欄。
  - 欄位：`Time, Gvcp, GvcpMs, CameraIp, TempC, PowerW, UpTimeS, LinkUpTimeS, AcqFps, TxFrameTimeUs, EstFps, RxMBps, TriggerMode, TransferStatusSel, Streaming, QueueCur, QueueMax, ResendRecv, ResendRecvDelta, ResendValid, ResendUnavail, ResendUnavailDelta, ThroughputLimitMode, ThroughputLimitBps, ThroughputReserve, CCP, Controller, SCP0Port, SCPD0, CamState`
  - 相機無回應時，其他欄留空，但每一列都有全部欄位。
- **`events_yyyyMMdd.csv`**：網卡、相機、最佳化設定的事件都在這裡（`Source` 欄分辨）。

Excel 開著原始檔也不會遺失資料：會先暫存，之後補寫。看記錄請按「用 Excel 開啟今日記錄」，它會先複製一份再開。

### 事件編號

| EventId | 來源 | 等級 | 意義 |
|---|---|---|---|
| 1 / 2 | CamNetTool | 資訊 | 監控開始 / 結束（含統計） |
| 10～13 | CamNetTool | 警告 | 網卡斷線、恢復、狀態改變、速度改變 |
| 20 / 21 | CamNetTool | 警告 / 資訊 | 相機 ping 失敗 / 恢復 |
| 22 | CamNetTool | 資訊 | 相機 ping 的來源 IP 改變 |
| 30 | CamNetTool | 資訊 | 網卡計數器歸零 |
| 40 | CamNetTool | 警告 | 網卡驅動內部重置（需系統管理員） |
| 50 / 51 | CamNetTool | 資訊 | 診斷快照開始 / 完成 |
| 60～62 | CamNetTool | 資訊 / 警告 | 線上查詢版本、網卡驅動安裝 |
| 90 / 91 | CamNetTool | 資訊 | 主機板溫度 / 網卡晶片溫度無法讀取 |
| **100 / 101** | Camera | **錯誤＋聲音** / 資訊 | **相機卡住** / 卡住狀態結束 |
| **102 / 103** | Camera | **錯誤＋聲音** / 資訊 | **相機無回應**（GVCP 重試 3 次）/ 恢復 |
| 104 / 105 | Camera | 警告 | 相機重開機（DeviceUpTime 變小）/ 連線重置（LinkUpTime 變小） |
| 106 | Camera | 資訊 / 警告 | 控制權取得 / 釋放 |
| 107 / 108 | Camera | 警告 | 重送暴增（單次 ≥ 500）/ 無法重送 |
| 109 | Camera | 警告 | 相機溫度 ≥ 60 °C |
| 110 | Camera | 警告 | XML 與上次不同（例如更新韌體後），已自動重新解析 |
| 111 | Camera | 警告 | 相機 IP 改變（自動偵測） |
| 112 | Camera | 警告 | 頻寬限制未生效（用本工具套用過，但取像中讀到 Off） |
| 113 | Camera | 警告 | 公式改變，請確認 |
| 114 / 115 | Camera | 資訊 | 相機連線資訊 / XML 中無法使用的項目 |
| 116 | Camera | 警告 | ACCESS_DENIED（有程式獨占控制相機） |
| 200～202 | Optimize | 警告 | 已套用 / 已復原 / 失敗（含修改前後的值與執行者） |

監控只送 READREG / READMEM（唯讀），每個週期約 37 個暫存器，用一個封包讀完（約 2 ms）。不會影響取像程式的控制權。

## 診斷快照

出事時按 **「出事了，收集資料」**。執行前請注意：**不要關 LabVIEW、不要開 MAX、不要拔線。**

- 會收集網卡、PCIe、IP / ARP、電源設定、軟體版本、程式與 UDP 埠、事件記錄（evtx）、排程工作。
- **封包擷取**以相機 IP 過濾 30 秒；有影像串流時，改成只抓標頭 5 秒。
- **相機探測**：Discovery、bootstrap、CCP 連續 5 秒、所有監控暫存器 3 輪、GenICam XML。
- 約 1～2 分鐘（實測 87 秒），期間監控照常進行。
- 封包擷取與 evtx 需要系統管理員權限。勾選「以系統管理員執行」時，只有快照本身會跳出確認視窗。
- 完成後產生 `CamDiag_<標籤>_<時間>.zip`，並提示上傳。解壓後的資料夾會刪掉，只留 zip 與 `_summary.txt`。

### 封包擷取分析（對應 reference 的 `fast_pcapng.py`、`resend_check.py`）

快照會自動分析 pktmon 的擷取檔，寫進 `summary.txt`：

- 每張影像的封包數、送完時間、突發速率、缺漏
- 電腦送出的 PACKETRESEND（0x0040）
- **被要求重送的封包，原本有沒有出現在擷取中**
  - 沒有出現：封包在擷取點之前（網卡接收環）就被丟掉，請先調大 Receive Buffers。
  - 有出現：遺失發生在 Windows 網路堆疊或取像程式。

也可以分析別台的擷取檔：

```
powershell -ExecutionPolicy Bypass -File lib\DiagRun.ps1 -AppDir . -OutRoot D:\out -NoCapture -AnalyzePcap D:\capture.pcapng
```

> **這台電腦的實測與 L5 不同**：每張影像同樣是 2,733 個封包，但約 **19.8 ms** 送完，突發約 **1,238 MB/s**，接近 10G 線速。L5 是 49.5 ms、494 MB/s。
>
> 「最佳化設定」計算 Receive Buffers 緩衝時間時，會用最近一次快照的實測值；還沒有快照時用 494 MB/s。

## 最佳化設定

每個寫入動作的流程都一樣：

1. 選一列。
2. 按「修正」或「復原」。
3. 確認視窗。
4. 寫入，並讀回驗證。
5. 記錄事件 200 / 201：修改前、修改後、時間、執行者。

修改前的值存在 `CamNetToolData\backup\`，可以復原。

| # | 項目 | 建議 | 修正方式 |
|---|---|---|---|
| 1 | **網卡 Receive Buffers（最優先）** | 驅動允許的最大值，並顯示約可緩衝幾 ms | `Set-NetAdapterAdvancedProperty`（網卡會重新啟動 5～10 秒） |
| 2 | Jumbo Packet | 9014 | 只檢查 |
| 3 | Interrupt Moderation | Enabled / Adaptive | 只檢查 |
| 4 | EEE | Disabled | 可修正 |
| 4b | Flow Control | 先只顯示目前的值（例如「Disabled（關閉）」），不給建議值 | 只顯示 |
| 5 | 網卡電源管理 | 不允許關閉裝置 | `Get-NetAdapterPowerManagement` 在這台會失敗，改讀寫登錄檔 `PnPCapabilities` |
| 6 | PCIe ASPM | 關閉 | `powercfg` |
| 7 | GigE 過濾驅動 | 只保留取像軟體需要的那一個（IMAQdx → 保留 NI 的） | `Disable-` / `Enable-NetAdapterBinding` |
| 7b | 非 GigE 驅動（VirtualBox、VMware、Hyper-V、VPN、防火牆／防毒、Npcap 等） | 在相機網卡上取消勾選。每個元件一列，標示類別；沒有時顯示「沒有」 | `Disable-` / `Enable-NetAdapterBinding`（可修正、可復原）。Windows 內建（`ms_*`）不列出 |
| 8 | 相機頻寬限制（**次要**） | 先不改。Receive Buffers 調大後仍有重送，再試 On、約 300 MB/s | 相機寫入，存到 UserSet1 並設為開機預設 |
| 9 | DeviceLinkThroughputReserve | 10% 以上 | 相機寫入 |
| 10 | Heartbeat 逾時 | 維持 | 只檢查 |

- **相機寫入的前提**：
  - CCP = 0，而且沒有取像程式在執行（Application.exe、LabVIEW、NI MAX）。不符合時按鈕不能按，並顯示原因。
  - 寫入流程：CCP = 2 → 每秒 heartbeat → WRITEREG → 讀回驗證 → CCP = 0。中途失敗也一定會釋放控制權。
- **被驅動更新重設**：用本工具套用過的網卡設定會記下來。之後如果變回別的值（例如更新驅動後），該列會標示「被重設」。
- **效果比較**：選一個套用時間按「計算」，會顯示套用前、後各 1 小時的網卡丟棄與相機重送次數。

## 版本與更新

- 顯示相機韌體、網卡驅動、網卡韌體、Arena SDK、Arena Lwf、NI-IMAQdx 的版本，並和最新版比較，例如「落後：1.21.0.0 → 1.54.0.0（次版本號差 33）」。
- **線上查詢**：
  - 相機韌體：用 LUCID 網站的搜尋 API 找「Atlas10 vX Firmware Release Notes」。下載清單要登入才看得到，所以不從下載頁抓。
  - Arena SDK：讀下載頁說明中的版本。實測下載頁寫的是 **1.0.65.17**（2025-12-11），比規格的 1.0.85.11 舊，所以取兩者中較新的，並在訊息中說明。
- 畫面會顯示最後一次成功查詢的時間；沒網路時標示「離線」，改用設定檔的值。
- **網卡驅動**：選擇解壓後的資料夾，按「安裝驅動」（`pnputil /add-driver … /subdirs /install`）。
  - 需要系統管理員權限，而且取像程式要先關閉。
  - 安裝後會自動重新檢查最佳化設定。
- **相機韌體**：本工具不直接燒錄，提供「開啟 ArenaView」與「更新前先做診斷快照」。
- **網卡韌體**：不建議主動更新。

## 建議的上線順序（規格第 10 節）

1. 先在 LabVIEW 加自動恢復（Stop/Start → Close/Open → DeviceReset）。
2. 在一台機台先調 **Receive Buffers**，再處理過濾驅動。觀察 3～7 天，重送次數應該接近 0；沒有的話再考慮頻寬限制。
3. 更新網卡驅動，再觀察。
4. 更新 Arena SDK 和相機韌體，再觀察。
5. 確認有效後再推到其他機台。每次只改一項。

## 需要現場確認的項目

1. **拔線測試**：拔掉相機網路線，應該出現網卡斷線（10）與相機無回應（102）；插回後兩者都恢復。
2. **相機卡住**：無法人為製造。判斷邏輯已用規格附的 L5 卡住讀值測試過。
3. **相機寫入**（頻寬限制、Reserve）：需要關閉 NI MAX / LabVIEW 才能測。
4. **網卡設定寫入**（過濾驅動、Receive Buffers）與驅動安裝：需要系統管理員權限，網卡會重新啟動。
5. 連續執行 72 小時的記憶體與 CPU。

## 測試

自動測試（`tests\CoreTests.ps1`，共 53 項）不包含在產線版裡，放在開發用的電腦上。測試只做讀取，不會寫入相機或網卡設定。
