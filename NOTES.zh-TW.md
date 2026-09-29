# MAPA — 踩到的坑與驗證方法

這份是 [MAPA](README.zh-TW.md) 的技術附錄，寫給會去動 macOS 電源管理、QoS、或想驗證這類東西的人。

**大部分內容跟你最後用哪個工具無關**——`exit 0` 不等於生效、fail-safe 的方向、怎麼在不弄壞自己機器的前提下驗證一支會改系統設定的腳本，這些是通用的。

實測環境：Apple M3 Pro / macOS 26.7 (Darwin 25.6) / `/bin/bash` 3.2.57。

> 🇬🇧 English → **[NOTES.md](NOTES.md)**

---

## 🔴 踩到的坑

這些大多跟你最後用哪個工具無關。

### `taskpolicy -c background -p <pid>` 是假動作 — exit 0 但完全沒作用

網路上流傳的 E-Core 降級寫法是 `taskpolicy -c background -p <pid>`。實測（用 `ps -o pri` 觀測）：

| 指令 | `pri` 變化 | exit code | |
|---|---|---|---|
| `taskpolicy -b -p` | **31 → 4** | 0 | ✓ 有效 |
| `taskpolicy -B -p` | **4 → 31** | 0 | ✓ 完整還原 |
| `taskpolicy -c background -p` | **31 → 31** | **0** | ✗ **無效，卻回報成功** |
| `taskpolicy -c default -p` | **4 → 4** | 非 0 | ✗ 報錯，且不還原 |

看 usage 就知道原因——`-c` 屬於「啟動新程式」那種用法，對既有 pid 動手只吃 `-b`/`-B`：

```
Usage: taskpolicy [-x|-X] ... [-c <clamp>] [-b] ... <program> [<pargs> [...]]
       taskpolicy [-b|-B] [-t <tier>] [-l <tier>] -p pid
```

`-c default -p` 的錯誤訊息是 `Could not parse 'default' as a QoS clamp`——**而流傳的寫法都帶 `2>/dev/null`，正好把唯一的線索吞掉**。

最糟的組合是：有人把降級修對成 `-b`，卻沒改還原那行 ⇒ 行程**永遠卡在 `pri 4`** 直到重開。

> **帶得走的一條：`exit 0` 不等於生效。** 任何「設定類」指令都該驗證可觀測的狀態變化，別拿 exit code 當驗收依據。這在 IaC / CLI 自動化一樣適用。

### `nice` 不是 QoS 的指標，`pri` 才是

`taskpolicy -b` 前後 `nice` 都是 5，完全沒動。拿 `nice` 當指標會得出「沒生效」的反向結論。

（`taskinfo` 看得更細但**需要 root**，所以在非 root 下讀不到行程的原始 QoS——這直接影響了下一條。）

### 「還原」不能重跑 `pgrep`

流傳的寫法在還原時重新 `pgrep` 一次，把命中的行程一律設回 default。兩個問題：中途新開的行程會被誤動；**本來就是 background 的行程會被「升級」**——那不是還原。

因為讀不到原始 QoS，改走另一條路：**只還原自己實際降級過的 PID**。

```bash
DEMOTED_PIDS=""

demote() {
  for p in $(pgrep -f "claude"); do
    [ "$p" = "$$" ] && continue
    taskpolicy -b -p "$p" 2>/dev/null && DEMOTED_PIDS="$DEMOTED_PIDS $p"
  done
}

restore() {
  for p in $DEMOTED_PIDS; do
    kill -0 "$p" 2>/dev/null || continue   # 已結束的跳過
    taskpolicy -B -p "$p" 2>/dev/null
  done
  DEMOTED_PIDS=""
}
```

### E-Core 流放真的有效嗎 — 實測數據

靶進程是吃滿一核的 `yes`，用 `powermetrics --samplers cpu_power` 前後對照：

