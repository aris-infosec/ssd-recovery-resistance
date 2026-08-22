# GitHub Setup Instructions – SSD Recovery Resistance (v1.8)

Repository:

https://github.com/aris-infosec/ssd-recovery-resistance

Script:

`SSD-Recovery-Resistance.sh`

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
creates its own project directory at runtime (see §7) — that directory,
including `runs/`, `.lock`, and everything under it, should stay out of Git.

---

## 2. Create `.gitignore`

```gitignore
# Runtime project directory (auto-created; named after the script)
SSD-Recovery-Resistance/
.lock

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

## 4. Add the Script

```bash
cp ~/Downloads/SSD-Recovery-Resistance.sh .
chmod +x SSD-Recovery-Resistance.sh
```

---

## 5. Install Dependencies

On Arch Linux:

```bash
sudo pacman -S imagemagick smartmontools nvme-cli util-linux openssl
```

`util-linux` provides `flock`, `findmnt`, `fstrim`, and `lsblk`, all of
which the script requires unconditionally. `openssl` is optional but
recommended — it's used to generate the incompressible random-data pool
faster than reading `/dev/urandom` directly.

The full list of hard-required commands the script checks for at startup:

```text
bash magick fstrim findmnt lsblk df stat dd sync awk grep head tail sed
sha256sum tee nproc mktemp flock
```

`smartctl` and `nvme` are optional — without them, temperature/SMART/NVMe
fields in the report will show as `n/a`, but the fill/delete/TRIM cycle
still works.

**Do not start the script with `sudo`.** Run it as your normal user:

```bash
./SSD-Recovery-Resistance.sh
```

The script checks whether it's already root; if not, it verifies `sudo`
works (`sudo -v`) up front and fails fast with a clear message if it
doesn't, rather than dying mid-run after hours of filling the disk. It then
uses `sudo` internally only for the specific commands that need root
(`fstrim`, `smartctl`, `nvme`, `dmsetup`, `btrfs`).

---

## 6. README Installation Section

```markdown
## Installation on Arch Linux

Install the required dependencies:

sudo pacman -S imagemagick smartmontools nvme-cli util-linux openssl

Clone the repository:

git clone https://github.com/aris-infosec/ssd-recovery-resistance.git
cd ssd-recovery-resistance

Make the script executable:

chmod +x SSD-Recovery-Resistance.sh

Run the tool from the directory whose disk you want to test:

./SSD-Recovery-Resistance.sh

> Do not start the script with `sudo`. It requests elevated privileges
> internally, only for the specific operations that need them.
```

---

## 7. Runtime Output

**Important correction:** the output location is based on the **current
working directory the script is launched from (`pwd`), not the directory
the script file itself lives in.** This matters if the script is called via
a symlink or through `$PATH` from somewhere else.

The script creates a project folder named after itself, at the launch
location, and treats *that folder* as the filesystem under test (so
`df`/`findmnt`/`fstrim` all operate on whatever disk you actually launched
the script from):

```text
<directory you ran it from>/
└── SSD-Recovery-Resistance/
    ├── .lock
    └── runs/
        └── 20260813-140500/
            ├── report.txt
            ├── manifest.txt
            ├── run.log
            └── runs.csv
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

The temporary `test-data/` directory inside each run is removed after that
run completes (or on interrupt/abort, via a `trap`-based cleanup). Reports,
manifests, and CSVs remain locally available afterward but are excluded
from Git via `.gitignore`.

A lockfile (`.lock`, via `flock`) prevents two instances from running
against the same project directory simultaneously.

---

## 8. Adaptive Allocation Profiles

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

## 9. Aggressive Allocation Mode

* **Normal** — always off.
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

## 10. TRIM Cooldown

Two distinct pauses exist:

* **Post-TRIM idle** (`POST_TRIM_IDLE`, default 10 s) — after every
  `fstrim` call, giving the controller a moment before the next
  measurement.
* **Run cooldown** (`RUN_COOLDOWN`) — between full fill/delete/TRIM runs;
  default 30 s, automatically raised to 60 s if the drive was running hot
  at the start of the run (`adapt_settings()`).

The controller's internal garbage-collection behavior remains outside OS
control, so these pauses are a heuristic, not a guarantee that background
housekeeping has fully completed.

---

