# MAPA — Make AI Peons Again

**Hand a long task to an AI coding agent, shut the lid, walk out. It keeps working, then shuts itself down when battery, time, or heat hits your limit.**

One bash script, 250 lines, **zero dependencies, zero install**. **This is a toy, not a product.** I'd rather it stay simple and readable than cover every case. Nobody will make money from it. It might keep your laptop from cooking in a backpack, or save you a few hours chasing a command that reports success while doing nothing.

```bash
./mapa.sh 180 15    # run 3 hours, wrap up when battery drops to 15%
```

Tested on: Apple M3 Pro / macOS 26.7 (Darwin 25.6) / `/bin/bash` 3.2.57.

> 🇹🇼 中文版 → **[README.zh-TW.md](README.zh-TW.md)**
> Pitfalls and how I verified it → **[NOTES.md](NOTES.md)**

---

## Usage

```bash
./mapa.sh                # defaults: 60 minutes, 10% battery floor
./mapa.sh 180 15         # 3 hours, 15% battery floor
./mapa.sh 0 20           # no time limit, run until battery hits 20%
```

Both arguments take integers: minutes (`0` means no limit) and battery floor in percent. The floor must sit between 0 and 100; the script rejects anything higher.

It asks for your sudo password once, because `pmset` and `powermetrics` need it. Then close the lid and go.

Here is a run in progress:

```
[2026/09/28 23:31:57 UTC+8] >>> 防休眠已啟用！隨時可按 Ctrl + C 取消。
[2026/09/28 23:31:57 UTC+8] >>> 電量保護下限：10%
[2026/09/28 23:31:58 UTC+8] >>> [警告] 偵測到機身過熱！熱壓力: Heavy
[2026/09/28 23:31:58 UTC+8] >>> 主動開啟「低耗電模式」進行強制 Throttle 降溫...
[2026/09/28 23:32:28 UTC+8] >>> 機身溫度已恢復正常，解除強制低耗電模式。
```

> Log messages come out in Traditional Chinese. The script arrived that way and I kept it. Timestamps carry the UTC offset, computed from `date +%z` at runtime instead of hardcoded, so half-hour zones like `UTC+5:45` and `UTC-3:30` come out right.

Press `Ctrl + C` whenever you want. The script restores every system setting it touched.

> One bit of fun: it plays the WC3 orc peon's "Work work" on start, "Under attack" when it sees heat, and "Ready to work" when it wraps up.
> **The sound files are not in this repo**, since they belong to someone else. Bring your own; [`audio/README.md`](audio/README.md) lists the filenames. Missing files cost you nothing but one log line.

---

## Before you leave: make the Mac find your phone's hotspot

**Once the lid is shut you cannot click a Wi-Fi network.** An agent that can reach no API burns battery and makes no progress. So set this up before you walk out.

> I verified the `networksetup` commands below on macOS 26.7. I did not test the phone-side steps or the System Settings path, and Apple moves those labels between versions.

### iPhone

Two paths. Set up both.

**① Instant Hotspot.** The Mac connects without a password, and you don't even have to flip the hotspot toggle on the iPhone first, because the Mac asks it over Bluetooth. You need:

- Both devices signed into the same Apple Account
- Wi-Fi and Bluetooth on, both sides
- Handoff enabled (Mac: Settings → General → AirDrop & Handoff; iPhone: Settings → General → AirPlay & Continuity)

**② Fixed SSID and password.** Fewer moving parts, and the only path Android gives you. The Mac treats your hotspot as an ordinary known network:

- iPhone: Settings → Personal Hotspot → set a Wi-Fi password
- The SSID is the device name. Change it at Settings → General → About → Name, and **pick something without special characters** so you skip the quoting headaches.
- Connect once from the Mac with that password. The hotspot lands in the preferred-networks list and the Mac joins it on its own after that.

Path ② drops three dependencies: Apple Account, Bluetooth, Handoff.

### 🔑 The setting people miss: auto-join hotspots

**Remembering the hotspot gets you nowhere on its own.** macOS leaves personal hotspots alone by default, to protect your cellular data. Turn it on:

**System Settings → Wi-Fi → scroll to "Ask to join hotspots" → choose "Automatically"**

| Option | What happens |
|---|---|
| Never | The Mac ignores hotspots |
| Ask | The Mac prompts you, so it connects to nothing while the lid is shut |
| **Automatically** | The Mac joins an available hotspot once no known Wi-Fi is around ✓ |

Skip this one setting and both paths above go to waste.

### From the command line (verified)

