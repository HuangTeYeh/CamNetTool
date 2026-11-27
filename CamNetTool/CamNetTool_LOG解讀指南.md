# CamNetTool 2.0.2 記錄檔解讀指南（給 AI 與分析人員）

本文件說明 CamNetTool 做了什麼、產生哪些檔案、每個欄位與事件的意義，以及如何從記錄判斷問題。讀者不需要看程式碼，就能正確解讀 CamNetTool 產出的記錄。

---

## 1. 背景：這個程式在監控什麼

- **系統**：一台 Windows 10 工業電腦，經由一張 10GbE 網卡（Marvell / Aquantia AQtion，驅動名稱 `aqnic650`），**直連**一台 LUCID Atlas10 10GigE 相機。
  - 相機型號：ATX245S-C，24.5 MP。
  - 取像軟體：LabVIEW + NI-IMAQdx（行程名稱 `Application.exe`、`LabVIEW`、`lvrt`），也可能是 NI MAX。
- **要解決的問題**：取像偶爾中斷，例如相機「卡住」、相機無回應、網卡丟封包、重送暴增。CamNetTool 持續記錄網卡與相機狀態，出事時能回頭比對。
- **相機與網卡直連**：網卡的接收流量（`RxMBps`）幾乎就等於相機送出的影像流量。
- **相機通訊協定**：GigE Vision。
  - 控制通道：GVCP（UDP 3956）。
  - 影像通道：GVSP。
- **CamNetTool 監控時只讀不寫**：
  - 對相機只送 READREG / READMEM，不會搶控制權、也不影響取像。
  - 對網卡只讀統計計數器。
- **只有「最佳化設定」分頁會寫入**，而且每次都需要人工按鈕、確認、留下事件記錄，並可以復原。

### 取樣週期

每個週期（設定 `IntervalSec`，常見為 5 或 10 秒）依序做：

1. **讀網卡計數器**：連線狀態、速度、接收位元組、丟棄、錯誤（Windows API `GetIfEntry2`）。
2. **ping 相機**：從所選網卡上與相機同網段的 IP 送出（等同 `ping -S`，Windows API `IcmpSendEcho2Ex`），不會經由別張網卡。2.0.1 以前用一般的 ping，由路由表決定從哪張網卡送出。
3. **讀 CPU 使用率與主機板 ACPI 溫度**。
4. **讀網卡晶片溫度與驅動內部重置計數**：AQtion WMI `Aq_DiagnosticsData`，需要系統管理員權限，約每 10 秒一次。
5. **讀相機約 37 個暫存器**：用一個 GVCP 封包讀完，約 2～7 ms。暫存器位址是從相機的 GenICam XML 解析出來的。
6. **檢查 Windows 系統事件記錄**中 `aqnic650` 與 `Microsoft-Windows-Kernel-Power` 的新事件。
7. **寫入記錄**：
   - `status` 和 `camstatus` 各寫一列。
   - 狀態有變化時，`events` 才寫一列。

---

## 2. 檔案位置與格式