| | 降級前 | 降級後 |
|---|---|---|
| **E-Cluster idle residency** | **23.58%** | **0.00%** |
| E-Cluster 頻率分布 | 744 MHz 佔 32% | **744 MHz 佔 83%** |
| E-Cluster 平均頻率 | 1495 MHz | 877 MHz |
| P-Cluster residency | 100% / idle 0% | 100% / idle 0%（沒變）|

**`E-Cluster idle residency 23.58% → 0.00%`** 是關鍵：E-Cluster 的閒置時間被吃光，同時頻率往**最低檔 744 MHz 集中到 83%**。這兩件同時發生只有一個解釋——持續吃 CPU 的工作被搬進 E-Cluster，而且系統用最低頻率跑它。

若 `-b` 只改優先級而不改 core 親和性，靶進程會留在 P-Core（只是排隊靠後），E-Cluster 的 idle 不會歸零。

E-Core 744 MHz vs P-Core 3699 MHz，**約 5 倍頻率差**，加上 E-Core 微架構本身更省電，實際功耗差更大。（精確瓦數沒測。）

> 誠實標註：P-Cluster 側看不出變化，因為測試機上還有別的負載佔著，靶進程離開後空位立刻被補上。所以「離開 P-Core」是從 E 側反推的**間接**證據。

### 為什麼不把「所有」行程都踢去 E-Core

很自然會想：既然降級有效，何不全部都踢？實測本機（M3 Pro / macOS 26.7）自己帳號下 **571 個行程**的 `pri` 分布，答案就很清楚了：

| `pri` | 行程數 | |
|---|---|---|
| **4** | **356** | 與實測 `taskpolicy -b` 的結果值相同 ⇒ 強烈指向**早已是 background QoS** |
| 20 | 26 | |
| 31 | 58 | 一般前景行程（降級的目標長相）|
| 37–61 | ~130 | UI／較高優先級 |
| 97 | 4 | realtime（音訊之類，不該碰）|

**62% 的行程本來就在 background。** macOS 自己早把絕大多數背景 daemon 丟到 E-Core 了（`accountsd`、`adprivacyd`、`AMPLibraryAgent` 等全是 `pri=4`）。

所以無差別全部降級有兩個問題，第二個是致命的：

1. **對那 62% 完全沒收益** — 它們已經在那裡了
2. 🔴 **還原會反效果** — 因為讀不到原始 QoS（`taskinfo` 需 root），還原時會把那 356 個本來是 background 的行程**升級**成非 background。**想省電，結果把 356 個 daemon 從 E-Core 放出來，比不做更糟。**

⇒ 所以用白名單。但白名單裡該放什麼，**別憑印象猜，量一次就知道**。

### 誰才是真的一直在吃 CPU

`ps` 的 `%CPU` 是行程啟動至今的平均值，看瞬時要用 `top` 取第二次取樣：

```bash
top -l 2 -n 25 -o cpu -stats pid,cpu,command | awk '/^PID/{p++} p==2'
```

在一台開著瀏覽器、通訊軟體、幾個 agent CLI 的工作機上實測，結果可能跟直覺不同：

| 類型 | 瞬時 %CPU | `pri` | 要不要放進白名單 |
|---|---|---|---|
| agent CLI（Claude Code 等） | 中～高 | 20–31 | ✓ 主要目標 |
| **瀏覽器 renderer / helper** | **可達 80%+** | **47–55** | ✓ **常是最大戶** |
| 通訊軟體 helper（Slack 等） | 個位數～中 | 46 | ✓ 可加 |
| 終端 app | 個位數 | 46 | △ 加了 Ctrl+C 反應會變鈍 |
| **EDR / DLP / MDM agent** | **可達 50%+** | 20–37 | 🔴 **不要碰**（見下）|
| `WindowServer`、`kernel_task` | 中～高 | 79 / — | 🔴 系統關鍵，多為 root，動不了也不該動 |
| 各種 `*d` daemon | 近 0 | 4 | ✗ 已在 background |

