Absolutely. Here is the **updated GitHub README text** for `aris-infosec/ssd-recovery-resistance`, using the current script name and current behavior.

````markdown
# SSD Recovery Resistance Tool

A Linux-based SSD recovery-resistance testing tool designed to make **already deleted data harder to recover** while avoiding deliberate deletion of currently existing user files.

The tool combines controlled test-data generation, filesystem TRIM, adaptive free-space filling, SMART/NVMe monitoring, adaptive execution profiles, identifiable test markers and SHA-256 manifests for controlled recovery experiments with tools such as PhotoRec.

> **Important:** This is **not** a Secure Erase or SSD Sanitize tool. It cannot guarantee physical destruction of every previous NAND-cell copy of deleted data.

---

## Features

- Pre-run system analysis
- Automatic execution-profile recommendation
- TRIM availability validation
- Automatic filesystem and block-device detection
- NVMe and SATA detection
- SMART monitoring
- Optional NVMe health monitoring through `nvme-cli`
- SSD temperature monitoring
- Automatic thermal pause when temperatures become critical
- Adaptive CPU/JPG worker selection
- Adaptive cooldown between runs
- Three execution profiles:
  - Normal
  - Secret
  - Paranoia
- HTML test files
- TXT test files
- JPEG test files
- Large-file write tests
- Many-small-file write tests
- Controlled free-space filling
- Dynamic free-space monitoring
- Configurable free-space safety reserve
- `sync` before deletion
- Filesystem TRIM after deletion
- Unique Run/File/Pattern identifiers
- PhotoRec-oriented recovery markers
- SHA-256 test manifest
- Runtime and remaining-time estimation
- SSD health and write-statistics logging
- NVMe before/after statistics
- Thermal throttling detection
- Automatic cleanup on interruption
- Timestamped reports
- Timestamped manifests
- Timestamped logs

---

# What This Tool Is Designed For

The purpose of this project is **not to actively delete personal files**.

Instead, it creates temporary test data, writes it to the filesystem, synchronizes it, deletes the test data and then performs TRIM.

The intention is to increase the likelihood that SSD firmware garbage collection and block reclamation will remove previously freed filesystem blocks.

The tool therefore targets the following situation:

```text
Existing user data
        │
        ├── remains untouched
        │
Deleted historical data
        │
        └── already free filesystem blocks
                    │
                    ▼
          controlled test writes
                    │
                    ▼
                  sync
                    │
                    ▼
                 delete
                    │
                    ▼
                  TRIM
                    │
                    ▼
      SSD controller garbage collection
````

The generated test data is temporary and is the only data the script intentionally deletes.

---

# Why SSDs Are Different

Traditional HDD wiping techniques cannot simply be transferred to SSDs.

SSDs use technologies such as:

* wear leveling
* garbage collection
* over-provisioning
* flash translation layers
* controller-managed block allocation
* background block recycling

Because of this, the operating system cannot directly know which physical NAND cells contain historical copies of a deleted file.

Repeatedly overwriting a logical file does **not** provide a physical guarantee that every previous NAND cell was overwritten.

This tool therefore uses filesystem TRIM and additional controlled filesystem activity instead of pretending to provide guaranteed physical NAND erasure.

---

# System Analysis

Before the actual workload begins, the tool performs a system analysis.

The analysis is designed to determine whether the configured test is appropriate for the current system.

It checks:

```text
SSD model
Transport type
Filesystem
Filesystem mountpoint
TRIM availability
Discard capability
Total capacity
Free space
SSD temperature
SMART health
NVMe health
Available spare
Percentage used
Critical warnings
Media/data integrity errors
Unsafe shutdown count
Power-cycle count
Data units written
CPU thread count
```

The analysis also estimates the workload for each execution profile.

Example:

```text
System Analysis

SSD:                  Samsung NVMe
Filesystem:           ext4
Mountpoint:           /home
TRIM:                 AVAILABLE
Temperature:          44 °C [NORMAL]
Endurance Used:       4% [EXCELLENT]
Available Spare:      100%
Free Space:           344.6 GiB

Estimated workload:
  Normal:              lower write load
  Secret:              moderate write load
  Paranoia:            substantially higher write load

Recommendation:
  Secret
