# MAPA — Make AI Peons Again

**把長任務丟給 AI coding agent，闔上筆電出門，它繼續跑；電量／時間／溫度任一條件到了，自己安全收工。**

一支 bash 腳本，250 行，**零依賴、零安裝**。**不是產品，就是個有趣的小玩具**——不求完美，但簡單、看得懂、改得動。拿去賣大概賣不到錢，但也許能讓某台筆電不要在背包裡被煮熟，或幫誰省下幾小時踩坑的時間。

```bash
./mapa.sh 180 15    # 跑 3 小時，電量降到 15% 就收工休眠
```

實測環境：Apple M3 Pro / macOS 26.7 (Darwin 25.6) / `/bin/bash` 3.2.57。

> 🇬🇧 English → **[README.md](README.md)**
> 想直接看技術細節（踩到的坑、怎麼驗的）→ **[NOTES.zh-TW.md](NOTES.zh-TW.md)**

---

## 怎麼用

```bash
./mapa.sh                # 預設：60 分鐘、電量下限 10%
./mapa.sh 180 15         # 3 小時、電量 15%
./mapa.sh 0 20           # 無時間上限，跑到電量剩 20%
```

兩個參數都是整數：**分鐘數**（`0` = 無上限）、**電量下限百分比**（必須在 0–100，超出會拒絕執行）。

會問一次 sudo 密碼（`pmset` 和 `powermetrics` 需要）。之後就可以闔蓋出門。

執行中的畫面：

```
[2026/09/28 23:31:57 UTC+8] >>> 防休眠已啟用！隨時可按 Ctrl + C 取消。
[2026/09/28 23:31:57 UTC+8] >>> 電量保護下限：10%
[2026/09/28 23:31:58 UTC+8] >>> [警告] 偵測到機身過熱！熱壓力: Heavy
[2026/09/28 23:31:58 UTC+8] >>> 主動開啟「低耗電模式」進行強制 Throttle 降溫...
[2026/09/28 23:32:28 UTC+8] >>> 機身溫度已恢復正常，解除強制低耗電模式。
```

`Ctrl + C` 隨時可中斷，會把所有改過的系統設定還原回去。

> 附帶一點惡趣味：啟動播 WC3 獸族苦工的 "Work work"、過熱播 "Under attack"、收工播 "Ready to work"。
> **音效檔沒有納入版控**（第三方版權素材），請自備——檔名見 [`audio/README.md`](audio/README.md)。缺檔不影響功能，只會 log 一行提示。

---

## 出門前：讓 Mac 自動連上手機熱點

**蓋子關著，你沒辦法手動點 Wi-Fi。** 而 agent 要呼叫 API，斷網就等於停工——機器還在耗電，任務卻沒進度。所以出門前得確保 Mac 會自己連上手機熱點。

> 以下的 `networksetup` 指令都在 macOS 26.7 上查證過可用；**手機端與系統設定的操作步驟未實測**，各版本 UI 名稱可能略有差異。

### iPhone

有兩條路，建議**兩條都設好**：

**① Instant Hotspot（即時熱點）** — Mac 不需要密碼就能連，iPhone 甚至不必先手動打開熱點開關（Mac 會透過 Bluetooth 請它開）。前置條件：

- Mac 與 iPhone 登入**同一個 Apple Account**
- 兩邊的 **Wi-Fi 與 Bluetooth 都開著**
- **Handoff** 開啟（Mac：系統設定 → 一般 → AirDrop 與 Handoff；iPhone：設定 → 一般 → AirPlay 與接續）

**② 固定 SSID ＋ 密碼（比較可靠，也適用 Android）** — 讓 Mac 把熱點當成一般的「已知網路」記住：

- iPhone：設定 → 個人熱點 → 設定「Wi-Fi 密碼」
- 熱點的 SSID 就是裝置名稱，可在 設定 → 一般 → 關於本機 → 名稱 修改（**建議改成沒有特殊字元的名字**，省掉引號轉義的麻煩）
- 然後用密碼在 Mac 上連一次 → 它就進了偏好網路清單，之後會自動加入

這條路不依賴 Apple Account、Bluetooth 或 Handoff，少三個失敗點。

