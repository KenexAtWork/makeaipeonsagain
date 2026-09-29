# MAPA — Pitfalls and How It Was Verified

Technical appendix to [MAPA](README.md), for anyone who pokes at macOS power management, QoS, or wants to verify this kind of thing without wrecking their own machine.

**Most of what follows is independent of whichever tool you end up using** — `exit 0` doesn't mean it worked, which direction fail-safe should point, how to test a script that modifies system settings without actually modifying them. That part is general.

This is a toy, not a product. It won't make anyone money. But if one of these notes saves you a few hours of chasing a command that silently does nothing, it did its job.

Tested on: Apple M3 Pro / macOS 26.7 (Darwin 25.6) / `/bin/bash` 3.2.57.

> 🇹🇼 中文版 → **[NOTES.zh-TW.md](NOTES.zh-TW.md)**

---

## 🔴 Pitfalls

This is the most useful section, and most of it applies regardless of which tool you use.

### `taskpolicy -c background -p <pid>` is a no-op — exit 0, zero effect

The E-core demotion recipe you'll find online is `taskpolicy -c background -p <pid>`. Measured (observed via `ps -o pri`):

| Command | `pri` change | exit code | |
|---|---|---|---|
| `taskpolicy -b -p` | **31 → 4** | 0 | ✓ works |
| `taskpolicy -B -p` | **4 → 31** | 0 | ✓ restores fully |
| `taskpolicy -c background -p` | **31 → 31** | **0** | ✗ **no effect, reports success** |
| `taskpolicy -c default -p` | **4 → 4** | non-zero | ✗ errors out, and doesn't restore |

The usage string explains why — `-c` belongs to the "launch a new program" form; acting on an existing pid only accepts `-b`/`-B`:

```
Usage: taskpolicy [-x|-X] ... [-c <clamp>] [-b] ... <program> [<pargs> [...]]
       taskpolicy [-b|-B] [-t <tier>] [-l <tier>] -p pid
```

The error from `-c default -p` is `Could not parse 'default' as a QoS clamp` — **and every version of that recipe floating around pipes stderr to `/dev/null`, swallowing the only clue you'd get.**

The worst combination is someone fixing the demotion to `-b` but leaving the restore line alone: processes then stay stuck at `pri 4` **until you restart them**.

> **Takeaway: `exit 0` does not mean it took effect.** Any "configure something" command should be verified by an observable state change, not by its exit code. This applies just as much to IaC and CLI automation.

### `nice` is not a QoS indicator — `pri` is

`nice` stayed at 5 before and after `taskpolicy -b`, completely unchanged. Using `nice` as your indicator will tell you the command didn't work.

(`taskinfo` shows much more but **requires root**, which is why there's no way to read a process's original QoS as a normal user — and that constrains the next item.)

### "Restore" must not re-run `pgrep`

The recipes out there re-run `pgrep` at restore time and set everything they find back to default. Two problems: processes started in the meantime get touched; and **anything that was already background gets *promoted*** — that isn't a restore.

Since the original QoS isn't readable, the way around it is to **only restore the pids you personally demoted**.