```

The recommendation is advisory. The user can still choose another profile.

---

# SSD Endurance

The NVMe `Percentage Used` value is an estimate of how much of the device's rated endurance has been consumed.

It is **not filesystem storage usage**.

For example:

```text
Percentage Used: 4%
```

means approximately:

```text
Estimated endurance consumed:  ~4%
Estimated endurance remaining: ~96%
Status:                         EXCELLENT
```

The value is a controller estimate and should not be interpreted as a guarantee of the exact remaining physical NAND lifetime.

Recommended interpretation:

| Percentage Used | Status                 |
| --------------: | ---------------------- |
|           0–20% | EXCELLENT              |
|          21–50% | GOOD                   |
|          51–75% | MODERATE               |
|          76–90% | HIGH                   |
|         91–100% | CRITICAL               |
|           >100% | BEYOND RATED ENDURANCE |

The tool also records `Data Units Written`, because `Percentage Used` may remain unchanged for substantial additional write activity.

---

# Security Profiles

## Normal

**1 run**

A lightweight test with relatively low write amplification.

Suitable for basic testing and validation.

Typical behavior:

```text
1 run
HTML/TXT/JPG test data
large-file test
many-small-file test
TRIM
no large free-space fill
```

---

## Secret

**5 runs**

Uses multiple data patterns and controlled free-space filling.

Designed for a stronger recovery-resistance experiment while limiting unnecessary SSD write load.

Typical behavior:

```text
5 runs
multiple data patterns
controlled free-space fill
TRIM after relevant deletion stages
cooldown between runs
```

---

## Paranoia

**10 runs**

Uses more varied data patterns, additional write activity and more extensive free-space filling.

This profile produces substantially more SSD write traffic.

Typical behavior:

```text
10 runs
multiple data patterns
larger test variation
controlled free-space filling
temperature-aware execution
cooldown between runs
```

> **More runs do not mean mathematically stronger physical erasure.**

Additional runs increase write activity and the opportunity for SSD firmware to recycle previously freed blocks, but physical behavior remains controller-dependent.

---

# Adaptive Execution

The tool does not blindly use a fixed configuration.

It evaluates:

* CPU thread count
* SSD temperature
* free space
* SSD health
* selected profile

and can adapt:

* JPG worker count
* workload concurrency
* cooldown duration
* free-space fill behavior
* thermal handling

A cooler SSD with more available CPU resources may use more JPG workers.

A warmer SSD may automatically reduce parallelism and increase cooldown time.

---

# Temperature Handling

The tool monitors SSD temperature whenever SMART/NVMe information is available.

| Temperature | Status   |
| ----------: | -------- |
|     ≤ 60 °C | NORMAL   |
|    61–70 °C | WARM     |
|    71–80 °C | HIGH     |
|     > 80 °C | CRITICAL |

At critical temperatures, the write workload pauses automatically.

It resumes after the SSD cools below the configured recovery threshold.

Example:

```text
SSD: 78 °C [HIGH]

Warning: SSD temperature is high.

SSD: 82 °C [CRITICAL]

Write workload paused.

Waiting for <= 65 °C...

SSD: 64 °C [NORMAL]

Workload resumed.
```

Exact thermal behavior is SSD-model dependent.

---

# NVMe Monitoring

When `nvme-cli` is available, the tool can collect:

* Critical Warning
* temperature
* Available Spare
* Percentage Used
* Data Units Written
* Media/Data Integrity Errors
* Unsafe Shutdowns
* Power Cycles

Example:

```text
NVMe:
  Critical Warning:      0
  Temperature:           44 °C
  Available Spare:       100%
  Percentage Used:       4%
  Data Units Written:    ...
  Media Errors:          0
  Unsafe Shutdowns:      ...
  Power Cycles:          ...
```

The tool records relevant values before and after the test when supported.

This makes it possible to compare the controller-reported write activity with the workload generated by the script.

---

# Free-Space Filling

Secret and Paranoia profiles can temporarily consume part of the currently free filesystem space.

A configurable safety reserve is always maintained.

The tool does **not** intentionally fill the filesystem to 100%.

The available free space is divided conceptually into:

```text
Total free space
        │
        ├── safety reserve
        │
        └── temporary fill capacity