**瀏覽器往往比 agent 本身還耗。** 背景 tab、擴充套件、Service Worker 在闔蓋後照樣跑，而它們的 `pri` 是 47–55（**比一般前景行程的 31 還高**），降級空間反而最大。瀏覽器自己會節流部分背景 tab（有些 helper 已經在 `pri=4`），但吃最兇的那幾個不會。

### 🔴 企業管控軟體：不要碰

受管的公司筆電上通常跑著 EDR、DLP、MDM agent，而且它們**經常是 CPU 排行前幾名**。不要把它們放進白名單：

- 多數以 root 執行，降級根本不會成功（靜默失敗）
- 少數以使用者身分跑的，降級可能**觸發合規告警**，或被判定為干擾安全代理的行為
- 這類軟體通常有自我保護與看門狗，你的變更可能被還原、或被記成一筆事件

判斷方式很簡單：**不是你自己裝的、名字沒聽過的，就別動。**

### 怎麼改白名單

腳本裡是寫死的一行（`demote_claude_to_ecore()` 內）：

```bash
pids=$(pgrep -f "claude")
```

要加別的目標就改這個 pattern。`pgrep -f` 是對**完整命令列**做比對、**區分大小寫**：

```bash
pids=$(pgrep -f "claude|Google Chrome|Slack|ffmpeg")    # 多個目標用 | 分隔
```

改完**務必先驗一次它抓到誰**，再讓腳本去動它們：

```bash
pgrep -fl "claude|Google Chrome|Slack|ffmpeg"    # -l 會一併印出命令列
```

這一步不能跳過。實際跑一次就知道為什麼——用 `iTerm` 當 pattern，抓到的第一筆不是終端主程式：

```
$ pgrep -fl 'claude|iTerm'
1079 /Applications/iTerm.app/Contents/XPCServices/pidinfo.xpc/Contents/MacOS/pidinfo
2499 claude --resume 97a0d3e3-...
```

`-f` 比對的是整條命令列，所以任何路徑裡含有該字串的行程都會中——包括 app 底下的 XPC service、helper、甚至你自己的測試腳本。**pattern 寫寬一個字，誤傷面就大一圈。看清楚了再跑。**

（`pgrep` 的 pattern 是 extended regular expression，所以 `|` 可用；區分大小寫，因此 `claude` 不會命中首字大寫的 Claude Desktop。兩者皆已實測。）

> **帶得走的一條**：動手「最佳化」之前先量測現狀。這裡的現狀有兩層——系統已經幫你把 62% 放進 E-Core（無差別套用會破壞它），而真正的大戶可能是瀏覽器而不是你以為的那個程式。

### `pmset -g therm` 在 Apple Silicon 平時是空的

腳本原本拿 `CPU_Speed_Limit` 當第二個判據。在 M3 Pro 上平時完全沒這個欄位：

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

所以那個判據不成立，保護全靠熱壓力等級撐。而日誌印的是 `CPU 限速: ${CPU_LIMIT:-100}%`，**讀不到時它顯示 100%，而那個 100% 的意思是「沒讀到值」**。

推測 `Heavy` 起該欄位才會被記錄（訊息用的是 "has been **recorded**"，即「尚未記錄」而非「不支援」）。**沒實證**——無法人為把機器逼到 `Heavy`。

### 背景啟動的行程，`SIGINT` 會被忽略（測試假陰性陷阱）

POSIX 行為：非互動 shell 用 `&` 啟動的行程，`SIGINT` 被設為忽略，而且腳本裡的 `trap` **蓋不掉**。

| 送什麼 | 結果 |
|---|---|
| 背景啟動 + `kill -INT` | **trap 完全沒觸發**，14 秒後行程還活著 |
| 背景啟動 + `kill -TERM` | trap 觸發，`exit 130` ✓ |

⇒ **用 `kill -INT` 測背景腳本的中斷路徑，會拿到永遠通過的假陰性。** 這支腳本就有一次「中斷路徑已驗證」是這樣來的假驗收。要改用 `SIGTERM` 走同一個 handler 才驗得到。

