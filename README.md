# SSD Recovery Resistance Tester (v1.10)

## What is this?

When you delete a file on an SSD, the data isn't necessarily gone — the
filesystem just stops pointing at it. Whether it's actually recoverable
afterward depends on things outside your direct control: whether TRIM ran,
whether the SSD controller has already reclaimed those physical NAND
cells for garbage collection, how much free space and overprovisioning
the drive has, and how the filesystem allocated blocks in the first place.

This tool exercises that whole pipeline, deliberately and repeatedly, so
you can actually observe it instead of just trusting that it works:

1. **Fill** — it generates its own test files (HTML, TXT, JPG, and binary
   data — a realistic mix, not one giant file) using incompressible random
   data, until your drive's free space is nearly exhausted.
2. **Delete** — it removes all of that test data.
3. **TRIM** — it tells the SSD which blocks are now free, so the
   controller can actually go reclaim them.
4. **Repeat** — for however many independent cycles the chosen level
   calls for, each with a fresh batch of random data.

Along the way it also reads and reports the SSD's own health data (SMART
attributes, NVMe wear percentage, temperature, controller-reported host
writes) before and after, so you can see the real cost of running this in
terms of drive wear — not just whether it "worked."

### What it actually does, step by step

1. Detects the filesystem, block device, transport (NVMe/SATA/etc.), and
   whether TRIM/discard is available.
2. Checks for common gaps that make TRIM *look* successful while data
   stays recoverable: LUKS/dm-crypt without `allow_discards`, LVM without
   `issue_discards`, unencrypted active swap, and (on btrfs) snapshots
   that keep old file versions alive (see §18a).
3. Shows a pre-run analysis and a level picker (or uses `--level`).
4. For each run: generates a pool of incompressible random data (for
   Restricted/Secret/Paranoia), cycles HTML/TXT/JPG/BIN file creation
   across multiple workers until free space hits the reserve, syncs,
   deletes everything it created, and runs `fstrim` (Paranoia adds an
   extra verification TRIM pass per run).
5. Monitors SSD temperature throughout via a background thread and
   pauses/aborts a run if the drive gets too hot.
6. Writes a report, manifest, per-run CSV, and full log, then prints a
   final summary including SMART/NVMe before/after values, TRIM
   effectiveness, wear delta, and the start/end time of the overall run
   and of every individual run.

## Why would you want this?

- **You're testing whether TRIM is actually working** on a given
  filesystem/LUKS/LVM/dm-crypt stack, instead of assuming it is.
- **You're doing forensic recovery research** — e.g. running PhotoRec
  against the drive afterward to see what, if anything, comes back. Every
  generated file is stamped with an identifying marker (level, run
  number, file ID) specifically so recovered fragments can be traced back
  to when and how they were created.
- **You're studying SSD garbage-collection behavior** under sustained
  fill/delete pressure, and want the free-space and TRIM-reclaimed
  numbers to actually watch it happen.
- **You want more confidence that deleted files are less likely to be
  casually recoverable** before handing off, reselling, or repurposing a
  drive — understanding clearly that this is a heuristic improvement, not
  a guaranteed erasure method (see below).

## What this is *not*

This is **not** a secure-erase tool in the NVMe Sanitize / ATA Secure
Erase / `blkdiscard`-the-whole-device sense. It never touches your
existing files, never wipes the whole drive, and never gives you a
mathematical guarantee that data is unrecoverable — because no filesystem
-level tool honestly can. The SSD controller's firmware, wear-leveling
tables, and internal NAND mapping are outside any OS-level tool's control,
by design (that abstraction is what makes SSDs work at all).

If you need guaranteed device-level destruction — decommissioning
hardware that held genuinely sensitive data, for example — use your
drive manufacturer's Secure Erase or NVMe Sanitize command instead. This
tool exists for the different situation: **your other files need to stay
exactly where they are, and you want the free space around them
subjected to real overwrite-and-TRIM activity.**

## How much does this cost my drive?

Every fill cycle is genuine write traffic — this isn't free. The tool
reports both its own nominal write count and (when available) the SSD
controller's own reported host-write delta, specifically so you can see
the real endurance cost rather than guessing. Four levels are available,
from a quick 1-run sanity check up to a 6-run "Paranoia" mode — pick
based on how much you actually need, not by default. The tool includes a
pre-run analysis that looks at your drive's current temperature, wear
level, and free space, and recommends an appropriate level rather than
assuming you should always run the heaviest one.


## Getting Started

Full installation, dependencies, command-line flags, and a detailed
technical walkthrough of every feature follow below.

---

## 1. Recommended Repository Structure

```text
ssd-recovery-resistance/
├── README.md
├── LICENSE
├── .gitignore
└── SSD-Recovery-Resistance.sh
```

**No `runs/` folder needs to be pre-created or committed.** The script
creates its own project directory at runtime (see §6) — that directory,
including `runs/`, `.lock`, `.eta_history`, and everything under it,
should stay out of Git.

---

## 2. Create `.gitignore`

```gitignore
# Runtime project directory (auto-created; named after the script)
SSD-Recovery-Resistance/
.lock

# Learned write-rate history (persists across invocations, machine-specific)
.eta_history

# Temporary test data (in case a run is interrupted before cleanup)
test-data/
wipe-test/
.randpool

# Logs
*.log

# Generated reports, manifests, CSVs
report.txt
manifest.txt
run.log
runs.csv
trace.log

# OS/editor files
.DS_Store
*.swp
*~
```

The old pattern `runs/*` / `!runs/.gitkeep` is no longer accurate on its
own, since the whole project folder (`SSD-Recovery-Resistance/`, containing
`runs/`) is created fresh at the launch location — not a `runs/` folder
sitting next to the script in the repo.

---

## 3. Clone the Repository

```bash
cd ~
git clone https://github.com/aris-infosec/ssd-recovery-resistance.git
cd ssd-recovery-resistance
```

No manual `runs/` setup is required — the script handles this itself on
first launch.

---

## 4. Enter the Folder and Run It

The script is already part of the repo you just cloned, so there's
nothing to copy — just move into the folder, confirm it's there, make it
executable, and run it:

```bash
cd ssd-recovery-resistance
ls
chmod +x SSD-Recovery-Resistance.sh
./SSD-Recovery-Resistance.sh
```

`ls` should show `SSD-Recovery-Resistance.sh`, `README.md`, `LICENSE`,
`.gitignore`, and the `tests/` folder. `chmod +x` only needs to be done
once — Git doesn't always preserve the executable bit on clone/download,
so if you skip this step you'll get a `Permission denied` error instead
of the script starting.