```bash
# Find your Wi-Fi interface (usually en0)
networksetup -listallhardwareports | grep -A1 "Wi-Fi"

# Connect now. A successful connect also records it as a known network.
networksetup -setairportnetwork en0 "MyiPhone" "password"

# Add it to the preferred list at top priority (index 0)
networksetup -addpreferredwirelessnetworkatindex en0 "MyiPhone" 0 WPA2PSK "password"

# See what you're on
networksetup -getairportnetwork en0

# See the preference order. Only the top few matter.
networksetup -listpreferredwirelessnetworks en0 | head
```

Index 0 earns its place: if the Mac still holds your office Wi-Fi when you leave, it walks the preference order looking for the next network as you go out of range. Put the hotspot near the top and the Mac tries it first.

### Prove it joins on its own

Don't trust "it should work." Toggle Wi-Fi off and on, then see whether the Mac comes back by itself:

```bash
networksetup -setairportpower en0 off
sleep 5
networksetup -setairportpower en0 on
sleep 20
networksetup -getairportnetwork en0     # should name your hotspot
```

### Android

Android gives you no Instant Hotspot equivalent, unless you stay inside one vendor's ecosystem (Samsung does this between its own devices). So you take the fixed SSID path:

1. Settings → Network & internet → Hotspot & tethering → Wi-Fi hotspot
2. Set a name and a password
3. **🔴 Turn OFF "Turn off hotspot automatically"**, which usually hides under advanced settings
4. Connect once from the Mac with the commands above

Step 3 carries the most weight on Android. **That option ships on**, and it kills the hotspot after a quiet spell with no clients. Walk into an elevator once, lose the link, and the hotspot goes down. Your lid is shut, so you learn about it when you get there.

### What you will run into

- **The iPhone stops advertising a hotspot when nothing is connected.** Instant Hotspot wakes it over Bluetooth, but both devices need to sit in range. Phone in your pocket and Mac in your bag works. On path ② leave "Allow Others to Join" on.
- **2.4 GHz against 5 GHz.** The iPhone's "Maximize Compatibility" ON gives you 2.4 GHz: slower, better through fabric. OFF gives you 5 GHz: faster, shorter reach. Same bag? Take 5 GHz. One in a pocket and one in a bag? 2.4 GHz holds up better.
- **Nothing guards your phone's battery.** MAPA watches the Mac. Running a hotspot drains a phone fast, and **your phone may die first**. Take a power bank on long runs.
- **Low Power Mode on the phone hurts hotspot stability.** Turn it off before you go.
- **MAPA never checks the network.** It watches battery, time, and heat. Lose connectivity and it keeps drawing power until one of those three trips. Run the toggle test above before you walk out.

---

## Three things worth knowing first

If macOS power management isn't your daily territory, these three cover it.

### 1. Why the lid puts it to sleep, and why `caffeinate` won't save you

`caffeinate` blocks idle sleep. **Closing the lid takes a different path.** macOS clamshell logic wants external power and an external display before it keeps running, and without them it sleeps.

To keep going on battery, nothing attached, lid shut, you get one lever:

```bash
sudo pmset -a disablesleep 1
```

That switch covers the whole system, which explains the sudo prompt, and explains why the script has to put it back on every exit path.

### 2. Thermal pressure level

**A closed lid is the worst cooling posture you can pick.** A machine at full tilt inside a bag is a real risk, and it drove most of this script.

You cannot read CPU temperature on Apple Silicon. `sysctl` carries no die temp, only `kern.clockrate` and `hw.tbfrequency`, and neither one is a temperature or a CPU frequency. `powermetrics` reports no die temperature. Reading SMC sensors means installing a third-party tool, which means a dependency.

So the script reads macOS's own **thermal pressure level**, a five-step state:

```bash
sudo powermetrics -n 1 -i 200 --samplers thermal | grep "pressure level"
# → Current pressure level: Nominal
```

| Level | What the system does |
|---|---|
| `Nominal` | Plenty of headroom, full speed |
| `Moderate` | Warming, fans spin up, clocks normal or trimmed |
| `Heavy` | **The system throttles.** `CPU_Speed_Limit` drops, background work gets suppressed |
| `Trapping` | Near TjMax. Aggressive down-clocking, voltage cuts |
| `Sleeping` | Throttling lost the fight. **The system force-sleeps or shuts down** to save the chip |

> ⚠️ That table comes from the community. **Apple documents none of it.** No published mapping ties these levels to temperatures, and the mapping shifts by model and environment.

### 3. E-cores and P-cores

Apple Silicon ships two core types. P-cores run fast and drink power. E-cores run slow and sip. The system decides what lands where.

macOS hands you a lever through **QoS**. Mark a process as background and the system pins it to E-cores:

```bash
taskpolicy -b -p <pid>    # demote: pin to E-cores
taskpolicy -B -p <pid>    # restore
```

**Child processes inherit QoS, and that is what makes this worth doing.** A coding agent runs as one process that forks `git`, test runners, and compilers as it works. Demote the parent once and every one of those children inherits the setting, so none of them wakes a P-core behind your back.

