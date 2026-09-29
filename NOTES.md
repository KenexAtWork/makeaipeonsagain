# MAPA — Pitfalls and How I Verified It

Technical appendix to [MAPA](README.md), for anyone who pokes at macOS power management or QoS, or who wants to test that kind of thing without wrecking their own machine.

**Most of this holds no matter which tool you pick.** `exit 0` does not mean a command worked. Fail-safe points in different directions depending on the operation. You can test a script that modifies system settings without modifying any.

This is a toy, not a product, and it will earn nobody any money. If one of these notes saves you a few hours chasing a command that reports success while doing nothing, it paid for itself.

Tested on: Apple M3 Pro / macOS 26.7 (build 25G229) / `/bin/bash` 3.2.57.

> 🇹🇼 中文版 → **[NOTES.zh-TW.md](NOTES.zh-TW.md)**

---

## 🔴 Pitfalls

Most of this section applies regardless of the tool you end up using.

### `taskpolicy -c background -p <pid>` does nothing, and reports success

The E-core demotion recipe you find online reads `taskpolicy -c background -p <pid>`. I measured it with `ps -o pri`:

| Command | `pri` change | exit code | |
|---|---|---|---|
| `taskpolicy -b -p` | **31 → 4** | 0 | ✓ works |
| `taskpolicy -B -p` | **4 → 31** | 0 | ✓ full restore |
| `taskpolicy -c background -p` | **31 → 31** | **0** | ✗ **no effect, claims success** |
| `taskpolicy -c default -p` | **4 → 4** | non-zero | ✗ errors, and restores nothing |

The usage string explains it. `-c` belongs to the form that launches a new program. Acting on a pid takes only `-b` or `-B`:

```
Usage: taskpolicy [-x|-X] ... [-c <clamp>] [-b] ... <program> [<pargs> [...]]
       taskpolicy [-b|-B] [-t <tier>] [-l <tier>] -p pid
```

`-c default -p` prints `Could not parse 'default' as a QoS clamp`. **Every copy of that recipe I found pipes stderr to `/dev/null`, which throws away your only clue.**

The worst version of this bug arrives when someone fixes the demotion to `-b` and leaves the restore line alone. Processes then sit at `pri 4` until you restart them.

> **Take this one with you: `exit 0` does not mean it worked.** Verify configuration commands by an observable state change, never by exit code. IaC and CLI automation break the same way.

### `nice` tells you nothing about QoS. `pri` does.

`nice` read 5 before and after `taskpolicy -b`. Use `nice` as your indicator and you conclude the command failed.

`taskinfo` shows far more, and it **needs root**. So a normal user cannot read a process's original QoS, which constrains the next item.

### Restore must not re-run `pgrep`

The recipes out there re-run `pgrep` at restore time and set everything they find back to default. That breaks twice: it touches processes that started in the meantime, and it **promotes anything that already ran as background**. Promotion is not restoration.

Since you cannot read the original QoS, restore only the pids you demoted yourself.

```bash
# simplified for illustration; the real one also counts them for the log line
DEMOTED_PIDS=""

demote() {
  for p in $(pgrep -f "claude"); do
    [ "$p" = "$$" ] && continue
    taskpolicy -b -p "$p" 2>/dev/null && DEMOTED_PIDS="$DEMOTED_PIDS $p"
  done
}

restore() {
  for p in $DEMOTED_PIDS; do
    kill -0 "$p" 2>/dev/null || continue   # already gone, skip
    taskpolicy -B -p "$p" 2>/dev/null
  done
  DEMOTED_PIDS=""
}
```

### Does E-core relegation work? Here are the numbers.

I ran a `yes` saturating one core as the target, then compared before and after with `powermetrics --samplers cpu_power`:

| | before | after |
|---|---|---|
| **E-Cluster idle residency** | **23.58%** | **0.00%** |
| E-Cluster frequency distribution | 744 MHz at 32% | **744 MHz at 83%** |
| E-Cluster average frequency | 1495 MHz | 877 MHz |
| P-Cluster residency | 100% / idle 0% | 100% / idle 0% (no change) |

**`E-Cluster idle residency 23.58% → 0.00%`** settles it. The E-cluster ran out of idle time, and at the same moment its frequency distribution collapsed onto the lowest step, 744 MHz, at 83%. One explanation fits both: a CPU-bound task moved into the E-cluster, and the system runs it at the bottom clock.