Running it with no flags launches the interactive numbered level picker
(see §11a) and asks its setup questions (sleep inhibitor, notifications,
power-off, repeat count) before doing anything destructive — nothing is
written to disk until you confirm. If you already know what you want,
skip straight to a non-interactive run, e.g.:

```bash
./SSD-Recovery-Resistance.sh --level=secret --yes
```

---

## 5. Install Dependencies

On Arch Linux:

```bash
sudo pacman -S imagemagick smartmontools nvme-cli util-linux openssl coreutils
```

`util-linux` provides `flock`, `findmnt`, `fstrim`, and `lsblk`, all of
which the script requires unconditionally. `openssl` is optional but
recommended — it's used to generate the incompressible random-data pool
faster than reading `/dev/urandom` directly. `coreutils` provides `b2sum`
(BLAKE2b) — optional but recommended, since the script uses it instead of
`sha256sum` for the manifest's per-file hashes when available (3–5x
faster on the same hardware); it automatically falls back to `sha256sum`
if `b2sum` isn't installed.

The full list of hard-required commands the script checks for at startup:

```text
bash fstrim findmnt lsblk df stat dd sync awk grep head tail sed
sha256sum tee nproc mktemp flock
```

plus ImageMagick: either `magick` (v7) **or** `convert` (v6) — the script uses
whichever it finds (v7 preferred). Optional helpers: `curl` (push
notifications), `systemd-inhibit` (blocks suspend during the run), `smartctl`
and `nvme` (see below).

`smartctl` and `nvme` are optional — without them, temperature/SMART/NVMe
fields in the report will show as `n/a`, but the fill/delete/TRIM cycle
still works.

On Debian/Ubuntu:

```bash
sudo apt install imagemagick util-linux smartmontools nvme-cli openssl coreutils
```

`shred` (part of `coreutils`) is only used by Paranoia to wipe its own
manifest; if it's missing, the manifest is left in place.

Requirements: Linux, Bash 4+ (arrays, `[[ ]]`), and either root or a
working `sudo`.

**Running as root vs. as a normal user.** The recommended way is to run
the script as your normal user:

```bash
./SSD-Recovery-Resistance.sh
```

Running it directly as root (or `sudo ./SSD-Recovery-Resistance.sh`)
also works — the script detects root and simply skips the internal
`sudo` calls — but running as a normal user keeps the output files owned
by you. The script checks whether it's already root; if not, it verifies `sudo`
works (`sudo -v`) up front and fails fast with a clear message if it
doesn't, rather than dying mid-run after hours of filling the disk. It
then uses `sudo` internally only for the specific commands that need root
(`fstrim`, `smartctl`, `nvme`, `dmsetup`, `btrfs`).

**New in this version — sudo keepalive.** A background loop refreshes the
cached `sudo` credential every 60 seconds for the entire run. Earlier
versions only authenticated once at the start, which meant a long
Paranoia session (Restricted/Secret/Paranoia can easily run for hours)
could outlast `sudo`'s cached-credential timeout, hit a silent re-auth
prompt with nobody at the terminal, time out, and abort mid-run. This is
now handled automatically — no action needed on your part.

---

## 6. Runtime Output

**Important correction (unchanged from v1.8):** the output location is
based on the **current working directory the script is launched from
(`pwd`), not the directory the script file itself lives in.** This
matters if the script is called via a symlink or through `$PATH` from
somewhere else.

The script creates a project folder named after itself, at the launch
location, and treats *that folder* as the filesystem under test (so
`df`/`findmnt`/`fstrim` all operate on whatever disk you actually launched
the script from):

```text
<directory you ran it from>/
└── SSD-Recovery-Resistance/
    ├── .lock
    ├── .eta_history
    └── runs/
        └── 20260827-140500/
            ├── report.txt
            ├── manifest.txt
            ├── run.log
            ├── runs.csv
            └── trace.log        (only if DEBUG=1)
```

So if the repo lives at `~/ssd-recovery-resistance` but you run it from
`/mnt/external-drive`:

```bash
cd /mnt/external-drive
~/ssd-recovery-resistance/SSD-Recovery-Resistance.sh
```

the project folder (and everything under it) is created inside
`/mnt/external-drive/`, testing *that* filesystem — not the repo's disk.
This is intentional: it lets you point the tool at any mounted drive
without copying the script there.

Everything the script creates is cleaned up automatically on exit
(including Ctrl-C), leaving only the report/manifest/CSV/log files
behind. The temporary `test-data/` directory inside each run is removed after
that run completes (or on interrupt/abort, via a `trap`-based cleanup),
using `find -mindepth 1 -delete` with an automatic verify-and-retry pass
rather than a shell glob — at tens of thousands of files, a glob-based
`rm .../*` can silently fail with "Argument list too long," which earlier
versions didn't detect. Reports, manifests, and CSVs remain locally
available afterward but are excluded from Git via `.gitignore`. The
learned `.eta_history` file persists across runs by design — see §13a.

A lockfile (`.lock`, via `flock`) prevents two instances from running
against the same project directory simultaneously.

---

## 7. Adaptive Allocation Profiles

The tool selects a `FILESYSTEM_PROFILE` based on the detected filesystem:

* `ext4`
* `btrfs`
* `xfs`
* `f2fs`
* `GENERIC` (anything else)

And, when aggressive allocation mode is active, a `BINARY_MODE` write
pattern for the large binary test files:

* `CONTIGUOUS` — one sequential write
* `MIXED_SIZES` — split into a large sequential half and a smaller
  512 KiB-chunked half
* `FRAGMENTED` — written in small (1–4 MiB) chunks scattered across the
  file's offset range

These change the write pattern presented to the filesystem/controller.
They do **not** provide direct control over physical NAND placement inside
the SSD.

---

## 8. Aggressive Allocation Mode

* **Normal** — always off.
* **Restricted** — off by default, same as Normal. (New level — see §13.)
* **Secret** — off by default; the script asks
  `Enable aggressive allocation mode (fragmented/mixed layouts)? [y/N]`
  unless `--yes`/`-y` is given (in which case it defaults to off), or it
  can be forced explicitly with `--aggressive` / `--no-aggressive`.
* **Paranoia** — **always on**, non-optional (unless overridden with
  `--no-aggressive`), using fragmented/mixed layouts for the binary test
  files.

It increases filesystem metadata churn, allocation/deallocation turnover,
runtime, and SSD write workload. It does not guarantee different physical
NAND placement. Because it increases write activity, only enable it
deliberately.