| 路徑（相對於程式資料夾） | 內容 |
|---|---|
| `CamNetToolLog\status_yyyyMMdd.csv` | 網卡與電腦，每週期一列 |
| `CamNetToolLog\camstatus_yyyyMMdd.csv` | 相機，每週期一列 |
| `CamNetToolLog\events_yyyyMMdd.csv` | 事件（狀態改變、警告、操作紀錄） |
| `CamNetToolLog\unsaved_*.csv` | 程式結束時還寫不進原檔的資料（例如檔案被 Excel 鎖住） |
| `CamNetToolLog\status_yyyyMMdd_2.csv` 等 | 同一天的檔案若是舊版程式寫的（表頭不同），新資料改寫到 `_2`、`_3` |
| `Diag\CamDiag_<標籤>_<yyyyMMdd_HHmmss>.zip` | 診斷快照（見第 6 節） |
| `Diag\CamDiag_..._summary.txt` | 快照的文字摘要（zip 內的 `summary.txt` 複本） |
| `CamNetToolData\last_capture.json` | 最近一次封包擷取分析的實測值 |
| `CamNetToolData\backup\backup_*.json` | 最佳化設定修改前的值（可復原） |
| `CamNetToolData\xml\` | 相機 GenICam XML 快取 |
| `CamNetTool.config.json` | 設定 |

> 程式資料夾路徑太長時（超過約 140～250 字元），`Diag` 與 XML 快取會改放到 `%LOCALAPPDATA%\CamNetTool\`。

### CSV 共通規則

- 編碼為 **UTF-8 with BOM**，逗號分隔。第一列是表頭。
- **欄位數固定**：讀不到的值留空字串，不會省略欄位。
- 時間格式 `yyyy-MM-dd HH:mm:ss`，電腦本地時間，沒有時區。
- **每天一個檔案**，以寫入當下的日期為準。
- **`events` 不保證嚴格依時間排序**。例如「監控開始」(1) 的時間取自按下開始的瞬間，可能比緊接著寫入的 114 早 1 秒，但排在 114 後面。分析前請先依 `Time` 排序。
- 寫入有緩衝：Excel 鎖住檔案時資料先留在記憶體，解鎖後補寫，所以檔案的列序可能和時間略有出入。
- 數值中的小數點是 `.`，數字不含千分位。
- 中文欄位值：`Level` 欄是中文（資訊／警告／錯誤／過熱）。

---

## 3. `status_yyyyMMdd.csv`：網卡與電腦（18 欄）

前 17 欄與前身 NicMonitor 1.1.0 相同，第 18 欄為新增。

| # | 欄位 | 單位 / 值 | 說明 |
|---|---|---|---|
| 1 | `Time` | 時間 | 取樣時間 |
| 2 | `LinkStatus` | `Up` / `Disconnected` / `Missing` / 其他 | 網卡連線狀態。`Missing` = 找不到網卡（被停用或驅動重載中） |
| 3 | `LinkSpeed` | 文字，例如 `10 Gbps` | 只有 `Up` 時才有值 |
| 4 | `RxMBps` | MB/s（1 MB = 10⁶ bytes） | 這個週期的平均接收速率。**第一列一定是空的**（沒有前一筆可以相減）。正常 10 fps 取像約 246 MB/s；未取像時接近 0 |
| 5 | `RxDiscardDelta` | 封包數 | 這個週期的**接收丟棄**增量（已修正，見下方說明） |
| 6 | `RxErrorDelta` | 封包數 | 接收錯誤增量（CRC 等）。正常應為 0 |
| 7 | `TxDiscardDelta` | 封包數 | 傳送丟棄增量 |
| 8 | `TxErrorDelta` | 封包數 | 傳送錯誤增量 |
| 9 | `CameraPingMs` | ms 或 `Fail:<狀態>` | ping 相機的往返時間（從相機網卡送出）。失敗時為 `Fail:TimedOut`、`Fail:DestinationHostUnreachable` 等；`Fail:NoSourceIp` = 所選網卡沒有 IPv4，這次沒有送 ping。沒設定相機 IP 時是空的 |
| 10 | `CpuPercent` | % | 整台電腦 CPU 使用率。第一列是空的 |
| 11 | `AcpiTempC` | °C | 主機板 ACPI 溫度區域中最高的值。讀不到時整欄為空，並有事件 90 |
| 12 | `RxDiscardDeltaDiv2p32` | 數字 | 原始丟棄差值 ÷ 2³²，四捨五入到小數 2 位。NicMonitor 1.1.0 留下的欄位，約等於第 5 欄 |
| 13 | `NicMacTempC` | °C | 網卡 MAC 晶片溫度（需要系統管理員，否則為空，並有事件 91） |
| 14 | `NicPhyTempC` | °C | 網卡 PHY 溫度（同上） |
| 15 | `AqRxPathReset` | 累計次數 | 驅動內部「接收路徑重置」的**累計值**（不是增量） |
| 16 | `AqTxPathReset` | 累計次數 | 驅動內部「傳送路徑重置」的累計值 |
| 17 | `AqTxWatchdog` | 累計次數 | 驅動「傳送逾時 watchdog」的累計值 |
| 18 | `RxDiscardDeltaRaw` | 整數（可能很大） | 驅動回報的**原始**丟棄差值，未修正 |

### 重要：接收丟棄的修正（第 5、12、18 欄）

- **AQtion 驅動的 64 位元 `InDiscards` 計數**：真正的丟棄數在**高 32 位元**，低 32 位元是不相干的值，而且會自己變動。
- **原始差值看起來會很大**：例如 `RxDiscardDeltaRaw = 17179894833` ≈ 4 × 2³²，代表實際 4 個丟棄。也可能是 `27776` 或 `1866458126` 這種小於 2³² 的值，那是低 32 位元自己變動，實際丟棄 0 個。
- **CamNetTool 的修正方式**：AQtion 網卡，或這次監控已經偵測到這種格式時，一律取高 32 位元的差。一般驅動，或計數值小於 2³² 時，照原值計算。修正後的結果放在 `RxDiscardDelta`。
- **分析時請用 `RxDiscardDelta`**，不要用 `RxDiscardDeltaRaw`。
- **例外：2.0.0 版寫的記錄**（事件 1 的訊息結尾是 `CamNetTool 2.0.0`，2026-11-25 以前）：有漏洞，`RxDiscardDelta` 偶爾會出現 12,794、27,776、1,866,458,126 這類錯誤的大數字，事件 2 的「接收丟棄累計」也會變成數十億。
  - 這種記錄請改用 `round(RxDiscardDeltaRaw ÷ 2³²)`，四捨五入到整數。
  - 只看單筆時，`RxDiscardDelta` 大於 20 都可以視為這個漏洞。
- **已知基準**（這台電腦，2026-11）：正常取像時每 5 秒 0～6 個，45 小時共約 66,000 個，約每小時 1,500 個。
- **這個計數不等於相機影像封包遺失**：同一段時間相機的重送次數（`camstatus.ResendRecv`）沒有增加。判斷影像是否真的掉封包，要看 `camstatus` 的重送欄位。
- **計數器變小時**（驅動重載），這一列的增量記為 0，並記事件 30。

---

## 4. `camstatus_yyyyMMdd.csv`：相機（30 欄）

| # | 欄位 | 單位 / 值 | 說明 |
|---|---|---|---|
| 1 | `Time` | 時間 | 與同一週期的 status 列時間相同 |
| 2 | `Gvcp` | `OK` / `NoResponse` / `AccessDenied` / `Error` | 這次讀相機的結果。`NoResponse` = 重試 3 次都沒回應；`AccessDenied` = 有程式以獨占模式控制相機 |
| 3 | `GvcpMs` | ms | 讀完全部暫存器花的時間。正常 2～7 ms |
| 4 | `CameraIp` | IPv4 | 本次使用的相機 IP |
| 5 | `TempC` | °C | 相機溫度（DeviceTemperature）。這台正常約 43 °C；警告門檻預設 60 |
| 6 | `PowerW` | W | 相機功耗。正常約 8.4 W |
| 7 | `UpTimeS` | 秒 | 相機開機至今時間。**變小 = 相機重新開機過**（事件 104） |
| 8 | `LinkUpTimeS` | 秒 | 相機端網路連線時間。**變小但 UpTime 沒變小 = 連線曾斷過**（事件 105） |
| 9 | `AcqFps` | fps | **設定的**幀率（1e6 ÷ AcquisitionFrameTime） |
| 10 | `TxFrameTimeUs` | µs | TransmissionFrameTime。**這台相機韌體 1.21.0.0 在正常送影像時也是 0，不能用來判斷卡住** |
| 11 | `EstFps` | fps | **實際**幀率的估計值 = `RxMBps` × 10⁶ ÷ PayloadSize |
| 12 | `RxMBps` | MB/s | 網卡接收速率，與 status 同一週期的值 |
| 13 | `TriggerMode` | `On` / `Off` | `On` 時沒有影像屬正常（在等觸發） |
| 14 | `TransferStatusSel` | 例如 `Streaming` | TransferStatusSelector 目前選的項目（唯讀，工具不會改） |
| 15 | `Streaming` | `1` / `0` | 相機自認「正在傳送」 |
| 16 | `QueueCur` | 張數 | 相機內部待送的影像數 |
| 17 | `QueueMax` | 張數 | 相機內部佇列上限（這台 37） |
| 18 | `ResendRecv` | 累計次數 | 相機**收到的重送要求**累計值（相機重開或重新開始取像會歸零） |
| 19 | `ResendRecvDelta` | 次數 | 這個週期新增的重送要求。**這是判斷「影像有沒有掉封包」最直接的指標** |
| 20 | `ResendValid` | 累計次數 | 有效的重送要求累計值 |
| 21 | `ResendUnavail` | 累計次數 | 相機**已無法重送**的封包累計值（封包已從相機緩衝區清掉） |
| 22 | `ResendUnavailDelta` | 次數 | 這個週期新增的無法重送。> 0 代表電腦端一定缺封包或整張影像 |
| 23 | `ThroughputLimitMode` | `On` / `Off` | 相機頻寬限制開關 |
| 24 | `ThroughputLimitBps` | bytes/s | 頻寬限制值。`1250000000` = 10G 線速（等於沒限制） |
| 25 | `ThroughputReserve` | % | DeviceLinkThroughputReserve |
| 26 | `CCP` | 十六進位，例如 `0x2` | 控制權：`0x0` = 沒有程式控制；`0x1` = 獨占；`0x2` = 一般控制 |
| 27 | `Controller` | `IP:port` 或 `無` | 持有控制權的電腦與埠 |
| 28 | `SCP0Port` | 埠號 | 影像串流送往電腦的 UDP 埠。`0` = 串流通道已關閉 |
| 29 | `SCPD0` | 數字 | 封包間隔（packet delay）。0 = 不延遲 |
| 30 | `CamState` | 見下表 | CamNetTool 對相機狀態的綜合判斷 |

`Gvcp` 不是 `OK` 時，第 5～29 欄大多是空的，但欄位數不變。

### `CamState` 的值

依優先順序判斷：

| 值 | 意義 | 條件 |
|---|---|---|
| `NoResponse` | 相機無回應 | GVCP 讀取重試 3 次失敗 |
| `Denied` | 被獨占 | 相機回 ACCESS_DENIED（狀態碼 0x8006） |
| `Error` | 讀取錯誤 | 其他錯誤 |
| `Stalled` | **相機卡住** | 連續 N 次（預設 3）都符合 `Watching` 的條件 |
| `Watching` | 疑似卡住，觀察中 | 有控制者（CCP≠0）+ `Streaming=1` + `TriggerMode≠On` + 網卡幾乎沒收到資料（`RxMBps` < max(1, 預期流量 × 5%)） |
| `Streaming` | 正常送影像 | `Streaming=1` 而且有資料進來 |
| `WaitTrigger` | 等待觸發 | `Streaming=1`、`TriggerMode=On`、沒有資料 |
| `Idle` | 未取像 | 其他情況（例如 CCP=0 或 Streaming=0） |

> **與原始規格的差異**：規格原本用「CCP≠0 + Streaming=1 + TransmissionFrameTime=0」判斷卡住。這台相機正常取像時 TransmissionFrameTime 也一直是 0，照規格會誤判，所以改用網卡流量判斷。

---

## 5. `events_yyyyMMdd.csv`：事件（5 欄）

欄位：`Time, Source, EventId, Level, Message`

- **`Source`**：
  - `CamNetTool`：網卡、ping、監控本身。
  - `Camera`：相機。
  - `Optimize`：設定修改。
  - `aqnic650`、`Microsoft-Windows-Kernel-Power`：從 Windows 系統事件記錄轉錄過來。
- **`Level`**：`資訊` / `警告` / `錯誤` / `過熱`。
- **`Message`**：中文說明，已去除換行。

### 5.1 CamNetTool 自己的事件

| EventId | Source | Level | 意義 | Message 中的資訊 |
|---|---|---|---|---|
| 1 | CamNetTool | 資訊 | 監控開始 | 網卡名稱、相機 IP、自動或手動、ping 從哪個 IP 送出（2.0.2 起）、取樣間隔、版本。例：`監控開始（網卡：小FOV，相機 IP：169.254.23.146（自動偵測，ping 從 169.254.192.4 送出），取樣間隔 10 秒，CamNetTool 2.0.2）` |
| 2 | CamNetTool | 資訊 | 監控結束 | 原因、監控時長、各種次數統計、溫度最高值（見 5.4） |
| 10 | CamNetTool | 警告 | 網卡連線中斷 | `Up → Disconnected` 等 |
| 11 | CamNetTool | 資訊 | 網卡連線恢復 | 速度、中斷多久 |
| 12 | CamNetTool | 警告 | 網卡狀態改變（非 Up 之間的變化） | 前後狀態 |
| 13 | CamNetTool | 警告（降速）/ 資訊（升速） | 連線速度改變 | 前後速度 |
| 20 | CamNetTool | 警告 | 相機 ping 失敗 | IP、失敗狀態 |
| 21 | CamNetTool | 資訊 | 相機 ping 恢復 | 延遲、中斷多久 |
| 22 | CamNetTool | 資訊 | 相機 ping 來源改變 | 舊來源 IP → 新來源 IP（或「網卡沒有 IPv4」）、相機 IP。2.0.2 起 |
| 30 | CamNetTool | 資訊 | 網卡計數器歸零（驅動重載） | |
| 40 | CamNetTool | 警告 | 網卡驅動內部重置（rxPathReset / txPathReset / txWatchdog 增加） | 增加量與累計值 |
| 50 | CamNetTool | 資訊 | 診斷快照開始 | 標籤 |
| 51 | CamNetTool | 資訊 | 診斷快照完成 | zip 路徑 |
| 60 | CamNetTool | 資訊 | 線上查詢最新版本 | 查到的版本 |
| 61 | CamNetTool | 警告 | 開始安裝網卡驅動 | 資料夾、目前版本、執行者 |
| 62 | CamNetTool | 資訊 / 警告 | 網卡驅動安裝結束 | pnputil 結束碼、前後版本 |
| 90 | CamNetTool | 資訊 | 主機板溫度無法讀取，該欄停用 | 原因 |
| 91 | CamNetTool | 資訊 | 網卡晶片溫度無法讀取，該欄停用 | 原因（通常是沒有系統管理員權限） |

### 5.2 相機事件（Source = `Camera`）

| EventId | Level | 意義 | 觸發條件 |
|---|---|---|---|
| **100** | **錯誤**（有聲音） | **相機卡住** | `CamState` 進入 `Stalled`。Message 含控制者、連續次數、網卡接收 MB/s、佇列、TransmissionFrameTime |
| 101 | 資訊 | 卡住狀態結束 | 恢復送影像 / Streaming=0 / 控制權釋放 |
| **102** | **錯誤**（有聲音） | **相機無回應** | GVCP 重試 3 次失敗（只在剛變成無回應時記一次）。**例外**：監控開始時連不上相機，也用 102 但 Level 是警告，Message 以「相機監控暫時無法開始」開頭 |
| 103 | 資訊 | 相機恢復回應 | |
| 104 | 警告 | 相機重新開機過 | `UpTimeS` 變小 |
| 105 | 警告 | 相機端網路連線重置過 | `LinkUpTimeS` 變小、`UpTimeS` 沒變小 |
| 106 | 資訊 / 警告 | 控制權取得（資訊）/ 釋放（警告） | CCP 值改變 |
| 107 | 警告 | 重送暴增 | 一個週期內 `ResendRecvDelta` ≥ 門檻（預設 500） |
| 108 | 警告 | 無法重送 | `ResendUnavailDelta` > 0 |
| 109 | 警告 | 相機溫度過高 | `TempC` ≥ 門檻（預設 60 °C），降到門檻 −2 °C 以下才會再次警告 |
| 110 | 警告 | 相機 XML 改變或無法取得 | 例如更新韌體後；已自動重新解析 |
| 111 | 警告 | 相機 IP 改變 | 自動偵測發現新 IP（相機重開機後 169.254.x.x 位址可能改變） |
| 112 | 警告 | 頻寬限制未生效 | 用本工具套用過頻寬限制，但取像中讀到 `Off` |
| 113 | 警告 | XML 中的換算公式和預期不同 | 溫度、功耗的換算可能不對，需人工確認 |
| 114 | 資訊 | 相機連線資訊 | IP、偵測方式、本機 IP、廠牌型號、序號、韌體、XML 檔名。每次開始監控或重新連線時記錄 |
| 115 | 資訊 | XML 中找不到的項目 | 這些欄位在 camstatus 會是空的 |
| 116 | 警告 | ACCESS_DENIED | 有程式以獨占模式控制相機 |

### 5.3 設定修改（Source = `Optimize`）

| EventId | 意義 | Message |
|---|---|---|
| 200 | 已套用設定 | 項目、修改前 JSON → 修改後 JSON、執行者（網域\帳號）、備份檔名 |
| 201 | 已復原設定 | 項目、寫回的值、原修改時間與執行者 |
| 202 | 套用或復原失敗 | 原因；相機寫入時附上過程記錄 |

**分析「設定修改前後的效果」時，以 200 / 201 的時間為分界**，比較前後的 `RxDiscardDelta` 與 `ResendRecvDelta`。

### 5.4 事件 2（監控結束）的統計格式

範例：

```
監控結束（使用者按下停止，已監控 00:13:24；斷線 0 次、ping 失敗 0 次、驅動警告 0 次、過熱警告 0 次、網卡重置 0 次、接收丟棄累計 357；相機卡住 0 次、無回應 0 次、重開機 0 次、連線重置 0 次、重送累計 0、無法重送累計 0；主機板最高 45.1 °C、相機最高 43.25 °C）
```

- **原因**：`使用者按下停止`、`使用者關閉程式`、`以系統管理員重新開啟`、`被工作管理員結束`、`Windows 關機或登出`、`程式結束：<原因>`。
- **沒有對應的事件 2**：如果只有事件 1、沒有對應的 2，代表程式被強制結束或電腦當機、斷電。這時請看 Kernel-Power 41。

### 5.5 轉錄的 Windows 系統事件

`Source` 是原始提供者名稱，`EventId` 是 Windows 原始事件 ID。Message 開頭可能有中文標籤：

| Source | EventId | 標籤 |
|---|---|---|
| `aqnic650` | 14 | 驅動回報 link down |
| `aqnic650` | 15 | 驅動回報 link up |
| `Microsoft-Windows-Kernel-Power` | 41 | 異常斷電／未正常關機 |
| `Microsoft-Windows-Kernel-Power` | 42 / 107 | 進入睡眠 / 從睡眠喚醒 |
| `Microsoft-Windows-Kernel-Power` | 109 | 開始關機 |
| `Microsoft-Windows-Kernel-Power` | 506 / 507 | 進入 / 離開新式待命 |

- **`Level`**：
  - 依原始事件等級轉換（1、2 → 錯誤，3 → 警告，其他 → 資訊）。
  - 訊息含 temperature / overheat / 溫度 / 過熱 時，標為 `過熱`。
- **`[監控停止期間]` 前綴**：Message 以它開頭，代表該事件發生在 CamNetTool 沒有執行的期間，是下次開始監控時補記的，最多 100 筆。

---

## 6. 診斷快照 zip（`CamDiag_<標籤>_<時間>.zip`）

出事時由人員按「出事了，收集資料」產生，約 1～2 分鐘，**期間不會中斷取像**。先看 `summary.txt`。

### `summary.txt` 結構

```
CamNetTool 診斷快照  <時間>  標籤 <標籤>

