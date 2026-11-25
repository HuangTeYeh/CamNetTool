# CamNetTool

10GigE 相機（LUCID Atlas10）與 AQtion 10G 網卡的監控、診斷與最佳化工具。只用 Windows 內建的 PowerShell 5.1，不需要安裝任何東西。

## 資料夾

| 路徑 | 內容 |
|---|---|
| `CamNetTool\` | **產線版**。整個資料夾複製到產線電腦，雙擊 `Start_CamNetTool.bat` 執行 |
| `CamNetTool\README.md` | 使用說明 |
| `CamNetTool\CamNetTool_LOG解讀指南.md` | 記錄檔欄位與事件的說明（可以給其他 AI 讀） |
| `tests\CoreTests.ps1` | 自動測試（開發用，不放到產線） |

## 部署到產線

兩種方式擇一：

- 到 **Releases** 下載 `CamNetTool_<版本>_production.zip`（產線版），解壓後整個資料夾複製到產線電腦。
- 或直接複製這個 repo 的 `CamNetTool\` 資料夾。

不要複製任何一台電腦的 `CamNetTool.config.json`、`CamNetToolLog\`、`CamNetToolData\`、`Diag\`：這些是執行後自動產生的本機資料，已列在 `.gitignore`。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -STA -File tests\CoreTests.ps1
```

只做讀取，不會寫入相機或網卡設定。有接相機時會多做幾項唯讀的實機測試。

## 版本

| 版本 | 日期 | 內容 |
|---|---|---|
| 2.0.1 | 2026-11-25 | 修正 AQtion 接收丟棄計數（低 32 位元自己變動時被誤算成大量丟棄）；最佳化設定新增「非 GigE 驅動」檢查（可修正、可復原）與 Flow Control 顯示 |
| 2.0.0 | 2026-11-23 | 以 NicMonitor 1.1.0 為基礎：相機監控（GVCP 唯讀）、自動偵測相機 IP、診斷快照、封包擷取分析、最佳化設定、版本與更新 |