---

## 9. TRIM Cooldown

Two distinct pauses exist:

* **Post-TRIM idle** (`POST_TRIM_IDLE`, default 10 s) — after every
  `fstrim` call, giving the controller a moment before the next
  measurement.
* **Break between runs** — between full fill/delete/TRIM runs, and
  between passes when repeating. It is **adaptive and temperature
  based** and can never wait longer than **7 minutes**:

  | Situation | What happens |
  |---|---|
  | Drive cools to the target (idle-at-launch + 5 °C, clamped to 35 °C … `TEMP_WARNING`−5) and stays there 10 s in a row, after at least `COOLDOWN_MIN_SECONDS` (30 s) | Break ends **early**, next run starts |
  | Drive is still warm when `COOLDOWN_MAX_SECONDS` (420 s = 7:00) is reached | Break ends anyway ("hard limit"); the next run starts and `adapt_settings()` lowers the worker count if the drive is still warm |
  | Temperature flaps around the target and is never steady | Same as above: ends at the hard limit |
  | No temperature sensor available | Fixed `COOLDOWN_SECONDS` break (default 300 s, never above the maximum) |
  | `COOLDOWN_MAX_SECONDS=0` | No break at all |

  The live line shows elapsed time, current drive temperature, the target
  and the hard limit. The plan/ETA use an estimate of `(min+max)/2` per
  break, replaced by the real average as breaks happen. No break is taken
  after the very last run, and the final report lists how many breaks
  ended early vs. at the limit.
* **Bounded thermal pause (no indefinite waiting).** If the drive reaches
  the PAUSE threshold *during* a run and cannot cool down within
  `THERMAL_PAUSE_MAX_SECONDS` (default 420 s), that run is ended
  gracefully — the same path as a CRITICAL event: test data deleted, TRIM
  run, the run marked as thermally aborted, exit code 2 — instead of
  waiting forever. The next run (after its break) then gets a fresh try.
  Set it to `0` for the old unlimited wait.

The controller's internal garbage-collection behavior remains outside OS
control, so these pauses are a heuristic, not a guarantee that background
housekeeping has fully completed.

---

## 10. NVMe Write Tracking

When NVMe health data is available, the script records `Data Units
Written` before and after the whole session (not just per run) and reports
the delta (`Controller host writes`) alongside its own nominal
byte-counter (`Nominal data written`) in the final report:

```text
Nominal data written:     35.2 GiB
Controller host writes:   37.8 GiB
```

The controller-reported figure is generally the more trustworthy measure
of actual host-write activity, since it reflects what the drive itself
recorded rather than the script's own accounting.

---

## 11. Pre-Run System Analysis

Before showing the level picker, `run_analysis()` checks:

```text
SSD model, transport type, filesystem, mountpoint
TRIM availability
Free space (bytes and %)
Temperature
SMART health / NVMe critical_warning
Percentage Used (endurance)
Available Spare
```

...and produces a recommendation: `NORMAL`, `RESTRICTED`, `SECRET`,
`PARANOIA`, or `STOP`. **This is a substantially expanded, graded system
compared to earlier versions**, which only ever recommended NORMAL or
PARANOIA. It's now a tiered risk assessment:

| Condition | Recommendation |
|---|---|
| SMART reports FAILED | STOP |
| NVMe critical_warning ≠ 0 | STOP |
| Temperature already above `TEMP_CRITICAL` (80 °C) | NORMAL |
| Percentage Used ≥ 80% | NORMAL |
| Free space < 5 GiB | NORMAL |
| Temperature ≥ `TEMP_WARNING` (65 °C) | RESTRICTED |
| Percentage Used ≥ 50% | RESTRICTED |
| Free space < 20 GiB | RESTRICTED |
| Percentage Used ≥ 21% | SECRET |
| Free space < 50 GiB | SECRET |
| none of the above | PARANOIA |

Each row is checked in order (first match wins) against the categories
above it — e.g. 55% wear recommends RESTRICTED, not SECRET, since the
50%+ check comes first.

The recommendation is advisory — you can still pick another level from
the picker. If analysis says `STOP` but you pass `--level=...` explicitly
on the CLI, the script honors your choice after an extra confirmation
(skipped with `--yes`; also skipped entirely under `--dry-run`, since
nothing destructive happens in that mode).

**Behavior change:** the numbered level picker is now the *default*
whenever `--level` isn't given explicitly — no `--menu` flag needed
anymore (see §11a). `--menu` still works and now means "show the picker
even if `--level` was also given."

---

## 11a. Level Selection — Picker is Now the Default

Earlier versions defaulted straight to Paranoia unless you passed
`--menu`. **This is reversed in the current version:**

| Flags given | Behavior |
|---|---|
| (none) | Interactive numbered picker shown |
| `--level=X` | Skips the picker, uses level `X` directly |
| `--yes` (no `--level`) | Skips the picker (it needs real keyboard input, which would hang forever in a non-interactive/cron/CI context), falls back to the `PARANOIA` default |
| `--level=X --yes` | Skips the picker, uses level `X`, no further prompts |
| `--menu` | Always shows the picker, even combined with `--level` or `--yes` |

The picker itself:

```text
[0] Run analysis again
[1] Normal       - 1 run, fastest baseline
[2] Restricted   - 2 runs, random data
[3] Secret       - 3 runs, varied patterns
[4] Paranoia     - 6 runs, highest test workload
[5] Use recommendation (<computed above>)
[6] Show analysis and exit
[7] Abort
```

### Repeat count and power-off questions (new in v1.10)

Right after the level is chosen — *before* the execution plan and the
final `Start?` confirmation — two more questions are asked:

1. **"Number of passes [1]"** — how many times the *complete* level
   should be run back to back. One pass = all runs of that level
   (Paranoia = 6 runs by default), so `2` passes of Paranoia = 12 runs.
   Every pass restarts the level's own pattern sequence (e.g. Paranoia
   begins each pass with RANDOM + FRAGMENTED again), and the normal
   cooldown is kept between runs *and* between passes. The plan, ETA,
   dashboard, report and `runs.csv` all show the real total.
2. **"Power off the computer automatically when everything has
   finished? [y/N]"** — if yes, the script shows a 30-second abortable
   countdown after the final report, runs its normal cleanup (swap
   re-enabled, helper processes stopped) and then powers the machine off
   (`systemctl poweroff`, falling back to `poweroff` / `shutdown -h now`).