```

The free-space amount is rechecked during the fill process.

This means:

```text
Free space != cumulative write workload
```

For example:

```text
Free space:            344 GiB
Safety reserve:         38 GiB
Maximum temporary fill: 306 GiB
```

The same free space can then be reused in later runs after deletion and TRIM.

Therefore a system with:

```text
344 GiB free
```

can legitimately perform:

```text
1+ TiB cumulative write activity
```

without requiring 1 TiB of free space at the same time.

---

# Test File Identification

Every generated test file contains an identifiable marker.

Example:

```text
WIPE-TEST
LEVEL: PARANOIA
RUN: 07
FILE: 0427
PATTERN: RANDOM
```

Markers are included in:

* HTML files
* TXT files
* JPEG files
* other recovery-test data where practical

This allows recovered files to be traced back to their original run and pattern.

---

# SHA-256 Manifest

The tool can create a SHA-256 manifest for generated test files.

This allows recovered files to be compared against their originals.

Example workflow:

```text
Original test file
        │
        ▼
SHA-256 recorded
        │
        ▼
File deleted + TRIM
        │
        ▼
PhotoRec recovery
        │
        ▼
Recovered file
        │
        ▼
SHA-256 comparison
```

The result can distinguish between:

* exact recovery
* partial/corrupted recovery
* unrelated data
* files recovered from another run

---

# PhotoRec Testing

The generated test files are intended to allow controlled recovery experiments.

A typical workflow is:

1. Run this tool.
2. Wait for the selected profile to finish.
3. Preserve the generated report and manifest.
4. Use a separate recovery environment where possible.
5. Run PhotoRec against the test filesystem/device.
6. Search recovered files for `WIPE-TEST` markers.
7. Compare recovered files against the SHA-256 manifest.
8. Identify which Run/Pattern survived.

Example:

```text
WIPE-TEST
LEVEL: PARANOIA
RUN: 07
FILE: 0427
PATTERN: RANDOM
```

This provides much more useful recovery information than generic filenames.

---

# Installation on Arch Linux

Install the required packages:

```bash
sudo pacman -S imagemagick smartmontools nvme-cli
```

Clone the repository:

```bash
git clone https://github.com/aris-infosec/ssd-recovery-resistance.git
cd ssd-recovery-resistance
```

Make the script executable:

```bash
chmod +x ssd-recovery-resistance.sh
```

Run it:

```bash
./ssd-recovery-resistance.sh
```

> **Do not start the entire script with `sudo`.**

The script requests elevated privileges only for operations that require them.

The script can be started from any working directory. Runtime results are stored relative to the script itself.

For example:

```bash
~/ssd-recovery-resistance/ssd-recovery-resistance.sh
```

will store runtime data inside the repository's `runs/` directory.

---

# Repository Structure

Recommended project structure:

```text
ssd-recovery-resistance/
├── README.md
├── LICENSE
├── .gitignore
├── ssd-recovery-resistance.sh
└── runs/
    └── .gitkeep
```

Runtime output is stored in timestamped directories:

```text
runs/
└── 2026-08-13-140500/
    ├── report.txt
    ├── manifest.txt
    ├── run.log
    └── test-data/