Had `-b` changed priority without touching core affinity, the target would have stayed on a P-core with a worse place in the queue, and E-cluster idle would not have hit zero.

E-core 744 MHz against P-core 3699 MHz gives you roughly a 5× frequency gap, and E-cores draw less per clock on top of that. I did not measure wattage.

> One caveat I owe you: the P-Cluster side shows no change, because other load on the test machine kept it busy and refilled the slot the target vacated. So I infer "it left the P-cores" from the E side rather than observing it.

### Why demoting every process backfires

The next thought comes fast: if demotion works, why not demote everything? I measured the `pri` distribution across all **571 processes** the user owned:

| `pri` | count | |
|---|---|---|
| **4** | **356** | the value `taskpolicy -b` produces, so these **already run as background** |
| 20 | 26 | |
| 31 | 58 | ordinary foreground processes, what demotion aims at |
| 37–61 | ~130 | UI and higher priority |
| 97 | 4 | realtime, audio and friends. Leave them alone. |

**62% of those processes already sit in background QoS.** macOS put most background daemons on E-cores long ago: `accountsd`, `adprivacyd`, `AMPLibraryAgent` all read `pri=4`.

Demoting indiscriminately breaks twice, and the second one hurts:

1. **You gain nothing on that 62%.** They already sit there.
2. 🔴 **Restore makes it worse.** You cannot read the original QoS, since `taskinfo` needs root, so restore would **promote** all 356 already-background processes. You set out to save power and instead released 356 daemons from the E-cores.

So use an allowlist. **And measure before you fill it, because intuition gets this wrong.**

### Who burns CPU around the clock

`ps` gives you an average since process start. For instantaneous numbers, run `top` and take the second sample:

```bash
top -l 2 -n 25 -o cpu -stats pid,cpu,command | awk '/^PID/{p++} p==2'
```

I measured a working machine with a browser, chat apps, and a few agent CLIs open:

| Type | instantaneous %CPU | `pri` | Allowlist? |
|---|---|---|---|
| agent CLI (Claude Code and friends) | medium to high | 20–31 | ✓ the main target |
| **browser renderer or helper** | **over 80%** | **47–55** | ✓ **often the biggest one** |
| chat app helpers (Slack and friends) | single digits to medium | 46 | ✓ worth adding |
| terminal app | single digits | 46 | △ adding it makes Ctrl+C feel sluggish |
| **EDR / DLP / MDM agents** | **over 50%** | 20–37 | 🔴 **leave alone**, see below |
| `WindowServer`, `kernel_task` | medium to high | 79 / — | 🔴 system-critical, mostly root, you cannot and should not |
| assorted `*d` daemons | near 0 | 4 | ✗ already background |

**Your browser often outweighs the agent.** Background tabs, extensions, and service workers keep running after the lid goes down, and their `pri` reads 47–55, above an ordinary foreground process at 31, which leaves them the most room to fall. Browsers throttle some background tabs on their own, and a few helpers already read `pri=4`, but the heavy ones do not.

### 🔴 Corporate management software: leave it alone

A managed work laptop runs EDR, DLP, and MDM agents, and **they show up near the top of the CPU list**. Keep them off your allowlist:

- Most run as root, so demotion fails without telling you
- The few running as your user may **trip a compliance alert**, or read as interference with a security agent
- This software carries self-protection and watchdogs. Your change may get reverted, or logged as an event

The rule is short: **if you did not install it and do not recognise the name, leave it alone.**

### Changing the allowlist

One hardcoded line does it, inside `demote_claude_to_ecore()`:

```bash
pids=$(pgrep -f "claude")
```

Change the pattern to add targets. `pgrep -f` matches the **full command line** and respects case:

```bash
pids=$(pgrep -f "claude|Google Chrome|Slack|ffmpeg")    # separate targets with |
```

After you change it, **check what it matches** before the script acts on anything:

```bash
pgrep -fl "claude|Google Chrome|Slack|ffmpeg"    # -l prints the command line too
```

Run that once with `iTerm` as a pattern and you see why the step matters. The first hit is not the terminal app:

```
$ pgrep -fl 'claude|iTerm'
1079 /Applications/iTerm.app/Contents/XPCServices/pidinfo.xpc/Contents/MacOS/pidinfo
2499 claude --resume 97a0d3e3-...
```