### 🔑 關鍵設定：自動加入熱點

**光是「記住熱點」還不會自動連**——macOS 預設不主動加入個人熱點（怕吃掉你的手機流量）。要打開：

**系統設定 → Wi-Fi → 往下找「詢問是否加入熱點」（Ask to join hotspots）→ 改成「自動」（Automatic）**

三個選項的差別：

| 選項 | 行為 |
|---|---|
| 永不 / Never | 完全不碰熱點 |
| 詢問 / Ask | 跳通知問你（**闔蓋出門時等於不會連**）|
| **自動 / Automatic** | 沒有已知 Wi-Fi 可用時，自動加入找得到的熱點 ✓ |

沒改這一項，前面兩條路都白設。

### 用指令做（已查證可用）

```bash
# Wi-Fi 介面代號（多數 Mac 是 en0）
networksetup -listallhardwareports | grep -A1 "Wi-Fi"

# 立刻連上熱點（連成功也會把它記進已知網路）
networksetup -setairportnetwork en0 "MyiPhone" "密碼"

# 明確加進偏好清單並放到第一優先（index 0 = 最優先）
networksetup -addpreferredwirelessnetworkatindex en0 "MyiPhone" 0 WPA2PSK "密碼"

# 確認目前連上什麼
networksetup -getairportnetwork en0

# 看偏好順序（前幾名才是實際會優先連的）
networksetup -listpreferredwirelessnetworks en0 | head
```

把熱點放在 index 0 的意義：如果出門前 Mac 還連著公司或家裡的 Wi-Fi，離開範圍後它會**按偏好順序**找下一個——排前面才會優先試熱點。

### 驗一下真的會自動連

別靠「應該可以」。關掉再打開 Wi-Fi，看它會不會自己回來：

```bash
networksetup -setairportpower en0 off
sleep 5
networksetup -setairportpower en0 on
sleep 20
networksetup -getairportnetwork en0     # 應該顯示你的熱點
```

### Android

沒有 Instant Hotspot 的等價機制（除非同品牌生態，例如 Samsung 自家裝置間的 Auto Hotspot），所以只有「固定 SSID ＋ 密碼」這條路：

1. 設定 → 網路與網際網路 → 熱點與網路共用 → Wi-Fi 熱點
2. 設好名稱與密碼
3. **🔴 關掉「自動關閉熱點」**（Turn off hotspot automatically，通常在進階設定裡）
4. Mac 端用上面的指令連一次

第 3 步是 Android 這條路最重要的一步：**那個選項預設是開的**，只要一段時間沒有裝置連線就自動關閉熱點。路上進一次電梯斷線，熱點就關了，Mac 再也連不回來——而你蓋子是關著的，不會知道。

### 幾個實際會踩到的

- **iPhone 熱點在沒有裝置連線時會停止廣播。** Instant Hotspot 可以透過 Bluetooth 把它叫醒，但需要兩邊都在藍牙範圍內——手機放口袋、Mac 在背包裡通常沒問題。用②那條路的話，iPhone 端要維持「允許其他人加入」開著。
- **2.4GHz vs 5GHz**：iPhone 的「最大化相容性」開啟＝走 2.4GHz，慢但穿透好；關閉＝5GHz，快但範圍小。手機和 Mac 都在同一個背包裡的話 5GHz 沒問題；一個在口袋一個在背包，2.4GHz 穩一些。
- **手機的電量沒人保護。** MAPA 顧的是 Mac 的電量，但開熱點很耗電，**手機可能比 Mac 先沒電**。長時間任務記得幫手機也帶顆行動電源。
- **手機的省電模式會影響熱點穩定性**，出門前建議關掉。
- **MAPA 不檢查網路。** 它只管電量／時間／溫度；斷網它不會停，會繼續耗電到條件觸發。所以出門前用上面那個開關 Wi-Fi 的方式確認一次，比較實在。

---

## 先懂三件事

如果你不熟 macOS 的電源管理，這三個概念就夠了。

### 1. 為什麼闔蓋會睡，而 `caffeinate` 救不了

`caffeinate` 防的是「閒置休眠」（idle sleep）。但**闔蓋是另一回事**——macOS 的 clamshell 邏輯預設要求接電源＋外接顯示器才會保持運作，沒有就睡。