```bash
# simplified for illustration (the real one also counts them for the log line)
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

### Does E-core relegation actually work — measured

Target process was a `yes` saturating one core, compared before/after with `powermetrics --samplers cpu_power`:

| | before | after |
|---|---|---|
| **E-Cluster idle residency** | **23.58%** | **0.00%** |
| E-Cluster frequency distribution | 744 MHz at 32% | **744 MHz at 83%** |
| E-Cluster average frequency | 1495 MHz | 877 MHz |
| P-Cluster residency | 100% / idle 0% | 100% / idle 0% (unchanged) |

**`E-Cluster idle residency 23.58% → 0.00%`** is the decisive bit: the E-cluster's idle time was consumed, and simultaneously its frequency distribution collapsed onto **the lowest step, 744 MHz, at 83%**. Those two happening together have one explanation — a CPU-bound task moved into the E-cluster and the system is running it at the lowest clock.

If `-b` only changed priority without affecting core affinity, the target would have stayed on a P-core (just scheduled later) and E-cluster idle wouldn't have gone to zero.

E-core 744 MHz vs P-core 3699 MHz is roughly a **5× frequency difference**, and E-cores are more efficient per clock on top of that, so the power difference is larger still. (Exact wattage not measured.)

> Honest caveat: the P-Cluster side shows no change, because the test machine had other load keeping it busy — the slot vacated by the target was immediately refilled. So "it left the P-cores" is **inferred** from the E side, not directly observed.

### Why *not* demote every process

The obvious next thought is: if demotion works, why not demote everything? Measuring the `pri` distribution of all **571 processes** owned by the user on the test machine answers it:

| `pri` | count | |
|---|---|---|
| **4** | **356** | same value `taskpolicy -b` produces ⇒ strongly suggests **already background QoS** |
| 20 | 26 | |
| 31 | 58 | ordinary foreground processes (what demotion targets look like) |
| 37–61 | ~130 | UI / higher priority |
| 97 | 4 | realtime (audio etc. — don't touch) |

**62% of processes are already background.** macOS long ago put most background daemons on E-cores (`accountsd`, `adprivacyd`, `AMPLibraryAgent` are all `pri=4`).

So demoting indiscriminately has two problems, and the second one is fatal:

1. **Zero benefit for that 62%** — they're already there
2. 🔴 **Restore makes things worse** — because the original QoS isn't readable (`taskinfo` needs root), restoring would **promote** those 356 already-background processes to non-background. **You set out to save power and instead released 356 daemons from the E-cores. Worse than doing nothing.**

⇒ So: use an allowlist. But **don't guess what belongs on it — measure once.**

### Who's actually burning CPU all the time

`ps`'s `%CPU` is an average since process start; for instantaneous values use `top` and take the second sample:

```bash
top -l 2 -n 25 -o cpu -stats pid,cpu,command | awk '/^PID/{p++} p==2'
```

Measured on a working machine with a browser, chat apps and a few agent CLIs open — the result may not match intuition:

| Type | instantaneous %CPU | `pri` | Allowlist? |
|---|---|---|---|
| agent CLI (Claude Code etc.) | medium–high | 20–31 | ✓ the primary target |
| **browser renderer / helper** | **can exceed 80%** | **47–55** | ✓ **often the biggest consumer** |
| chat app helpers (Slack etc.) | single digits–medium | 46 | ✓ worth adding |
| terminal app | single digits | 46 | △ adding it makes Ctrl+C feel sluggish |
| **EDR / DLP / MDM agents** | **can exceed 50%** | 20–37 | 🔴 **do not touch** (see below) |
| `WindowServer`, `kernel_task` | medium–high | 79 / — | 🔴 system-critical, mostly root, can't and shouldn't |
| assorted `*d` daemons | ~0 | 4 | ✗ already background |

**The browser is often heavier than the agent itself.** Background tabs, extensions and service workers keep running after you close the lid, and their `pri` is 47–55 — **higher than an ordinary foreground process's 31** — so they have the most room to be demoted. Browsers throttle some background tabs themselves (some helpers are already at `pri=4`), but not the heavy ones.

### 🔴 Corporate management software: do not touch

A managed work laptop typically runs EDR, DLP and MDM agents, and **they're frequently near the top of the CPU list**. Keep them off your allowlist:

- Most run as root, so demotion silently fails anyway
- The few running as your user may **trigger a compliance alert**, or be interpreted as interfering with a security agent
- This class of software usually has self-protection and watchdogs — your change may be reverted, or logged as an event

The rule of thumb is simple: **if you didn't install it and don't recognise the name, leave it alone.**

### How to change the allowlist

It's one hardcoded line, inside `demote_claude_to_ecore()`:

```bash
pids=$(pgrep -f "claude")
```

Change the pattern to add targets. `pgrep -f` matches against the **full command line** and is **case-sensitive**:

```bash
pids=$(pgrep -f "claude|Google Chrome|Slack|ffmpeg")    # separate targets with |
```

After changing it, **always check what it actually matches** before letting the script act on them:

```bash
pgrep -fl "claude|Google Chrome|Slack|ffmpeg"    # -l also prints the command line
```

Don't skip that step. Run it once and you'll see why — with `iTerm` as the pattern, the first hit isn't the terminal app at all:

```
$ pgrep -fl 'claude|iTerm'
1079 /Applications/iTerm.app/Contents/XPCServices/pidinfo.xpc/Contents/MacOS/pidinfo
2499 claude --resume 97a0d3e3-...
```

`-f` matches the whole command line, so anything with that string anywhere in its path gets caught — XPC services under an app bundle, helpers, even your own test scripts. **One character wider in the pattern, one ring wider in the blast radius. Look before you run.**

(`pgrep` patterns are extended regular expressions, so `|` works; and it's case-sensitive, so `claude` won't catch the capital-C Claude Desktop app. Both verified.)

### `pmset -g therm` is empty most of the time on Apple Silicon

The script originally used `CPU_Speed_Limit` as a second signal. On an M3 Pro the field simply isn't there under normal conditions:

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

So that signal doesn't hold, and protection rests entirely on thermal pressure level. Worse, the log line prints `CPU 限速: ${CPU_LIMIT:-100}%`, so **an unreadable value displays as 100% — which looks like "not throttled" when it actually means "no idea."**

Presumably the field only gets populated from `Heavy` upward (the message says "has been **recorded**", i.e. not yet recorded rather than unsupported). **Not proven** — there's no way to force a machine to `Heavy` on demand.

### Background processes have `SIGINT` ignored (a false-negative test trap)

POSIX behaviour: a process started with `&` from a non-interactive shell has `SIGINT` set to `SIG_IGN`, and a `trap` inside the script **cannot override it**.

| Signal sent | Result |
|---|---|
| background start + `kill -INT` | **trap never fires**, process still alive 14 seconds later |
| background start + `kill -TERM` | trap fires, `exit 130` ✓ |

⇒ **Testing a background script's interrupt path with `kill -INT` gives you a test that always passes.** This project had exactly one such bogus "interrupt path verified" result. Use `SIGTERM` against the same handler (`trap ... INT TERM`) to actually exercise it.

As for the delay: when you signal a single process, bash receives it while waiting on a foreground child (`sleep 10`) and **won't run the handler until that child exits**, so the worst-case delay is one sleep period. A real `Ctrl + C` isn't subject to this — the terminal sends `SIGINT` to the **entire foreground process group**, killing the `sleep` too, so bash returns immediately ⇒ instant exit.

### Blacklist or allowlist — fail-safe direction depends on whether the operation is one-way

The thermal check enumerates the dangerous levels (a blacklist). Switching to an allowlist was considered ("only `Nominal`/`Moderate` are safe, everything else is dangerous"), which would make any future new level fail safe automatically. **Rejected**, because the throttling here is bidirectional:

- entry condition: not `Nominal`/`Moderate`
- exit condition: `Nominal`/`Moderate`

Under an allowlist an unknown level **gets in but can't get out** — it would stick in low power mode forever.

The cost is that a blacklist silently misses anything you forgot to list — and that's not hypothetical: **the original script was missing `Sleeping`** (mentioned in a comment, absent from the condition), and that's precisely the level meaning "about to cook the chip." Hence the maintenance note left in the code.

---

## How it was verified

The thing under test modifies **power settings** and touches **processes you're actively working in**, so verification has to be fully isolated. The method may be more reusable than the script itself.

### Shims to isolate system commands

Prepend a directory of fake commands to `PATH`, replacing `sudo` / `pmset` / `powermetrics` / `afplay`. **At no point were the test machine's real power settings changed:**

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

The shim echoes intercepted calls to stderr, which turns it into **positive evidence that `restore_settings` really ran**.

### Stateful shims to force state-transition branches

To test "throttled, then cooled down, then un-throttled", the shim has to change its answer partway through. A counter file does it:

```bash
cat > "$SHIM/powermetrics" <<EOF
#!/usr/bin/env bash
n=\$(cat "$CNT"); n=\$((n + 1)); echo "\$n" > "$CNT"
if [ "\$n" -le 1 ]; then echo "Current pressure level: Heavy"
else                     echo "Current pressure level: Nominal"; fi
EOF
```

The resulting timeline (thermal is checked every 30 seconds):

```
23:31:58  Heavy    → enable low power mode  → [shim pmset] -a lowpowermode 1
23:32:28  Nominal  → disable it again       → [shim pmset] -a lowpowermode 0
```

### Wrapper + allowlist, for when you must touch real processes

E-core demotion needs the **real** `taskpolicy` to produce an observable QoS change, but the test machine had working agent processes that must not be touched. The answer is a wrapper: log the call, **forward it only for allowlisted target pids**, reject everything else.

```bash
if grep -q "^${PID}$" "$TARGET_PIDS"; then
  exec /usr/sbin/taskpolicy "$@"          # forward to the real one