自動判斷：
  ● <結論 1>
  ● <結論 2>

詳細過程：
== 1. 網卡資訊
== 2. 系統、電源與軟體版本
== 3. 程式與 UDP 連接埠
== 4. 事件記錄與排程工作
== 5. 封包擷取（N 秒）
== 5b. 分析封包擷取
== 6. 相機 GigE Vision 探測（只讀不寫）
== 7. 5 秒內相機網卡接收 X MB/s
== 自動判斷
```

### 「自動判斷」可能出現的結論

| 結論開頭 | 意義 |
|---|---|
| `Discovery 無回應` | 相機韌體可能卡死，或網路不通 |
| `CCP = 0` | 沒有程式控制相機（heartbeat 逾時，或主機已釋放） |
| `CCP ≠ 0、Streaming = 1、但沒有影像進來` | **相機內部傳送卡死** |
| `相機正常送影像` | 快照當下正常 |
| `有程式控制相機，但相機沒有在傳送` | 取像程式沒有開始取像 |
| `SCP0 = 0` | 串流通道已關閉 |
| `被要求重送的封包…原本沒有出現在擷取中` | 封包在**網卡接收環**就被丟掉 → 調大 Receive Buffers |
| `被要求重送的封包…原本有到達擷取點` | 遺失發生在 **Windows 網路堆疊或取像程式**（CPU、GigE 過濾驅動） |
| `封包擷取…沒有 PACKETRESEND` | 擷取期間沒有掉封包 |
| `Receive Buffers N…約可緩衝 X ms → 太短` | 緩衝時間 < 20 ms，建議調到最大 |

「詳細過程」的「== 1. 網卡資訊」中還有這幾行：

- `GigE 過濾驅動：<名稱>（<ComponentID>）已啟用`
- `非 GigE 驅動（<類別>）：<名稱>（<ComponentID>）已啟用 → 建議在相機網卡上取消`
  - 類別：虛擬機、VPN、防火牆／防毒、封包擷取、其他第三方。
  - 沒有時寫 `非 GigE 驅動（VirtualBox、VMware、VPN、防火牆等）：沒有`。
- `Flow Control：<值>`，例如 `Disabled（關閉）`。

### zip 內的檔案

| 檔案 | 內容 |
|---|---|
| `nic_adapter.txt`、`nic_advanced.txt` | 網卡資訊與所有進階設定（Receive Buffers、Jumbo Packet、中斷調節、EEE 等） |
| `nic_statistics.txt`、`nic_power.txt`、`nic_hardware.txt` | 統計、電源管理、PCIe 連線速度與寬度 |
| `nic_bindings.txt` | 網卡綁定的元件，含 GigE 過濾驅動（OMRON SENTECH、Lucid、NI 等） |
| `nic_ip.txt`、`nic_neighbors.txt`、`ipconfig.txt`、`arp.txt`、`route.txt` | IP 與路由 |
| `os.txt`、`power_*.txt` | 作業系統、電源計畫、PCIe ASPM、最後喚醒來源 |
| `software.csv` | 已安裝軟體清單 |
| `processes.csv` | 所有行程（啟動時間、CPU、記憶體、是否回應） |
| `udp_endpoints.csv` | 所有 UDP 埠與擁有的程式 |
| `events_incident_window.csv` | 事發時間前後 1 小時的系統 / 應用程式事件 |
| `events_warnings_recent.csv` | 最近 3 天的系統 / 應用程式警告與錯誤 |
| `evt_*.evtx` | 最近 3 天的事件記錄原始檔（需要系統管理員） |
| `scheduled_tasks.csv` | 排程工作；時間接近事發時刻的會寫進 summary |
| `CamNetToolLog\` | 事發當天與前一天的 status / camstatus / events |
| `capture.etl`、`capture.pcapng` | pktmon 封包擷取（需要系統管理員）。有影像串流時只抓每個封包前 128 bytes、5 秒 |
| `gev_discovery.csv`、`gev_bootstrap.csv` | GigE Vision Discovery 回應、bootstrap 暫存器 |
| `gev_registers_3rounds.csv` | 監控用的暫存器讀 3 輪（含位址與換算公式） |
| `genicam.xml`、`genicam_*.zip` | 相機的 GenICam XML |

---

## 7. `last_capture.json`

最近一次封包擷取分析的結果，「最佳化設定」用它計算 Receive Buffers 可以緩衝多久。

```json
{
    "Time": "2026-11-23 12:25",
    "MedianBurstMBps": 1238,
    "MedianBlockMs": 19.8,
    "PacketsPerBlock": 2733,
    "Blocks": 48,
    "Missing": 0,
    "ResendCmds": 0
}
```

| 欄位 | 意義 |
|---|---|
| `MedianBurstMBps` | 每張影像送出時的突發速率（中位數） |
| `MedianBlockMs` | 每張影像從第一個到最後一個封包的時間（中位數） |
| `PacketsPerBlock` | 每張影像的封包數 |
| `Blocks` | 擷取到的完整影像數 |
| `Missing` | 擷取中缺漏的封包數 |
| `ResendCmds` | 電腦送出的 PACKETRESEND 次數 |

Receive Buffers 緩衝時間（ms）= Receive Buffers × 9014 ÷ (`MedianBurstMBps` × 10⁶) × 1000。

---

## 8. `backup_*.json`（設定修改備份）

檔名：`backup_<yyyyMMdd_HHmmss>_<項目Id>.json`

```json
{
  "Id": "項目代號",
  "Item": "項目中文名稱",
  "Time": "修改時間",
  "User": "網域\\帳號",
  "Machine": "電腦名稱",
  "Before": { "修改前的值": "..." },
  "After":  { "修改後的值": "..." },
  "Restored": "復原時間；空字串 = 尚未復原"
}
```

---

## 9. 建議的分析步驟

1. **先看 `events`**：
   - 依 `Time` 排序，找 `Level` 為錯誤或警告的列。
   - 特別注意 100、102、104、105、107、108、10、20、40，以及 Kernel-Power 41。
2. **對齊時間**：以事件時間為中心，取前後幾分鐘的 `status` 與 `camstatus` 列（兩者同一週期的 `Time` 相同，可直接用 `Time` 合併）。
3. **判斷屬於哪一類問題**：

| 現象 | 可能原因 |
|---|---|
| `CamState = Stalled`、`Gvcp = OK`、`CCP ≠ 0x0`、`RxMBps` ≈ 0 | 相機內部傳送卡死（相機韌體） |
| `Gvcp = NoResponse` 而且 `CameraPingMs = Fail:…` | 網路層斷了。看 `LinkStatus` 與事件 10 |
| `Gvcp = NoResponse` 但 ping 正常 | 相機韌體的控制層卡死 |
| `UpTimeS` 歸零（事件 104） | 相機重開機（斷電、看門狗） |
| `CCP` 變成 `0x0`（事件 106 警告）但沒有 104 | 取像程式釋放或遺失控制權（heartbeat 逾時，或程式結束） |
| `ResendRecvDelta` 大量增加 | 電腦端掉封包。對照同時段 `RxDiscardDelta`、`CpuPercent`、事件 40 |
| `ResendUnavailDelta > 0` | 已經造成影像缺漏 |
| `LinkStatus` 不是 `Up` / 事件 10、aqnic650 14 | 網卡或線路斷線 |
| 事件 40（驅動內部重置） | 網卡驅動問題；考慮更新驅動 |
| `AcpiTempC`、`NicMacTempC`、`TempC` 異常升高 | 散熱問題 |
| 只有事件 1 沒有 2，或有 Kernel-Power 41 | 電腦當機或斷電 |

4. **評估設定修改的效果**：以事件 200 為分界，比較前後相同長度時段的 `ResendRecvDelta` 總和與 `RxDiscardDelta` 總和。

### 計算時的注意事項

- **加總時用增量欄**（`*Delta`）。累計欄（`ResendRecv`、`ResendUnavail`、`Aq*`）會因相機重開或驅動重載而歸零，不能直接相減跨越歸零點。
- **空字串代表讀不到**，不是 0。
- **`RxMBps` 的空值**：第一列、網卡斷線期間都是空的。
- **`EstFps`**：取像中約等於 `AcqFps`；明顯偏低代表有掉幀。
- **取樣間隔**：見事件 1 的「取樣間隔 N 秒」。不同次監控可能不同，比較速率時要換算。

---

## 10. 這台電腦的已知正常基準（2026-11-23 實測）

| 項目 | 正常值 |
|---|---|
| 相機 | LUCID ATX245S-C，序號 263502549，韌體 1.21.0.0 |
| 相機 IP / 電腦端 IP | 169.254.23.146 / 169.254.192.4（Link-Local，相機重開機後可能改變） |
| 網卡 | 「小FOV」，AQtion 10G，驅動 2.2.2.0（2020-04-30），Receive Buffers 4096（最大） |
| 取像中 `RxMBps` | 約 246 MB/s（10 fps） |
| `EstFps` / `AcqFps` | 約 10.06 / 10 |
| 相機溫度 / 功耗 | 約 43 °C / 8.4 W |
| `TxFrameTimeUs` | 0（正常，這台韌體不更新此值） |
| `QueueCur` / `QueueMax` | 0 / 37 |
| `ResendRecvDelta` | 0 |
| `RxDiscardDelta` | 每 5 秒約 2～3（不影響影像） |
| `ThroughputLimitMode` / `Bps` | Off / 1250000000 |
| `CCP` / `Controller` | 0x2 / 169.254.192.4:<埠>（取像程式持有控制權） |
| `GvcpMs` | 2～7 ms |
| 每張影像 | 2,733 個封包，約 19.8 ms 送完，突發約 1,238 MB/s |
| GigE 過濾驅動 | OMRON SENTECH StGigE 與 Lucid_NdisLwf 都啟用中 |
| 非 GigE 驅動 | 沒有（2026-11-25 確認） |
| Flow Control | Disabled |

---

## 11. CamNetTool 不會做的事

- **不會寫入相機或網卡**：
  - 監控、診斷快照都只讀取。
  - 只有人員在「最佳化設定」分頁按下按鈕並確認後才會寫入，而且一定會有事件 200 / 201 / 202。
  - 相機寫入只在沒有程式控制相機（CCP=0）、取像程式沒有執行時才允許。
- **不會更新相機韌體**。
- **不會呼叫網卡的纜線診斷**等會中斷連線的功能。
- **只在固定時機需要系統管理員權限**：
  - 網卡晶片溫度與驅動重置計數。
  - 封包擷取與匯出 evtx。
  - 修改網卡設定、安裝驅動。
  
  沒有權限時，相關欄位留空，並有事件 90 / 91 說明。