The agent's work has no use for P-core speed once you're out with the lid down. Pin it to E-cores and you save power and heat. This trick does more for the machine than anything else in the script.

---

## What it does

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

The three guards respond differently, and the difference carries weight:

| Trigger | What the script does |
|---|---|
| Battery floor | Wrap up, then sleep |
| Time limit | Wrap up, then sleep |
| Thermal `Heavy` | **Enable low power mode and keep going.** Disable it once things settle |
| Thermal `Trapping` / `Sleeping` | **Wrap up and sleep now.** Throttling already lost |

`Heavy` is the level throttling can still hold. By `Trapping` the script's job narrows to one decision: sleep.

Three choices I made on purpose:

1. **The `trap` goes in before the first command that changes system state** (`mapa.sh:157` against `:160`). Put it after and you open a window where state has changed but `Ctrl + C` goes nowhere.
2. **All four exit paths run the same `restore_settings()`.** I verified all four reach it.
3. **Restore writes back the original value, never a hardcoded default.** The script records `ORIG_LOW_POWER` at startup and writes that back, so it never assumes low power mode started off.

---

## Things to know

This is a toy and it stays rough in places. You will meet these:

- **Agents you start mid-run stay on P-cores.** The script scans once at startup and never polls.
- **`kill -9` leaves processes demoted**, because `trap` cannot catch `SIGKILL`. Put them back with:
  ```bash
  pgrep -f "claude" | xargs -I {} taskpolicy -B -p {}
  ```
- **One thermal sample decides, with no sustained check.** A single 100 ms reading of `Trapping` sends the machine to sleep, so a momentary spike could cut your task short. I have not seen it happen, and it stays a weak spot.
- **You get one stray `Terminated: 15` line on exit.** That is the job-control notice from killing the background sudo-keepalive job. Harmless. Fixing it means touching that keepalive loop, and the loop is load-bearing: lose the credential and sleep prevention dies with it. So the line stays.
- **Piping the output, or capturing it with `$(...)`, can hang for up to 60s.** An orphaned `sleep` still holds the stdout write end. Run it in a terminal and nothing hangs. To save a log, redirect with `> file`.
- **The demotion target sits hardcoded at `pgrep -f "claude"`.** Change the pattern for a different agent. `pgrep` respects case, so it skips the capital-C Claude Desktop app. I verified that.
- **I never tested bash 5.x.** The test machine carries `/bin/bash` 3.2.57 and nothing else.

---

## If you want more than a toy

This script trades features for "install nothing, read it in five minutes, change it in one line." Two projects beat it on features.

**[keepresso](https://github.com/gyorgysh/keepresso)** (Swift/SwiftUI menu bar app, GPL-3.0) covers nearly everything here and does most of it better. Its thermal protection reads temperature sensors, holds a **sustained** threshold before acting, boosts fans before it pauses your session, and recovers on its own. It also ships agent hooks for Claude Code, Cursor, and Codex. It skips E-core relegation.

**[Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704)** (App Store, free) handles sleep prevention plus battery and CPU-utilization triggers. It offers no thermal protection.

| | This script | keepresso | Amphetamine |
|---|---|---|---|
| Lid closed, battery only, no external display | ✓ | ✓ | ✓ |
| Battery and time limits | ✓ | ✓ richer | ✓ |
| Thermal protection | ✓ | ✓ more complete | ✗ |
| **E-core relegation** | ✓ | ✗ | ✗ |
| **What you install** | **nothing** | DMG or Homebrew cask, plus an optional admin helper | App Store. On Apple Silicon, closed-display mode wants a file in `/private/etc/sudoers.d/` |

That last row decides it for some people. **Your IT review may block a third-party app, a Homebrew cask, or a write into `/private/etc/sudoers.d/`. A bash script you can read in five minutes usually clears.**

---

## Going deeper

Everything you need to run it sits above. **[NOTES.md](NOTES.md)** holds the rest:

- **Pitfalls.** `taskpolicy -c background -p` returns exit 0 and changes nothing. `nice` tells you nothing about QoS. Why "restore" must not re-run `pgrep`. Measured evidence that E-core relegation works. Why demoting every process backfires, since 62% already sit there. Which processes bite back when you touch them. `pmset -g therm` sits empty on Apple Silicon most of the time. Background processes ignore `SIGINT`, which hands you a test that always passes. Blacklist against allowlist as a fail-safe choice.
- **How I verified it.** Shims that isolate system commands, so no real power setting ever changed on the test machine. Stateful shims that force state-transition branches. A wrapper plus allowlist for the cases that need real processes. The eleven scenarios I covered.
- **Four principles worth taking with you.**
