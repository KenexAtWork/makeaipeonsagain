# MAPA — Make AI Peons Again

**Hand a long task to an AI coding agent, shut the lid, walk out. It keeps working — and shuts itself down safely when battery, time, or heat hits your limit.**

One bash script, 250 lines, **zero dependencies, zero install**. **Not a product — a fun little toy**, and worth saying twice. It doesn't aim to be perfect; it aims to be simple, readable, and easy to change. Nobody's going to make money off it, but it might keep a laptop from cooking in a backpack, or save someone a few hours of chasing a command that silently does nothing.

```bash
./mapa.sh 180 15    # run 3 hours, wrap up when battery drops to 15%
```

Tested on: Apple M3 Pro / macOS 26.7 (Darwin 25.6) / `/bin/bash` 3.2.57.

> 🇹🇼 中文版 → **[README.zh-TW.md](README.zh-TW.md)**
> Want the technical details — pitfalls hit, how it was verified? → **[NOTES.md](NOTES.md)**

---

## Usage

```bash
./mapa.sh                # defaults: 60 minutes, 10% battery floor
./mapa.sh 180 15         # 3 hours, 15% battery floor
./mapa.sh 0 20           # no time limit, run until battery hits 20%
```

Both arguments are integers: **minutes** (`0` = no limit) and **battery floor in percent** (must be 0–100; anything higher is rejected).

It asks for your sudo password once (`pmset` and `powermetrics` need it). After that, close the lid and go.

What it looks like while running:

```
[2026/09/28 23:31:57 UTC+8] >>> 防休眠已啟用！隨時可按 Ctrl + C 取消。
[2026/09/28 23:31:57 UTC+8] >>> 電量保護下限：10%
[2026/09/28 23:31:58 UTC+8] >>> [警告] 偵測到機身過熱！熱壓力: Heavy
[2026/09/28 23:31:58 UTC+8] >>> 主動開啟「低耗電模式」進行強制 Throttle 降溫...
[2026/09/28 23:32:28 UTC+8] >>> 機身溫度已恢復正常，解除強制低耗電模式。
```

> Log messages are in Traditional Chinese (the script was written that way and I kept it). Timestamps show the UTC offset, computed live from `date +%z` rather than hardcoded — half-hour zones like `UTC+5:45` and `UTC-3:30` are handled correctly.

`Ctrl + C` at any time — it restores every system setting it touched.

> A bit of fun baked in: it plays the WC3 orc peon's "Work work" on start, "Under attack" when it detects heat, and "Ready to work" when it wraps up.
> **Sound files are not in this repo** (third-party copyrighted material) — bring your own; filenames are in [`audio/README.md`](audio/README.md). Missing files don't break anything, you just get one log line saying it skipped them.

---

## Before you leave: make the Mac auto-connect to your phone's hotspot

**With the lid shut, you can't click a Wi-Fi network.** And an agent that can't reach an API is an agent burning battery for nothing — the machine keeps drawing power while the task makes no progress. So make sure the Mac will connect on its own.

> The `networksetup` commands below were verified on macOS 26.7. **The phone-side and System Settings steps were not tested** — UI labels shift between versions.

### iPhone

Two paths. Set up **both**:

**① Instant Hotspot** — the Mac connects without a password, and the iPhone doesn't even need its hotspot toggle flipped first (the Mac asks it over Bluetooth). Requirements:

- Mac and iPhone signed into the **same Apple Account**
- **Wi-Fi and Bluetooth on** on both
- **Handoff** enabled (Mac: Settings → General → AirDrop & Handoff; iPhone: Settings → General → AirPlay & Continuity)

**② Fixed SSID + password** — more reliable, and it's the only option for Android. Makes the Mac treat the hotspot as an ordinary known network:

- iPhone: Settings → Personal Hotspot → set a Wi-Fi password
- The hotspot SSID is the device name, changeable at Settings → General → About → Name (**pick something without special characters** to save yourself quoting headaches)
- Connect once from the Mac using the password → it lands in the preferred-networks list and will be joined automatically afterwards