`-f` matches the whole command line, so anything carrying that string in its path gets caught: XPC services inside an app bundle, helpers, even your own test scripts. Widen the pattern by one character and you widen what you hit. Look first.

(`pgrep` patterns are extended regular expressions, so `|` works. It respects case, so `claude` skips the capital-C Claude Desktop app. I verified both.)

### `pmset -g therm` sits empty on Apple Silicon most of the time

The script first used `CPU_Speed_Limit` as a second signal. On an M3 Pro the field does not exist under normal conditions:

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

So that signal fails, and protection rests on thermal pressure level alone. The log line reads `CPU 限速: ${CPU_LIMIT:-100}%`, so **an unreadable value prints as 100%, which looks like "not throttled" when it means "no idea."**

The field probably fills in from `Heavy` upward, since the message says "has been **recorded**" rather than "unsupported." I could not prove it. No one can force a machine to `Heavy` on demand.

### Background processes ignore `SIGINT`, which hands you a test that always passes

POSIX says a process started with `&` from a non-interactive shell gets `SIGINT` set to `SIG_IGN`, and a `trap` inside the script **cannot take it back**.

| Signal sent | Result |
|---|---|
| background start, `kill -INT` | **trap never fires.** Process still alive 14 seconds later |
| background start, `kill -TERM` | trap fires, `exit 130` ✓ |

So testing a background script's interrupt path with `kill -INT` gives you a test that passes forever. This project carried exactly one bogus "interrupt path verified" result from that. Send `SIGTERM` against the same handler (`trap ... INT TERM`) and you exercise the real path.

On the delay: signal one process and bash receives it while waiting on a foreground child (`sleep 10`), then **holds the handler until that child exits**, so worst case costs you one sleep period. A real `Ctrl + C` skips this, because the terminal signals the **entire foreground process group** and kills the `sleep` too, so bash returns and exits at once.

### Blacklist or allowlist depends on whether the operation runs one way

The thermal check lists the dangerous levels, a blacklist. I considered an allowlist instead, where only `Nominal` and `Moderate` count as safe and everything else counts as dangerous, which would make any future level fail safe. **I rejected it**, because throttling here runs both ways:

- enters on: not `Nominal` or `Moderate`
- exits on: `Nominal` or `Moderate`

Under an allowlist an unknown level **gets in and never gets out**. It would stick in low power mode forever.

A blacklist costs you anything you forgot to list, and that cost already landed once: **the original script omitted `Sleeping`**, which a comment mentioned and the condition did not, and that level means the chip is about to cook. Hence the maintenance note now sitting in the code.

---

## How I verified it

The thing under test changes **power settings** and touches **processes you work in**, so verification has to isolate completely. The method may outlast the script.

### Shims that isolate system commands

Prepend a directory of fake commands to `PATH` and replace `sudo`, `pmset`, `powermetrics`, `afplay`. **No real power setting on the test machine ever changed:**

```bash
SHIM=$(mktemp -d)
cat > "$SHIM/pmset" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *batt*)     echo " -InternalBattery-0 (id=1)	${MAPA_BATT:-100}%; discharging; ..." ;;
  "-g therm") echo "CPU_Speed_Limit 	= 100" ;;
  *)          echo "[shim pmset] $*" >&2 ;;   # log the call as evidence
esac
EOF
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH" bash mapa.sh 0 10
```

The shim echoes intercepted calls to stderr, which turns it into positive evidence that `restore_settings` ran.

### Stateful shims that force state-transition branches

Testing "throttled, cooled, un-throttled" needs the shim to change its answer partway. A counter file handles it:

```bash
cat > "$SHIM/powermetrics" <<EOF
#!/usr/bin/env bash
n=\$(cat "$CNT"); n=\$((n + 1)); echo "\$n" > "$CNT"
if [ "\$n" -le 1 ]; then echo "Current pressure level: Heavy"
else                     echo "Current pressure level: Nominal"; fi
EOF
```

The timeline came out like this, with thermal checked every 30 seconds:

```
23:31:58  Heavy    → enable low power mode  → [shim pmset] -a lowpowermode 1
23:32:28  Nominal  → disable it again       → [shim pmset] -a lowpowermode 0
```

### A wrapper plus allowlist, for the cases that need real processes