至於延遲：單一行程送訊號時，bash 在等前景子行程（`sleep 10`）時收到訊號，**要等子行程結束才跑 handler**，所以延遲上限是一個 sleep 週期。真的按 `Ctrl + C` 不受此限——終端把 `SIGINT` 送給**整個 foreground process group**，`sleep` 一起被殺，bash 立刻返回 ⇒ 即時退出。

### 黑名單還是白名單 — fail-safe 的方向要看操作是單向還是雙向

熱壓力判定式是列舉危險等級（黑名單）。曾想改成白名單（「只有 `Nominal`/`Moderate` 算安全，其餘都危險」），那樣未來新增的等級會自動 fail-safe。**否決了**，因為降頻是雙向的：

- 進入條件：非 `Nominal`/`Moderate`
- 解除條件：`Nominal`/`Moderate`

白名單下，未知等級**進得去卻出不來**，會黏在低耗電模式裡永不解除。

代價是黑名單漏列就會靜默漏接——而這不是理論風險：**原版就漏了 `Sleeping`**（註解裡寫了、判定式裡沒有），漏掉的正好是「防止晶片永久燒毀」那一級。所以程式碼裡留了維護責任註記。

---

## 怎麼驗的

被測物會改**電源設定**、還會對**正在工作的行程**動手，所以驗證必須完全隔離。方法本身也許比這支腳本更值得帶走。

### shim 隔離系統指令

PATH 前置一組假指令替換 `sudo` / `pmset` / `powermetrics` / `afplay`，**全程沒有真的改過測試機的電源設定**：

```bash
SHIM=$(mktemp -d)
cat > "$SHIM/pmset" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *batt*)     echo " -InternalBattery-0 (id=1)	${MAPA_BATT:-100}%; discharging; ..." ;;
  "-g therm") echo "CPU_Speed_Limit 	= 100" ;;
  *)          echo "[shim pmset] $*" >&2 ;;   # 把呼叫記到 stderr 當證據
esac
EOF
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH" bash mapa.sh 0 10
```

shim 把攔下的呼叫印到 stderr，反過來成為**「`restore_settings` 真的跑到了」的正面證據**。

### 有狀態的 shim — 逼出狀態轉換分支

要測「降頻後回穩再解除」，shim 得中途改變回傳值。用一個計數檔：

```bash
n=$(cat "$CNT"); n=$((n + 1)); echo "$n" > "$CNT"
if [ "$n" -le 1 ]; then echo "Current pressure level: Heavy"
else                     echo "Current pressure level: Nominal"; fi
```

跑出來的時序（熱壓力每 30 秒查一次）：

```
23:31:58  Heavy    → 主動開啟低耗電模式  → [shim pmset] -a lowpowermode 1
23:32:28  Nominal  → 解除強制低耗電模式  → [shim pmset] -a lowpowermode 0
```

### wrapper ＋ 白名單 — 非得對真實行程動手時

E-Core 降級必須用**真的** `taskpolicy` 才驗得到 QoS 變化，但測試機上有正在工作的 agent 不能碰。做法是 wrapper：記錄呼叫、**只對白名單內的靶進程轉發**，其餘一律拒絕。

```bash
if grep -q "^${PID}$" "$TARGET_PIDS"; then
  exec /usr/sbin/taskpolicy "$@"          # 轉發給真的
else
  echo "[BLOCKED] PID=$PID not in target list" >> "$LOG"; exit 1
fi
```

再加一層保險：`pgrep` 也被 shim 成只回傳靶進程 PID，所以即使白名單失效也碰不到真實行程。

### 測過的情境