## 11. NVMe Write Tracking

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

## 12. Pre-Run System Analysis

Before showing the level menu, `run_analysis()` checks:

```text
SSD model, transport type, filesystem, mountpoint
TRIM availability
Free space (bytes and %)
Temperature
SMART health / NVMe critical_warning
Percentage Used (endurance)
Available Spare
```

...and produces a recommendation: `NORMAL`, `SECRET`, `PARANOIA`, or
`STOP`. Triggers for a downgraded/stopped recommendation:

| Condition | Recommendation |
|---|---|
| SMART reports FAILED | STOP |
| NVMe critical_warning ≠ 0 | STOP |
| Temperature already above `TEMP_CRITICAL` (80 °C) | NORMAL |
| Percentage Used ≥ 80% | NORMAL |
| Free space < 5 GiB | NORMAL |
| none of the above | PARANOIA |

The recommendation is advisory — you can still pick another level from the
menu (option `[4]` applies it, `[0]` re-runs the analysis, `[5]` shows it
and exits without writing anything). If analysis says `STOP` but you pass
`--level=...` explicitly on the CLI, the script honors your choice after an
extra confirmation (skipped with `--yes`).

---

## 13. SSD Endurance

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

## 14. Security Profiles

**Corrected run counts** — these are configurable via environment
variables, and the current defaults are lower than earlier drafts of this
doc stated:

### Normal
**1 run.** Zero-filled data (fast), normal allocation, standard reserve.
Basic check that TRIM runs and free space is reclaimed correctly.

### Secret
**`SECRET_RUNS` runs — default 2** (override: `SECRET_RUNS=5 ./SSD-Recovery-Resistance.sh`).
Incompressible random data (fresh pool per run), optional aggressive
allocation, standard reserve. Guards against a single incomplete TRIM
pass.

### Paranoia
**`PARANOIA_RUNS` runs — default 3** (override:
`PARANOIA_RUNS=8 ./SSD-Recovery-Resistance.sh`). Incompressible random
data, aggressive allocation always on, a tighter reserve (reaches further
into controller overprovisioning space), an extra verification TRIM pass
per run, and secure deletion (`shred -u -z -n 3`) of the run's own
`manifest.txt` at the end.

A built-in sanity check enforces `PARANOIA_RUNS > SECRET_RUNS` — if you set
`PARANOIA_RUNS` at or below `SECRET_RUNS`, the script automatically raises
it to `SECRET_RUNS + 1` and prints a note, so "Paranoia" can never end up
weaker than "Secret."

> More runs do not mean mathematically stronger physical erasure — they
> mean more overwrite/TRIM cycles, which is a heuristic improvement, not a
> guarantee.

---

## 15. Temperature Handling

**Corrected — this is now a 5-tier system**, not the 4-tier one from
earlier drafts, and it runs as a continuous background monitor rather than
a periodic check:

| Threshold (default) | State | Behavior |
|---:|---|---|
| < 65 °C | NORMAL | normal operation |
| ≥ 65 °C (`TEMP_WARNING`) | WARNING | JPG worker count reduced |
| ≥ 70 °C (`TEMP_PAUSE`) | PAUSE | writes pause until ≤ 62 °C (`TEMP_RESUME`) for a sustained window |
| ≥ 80 °C (`TEMP_CRITICAL`) | CRITICAL | current run aborted, 3× audible alert |
| ≥ 85 °C (`TEMP_EMERGENCY`) | EMERGENCY | current run aborted, 5× audible alert |

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

## 16. PhotoRec Test Markers

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

## 17. SHA-256 Manifest

`manifest.txt` records, per generated file: type, level, run number, file
ID, allocation pattern, size, SHA-256 hash, and relative path.

```text
Original test file
        │
        ▼
SHA-256 recorded in manifest.txt
        │
        ▼
File deleted + TRIM
        │
        ▼
PhotoRec recovery attempt
        │
        ▼
SHA-256 comparison against manifest.txt
```

**Paranoia-specific:** at the very end of the run, `manifest.txt` is
itself securely overwritten (`shred -u -z -n 3`) and replaced with a
one-line placeholder, since it's metadata worth not leaving readable even
though the underlying test data is already gone. This does not happen on
Normal or Secret — their manifests remain intact for later comparison.

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
  the target directory itself — before any `rm -rf` runs.