else
  echo "[BLOCKED] PID=$PID not in target list" >> "$LOG"; exit 1
fi
```

Belt and braces: `pgrep` was also shimmed to return only the decoy pids, so even a broken allowlist couldn't reach a real process.

### Scenarios covered

| Scenario | Result |
|---|---|
| Battery ≤ floor | ✓ |
| Time limit (real 60-second wait): projected end time, `執行 1 分鐘` arithmetic | ✓ |
| `Sleeping` cut-off (**missed before the fix**) | ✓ |
| `Trapping` cut-off | ✓ |
| `Heavy` throttles only, does **not** cut off | ✓ |
| `Heavy → Nominal`: throttle then recover, un-throttle (writes back original, not a hardcoded default) | ✓ |
| `Nominal` triggers nothing | ✓ |
| `SIGTERM` through `on_interrupt`: `exit 130`, all state restored | ✓ |
| No target processes present: demotion skips quietly | ✓ |
| Non-numeric arguments rejected | ✓ |
| Timestamps across zones: `UTC+8` / `UTC+5:45` / `UTC-4` / `UTC-9:30` | ✓ |

Every exit path was additionally confirmed to: disable sleep prevention, write low power mode back to its original value, and restore process QoS.

---

## Principles worth taking away

1. **`exit 0` does not mean it took effect.** Configuration commands need verification by observable state change. `taskpolicy -c background -p` reports success while doing nothing, and the circulating recipe pipes away the one clue with `2>/dev/null`.

2. **Which way fail-safe points depends on whether the operation is one-way or bidirectional.** "Unknown means dangerous" is safer for one-way operations, but in an enter/exit mechanism it produces states you can get into and never out of. Before choosing, ask: what's the cost of not being able to get out?

3. **"Restore" means writing back the original value, not a hardcoded default.** The circulating QoS recipe hardcodes `default`, which is wrong. When the original isn't readable (e.g. `taskinfo` needs root), fall back to recording *what you changed* and restoring only that.

   **The best counter-example for this principle was this very script.** It got `lowpowermode` right (records `ORIG_LOW_POWER` at startup, writes it back), but one line above in the same function, `disablesleep` used to be hardcoded to `0`:

   ```bash
   # BEFORE THE FIX — not what the script does today
   restore_settings() {
     sudo pmset -a disablesleep 0                    # ← hardcoded, wrong
     sudo pmset -a lowpowermode "$ORIG_LOW_POWER"    # ← writes back original, right
   ```

   A user who had `disablesleep=1` on purpose (say they never want the machine sleeping) would have had it silently switched off on exit. Same function, adjacent lines, two different standards.

   **Fixed** — the script now records `ORIG_DISABLE_SLEEP` at startup and writes that back, exactly as it does for `lowpowermode`.

   And *when* it was caught is the point: **it was found by the independent review that runs before commit, and it was found *after* this principle had already been written down in this file.** Knowing a principle is not the same as following it — which is exactly the value of a mechanical gate like "no commit without independent review": it doesn't depend on anyone remembering whether they violated their own rule.

4. **The guarantee "every exit path restores state" has to cover the teardown phase itself.** Installing the `trap` at the top isn't enough — if teardown removes the `trap` early, every action still pending restoration sits in a dead zone.

   This script used to do exactly that:

   ```bash
   # BEFORE THE FIX — not what the script does today
   trap - INT TERM                      # ← removed at the start of teardown
   play_audio "ready_to_work.mp3" true  # ← blocks for seconds, waiting on playback
   restore_settings                     # ← interrupt during the above and this never runs
   ```

   The wrap-up sound is played synchronously, so a `Ctrl + C` during those few seconds left sleep prevention on and processes stuck on E-cores — violating the guarantee the docs themselves make. **Fixed** — `trap -` now sits **after** `restore_settings`. The prerequisite is that the restore function be **idempotent** (rewriting the same value is harmless, the demoted list is already cleared), so re-entering it partway through is safe.

   Also found by the independent review — the second P1 in the same round. **"I installed the trap at the top" creates a feeling of having handled it, and what gets missed is the other end.**