Power-off only happens after a **normal completion**. Ctrl-C, `kill`,
pre-flight failures or any error exit *never* power the machine off, and
Ctrl-C (or SIGTERM) during the 30 s countdown simply cancels it and
exits with the normal exit code (0, or 2 after a thermal abort).

Both can be answered up front on the command line (`--repeat=N`,
`--poweroff` / `--no-poweroff`); with `--yes` or `--dry-run` nothing is
asked and the defaults apply (1 pass, no power-off).

> **v1.10 fix worth knowing about:** earlier versions waited for the
> background JPG workers with a check that also counted the thermal
> monitor as a "worker". After *every* run that meant an idle 180 s wait,
> followed by the script terminating its own thermal monitor — so from
> run 2 onward there was no thermal monitoring at all. Workers are now
> waited for by PID and the monitor is left running for the whole session.

> **v1.10 fix #2 — Ctrl-C now really cleans up.** In earlier versions a
> genuine Ctrl-C at the terminal (not `kill`) stopped the script with exit
> status 1 *without* running the cleanup: the log-writing `tee` process was
> killed by the same Ctrl-C, the next message failed, and the script exited
> before removing the test files or re-enabling swap. Now Ctrl-C prints
> `ABORT REQUESTED`, cleans up and exits with status 130. Closing the
> terminal / a dropped SSH connection also runs the cleanup.

> **Wear warning:** every extra pass writes almost the full free space
> again. Repeating Paranoia consumes real NAND endurance — use it
> deliberately.

### Push notifications (new in v1.10)