* If the computed run directory already exists, the script **refuses to
  proceed** rather than overwrite/delete into it.
* A `trap` on `INT`/`TERM`/`EXIT` runs cleanup (kill background jobs,
  remove only the script-owned `TEST_DIR`, stop the thermal monitor) even
  on Ctrl+C or an unexpected error.
* Post-TRIM free-space verification: if free space unexpectedly drops
  right after a TRIM, the script warns that something else may be writing
  to the target directory concurrently.

The tool does not intentionally delete user files outside its own
generated `TEST_DIR`.

---

## 19. Free-Space Filling

Secret and Paranoia temporarily consume free space on the target
filesystem, down to a configurable reserve (`RESERVE_MB`, default 100
MiB) — smaller for Paranoia specifically (`RESERVE_MB / 2`, floor
`PARANOIA_RESERVE_FLOOR_MB`, default 50 MiB), to reach further into
controller overprovisioning space. The filesystem is never intentionally
filled to 100%.

```text
Free space:              344 GiB
Reserve kept free:        0.1 GiB (Normal/Secret) / ~0.05–0.1 GiB (Paranoia)
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

**Corrected** to reflect the actual continuous cycling behavior (the
script does not run separate "large-file" / "many-small-file" phases —
it rotates through all four file types together, continuously, until the
reserve is hit):

```text
START
  │
  ├── Root/sudo pre-check, lockfile
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
  ├── Pre-run system analysis + recommendation
  ├── Level selection (menu, or --level=...)
  ├── Aggressive allocation mode decision
  ├── Effective reserve calculated (tighter for Paranoia)
  ├── Execution plan shown
  ├── Final confirmation (or --yes)
  │
  └── For each run (1..TOTAL_RUNS):
         │
         ├── Fresh incompressible random-data pool generated
         ├── Cycle HTML → TXT → JPG → BIN continuously,
         │     with live dashboard + thermal gate,
         │     until free space <= reserve
         ├── sync
         ├── Delete all generated test data
         ├── TRIM (+ extra verification TRIM on Paranoia)
         ├── Post-TRIM idle
         ├── Per-run report row appended to runs.csv
         └── Cooldown before next run

  ├── Final verification TRIM (after all runs)
  ├── Final report written (report.txt)
  ├── Paranoia: manifest.txt shredded
  └── DONE (exit 0, or 2 if any run was thermally aborted)
```

---

## 21. Reports and Logs

```text
SSD-Recovery-Resistance/          (auto-created at launch location)
└── runs/
    └── 20260813-140500/
        ├── report.txt
        ├── manifest.txt
        ├── run.log
        └── runs.csv
```

`report.txt` contains: SSD model, filesystem info, mountpoint, TRIM
status, selected level + recommendation, run count, aggressive-allocation
setting, reserve size, temperature limits, execution time, CPU thread
count, peak temperature, nominal vs. controller-reported write totals,
TRIM operation count and reported bytes (with a warning if TRIM reported
well under 50% of what was written), free space before/after, endurance
delta (wear % before → after), and the full SMART/NVMe start/end
comparison table.

`runs.csv` adds one machine-readable row per run:
`run,total_runs,level,pattern,filesystem,allocation,aggressive_alloc,files,duration_s,free_bytes_end,peak_temp_c,aborted_thermal,nominal_written_bytes,host_write_delta_bytes`

All of the above are intentionally excluded from Git via `.gitignore`.

---

## 22. Recommended `.gitignore`

(Same as §2 — repeated here for convenience.)

```gitignore
# Runtime project directory (auto-created; named after the script)
SSD-Recovery-Resistance/
.lock

# Temporary test data
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

# OS/editor files
.DS_Store
*.swp
*~
```

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

## 26. License

MIT License — see `LICENSE`.

---

## 27. Disclaimer

Use this software at your own risk. The author does not guarantee that
deleted data will become unrecoverable. The software performs
filesystem-intensive operations and generates substantial SSD write
traffic — repeated Paranoia runs measurably consume drive write endurance
(see §13/§14).

Always maintain backups of important data before running filesystem-
intensive experiments. Do not run this tool against a system or
filesystem containing data you cannot afford to lose. The user is
responsible for selecting an appropriate level and understanding the
consequences of substantial SSD write activity.