要在「純電池、沒外接任何東西、蓋子關著」的狀態下繼續跑，只有一條路：

```bash
sudo pmset -a disablesleep 1
```

這是個全系統開關，所以需要 sudo，而且**用完一定要還原**（腳本退出時無論走哪條路都會還原）。

### 2. 熱壓力等級（thermal pressure level）

**闔蓋 = 散熱最差的姿勢。** 機器在背包裡悶著跑滿載，這是真實風險，也是這支腳本存在的主要理由。

但 Apple Silicon 上**拿不到 CPU 溫度**——`sysctl` 沒有這個欄位，`powermetrics` 也不吐 die temperature，要讀 SMC sensor 得裝第三方工具。

macOS 提供的替代品是「熱壓力等級」，一個五檔的狀態：

```bash
sudo powermetrics -n 1 -i 200 --samplers thermal | grep "pressure level"
# → Current pressure level: Nominal
```

| 等級 | 意思 |
|---|---|
| `Nominal` | 正常，全速跑 |
| `Moderate` | 溫度略升，風扇加速 |
| `Heavy` | **系統開始降頻**了，背景工作被抑制 |
| `Trapping` | 逼近溫度上限，激進降頻與降壓 |
| `Sleeping` | 降頻已經救不回來，**系統強制休眠以免晶片燒毀** |

> ⚠️ 這張表是社群整理的，**Apple 沒有官方文件**說明各等級對應幾度。等級與攝氏度數的對應不公開，且隨機型與環境而異。

### 3. E-Core 與 P-Core

Apple Silicon 有兩種核心：**P-Core**（performance，快但耗電）和 **E-Core**（efficiency，慢但省電）。平常系統自己決定工作放哪。

而 macOS 有個機制叫 **QoS（Quality of Service）**——把一個行程標記為「background」，系統就會把它關進 E-Core：

```bash
taskpolicy -b -p <pid>    # 降級：關進 E-Core
taskpolicy -B -p <pid>    # 還原
```

**關鍵在於 QoS 會被子行程繼承。** coding agent 是個主行程，跑工具時會 fork 出 `git`、測試、編譯等一大堆子行程——降級主行程一次，這些**全部自動繼承**，不會有哪個突然把 P-Core 叫醒。

出門時 agent 的工作不需要 P-Core 的速度，關進 E-Core 省電又降溫。這是這支腳本最有用的一招。

---

## 它做了什麼

```
  啟動 ──► 設 trap（確保任何中斷都能還原）
           ├─ pmset -a disablesleep 1     防休眠
           └─ agent 行程降級至 E-Core
             │
             ▼
  主迴圈（每 10 秒）
    │
    ├─[1] 電量 ≤ 閾值 ─────────────────────┐
    ├─[2] 時間到上限 ──────────────────────┤
    └─[3] 熱壓力（每 30 秒查一次）          │
            ├─ Heavy ────► 開低耗電模式，繼續跑
            ├─ 回到 Nominal ─► 解除低耗電模式
            └─ Trapping / Sleeping ────────┤
                                           ▼
                                  還原全部設定
                              （防休眠、低耗電、QoS）
                                           │
                            ┌──────────────┴──────────────┐
                            ▼                             ▼
                      pmset sleepnow              exit 130（Ctrl+C）
```

三層保護的處置不一樣，值得分清：

| 觸發 | 做什麼 |
|---|---|
| 電量到下限 | 收工 → 休眠 |
| 時間到上限 | 收工 → 休眠 |
| 熱壓力 `Heavy` | **開低耗電模式撐著繼續跑**，溫度回穩就解除 |
| 熱壓力 `Trapping` / `Sleeping` | **直接收工休眠**（降頻已經救不回來了）|

也就是說：**真正靠降頻撐住的是 `Heavy`；到 `Trapping` 腳本的判斷是「該睡了」。**

三個設計上刻意的地方：

1. **`trap` 設在第一個改變系統狀態的指令之前**（`mapa.sh:157` vs `:160`）。否則會有「已經改了設定卻攔不到 Ctrl+C」的空窗。
2. **四條退出路徑共用同一個 `restore_settings()`**，都經實測確認會執行到。
3. **還原是回填原值，不是寫死。** 啟動時記下 `ORIG_LOW_POWER`，退出時填回去——不假設你原本沒開低耗電模式。

