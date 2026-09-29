#!/usr/bin/env bash

# ============================================================
# MAPA: Make AI Peons Again (溫控降頻與音效增強版)
#
# 作者：Kenex Huang（github.com/KenexAtWork）
# 授權：MIT — Copyright (c) 2026 Kenex Huang（全文見 LICENSE）
#
# 參數 1: 運作分鐘數（預設 60 分鐘；輸入 0 為無上限）
# 參數 2: 電量保護閾值（預設 10%）
#
# 謝謝強者大大：
#   Bo-Wei Chen    ｜delay_sleep.sh 的 trap EXIT 完整清理做法
#   Shih-Yong Wang ｜題目發想與 painpoint 確認
#   Cliff Lu       ｜Thermal 限制與時戳日誌的原始建議
# ============================================================

MINS="${1:-60}"
LOW_BATT_THRESHOLD="${2:-10}"

# 取得腳本所在目錄，確保能找到相對路徑的 audio/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIO_DIR="$SCRIPT_DIR/audio"

# 產生時間戳記，格式如：2026/09/28 10:40:35 UTC+8
# 時區偏移由 date +%z 即時換算（不寫死 +8），主公換時區也不會報錯誤資訊
timestamp() {
  local now off sign hh mm
  now=$(date +'%Y/%m/%d %H:%M:%S %z')   # 一次取得，避免跨秒不一致
  off="${now##* }"                      # +0800
  now="${now% *}"                       # 2026/09/28 10:40:35
  sign="${off:0:1}"
  hh=$((10#${off:1:2}))
  mm=$((10#${off:3:2}))
  if [ "$mm" -eq 0 ]; then
    printf '%s UTC%s%d' "$now" "$sign" "$hh"
  else
    printf '%s UTC%s%d:%02d' "$now" "$sign" "$hh" "$mm"   # 半小時制時區（如 +5:30）
  fi
}

# 統一的事件日誌輸出（時戳 + >>> 前綴）
log() {
  printf '[%s] >>> %s\n' "$(timestamp)" "$*"
}

# 參數檢查
# 位數上限不只是防呆，也避免超大數字讓後面的 $((MINS * 60)) 算術溢位。
if ! [[ "$MINS" =~ ^[0-9]{1,7}$ ]] || ! [[ "$LOW_BATT_THRESHOLD" =~ ^[0-9]{1,3}$ ]]; then
  echo "錯誤：參數必須為整數（分鐘數最多 7 位、電量下限最多 3 位）。"
  echo "範例: $0 60 10"
  exit 1
fi
# 電量下限必須落在 0–100：若填了大於 100 的值，主迴圈第一輪就會判定
# 「電量已低於閾值」而立刻收工休眠——使用者只是打錯字，卻會看到機器馬上睡著。
if [ "$LOW_BATT_THRESHOLD" -gt 100 ]; then
  echo "錯誤：電量保護下限必須在 0–100 之間（收到 ${LOW_BATT_THRESHOLD}）。"
  echo "範例: $0 60 10"
  exit 1
fi

echo "=================================================="
echo "   MAPA: Make AI Peons Again"
echo "=================================================="
log "請輸入 Mac 密碼以取得電源管理權限..."
sudo -v || exit 1

# 記錄原始的電源設定（以便退出時精確還原，而非寫死預設值）
ORIG_LOW_POWER=$(pmset -g | awk '/lowpowermode/ {print $2}')
ORIG_LOW_POWER="${ORIG_LOW_POWER:-0}"
# disablesleep 也要存原值：使用者可能本來就自行開著（例如平常就不讓機器睡），
# 收尾時若寫死 0 會把他的設定一併關掉。欄位名是 SleepDisabled（pmset -g 輸出），
# 設定時的參數名才是 disablesleep。
ORIG_DISABLE_SLEEP=$(pmset -g | awk '/SleepDisabled/ {print $2}')
ORIG_DISABLE_SLEEP="${ORIG_DISABLE_SLEEP:-0}"

# 背景保活 sudo（每 60 秒刷新一次憑證）
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

# 音效播放輔助函式（支援精確路徑或自動補 .mp3）
play_audio() {
  local target_name="$1"
  local wait_for_finish="${2:-false}"
  local sound_path=""

  if [[ -f "$AUDIO_DIR/$target_name" ]]; then
    sound_path="$AUDIO_DIR/$target_name"
  elif [[ -f "$AUDIO_DIR/${target_name}.mp3" ]]; then
    sound_path="$AUDIO_DIR/${target_name}.mp3"
  elif [[ -f "./audio/$target_name" ]]; then
    sound_path="./audio/$target_name"
  elif [[ -f "./audio/${target_name}.mp3" ]]; then
    sound_path="./audio/${target_name}.mp3"
  fi

  if [[ -n "$sound_path" ]]; then
    if [ "$wait_for_finish" = true ]; then
      afplay "$sound_path"
    else
      afplay "$sound_path" &
    fi
  else
    log "[提示] 未找到音效檔: $target_name（略過播放）"
  fi
}

# ============================================================
# Claude 行程排程切換（mapa 期間把 AI 苦工壓到 E-Core 省電降溫）
#
# 實測依據（2026-09-28, Apple M3 Pro, macOS 26.7）——以 ps 的 pri 欄位觀測：
#   taskpolicy -b -p <pid>              有效：pri 31 → 4
#   taskpolicy -B -p <pid>              有效：pri 4 → 31（完整還原）
#   taskpolicy -c background -p <pid>   ✗ 無效：pri 不變，但 exit code 仍為 0（靜默失敗）
#   taskpolicy -c default  -p <pid>     ✗ 報錯「Could not parse 'default' as a QoS clamp」且不還原
# ⇒ 只能用 -b / -B，不可用 -c。（nice 欄位不隨 QoS 變動，不可拿來當指標。）
#
# -b 確實有 core 親和性效果（不只是改優先級）——以 powermetrics cpu_power 實測，
# 靶進程為吃滿一核的 yes：
#   E-Cluster idle residency:   23.58% → 0.00%   （E-cluster 閒置被吃光 ⇒ 工作搬進來了）
#   E-Cluster 頻率分布 744 MHz:    32% → 83%     （且以最低頻率檔執行 ⇒ 省電）
#   E-Cluster 平均頻率:        1495 → 877 MHz
#   P-Cluster residency:       100% → 100%（無變化；因同時有其他負載佔著，空位立刻被補上
#                              ⇒「離開 P-core」是從 E 側反推的間接證據，非直接觀測）
#
# 已知取捨：
#   ①taskinfo 需 root，讀不到各行程的原始 QoS ⇒ 無法「存原值再回填」。
#     改為只還原本腳本實際降級過的 PID（DEMOTED_PIDS），不在還原時重跑 pgrep
#     ——否則會誤動中途新開的行程，或把本來就是 background 的行程「升級」。
#   ②中途新開的 Claude 行程不會被降級（只在啟動時掃一次）。
#   ③若本腳本被 kill -9（trap 攔不到），行程會卡在降級狀態；
#     手動還原：pgrep -f "claude" | xargs -I {} taskpolicy -B -p {}
# ============================================================
DEMOTED_PIDS=""

demote_claude_to_ecore() {
  local pids p ok=0
  pids=$(pgrep -f "claude" 2>/dev/null)
  [ -z "$pids" ] && return 0
  for p in $pids; do
    [ "$p" = "$$" ] && continue   # 不降級自己
    if taskpolicy -b -p "$p" 2>/dev/null; then
      DEMOTED_PIDS="$DEMOTED_PIDS $p"
      ok=$((ok + 1))
    fi
  done
  [ "$ok" -gt 0 ] && log "已將 ${ok} 個 Claude 行程降級至 E-Core（Background QoS）"
  return 0
}

restore_claude_from_ecore() {
  local p ok=0
  [ -z "$DEMOTED_PIDS" ] && return 0
  for p in $DEMOTED_PIDS; do
    kill -0 "$p" 2>/dev/null || continue   # 已結束的行程跳過
    taskpolicy -B -p "$p" 2>/dev/null && ok=$((ok + 1))
  done
  [ "$ok" -gt 0 ] && log "已將 ${ok} 個 Claude 行程還原至正常排程"
  DEMOTED_PIDS=""   # 清空，避免 restore_settings 被呼叫兩次時重複動作
  return 0
}

# 系統電源設定還原函式
# 防重入旗標：EXIT trap 與正常路徑／中斷路徑可能各呼叫一次，只讓它實際跑一次。
# （做法借自 Bo-Wei Chen 的 delay_sleep.sh）
RESTORED=0
restore_settings() {
  [ "$RESTORED" -eq 1 ] && return 0
  local attempt ok
  # 重試放在函式裡而不是各呼叫端，這樣正常收工、中斷、EXIT trap 三條路徑
  # 都自動有同樣的保障。原本只在正常路徑重試，等於讓「最後一道保險」那條
  # 反而只試一次——而它最需要重試，因為下面會殺掉 sudo keep-alive。
  for attempt in 1 2; do
    ok=1
    # 兩者都回填啟動時記錄的原值，不寫死預設值。
    # 註：若使用者原本就是 disablesleep=1，還原後最後那道 `pmset sleepnow` 可能
    #     不會真的讓機器睡——那符合他原本「不讓機器睡」的設定意圖，優先尊重。
    sudo pmset -a disablesleep "$ORIG_DISABLE_SLEEP" || ok=0
    sudo pmset -a lowpowermode "$ORIG_LOW_POWER" || ok=0
    [ "$ok" -eq 1 ] && break
  done
  restore_claude_from_ecore
  # keep-alive 要最後才殺：它撐著 sudo 憑證，先殺會讓上面的重試更沒機會成功。
  kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null
  # 只有 pmset 真的成功才鎖上旗標。失敗就不鎖，讓後續路徑還能再試
  # ——若在動作前就鎖，失敗時「最後一道保險」會被自己的防重入旗標關掉。
  # 重試是安全的：DEMOTED_PIDS 已清空、pmset 重設同值無害、kill 對已結束的行程無作用。
  [ "$ok" -eq 1 ] && RESTORED=1
  return 0
}

# 處理 Ctrl + C 手動中斷
on_interrupt() {
  echo ""
  log "[取消] 使用者中斷，正在還原系統設定..."
  restore_settings
  log "已安全退出，Mac 維持喚醒狀態。"
  exit 130
}
trap on_interrupt INT TERM
# EXIT trap 是最後一道保險：涵蓋「以其他方式離開」的情況（例如日後有人在
# 腳本中間加一行 exit，或某個未預期的錯誤讓 shell 退出）。目前的結構沒有
# 這種路徑，但靠的是「剛好沒有」而不是機制保證，所以補上這道。
# restore_settings 有防重入旗標，重複呼叫不會重跑。
trap restore_settings EXIT

# 1. 啟動關閉休眠，並播放起始音效
sudo pmset -a disablesleep 1
play_audio "work_work_peon_wc3" false

# 2. 把既有的 Claude 行程壓到 E-Core（省電降溫；退出時由 restore_settings 還原）
demote_claude_to_ecore

echo "--------------------------------------------------"
log "防休眠已啟用！隨時可按 Ctrl + C 取消。"
log "電量保護下限：${LOW_BATT_THRESHOLD}%"
if [ "$MINS" -eq 0 ]; then
  log "時間上限：無限制（運作至電量耗盡至閾值）"
else
  TARGET_TIME=$(date -v+"${MINS}M" +"%Y/%m/%d %H:%M:%S" 2>/dev/null || date +"%Y/%m/%d %H:%M:%S")
  log "時間上限：${MINS} 分鐘（預計至 ${TARGET_TIME}）"
fi
echo "--------------------------------------------------"

START_TIME=$(date +%s)
MAX_SECONDS=$((MINS * 60))
THROTTLED=0
CHECK_COUNTER=0

# 主監控迴圈（每 10 秒檢查一次）
while true; do
  # 1. 電量檢查
  BATT_LEVEL=$(pmset -g batt | grep -o '[0-9]\{1,3\}%' | head -n 1 | tr -d '%')
  if [ -n "$BATT_LEVEL" ] && [ "$BATT_LEVEL" -le "$LOW_BATT_THRESHOLD" ]; then
    log "電量剩餘 ${BATT_LEVEL}%（達保護閾值），準備收工..."
    break
  fi

  # 2. 時間檢查
  if [ "$MINS" -gt 0 ]; then
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $ELAPSED -ge $MAX_SECONDS ]; then
      log "已達設定時間上限（執行 $((ELAPSED / 60)) 分鐘），苦工完成差事..."
      break
    fi
  fi

  # 3. 溫度與散熱壓力檢查（每 30 秒評估一次，減低監控負擔）
  if [ $((CHECK_COUNTER % 3)) -eq 0 ]; then
    # 讀取系統熱壓力等級（由輕到重：Nominal / Moderate / Heavy / Trapping / Sleeping）
    # 判定式另含 Critical 作為保險（部分版本/文件用此名稱）。
    # ⚠️ 若 Apple 新增等級，須同步更新下方兩處判定式（降頻段、熔斷段），
    #    否則新等級兩邊都不匹配 → 既不保護也不解除降頻，會被靜默漏接。
    THERMAL_LEVEL=$(sudo powermetrics -n 1 -i 100 --samplers thermal 2>/dev/null | awk -F': ' '/pressure level/ {print $2}')
    # 讀取 CPU 速度限制百分比
    CPU_LIMIT=$(pmset -g therm | awk -F'=' '/CPU_Speed_Limit/ {gsub(/[ \t]/,"",$2); print $2}')

    # 判斷是否過熱 (壓力為 Heavy/Trapping 或 CPU 限速低於 80%)
    if [[ "$THERMAL_LEVEL" =~ (Heavy|Trapping|Critical|Sleeping) ]] || [[ -n "$CPU_LIMIT" && "$CPU_LIMIT" -lt 80 ]]; then
      log "[警告] 偵測到機身過熱！熱壓力: ${THERMAL_LEVEL:-未知}, CPU 限速: ${CPU_LIMIT:-100}%"
      play_audio "under_attack.mp3" false

      if [ $THROTTLED -eq 0 ]; then
        log "主動開啟「低耗電模式」進行強制 Throttle 降溫..."
        sudo pmset -a lowpowermode 1
        THROTTLED=1
      fi

      # 若已經達到極端熔斷等級（Trapping 或 Critical），強制休眠防護
      if [[ "$THERMAL_LEVEL" =~ (Trapping|Critical|Sleeping) ]]; then
        log "[緊急] 溫度達到極限臨界點！為防止硬體受損，立即強制休眠..."
        break
      fi
    elif [[ "$THERMAL_LEVEL" =~ (Nominal|Moderate) && $THROTTLED -eq 1 ]]; then
      # 溫度回穩後恢復原設定
      log "機身溫度已恢復正常，解除強制低耗電模式。"
      sudo pmset -a lowpowermode "$ORIG_LOW_POWER"
      THROTTLED=0
    fi
  fi

  CHECK_COUNTER=$((CHECK_COUNTER + 1))
  sleep 10
done

log "任務結束，播放完工音效..."
# 等待 ready_to_work 音效播放完畢——這行會阻塞數秒，所以 trap 必須還在。
play_audio "ready_to_work.mp3" true

log "還原系統設定並使 Mac 進入休眠..."
restore_settings
# 還原完成後才解除中斷攔截。
# 原本這行放在收尾段的開頭，結果上面「等音效播完」那段阻塞期間若被
# Ctrl+C／SIGTERM 打斷，會整個跳過 restore_settings——防休眠留著開著、
# 行程留在 E-Core，正好違反「任何退出路徑都會還原」這個保證。
# restore_settings 本身是冪等的（pmset 重設同值無害、DEMOTED_PIDS 已清空），
# 所以萬一在它執行途中被中斷而重入 on_interrupt，也不會出問題。
trap - INT TERM EXIT
sudo pmset sleepnow