This path doesn't depend on Apple Account, Bluetooth, or Handoff — three fewer things to fail.

### 🔑 The setting people miss: auto-join hotspots

**Remembering the hotspot isn't enough.** macOS won't join a personal hotspot on its own by default (it's trying not to eat your cellular data). Turn it on:

**System Settings → Wi-Fi → scroll down to "Ask to join hotspots" → set to "Automatically"**

| Option | Behaviour |
|---|---|
| Never | Ignores hotspots entirely |
| Ask | Prompts you — **which means it won't connect while the lid is shut** |
| **Automatically** | Joins an available hotspot when no known Wi-Fi is around ✓ |

Skip this and both paths above are wasted.

### Doing it from the command line (verified)

```bash
# Find your Wi-Fi interface (usually en0)
networksetup -listallhardwareports | grep -A1 "Wi-Fi"

# Connect now (a successful connect also records it as a known network)
networksetup -setairportnetwork en0 "MyiPhone" "password"

# Explicitly add it to the preferred list at top priority (index 0)
networksetup -addpreferredwirelessnetworkatindex en0 "MyiPhone" 0 WPA2PSK "password"

# Check what you're on
networksetup -getairportnetwork en0

# Check preference order (only the top few really matter)
networksetup -listpreferredwirelessnetworks en0 | head
```

Why index 0 matters: if the Mac is still on your office or home Wi-Fi when you leave, it walks the **preference order** looking for the next network as you go out of range — put the hotspot near the top so it gets tried first.

### Verify it actually auto-connects

Don't trust "it should work." Toggle Wi-Fi off and on and see whether it comes back on its own:

```bash
networksetup -setairportpower en0 off
sleep 5
networksetup -setairportpower en0 on
sleep 20
networksetup -getairportnetwork en0     # should show your hotspot
```

### Android

There's no Instant Hotspot equivalent (unless you're in a single-vendor ecosystem, e.g. Samsung's Auto Hotspot between its own devices), so it's the fixed SSID + password path only:

1. Settings → Network & internet → Hotspot & tethering → Wi-Fi hotspot
2. Set a name and password
3. **🔴 Turn OFF "Turn off hotspot automatically"** (usually under advanced settings)
4. Connect once from the Mac using the commands above

Step 3 is the one that matters most on Android: **that option is on by default**, and it shuts the hotspot down after a while with no clients connected. Step into an elevator once, lose the connection, and the hotspot is gone — and your lid is shut, so you won't find out.

### Things you'll actually run into

- **The iPhone stops advertising its hotspot when nothing is connected.** Instant Hotspot can wake it over Bluetooth, but both devices need to be in range — phone in your pocket, Mac in your bag is usually fine. On path ② keep "Allow Others to Join" on.
- **2.4 GHz vs 5 GHz**: the iPhone's "Maximize Compatibility" ON = 2.4 GHz, slower but better penetration; OFF = 5 GHz, faster but shorter range. Phone and Mac in the same bag? 5 GHz is fine. One in a pocket, one in a bag? 2.4 GHz is steadier.
- **Nothing is protecting your phone's battery.** MAPA watches the Mac's battery, but running a hotspot drains a phone fast — **your phone may die before the Mac does**. Bring a power bank for long runs.
- **Low Power Mode on the phone hurts hotspot stability.** Turn it off before you go.
- **MAPA doesn't check the network.** It only watches battery, time, and heat. If you lose connectivity it won't stop — it keeps drawing power until one of its limits trips. So verify with the toggle test above before you leave.

---

## Three things worth understanding first

If you're not deep in macOS power management, these three are enough.

### 1. Why closing the lid puts it to sleep, and why `caffeinate` can't help

`caffeinate` prevents **idle sleep**. But **closing the lid is a different thing** — macOS clamshell logic wants external power *and* an external display before it'll keep running; without them, it sleeps.

To keep running on **battery, with nothing attached, lid shut**, there is exactly one lever:

```bash
sudo pmset -a disablesleep 1
```

It's a system-wide switch, which is why sudo is needed — and why it **must** be restored on exit (this script restores it on every exit path).

### 2. Thermal pressure level

**A closed lid is the worst possible cooling posture.** A machine running flat out inside a bag is a real risk, and it's the main reason this script exists.

But **you can't read CPU temperature on Apple Silicon**: `sysctl` has no die-temp field (only `kern.clockrate` and `hw.tbfrequency`, neither of which is temperature or CPU frequency), `powermetrics` doesn't report die temperature, and reading SMC sensors means a third-party tool — i.e. a dependency.

So the signal used here is macOS's own **thermal pressure level**, a five-step state:

```bash
sudo powermetrics -n 1 -i 200 --samplers thermal | grep "pressure level"
# → Current pressure level: Nominal
```

| Level | What the system is doing |
|---|---|
| `Nominal` | Comfortable headroom, running at full speed |
| `Moderate` | Warming up, fans spinning up, clocks normal or lightly trimmed |
| `Heavy` | **System is throttling**, `CPU_Speed_Limit` drops, background work suppressed |
| `Trapping` | Close to TjMax, aggressive down-clocking and voltage reduction |
| `Sleeping` | Throttling no longer contains it — **system force-sleeps or shuts down** to avoid permanent damage |

> ⚠️ That table is community knowledge. **Apple publishes no documentation** mapping these levels to actual temperatures or behaviour, and the mapping varies by model and environment.

### 3. E-cores and P-cores

Apple Silicon has two core types: **P-cores** (performance — fast, power-hungry) and **E-cores** (efficiency — slow, frugal). Normally the system decides what runs where.

macOS exposes a lever for this via **QoS (Quality of Service)** — mark a process as "background" and the system confines it to E-cores:

```bash
taskpolicy -b -p <pid>    # demote: confine to E-cores
taskpolicy -B -p <pid>    # restore
```

**The key part is that QoS is inherited by child processes.** A coding agent is one main process that forks `git`, test runners, compilers and so on when it uses tools — demote the parent once and **all of those inherit it automatically**, so none of them suddenly wakes a P-core.

When you're out with the lid shut, the agent's work doesn't need P-core speed. Confining it to E-cores saves power and heat. This is the single most useful trick in the script.

---

## What it actually does

```
  start ──► install trap (so any interruption still restores)
            ├─ pmset -a disablesleep 1      prevent sleep
            └─ demote agent processes to E-cores
              │
              ▼
  main loop (every 10s)
    │
    ├─[1] battery ≤ floor ──────────────────┐
    ├─[2] time limit reached ───────────────┤
    └─[3] thermal pressure (checked /30s)   │
            ├─ Heavy ────► enable low power mode, keep running
            ├─ back to Nominal ─► disable low power mode
            └─ Trapping / Sleeping ─────────┤
                                            ▼
                                  restore everything
                          (sleep prevention, low power mode, QoS)
                                            │
                             ┌──────────────┴──────────────┐
                             ▼                             ▼
                       pmset sleepnow              exit 130 (Ctrl+C)
```

The three guards respond differently, and the difference matters:

| Trigger | Action |
|---|---|
| Battery floor | Wrap up → sleep |
| Time limit | Wrap up → sleep |
| Thermal `Heavy` | **Enable low power mode and keep going**; disable it once things settle |
| Thermal `Trapping` / `Sleeping` | **Wrap up and sleep immediately** (throttling isn't going to save it) |

In other words: **`Heavy` is the level that throttling can actually hold; by `Trapping` the script's job is to decide "time to sleep."**

Three deliberate design points:

1. **The `trap` is installed before the first command that changes system state** (`mapa.sh:157` vs `:160`). Otherwise there's a window where state is already modified but Ctrl+C isn't caught.
2. **All four exit paths share one `restore_settings()`**, and all four are verified to reach it.
3. **Restore writes back the original value rather than a hardcoded default.** It records `ORIG_LOW_POWER` at startup and writes that back — it doesn't assume low power mode was off to begin with.

---

## Things worth knowing

It's not a product and doesn't try to be perfect. These are the ones you'll actually meet:

- **Agents started mid-run don't get demoted** — it scans once at startup, no polling.
- **`kill -9` leaves processes demoted** (`trap` can't catch `SIGKILL`). Manual restore:
  ```bash
  pgrep -f "claude" | xargs -I {} taskpolicy -B -p {}
  ```
- **Thermal decisions are made on a single sample, with no sustained check** — one 100 ms reading of `Trapping` triggers sleep, so in theory a momentary spike could cut a long task short. Hasn't happened in practice, but it's a known weak spot.
- **One stray `Terminated: 15` line on exit** — the job-control notice from killing the background sudo-keepalive job. Harmless. Fixing it means touching the keepalive loop, which is load-bearing (lose the credential and sleep prevention fails entirely), so it stays.
- **Piping or `$(...)`-capturing the output can hang for up to 60s** — an orphaned `sleep` still holds the stdout write end. Running it directly in a terminal is unaffected; to save a log use `> file` (redirection doesn't block).
- **The demotion target is hardcoded to `pgrep -f "claude"`** — change that pattern for a different agent. `pgrep` is case-sensitive, so it won't catch the capital-C Claude Desktop app (verified).
- **bash 5.x untested** — the test machine only has `/bin/bash` 3.2.57.

---

## Want something more full-featured

This script's angle is "install nothing, read it in five minutes, change it in one line." If you want a finished product, there are better options.

**[keepresso](https://github.com/gyorgysh/keepresso)** (Swift/SwiftUI menu bar app, GPL-3.0) covers nearly everything here and does most of it better — thermal protection can read temperature sensors, has a **sustained** threshold check, boosts fans before pausing the session, and recovers automatically; it also has agent hooks for Claude Code / Cursor / Codex. What it doesn't have is E-core relegation.

**[Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704)** (App Store, free) has sleep prevention plus battery and CPU-utilization triggers, but **no** thermal protection.

| | This script | keepresso | Amphetamine |
|---|---|---|---|
| Lid-closed, battery only, no external display | ✓ | ✓ | ✓ |
| Battery / time limits | ✓ | ✓ richer | ✓ |
| Thermal protection | ✓ | ✓ more complete | ✗ |
| **E-core relegation** | ✓ | ✗ | ✗ |
| **What you have to install** | **nothing** | DMG / Homebrew cask + optional admin helper | App Store; on Apple Silicon, closed-display mode needs a file written to `/private/etc/sudoers.d/` |

That last row is the main reason to pick this one: **on a managed corporate laptop, installing a third-party app, a Homebrew cask, or writing into `/private/etc/sudoers.d/` can all fail review. A bash script you can read usually doesn't.**

---

## Going deeper

Everything you need to *use* it is above. If you want to modify it, or want to know what went wrong while building it, that's all in **[NOTES.md](NOTES.md)**:

- **Pitfalls hit** — `taskpolicy -c background -p` returns exit 0 while doing nothing at all; `nice` is not a QoS indicator; why "restore" must not re-run `pgrep`; measured evidence that E-core relegation works; why you should *not* demote every process (62% are already there); which processes will bite you if you touch them; `pmset -g therm` is empty most of the time on Apple Silicon; background processes have `SIGINT` ignored, which produces false-negative tests; blacklist vs whitelist as a fail-safe trade-off
- **How it was verified** — shims to isolate system commands (no real power settings were ever changed on the test machine), stateful shims to force state-transition branches, a wrapper + allowlist for when you must touch real processes, and the eleven scenarios covered
- **Three principles worth taking away**