---

## 知道這些就好

不是產品，沒打算做到完美。實際會遇到的就這幾個：

- **中途新開的 agent 不會被降級** — 只在啟動時掃一次，不做輪詢。
- **被 `kill -9` 的話行程會卡在降級狀態**（`trap` 攔不到 `SIGKILL`）。手動還原：
  ```bash
  pgrep -f "claude" | xargs -I {} taskpolicy -B -p {}
  ```
- **熱壓力是單次取樣就判定，沒有 sustained 機制** — 讀一次 100ms 取樣看到 `Trapping` 就休眠，理論上一個瞬時抖動就可能中斷長任務。實務上還沒遇到，但這是已知的脆弱點。
- **收工時會多吐一行 `Terminated: 15`** — 背景保活 job 被 kill 的 job-control 通知，無害。修它要動 sudo 保活迴圈（那是承重柱，憑證一斷防休眠整個失效），不值得。
- **用管線或 `$(...)` 抓輸出會卡最多 60 秒** — 孤兒 `sleep` 還持有 stdout 寫入端。在終端直接跑不受影響；要存 log 用 `> file`（重定向不會卡）。
- **降級目標寫死 `pgrep -f "claude"`** — 換別的 agent 改那個 pattern 就好。`pgrep` 區分大小寫，所以不會誤傷首字大寫的 Claude Desktop（實測過）。
- **bash 5.x 沒測** — 測試機只有 `/bin/bash` 3.2.57。

---

## 想要更多功能

這支腳本的取向是「不裝東西、看得懂、改得動」。如果你要的是功能完整的成品，有更好的選擇：

**[keepresso](https://github.com/gyorgysh/keepresso)**（Swift/SwiftUI menu bar app，GPL-3.0）覆蓋這裡幾乎所有功能，而且多數做得更好——熱保護可以讀溫度 sensor、有 sustained 判定、會先提升風扇再暫停 session、自動恢復；還有針對 Claude Code / Cursor / Codex 的 agent hooks。它沒有的是 E-Core 流放。

**[Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704)**（App Store，免費）防休眠與電量／CPU 使用率的 Trigger 都有，但**沒有**熱保護。

| | 這支腳本 | keepresso | Amphetamine |
|---|---|---|---|
| 闔蓋防休眠（純電池、無外接） | ✓ | ✓ | ✓ |
| 電量／時間 | ✓ | ✓ 更豐富 | ✓ |
| 熱保護 | ✓ | ✓ 更完整 | ✗ |
| **E-Core 流放** | ✓ | ✗ | ✗ |
| **需要安裝什麼** | **無** | DMG / Homebrew cask ＋ 選配 admin helper | App Store；Apple Silicon 闔蓋模式需寫入 `/private/etc/sudoers.d/` |

最後一列是選這支腳本的主要理由：**受管的企業筆電上，裝第三方 app、Homebrew cask、或往 `/private/etc/sudoers.d/` 寫檔案，這三件都可能過不了審核；一支看得懂的 bash 腳本通常可以。**

---

## 想再深入

上面是全部你需要知道的用法。如果你要動手改、或想知道做這支腳本時撞到什麼，都在 **[NOTES.zh-TW.md](NOTES.zh-TW.md)**：

- **踩到的坑** — `taskpolicy -c background -p` 回報 exit 0 卻完全沒作用、`nice` 不是 QoS 指標、「還原」為什麼不能重跑 `pgrep`、E-Core 流放的實測數據、為什麼不該把所有行程都踢去 E-Core（62% 本來就在那）、哪些行程碰了會出事、`pmset -g therm` 在 Apple Silicon 平時是空的、背景行程的 `SIGINT` 會被忽略造成測試假陰性、黑名單與白名單的 fail-safe 取捨
- **怎麼驗的** — 用 shim 隔離系統指令（全程沒真的改過測試機的電源設定）、有狀態的 shim 逼出狀態轉換分支、wrapper ＋ 白名單（非得對真實行程動手時的保護）、測過的十一個情境
- **三條帶得走的原則**