E-core demotion needs the **real** `taskpolicy` to produce an observable QoS change, and the test machine ran working agent processes I could not touch. A wrapper solves it: log the call, forward it only for allowlisted target pids, reject the rest.

```bash
if grep -q "^${PID}$" "$TARGET_PIDS"; then
  exec /usr/sbin/taskpolicy "$@"          # forward to the real one
else
  echo "[BLOCKED] PID=$PID not in target list" >> "$LOG"; exit 1
fi
```

Belt and braces: I shimmed `pgrep` as well, so it returned only decoy pids. A broken allowlist still could not reach a real process.

### Scenarios covered

| Scenario | Result |
|---|---|
| Battery ≤ floor | ✓ |
| Time limit, waiting the real 60 seconds: projected end time, `執行 1 分鐘` arithmetic | ✓ |
| `Sleeping` cut-off, **which the pre-fix script missed** | ✓ |
| `Trapping` cut-off | ✓ |
| `Heavy` throttles only, never cuts off | ✓ |
| `Heavy → Nominal`: throttle, recover, un-throttle, writing back the original rather than a default | ✓ |
| `Nominal` triggers nothing | ✓ |
| `SIGTERM` through `on_interrupt`: `exit 130`, all state restored | ✓ |
| No target processes present: demotion skips without complaint | ✓ |
| Non-numeric arguments rejected | ✓ |
| Timestamps across zones: `UTC+8` / `UTC+5:45` / `UTC-4` / `UTC-9:30` | ✓ |

For every exit path I also confirmed three things: sleep prevention off, low power mode back to its original value, process QoS restored.

---

## Four principles worth taking with you

1. **`exit 0` does not mean it worked.** Verify configuration commands by an observable state change. `taskpolicy -c background -p` reports success and does nothing, and the recipe circulating online pipes the one clue into `/dev/null`.

2. **Which way fail-safe points depends on whether the operation runs one way or both.** "Unknown means dangerous" keeps one-way operations safe. Put it in an enter-and-exit mechanism and you build states you get into and never leave. Ask what it costs to be stuck before you choose.

3. **Restore means writing back the original value, not a hardcoded default.** The QoS recipe circulating online hardcodes `default`, and that is wrong. When you cannot read the original, because `taskinfo` needs root, fall back to recording what you changed and restoring only that.

   **The best counter-example for this principle was this script.** It handled `lowpowermode` right, recording `ORIG_LOW_POWER` at startup and writing it back. One line above, in the same function, `disablesleep` used to sit hardcoded at `0`:

   ```bash
   # BEFORE THE FIX — not what the script does today
   restore_settings() {
     sudo pmset -a disablesleep 0                    # ← hardcoded, wrong
     sudo pmset -a lowpowermode "$ORIG_LOW_POWER"    # ← writes back original, right
   ```

   Anyone who had turned `disablesleep=1` on for their own reasons, say they never want the machine sleeping, would have found it off after MAPA exited. Same function, adjacent lines, two standards.

   **Fixed.** The script now records `ORIG_DISABLE_SLEEP` at startup and writes that back, the same way it handles `lowpowermode`.

   When I caught it matters as much as what it was. **The independent review that runs before every commit found it, and it found it after I had already written this principle into this file.** You can know a rule and still break it in the next function, which is the argument for a mechanical gate like "no commit without independent review." The gate remembers what you forget.

4. **The promise "every exit path restores state" has to cover the teardown itself.** Installing the `trap` at the top buys you less than it looks. Remove the `trap` early in teardown and every action still awaiting restoration sits unprotected.

   This script did that:

   ```bash
   # BEFORE THE FIX — not what the script does today
   trap - INT TERM                      # ← removed at the start of teardown
   play_audio "ready_to_work.mp3" true  # ← blocks for seconds, waiting on playback
   restore_settings                     # ← interrupt above and this never runs
   ```

   The wrap-up sound plays synchronously, so `Ctrl + C` during those few seconds left sleep prevention on and processes stuck on E-cores, which breaks the promise the docs make. **Fixed.** `trap -` now sits after `restore_settings`. That works because the restore function is **idempotent**: rewriting the same value costs nothing, and the demoted list is already empty, so re-entering it partway through stays safe.

   The same independent review caught this one, the second P1 in a single round. Setting the trap at the top feels like handling the problem, and the other end of the script is where it bites.