| 情境 | 結果 |
|---|---|
| 電量 ≤ 閾值 | ✓ |
| 時間上限（真等 60 秒）：預計結束時間、`執行 1 分鐘` 計算 | ✓ |
| `Sleeping` 熔斷（**修前會漏接**） | ✓ |
| `Trapping` 熔斷 | ✓ |
| `Heavy` 只降頻、不熔斷 | ✓ |
| `Heavy → Nominal` 降頻後回穩解除（回填原值非寫死） | ✓ |
| `Nominal` 完全不觸發 | ✓ |
| `SIGTERM` 走 `on_interrupt`：`exit 130`、狀態全還原 | ✓ |
| 沒有目標行程時安靜跳過 | ✓ |
| 非數字參數正常拒絕 | ✓ |
| 多時區時戳：`UTC+8` / `UTC+5:45` / `UTC-4` / `UTC-9:30` | ✓ |

每條退出路徑都另外確認：防休眠解除、低耗電回填原值、行程 QoS 還原。

---

## 四條帶得走的原則

1. **`exit 0` 不等於生效。** 設定類指令要驗證可觀測的狀態變化。`taskpolicy -c background -p` 回報成功卻什麼都沒做，而流傳的寫法還用 `2>/dev/null` 吞掉唯一線索。
2. **fail-safe 的方向要看操作是單向還是雙向。** 「未知即危險」在單向操作上更安全，但在「進入／解除」雙向的機制裡會造成進得去出不來。選之前先問：出不來的代價是什麼。
3. **「還原」要回填原值，不要寫死預設值。** 流傳的 QoS 寫法寫死 `default`，是錯的。讀不到原值時（例如 `taskinfo` 需 root），退而記錄「自己改過哪些」，只還原那些。

   **這條最好的反面教材就是這支腳本自己。** 它對 `lowpowermode` 做對了（啟動時存 `ORIG_LOW_POWER` 再回填），但同一個函式的上一行，`disablesleep` **曾經**寫死 `0`：

   ```bash
   # 修復前的樣子 —— 不是現在的程式碼
   restore_settings() {
     sudo pmset -a disablesleep 0                    # ← 寫死，錯的
     sudo pmset -a lowpowermode "$ORIG_LOW_POWER"    # ← 回填原值，對的
   ```

   使用者若本來就自己開著 `disablesleep=1`（例如平常就不讓機器睡），MAPA 收工時會把他的設定一併關掉。同一個函式、相鄰兩行、兩種標準。

   **已修** —— 腳本現在啟動時會記下 `ORIG_DISABLE_SLEEP` 並回填，跟 `lowpowermode` 同一套做法。

   抓到它的時機跟缺陷本身一樣要緊：**是在 commit 前的獨立審查（`codex review`）裡抓到的，而且是在這條原則已經寫進本文之後。** 知道原則不等於遵守原則——這正是「commit 前必須先過獨立審查」這種機械閂的價值：它不依賴任何人記得自己有沒有違反自己寫的規則。

4. **「任何退出路徑都會還原」這個保證，必須涵蓋收尾階段本身。** 只把 `trap` 設在開頭不夠——收尾如果提早解除 `trap`，後面每一個還沒還原完的動作都是真空窗口。

   這支腳本原本就是這樣寫的：

   ```bash
   # 修復前的樣子 —— 不是現在的程式碼
   trap - INT TERM                      # ← 收尾一開始就解除
   play_audio "ready_to_work.mp3" true  # ← 等音效播完，阻塞數秒
   restore_settings                     # ← 上面那幾秒被中斷，這行永遠不會執行
   ```

   收工音效是「等它播完」的，那幾秒內按 Ctrl+C，防休眠會留著開、行程留在 E-Core——正好違反文件自己宣稱的保證。**已修** —— `trap -` 現在放在 `restore_settings` **之後**。前提是還原函式要**冪等**（重設同一個值無害、已還原的清單已清空），這樣中途被中斷而重入也安全。

   一樣是獨立審查抓到的，同一輪的第二個 P1。**「開頭設好 trap」會給人一種已經處理完的錯覺，而漏掉的是另一端。**