```

The temporary `test-data/` directory is removed after the run.

Reports, manifests and logs remain locally for analysis.

---

# .gitignore

Runtime results should not be committed to a public GitHub repository.

Recommended `.gitignore`:

```gitignore
# Runtime test output
runs/*
!runs/.gitkeep

# Temporary test data
test-data/

# Logs and reports
*.log
*-report.txt
*-manifest.txt

# Editor / OS files
.DS_Store
*.swp
*~
```

This prevents personal SSD information, SMART data, reports and manifests from being accidentally uploaded to GitHub.

---

# Execution Flow

```text
START
  │
  ├── System analysis
  │
  ├── SSD / filesystem validation
  │
  ├── TRIM availability check
  │
  ├── Health / temperature check
  │
  ├── Workload estimation
  │
  ├── Profile recommendation
  │
  ├── User selection
  │
  ├── Countdown
  │
  └── Test runs
         │
         ├── Generate test data
         ├── sync
         ├── delete generated data
         ├── TRIM
         ├── large-file test
         ├── TRIM
         ├── many-small-file test
         ├── controlled free-space fill
         ├── delete temporary fill
         ├── final TRIM
         ├── report run
         └── cooldown
```

---

# Reports and Logs

Reports are stored relative to the script location.

Example:

```text
ssd-recovery-resistance/
├── ssd-recovery-resistance.sh
└── runs/
    └── 2026-08-13-140500/
        ├── report.txt
        ├── manifest.txt
        └── run.log
```

Reports may contain:

* SSD model
* filesystem information
* mountpoint
* TRIM status
* selected profile
* recommended profile
* run count
* data patterns
* execution time
* CPU configuration
* temperature
* maximum temperature
* SMART/NVMe health
* Percentage Used
* Available Spare
* controller statistics
* free space before/after
* temporary free-space fill
* estimated write workload
* controller-reported write statistics
* run-by-run results

---

# Safety Model

The tool intentionally avoids destructive whole-device operations.

It does **not** perform:

```text
blkdiscard on the entire device
NVMe Sanitize
ATA Secure Erase
partition table changes
filesystem formatting
mkfs
```

The generated test directory is validated before deletion.

If an unexpected existing test directory is detected, the tool stops instead of deleting it.

The tool does not intentionally delete user files outside its own temporary test directory.

Interrupting the program attempts to clean up only its own temporary test directory.

---

# TRIM Behavior

TRIM availability is checked before the actual workload begins.

If TRIM is not available, the test is aborted rather than continuing under conditions that do not match the intended recovery-resistance workflow.

The first **real** TRIM occurs after generated test data has been written, synchronized and deleted.

Later TRIM operations are performed after appropriate test phases.

This avoids an unnecessary real TRIM immediately before the first test workload.

---

# Endurance and SSD Wear

The tool records both:

* NVMe `Percentage Used`
* controller-reported write statistics where available

`Percentage Used` is an estimate of consumed endurance.

It is not filesystem disk usage.

The actual physical wear of NAND cells cannot be observed directly from the operating system.

The tool therefore reports both endurance information and actual controller write statistics where supported.

---

# Limitations

This tool **cannot guarantee** that previously deleted information is physically impossible to recover.

In particular, it cannot directly control:

* NAND flash cells
* wear leveling
* over-provisioned blocks
* SSD garbage collection
* controller firmware
* flash translation layers
* hidden/internal SSD mappings

TRIM informs the storage stack which filesystem blocks are no longer required. The SSD controller decides how and when those blocks are physically processed.

Therefore:

> **TRIM + controlled writes + SSD garbage collection can improve recovery resistance, but cannot provide a mathematical guarantee of physical NAND erasure.**

---

# Secure Erase and Sanitize

For guaranteed device-level destruction, manufacturer-supported SSD Secure Erase or NVMe Sanitize procedures are generally more appropriate.

Those operations are intentionally **not included** in this project because they can destroy currently existing data across the entire device.

This project focuses on the different situation where:

> **existing files should remain intact while previously deleted data is subjected to additional recovery-resistance activity.**

---

# Recommended Usage

This project is best suited for:

* SSD recovery experiments
* PhotoRec testing
* filesystem/TRIM experiments
* studying SSD garbage collection behavior
* testing recovery resistance of deleted test data
* comparing SSD/filesystem configurations
* documenting recovery experiments

It should **not** be treated as a cryptographic erasure standard.

---

# Example System Analysis

```text
============================================================
                    SYSTEM ANALYSIS
============================================================

SSD:                  Samsung NVMe
Filesystem:           ext4
Mountpoint:           /home
TRIM:                 AVAILABLE

Temperature:          44 °C [NORMAL]
Endurance Used:       4% [EXCELLENT]
Available Spare:      100%
Free Space:           344.6 GiB
Safety Reserve:        38.6 GiB
Maximum Temporary Fill:
                      306.0 GiB

Estimated cumulative workload:

NORMAL:
  1 run
  lower write load

SECRET:
  5 runs
  moderate write load

PARANOIA:
  10 runs
  substantially higher write load

Recommendation:
  SECRET
============================================================
```

---

# License

This project is licensed under the MIT License.

See `LICENSE` for details.

---

# Disclaimer

Use this software at your own risk.

The author does not guarantee that deleted data will become unrecoverable.

The software performs filesystem-intensive operations and may generate substantial SSD write traffic.

Always maintain backups of important data before running filesystem-intensive experiments.

Do not run this tool against a system or filesystem containing data you cannot afford to lose.

The user is responsible for selecting an appropriate execution profile and understanding the potential consequences of substantial SSD write activity.

```

For your GitHub repository, I would use this exact description:

> **Linux SSD recovery-resistance testing tool with TRIM, SMART/NVMe monitoring, adaptive execution and PhotoRec test markers.**
```