After you choose the mode (and passes / power-off) the setup asks
**"Send notifications? [y/N]"** and, if yes, for a **channel name** (an
[ntfy](https://ntfy.sh) topic). The last channel is remembered
(`~/.config/ssd-recovery-resistance/notify.conf`, mode 600) and offered as the
default next time. Non-interactive: `--notify=NAME` / `--no-notify`.

You get a message when the test **starts** (level, estimate, wear now) and when it
**finishes, aborts or fails** — with runtime, data written (nominal and
controller host writes), temperatures (start / peak / end), wear status
(percentage used, delta, spare, health), media errors, unsafe shutdowns, breaks,
thermal cut-offs and TRIM. If power-off is enabled the message is sent
**before** the countdown and the shutdown. Failures (Ctrl-C, `kill`, closed
terminal, script error) send a high-priority message too, after cleanup.

In between, every run sends three short low-priority messages so you can follow
along: **`Run 1/6 started`**, **`Run 1/6 50%`** (fill phase half way) and
**`Run 1/6 finished`**. There are no per-TRIM messages.

Problems get their own message (prefixed with `Run n/N:`):

| Message | Priority | When |
|---|---|---|
| `drive is hot (66 C)` | default | Warning temperature reached (once per run) |
| `thermal PAUSE (70 C)` | high | Writing is paused until the drive cools down |
| `cooled down, resuming` | default | Pause ended, run continues |
| `thermal pause timed out` | high | Drive did not cool in time, run ended early |
| `THERMAL CUT-OFF (CRITICAL/EMERGENCY)` | high / urgent | Critical temperature, run ended early |
| `stuck worker(s) killed` | default | A background writer hung and was terminated |
| `test files could not be deleted` | high | Delete step left files behind |

A message that cannot be sent never blocks the run: curl gives up after about
12 seconds and the script carries on (power-off included).

> **Privacy:** on the public ntfy.sh anyone who knows the channel name can read
> the messages. Choose a hard-to-guess name (e.g. `ssdtest-k7x2q9`), or run your
> own server and set `NOTIFY_SERVER` / `NOTIFY_TOKEN`. The channel name is never
> written to the report.

### Sleep inhibitor and SSH sessions (new in v1.10)

A multi-hour test must not fall asleep. Unless `--no-inhibit` is given, the run
holds a `systemd-inhibit` lock (`sleep:idle:handle-lid-switch`), released
automatically when the script ends — even after `kill -9`. If it cannot be
obtained (no systemd, no permission) the plan says so; make sure the computer
cannot suspend by other means.

Over SSH, a dropped connection sends SIGHUP: the run is **aborted** (cleanup runs,
results incomplete, a `FAILED (connection lost)` notification is sent). The plan
warns when you run over SSH without `tmux`/`screen` — start the test inside
`tmux new -s ssdtest`.

### Recovering after a crash: `--cleanup` (new in v1.10)

After a power cut or `kill -9` the normal cleanup never ran. `--cleanup` finds
leftover script-owned `test-data` folders (and reports whether swap was left
disabled), then offers to delete them, switch swap back on and run TRIM. It
only touches real directories named `test-data` exactly one level below a run
folder in this script's own `runs/` directory; reports and logs are kept.
`--cleanup --dry-run` only lists, `--cleanup --yes` does everything.

### Other v1.10 fixes worth knowing

* Peak temperature is tracked **per run** by the monitor (it used to be cumulative
  and only sampled inside the thermal gate, so short spikes were missed).
* A thermal PAUSE now ends when the drive is back at `TEMP_RESUME` (62 °C) for the
  cool-down time — previously it ended as soon as it dropped below 70 °C.
* Closed terminal / dropped SSH (SIGHUP) has its own handler (exit 129). After
  death by an untrapped signal bash reports `$?` = 0 in the exit trap, so the
  script no longer relies on the exit code to detect an abnormal end.
* The abort handler ignores further Ctrl-C while cleaning up (a second Ctrl-C used
  to cut the cleanup short).
* Stalled background workers are now really killed after `WORKER_WAIT_MAX_SECONDS`:
  the PID list was built in a way that always came back empty.
* ImageMagick 6 (`convert`) is accepted where v7 (`magick`) is missing.

If you're scripting this tool (cron, CI, a wrapper script) and want
deterministic non-interactive behavior, always pass `--level=X --yes`
explicitly — don't rely on the `--yes`-without-`--level` fallback staying
`PARANOIA` forever, since that default can change in a future version.

---

## 12. SSD Endurance

`Percentage Used` (NVMe) — or, on SATA drives without that field, a
best-effort estimate from SMART attribute 177 (`Wear_Leveling_Count`) or
233/231 (`Media_Wearout_Indicator` / `SSD_Life_Left`) — reflects rated
endurance consumed, **not filesystem storage usage**.

```text
Percentage Used: 4%
Status: EXCELLENT
```

| Percentage Used | Status |
|---:|---|
| 0–20% | EXCELLENT |
| 21–50% | GOOD |
| 51–75% | MODERATE |
| 76–90% | HIGH |
| 91%+ | CRITICAL |
| unparseable / no data | UNKNOWN |

If the drive already reports ≥ 80% wear at the start, the script shows an
explicit warning before letting you proceed (bypassable with `--yes`).

This value is a controller estimate, not a guarantee of exact remaining
physical NAND lifetime — and it's clearly labeled "(est., ...)" in the
report when it's the SATA SMART-based fallback rather than the native NVMe
field.

---

## 13. Security Profiles

**Run counts have changed again in this version** — there are now four
levels instead of three:

### Normal
**1 run.** Zero-filled data (fast), normal allocation, standard reserve.
Basic check that TRIM runs and free space is reclaimed correctly.

### Restricted *(new)*
**`RESTRICTED_RUNS` runs — default 2**
(override: `RESTRICTED_RUNS=3 ./SSD-Recovery-Resistance.sh`).
Incompressible random data (fresh pool per run, same as Secret/Paranoia),
standard allocation (no aggressive fragmentation), standard reserve. Sits
between Normal and Secret: more thorough than a single zero-fill pass,
without Secret's varied-pattern rotation or Paranoia's extras.

### Secret
**`SECRET_RUNS` runs — default 3** (was 2 in earlier versions; override:
`SECRET_RUNS=5 ./SSD-Recovery-Resistance.sh`). Incompressible random data
(fresh pool per run), optional aggressive allocation, standard reserve.
Guards against a single incomplete TRIM pass.

### Paranoia
**`PARANOIA_RUNS` runs — default 6** (was 3 in earlier versions; override:
`PARANOIA_RUNS=10 ./SSD-Recovery-Resistance.sh`). Incompressible random
data, aggressive allocation always on, a tighter reserve (reaches further
into controller overprovisioning space), an extra verification TRIM pass
per run, and secure deletion (`shred -u -z -n 3`) of the run's own
`manifest.txt` at the end.

A built-in sanity cascade now enforces the full ordering —
`PARANOIA_RUNS > SECRET_RUNS > RESTRICTED_RUNS > 1` — auto-correcting any
level upward if an environment-variable override breaks that order, and
printing a note when it does.

> More runs do not mean mathematically stronger physical erasure — they
> mean more overwrite/TRIM cycles, which is a heuristic improvement, not a
> guarantee.

---

## 13a. Learned ETA (New)

The script now persists a small history file, `.eta_history`, in the
project directory (survives individual runs being deleted, since it lives
in `PROJECT_DIR` rather than `RUN_DIR`/`TEST_DIR`). After every completed
run, it records the actual achieved fill rate (bytes/second) for that
level, as a rolling average capped at 15 samples — recent runs matter more
as the sample count grows, so the estimate stays adaptive to a machine or
drive that changes over time rather than converging permanently to old
data.

Once at least one run has completed at a given level, the execution plan
shows a data-informed estimate before you start the next one:

```text
Estimated total time: ~06:02:12 (learned from 4 past run(s) at this level on this system)
```

Before any history exists for a level, it instead shows:

```text
Estimated total time: n/a (no history yet for PARANOIA level - will learn after this run)
```

This estimate is fill-time-only (plus per-run cooldown) — it doesn't
account for delete+TRIM phase time, so actual wall-clock time will run
somewhat longer than the estimate. Delete `.eta_history` manually if you
want to reset the learned average (e.g. after moving the script to a
different, much faster or slower drive).

---

## 14. Temperature Handling

This is a 5-tier system that runs as a continuous background monitor
rather than a periodic check:

| Threshold (default) | State | Behavior |
|---:|---|---|
| < 65 °C | NORMAL | full worker count |
| ≥ 65 °C (`TEMP_WARNING`) | WARNING | worker count reduced |
| ≥ 70 °C (`TEMP_PAUSE`) | PAUSE | writes pause until ≤ 62 °C (`TEMP_RESUME`) for a sustained window |
| ≥ 80 °C (`TEMP_CRITICAL`) | CRITICAL | current run aborted, 3× audible alert |
| ≥ 85 °C (`TEMP_EMERGENCY`) | EMERGENCY | current run aborted, 5× audible alert |

**Worker scaling is now derived from actual core count** rather than a
fixed number. Earlier versions capped concurrent workers at 6 regardless
of CPU thread count; the current version computes a ceiling of
`nproc - 2` (leaving headroom for the OS/monitor thread/shell), so a
12-thread machine gets up to 10 workers instead of being capped at 6. The
adaptive logic starts at that full ceiling when temperature and free space
are healthy, and only ever scales *down* from there for heat or low free
space — it no longer permanently halves the worker count as its starting
baseline regardless of conditions.

All five thresholds are overridable via environment variables
(`TEMP_WARNING`, `TEMP_PAUSE`, `TEMP_RESUME`, `TEMP_CRITICAL`,
`TEMP_EMERGENCY`). A dedicated background thread polls temperature every
`TEMP_INTERVAL` (default 1 s) so the write loop itself never blocks on a
`smartctl`/`nvme` call. Audible alerts can be disabled with
`SOUND_ENABLED=0`.

If any run is thermally aborted, the script still completes the remaining
runs and the final verification TRIM, but exits with code `2` instead of
`0` so this is scriptable/detectable in cron or CI.

---

## 15. Live Dashboard (New/Changed)

A four-line live dashboard renders during each run's fill phase:

```text
[PARANOIA] Overall: [#######.................]  33%   Run 1/6: [########.] 100%   ETA to reserve: 00:12:40
files:87440   free:   0.1GiB  rate:103.68 MiB/s  temp: 49°C[NORMAL] (peak:55°C)  trim:0
workers:9/10 active  |  dispatched -> html/txt:43720 jpg:21860 bin:21860
elapsed:00:57:22
```

Compared to earlier versions, this adds: an ETA to the current run's
reserve floor; live peak temperature (not just at the end-of-run summary);
and an active-worker count against the current ceiling. Redraws are now
throttled by wall-clock time (at most once per second) in addition to the
dispatch-count interval — at high worker counts, dispatch itself can
happen many times per second, which previously could still produce far
more redraws than intended when captured in a log file or terminal
scrollback, since cursor-repositioning escape codes only affect what's
currently visible on screen, not what a log or copy-paste captures.

`DASHBOARD_INTERVAL` (dispatch-count based) and `VERBOSE=1` (forces
interval to 1) both still work as before, layered under the new
time-based floor.

---

## 16. Manifest Hashing

`manifest.txt` records, per generated file: type, level, run number, file
ID, allocation pattern, size, hash, and relative path.

**Hash algorithm changed:** BLAKE2b (`b2sum`) is now used instead of
SHA-256 when available, falling back to `sha256sum` automatically if
`b2sum` isn't installed. This is 3–5x faster per file while remaining
cryptographically strong — purely a manifest-generation speedup, with no
effect on the actual overwrite/TRIM test data.

The hash step now has a 20-second timeout, since it was previously the
only unprotected potentially-slow I/O operation left in the write path —
right as free space bottoms out at the reserve floor, disk read latency
can spike sharply under heavy SSD garbage-collection pressure, and this
used to be able to hang indefinitely for any file type, not just the
image-generation step (which already had its own timeout). On timeout,
the manifest records `TIMEOUT_OR_ERROR` for that file's hash instead of
hanging the run.

New flag: `--no-manifest-hash` skips hashing entirely (manifest records
`SKIPPED` instead), avoiding a full second disk read per file. Useful if
cumulative data written per run exceeds available RAM, since the hash's
post-write re-read then falls out of page cache and becomes a real
physical read rather than a cache hit.

```text
Original test file
        │
        ▼
Hash recorded in manifest.txt (BLAKE2b by default, SHA-256 fallback)
        │
        ▼
File deleted + TRIM
        │
        ▼
PhotoRec recovery attempt
        │
        ▼
Hash comparison against manifest.txt
```

**Paranoia-specific:** at the very end of the run, `manifest.txt` is
itself securely overwritten (`shred -u -z -n 3`) and replaced with a
one-line placeholder, since it's metadata worth not leaving readable even
though the underlying test data is already gone. This does not happen on
Normal, Restricted, or Secret — their manifests remain intact for later
comparison. The final file listing now explicitly notes when this
happened (`manifest.txt (content shredded per Paranoia policy)`).

---

## 17. PhotoRec Test Markers

Every generated test file (HTML, TXT, JPG annotation, and a text header
stamped into each binary file) contains an identifiable marker, e.g.:

```text
WIPE-TEST
LEVEL: PARANOIA
RUN: 07
FILE: 000427
PATTERN: FRAGMENTED
```

These are useful when evaluating recovery with PhotoRec — recovered files
can be associated with their originating run, level, and allocation
pattern.

---

## 18. Safety Model

The tool intentionally avoids destructive whole-device operations. It does
**not** perform:

```text
blkdiscard on the entire device
NVMe Sanitize
ATA Secure Erase
partition table changes
filesystem formatting
mkfs
```

Additional safeguards present in the current script:

* **Lockfile** (`flock`) prevents two instances from running against the
  same project directory concurrently.
* **`safe_test_dir()`** validates that `TEST_DIR` is exactly
  `<run_dir>/test-data` under the script's own `runs/` tree — never `/` or
  the target directory itself — before any deletion runs.
* **Deletion mechanism changed:** bulk per-run deletion now uses
  `find "$TEST_DIR" -mindepth 1 -delete` instead of a shell glob
  (`rm -rf .../*`). At high file counts (tens of thousands per run is
  typical at Secret/Paranoia), a glob-expanded `rm` can silently fail with
  "Argument list too long" and do almost nothing — this went undetected in
  an earlier version, since the script only checked whether `rm` itself
  errored, not whether the directory was actually empty afterward. The
  current version verifies the directory is empty after deletion, retries
  once if not, and prints a loud `!! ERROR` (rather than silently
  continuing) if files still remain after the retry.
* If the computed run directory already exists, the script **refuses to
  proceed** rather than overwrite/delete into it.
* A `trap` on `INT`/`TERM`/`EXIT` runs cleanup (kill background jobs, stop
  the sudo keepalive, remove only the script-owned `TEST_DIR`, stop the
  thermal monitor) even on Ctrl+C or an unexpected error. This trap chain
  was previously double-firing on Ctrl+C specifically (harmless, since
  every cleanup step is idempotent, but sloppy) — fixed to run exactly
  once.
* Post-TRIM free-space verification: if free space unexpectedly drops
  right after a TRIM, the script warns that something else may be writing
  to the target directory concurrently.
* **Swap is restored.** If the script disables swap (`swapoff -a`, the
  default when unencrypted swap is detected — see `--swapoff` /
  `--no-swapoff`), it re-enables it (`swapon -a`) when it exits,
  including on Ctrl+C.

The tool does not intentionally delete user files outside its own
generated `TEST_DIR`.

---

## 18a. Important Warnings the Script May Show

* **Discard passthrough:** if the filesystem sits on LUKS and/or LVM, the
  script walks the whole device-mapper stack and warns if
  `allow_discards` (LUKS) or `issue_discards` (LVM) is missing anywhere
  in it — TRIM can report success while never reaching the physical SSD.
* **btrfs snapshots:** Snapper/Timeshift/manual snapshots keep old file
  versions alive; overwriting/deleting in the current subvolume alone
  will not free or TRIM them. Delete relevant snapshots first if you
  want a meaningful result.
* **Unencrypted swap:** sensitive data can land in swap; this script
  never touches swap contents itself (it only temporarily disables swap
  so the fill isn't disturbed).
* **TRIM reported vs. written far below 100%:** printed in the final
  report if TRIM reclaimed much less than was written — treat it as a
  sign discard isn't fully passing through your storage stack, not as
  proof the test failed.

None of these are fatal by default (except a hard `STOP` from
SMART/NVMe health) — you're asked to confirm before continuing.

---

## 19. Free-Space Filling

Restricted, Secret, and Paranoia temporarily consume free space on the
target filesystem, down to a configurable reserve (`RESERVE_MB`, default
100 MiB) — smaller for Paranoia specifically (`RESERVE_MB / 2`, floor
`PARANOIA_RESERVE_FLOOR_MB`, default 50 MiB), to reach further into
controller overprovisioning space. The filesystem is never intentionally
filled to 100%.

```text
Free space:              344 GiB
Reserve kept free:        0.1 GiB (Normal/Restricted/Secret) / ~0.05–0.1 GiB (Paranoia)
Maximum temporary fill: ~344 GiB
```

The same free space is reused after each run's delete + TRIM, so a system
with 344 GiB free can legitimately generate well over 1 TiB of cumulative
write traffic across a multi-run Secret/Paranoia session, without ever
needing 1 TiB free at once. If free space is already too close to the
reserve to do anything meaningful, the script refuses to start
(`check_min_free_space()`).

---

## 20. Execution Flow

This reflects the actual continuous cycling behavior — the script does
not run separate "large-file" / "many-small-file" phases; it rotates
through all four file types together, continuously, until the reserve is
hit:

```text
START
  │
  ├── Root/sudo pre-check, lockfile
  ├── sudo keepalive loop started in the background
  │
  ├── Device/filesystem detection
  │
  ├── Discard passthrough check (LUKS/dm-crypt, LVM)
  ├── btrfs snapshot check
  ├── Swap encryption check
  │
  ├── Minimum free-space check
  ├── TRIM availability check (fstrim --dry-run)
  │
  ├── SMART/NVMe baseline capture
  ├── Wear warning (if already ≥ 80% used)
  │
  ├── Pre-run system analysis + graded recommendation (STOP/Normal/
  │     Restricted/Secret/Paranoia)
  ├── Level selection (numbered picker by default, or --level=...)
  ├── Question: how many passes of the whole level? (or --repeat=N)
  ├── Question: power off when finished? (or --poweroff/--no-poweroff)
  ├── Aggressive allocation mode decision
  ├── Effective reserve calculated (tighter for Paranoia)
  ├── Learned ETA shown if history exists for the selected level
  ├── Execution plan shown
  ├── Final confirmation (or --yes; skipped entirely under --dry-run)
  ├── 5-second countdown
  │
  └── For each run (1..TOTAL_RUNS = passes x runs-per-level):
         │
         ├── Fresh incompressible random-data pool generated
         │     (Restricted/Secret/Paranoia; Normal uses zero-fill)
         ├── Cycle HTML → TXT → JPG → BIN continuously,
         │     with live 4-line dashboard + thermal gate,
         │     until free space <= reserve
         ├── sync
         ├── Delete all generated test data (find -delete, verified)
         ├── TRIM (+ extra verification TRIM on Paranoia)
         ├── Post-TRIM idle
         ├── This run's fill rate recorded into .eta_history
         ├── Per-run report row appended to runs.csv
         └── Cooldown before next run

  ├── Final verification TRIM (after all runs)
  ├── Final report written (report.txt)
  ├── Paranoia: manifest.txt shredded
  ├── sudo keepalive loop stopped
  ├── Optional: 30 s abortable countdown, cleanup, power off
  └── DONE (exit 0, or 2 if any run was thermally aborted)
```

---

## 21. Reports and Logs

```text
SSD-Recovery-Resistance/          (auto-created at launch location)
├── .eta_history                  (learned per-level write rates)
└── runs/
    └── 20260827-140500/
        ├── report.txt
        ├── manifest.txt
        ├── run.log
        ├── runs.csv
        └── trace.log             (only if DEBUG=1)
```

`report.txt` contains: SSD model, filesystem info, mountpoint, TRIM
status, selected level + recommendation, run count, aggressive-allocation
setting, reserve size, temperature limits, execution time, CPU thread
count, peak temperature, a genuine start→end temperature comparison
(fixed in this version — it previously always showed the same value
twice), nominal vs. controller-reported write totals, TRIM operation
count and reported bytes (with a warning if TRIM reported well under 50%
of what was written), free space before/after, endurance delta (wear %
before → after), and the full SMART/NVMe start/end comparison table.

The report also records timing: total duration, **overall start/end
time**, and a **per-run start → end list**; each run's own start/end is
also printed live when the run completes and stored in its report block:

```text
Total duration:           04:04:07
Overall start time:       2026-09-20 03:30:14
Overall end time:         2026-09-20 07:34:21
Per-run start/end times:
  run 1: start 2026-09-20 03:30:19 -> end 2026-09-20 04:15:40
  run 2: start 2026-09-20 04:15:41 -> end 2026-09-20 05:01:58
  ...
```

`runs.csv` adds one machine-readable row per run:
`run,total_runs,level,pattern,filesystem,allocation,aggressive_alloc,files,duration_s,free_bytes_end,peak_temp_c,aborted_thermal,nominal_written_bytes,host_write_delta_bytes`

`run.log` is the full console output of the run. `trace.log` exists only
with `DEBUG=1` and contains the full `set -x` bash trace.

All of the above are intentionally excluded from Git via `.gitignore`,
along with `.eta_history`.

---

## 22. Command-Line Flags Reference

```text
--level=normal|restricted|secret|paranoia
                    Skip the interactive picker, pick this level directly.
--menu              Force the interactive picker even if --level was
                    also given.
--yes, -y           Skip confirmation prompts and the interactive picker
                    (falls back to --level, or paranoia if not given).
--aggressive        Force aggressive allocation mode on.
--no-aggressive     Force aggressive allocation mode off.
--swapoff           (default) If unencrypted swap is detected, run
                    'swapoff -a' automatically, no prompt. Swap is
                    re-enabled ('swapon -a') when the script exits,
                    including on Ctrl-C.
--no-swapoff        Prompt instead (or leave swap alone if combined
                    with --yes).
--jobs=N            Pin worker count to N, skipping the adaptive CPU/
                    temp/free-space analysis entirely (the thermal
                    safety pause/abort still applies regardless).
--no-manifest-hash  Skip per-file hashing in manifest.txt (see §16).
--repeat=N          Run the complete level N times in a row, N = 1..99 (e.g. paranoia
                    --repeat=2 = 2 x 6 runs). Skips the "how many times?"
                    question. Default: ask (1 with --yes).
--poweroff          Power off the computer after a normal, complete finish
                    (30 s abortable countdown). Skips the question.
--no-poweroff       Never power off. Skips the question. Default: ask
                    (no power-off with --yes).
--notify[=NAME]     Push notifications via ntfy to channel NAME (start, and
                    finished / aborted / failed - before a power-off). Without
                    =NAME the saved channel or env NOTIFY_CHANNEL is used.
                    Default: ask (off with --yes).
--no-notify         Never send notifications (skips the question).
--cleanup           Remove leftovers of an interrupted run (script-owned
                    test-data folders, switch swap back on), optionally TRIM.
--no-inhibit        Do not block suspend / idle / lid-close during the run.
--dry-run           Show the full analysis and execution plan, write no
                    files, run no TRIM, exit before the actual test.
-h, --help          Show help and exit.
```

### Environment variable overrides

| Variable | Default | Meaning |
|---|---|---|
| `RESERVE_MB` | 100 | MiB kept free at all times per run (fill stops here) |
| `RESTRICTED_RUNS` | 2 | Runs for the Restricted level |
| `SECRET_RUNS` | 3 | Runs for the Secret level |
| `PARANOIA_RUNS` | 6 | Runs for the Paranoia level |
| `PARANOIA_RESERVE_FLOOR_MB` | 50 | Hard floor for Paranoia's tighter reserve |
| `NOTIFY_SERVER` | https://ntfy.sh | ntfy server (self-hosted works too) |
| `NOTIFY_CHANNEL` | – | Default channel when `--notify` is given without a name |
| `NOTIFY_TOKEN` | – | Optional bearer token for a protected server (passed via stdin, never in `ps`) |
| `WORKER_WAIT_MAX_SECONDS` | 180 | Background workers still running this long after a fill get SIGTERM, then SIGKILL |
| `COOLDOWN_MIN_SECONDS` | 30 | Shortest break, even if the drive is already cool |
| `COOLDOWN_MAX_SECONDS` | 420 | **Hard limit** of a break (7 min); `0` = no break |
| `COOLDOWN_TARGET_C` | auto | Temperature to cool down to (`auto` = idle at launch + 5 °C; or 20–90) |
| `COOLDOWN_SECONDS` | 300 | Fixed break used only when no temperature sensor is available |
| `THERMAL_PAUSE_MAX_SECONDS` | 420 | Longest in-run thermal PAUSE before the run is ended gracefully; `0` = unlimited |
| `SOUND_ENABLED` | 1 | Terminal bell on CRITICAL/EMERGENCY thermal events |
| `VERBOSE` | 0 | Per-file/per-worker detail; dashboard refreshed every file |
| `DEBUG` | 0 | Full `set -x` trace written to `<run-dir>/trace.log` |
| `DASHBOARD_INTERVAL` | 10 | Dashboard redraw interval (dispatch-count based) |
| `TEMP_INTERVAL` | 1 | Temperature polling interval in seconds |
| `TEMP_WARNING` / `TEMP_PAUSE` / `TEMP_RESUME` / `TEMP_CRITICAL` / `TEMP_EMERGENCY` | 65 / 70 / 62 / 80 / 85 (°C) | Thermal thresholds |

### Examples

```bash
# Non-interactive Paranoia run, no prompts:
./SSD-Recovery-Resistance.sh --level=paranoia --yes

# See what it *would* do, without writing anything:
./SSD-Recovery-Resistance.sh --level=secret --dry-run

# Pin to 4 worker threads, skip manifest hashing for speed:
./SSD-Recovery-Resistance.sh --level=restricted --jobs=4 --no-manifest-hash --yes

# Run Paranoia twice in a row, then power the computer off (unattended):
./SSD-Recovery-Resistance.sh --level=paranoia --repeat=2 --poweroff --yes

# Custom run counts and reserve:
RESERVE_MB=200 SECRET_RUNS=5 PARANOIA_RUNS=8 ./SSD-Recovery-Resistance.sh --level=paranoia
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Completed normally, no thermal aborts |
| 1 | Pre-flight failure (missing tool, TRIM unavailable, SMART/NVMe STOP, bad config, user declined a prompt, etc.) |
| 2 | Completed, but at least one run was cut short by thermal limits |
| 129 | Terminal closed / SSH connection lost (SIGHUP) — cleanup ran, results incomplete |
| 130 | Interrupted (Ctrl-C, SIGTERM) — cleanup ran |

---

## 23. Limitations

This tool **cannot guarantee** that previously deleted information is
physically impossible to recover. It cannot directly control:

* NAND flash cells
* wear leveling
* over-provisioned blocks
* SSD garbage collection
* controller firmware
* flash translation layers
* hidden/internal SSD mappings

TRIM informs the storage stack which filesystem blocks are no longer
required. The SSD controller decides how and when those blocks are
physically processed.

> **TRIM + controlled overwrite + SSD garbage collection can improve
> recovery resistance, but cannot provide a mathematical guarantee of
> physical NAND erasure.**

---

## 24. Secure Erase and Sanitize

For guaranteed device-level destruction, manufacturer-supported SSD Secure
Erase or NVMe Sanitize procedures are generally more appropriate. Those
operations are intentionally **not included** in this project, since they
destroy all existing data across the entire device.

This project targets the different situation where:

> **existing files should remain intact while previously deleted data is
> subjected to additional recovery-resistance activity.**

---

## 25. Recommended Usage

Best suited for:

* SSD recovery experiments
* PhotoRec testing
* filesystem/TRIM experiments
* studying SSD garbage collection behavior
* testing recovery resistance of deleted test data
* comparing SSD/filesystem configurations
* documenting recovery experiments

**Not** a cryptographic erasure standard.

---

## 25a. Automated tests (new in v1.10)

```bash
sudo tests/run-all.sh            # everything except the slow Paranoia test (~13 min)
sudo tests/run-all.sh --quick    # only the fast cases (~30 s)
sudo tests/run-all.sh --full     # also the Paranoia repeat test (adds ~3 min)
tests/run-all.sh --list          # show the cases
sudo tests/run-all.sh --only 08  # a single case (--keep keeps the work dir)
```

It **never touches your real drives**: everything runs on a 300 MB ext4 image
loop-mounted under `/tmp/ssdrr-tests`, with a fake temperature sensor, fake SMART
wear counters, a local ntfy-compatible capture server and stubbed
`systemctl`/`poweroff`/`shutdown` (nothing is ever shut down). Needs root,
`mkfs.ext4`, `losetup`, `mount`, `fstrim`, `python3`, `curl` and ImageMagick.

The cases cover: static checks and `--help`, command-line / environment
validation, unit tests of the real functions cut out of the script (thermal gate,
adaptive break, message builder, ImageMagick detection, worker handling), `--cleanup`,
full end-to-end runs (repeat + power-off + notification order, thermal cut-off,
drive that never cools), signals (TERM, HUP, USR1), **real keyboard Ctrl-C and a
closed terminal through a pseudo terminal**, the interactive questions, the sleep
inhibitor and Paranoia pass restarts. Set `SCRIPT_UNDER_TEST=/path/to/script` to
test another copy.

---

## 26. License

MIT License — see `LICENSE`.

---

## 27. Disclaimer

Use this software at your own risk. The author does not guarantee that
deleted data will become unrecoverable. The software performs
filesystem-intensive operations and generates substantial SSD write
traffic — repeated Restricted/Secret/Paranoia runs measurably consume
drive write endurance (see §12/§13), and Paranoia's default run count has
doubled in this version (3 → 6), meaningfully increasing both total write
volume and total runtime compared to earlier versions for the same level
name.

Always maintain backups of important data before running filesystem-
intensive experiments. Do not run this tool against a system or
filesystem containing data you cannot afford to lose. The user is
responsible for selecting an appropriate level and understanding the
consequences of substantial SSD write activity.
