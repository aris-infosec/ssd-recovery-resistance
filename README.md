# SSD Recovery Resistance Tool - Remnant Wipe

A Linux-based SSD remnant-wipe and recovery-resistance testing tool designed to make **already deleted data harder to recover** while avoiding deliberate deletion of currently existing user files.

The tool combines controlled test-data generation, filesystem TRIM, controlled free-space filling, SMART/NVMe monitoring, adaptive execution profiles, identifiable test markers and SHA-256 manifests for recovery testing with tools such as PhotoRec.

> **Important:** This is **not** a Secure Erase or SSD Sanitize tool. It cannot guarantee physical destruction of every previous NAND-cell copy of deleted data.

---

## Features

* TRIM availability check before any test workload begins
* Automatic filesystem and block-device detection
* NVMe and SATA SSD detection
* SMART monitoring
* Optional NVMe health monitoring through `nvme-cli`
* SSD temperature monitoring
* Automatic thermal pause when temperatures become critical
* Adaptive execution based on SSD conditions and available resources
* Automatic system analysis and profile recommendation
* Three execution profiles:

  * **Normal**
  * **Secret**
  * **Paranoia**
* HTML test files
* TXT test files
* JPEG test files
* Large-file write tests
* Many-small-file write tests
* Controlled free-space filling
* Dynamic free-space checks during filling
* Configurable free-space safety reserve
* Filesystem `sync` before deletion
* Filesystem TRIM after test-data deletion
* Unique Run/File/Pattern identifiers
* PhotoRec-oriented recovery markers
* SHA-256 test manifest
* Runtime and remaining-time estimation
* SSD health and write-statistics logging
* Before/after NVMe statistics
* Thermal throttling detection
* Automatic cooldown between runs
* Automatic cleanup after interruption
* Timestamped reports and logs
* Timestamped test results for multiple runs

---

## What This Tool Is Designed For

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
```

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

The analysis is designed to be **read-only with respect to the test workload** and determines the conditions under which the test will run.

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

The analysis also estimates the expected workload for each execution profile.

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
  Normal:              ~XX GiB
  Secret:              ~XXX GiB
  Paranoia:            ~XXXX GiB
```

The analysis then provides a **recommended profile**.

The recommendation is advisory. The user can still select another profile.

---

# SSD Endurance Interpretation

The NVMe `Percentage Used` value is an estimate of how much of the device's rated endurance has been consumed.

It is **not filesystem storage usage**.

For example:

```text
Percentage Used: 4%
```

means approximately:

```text
Estimated endurance consumed: ~4%
Estimated endurance remaining: ~96%
Status: EXCELLENT
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

The tool also records `Data Units Written`, because `Percentage Used` may remain unchanged for a substantial amount of additional write activity.

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

The additional runs increase write activity and the opportunity for SSD firmware to recycle previously freed blocks, but the actual physical behavior remains controller-dependent.

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

For example, a cooler SSD with many CPU threads may allow more JPG workers, while a hot SSD may automatically reduce parallelism.

This reduces unnecessary thermal stress and helps avoid making the system slower through excessive parallelism.

---

# Temperature Handling

The tool monitors SSD temperature whenever SMART/NVMe information is available.

| Temperature | Status   |
| ----------: | -------- |
|     ≤ 60 °C | NORMAL   |
|    61–70 °C | WARM     |
|    71–80 °C | HIGH     |
|     > 80 °C | CRITICAL |

At critical temperatures, the write process pauses automatically.

It resumes after the SSD cools below the configured recovery threshold.

Typical behavior:

```text
SSD: 78 °C [HIGH]
Warning: SSD is getting hot.

SSD: 82 °C [CRITICAL]
Write workload paused.

Waiting for <= 65 °C...

SSD: 64 °C
Workload resumed.
```

Exact thermal behavior is SSD-model dependent.

---

# NVMe Monitoring

When `nvme-cli` is available, the tool can collect NVMe health information such as:

* temperature
* critical warning
* available spare
* percentage used
* data units written
* media/data integrity errors
* unsafe shutdowns
* power cycles

Example:

```text
NVMe:
  Critical Warning:     0
  Temperature:          44 °C
  Available Spare:      100%
  Percentage Used:      4%
  Data Units Written:   ...
  Media Errors:         0
  Unsafe Shutdowns:     ...
  Power Cycles:         ...
```

The tool records values before and after the test when supported.

This makes it possible to distinguish **nominal test writes** from controller-reported write activity.

---

# Free-Space Filling

Secret and Paranoia profiles can temporarily consume part of the currently free filesystem space.

A configurable safety reserve is always maintained.

The tool does **not** intentionally fill the filesystem to 100%.

Instead:

```text
Total free space
        │
        ├── safety reserve
        │
        └── available temporary fill
```

The free-space amount is rechecked during the fill process.

This means that:

```text
Free space != total write workload
```

For example, a system may have:

```text
344 GiB free
```

while a Paranoia run produces:

```text
1+ TiB cumulative write activity
```

because the same free space can be reused across multiple runs.

The tool clearly distinguishes:

```text
Temporary fill capacity
```

from:

```text
Cumulative write workload
```

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

This marker is included in:

* HTML files
* TXT files
* JPEG files
* other recovery-test data where practical

This makes later PhotoRec recovery testing much more useful because recovered files can be traced back to their original run.

---

# SHA-256 Manifest

The tool can generate a SHA-256 manifest for generated test files.

This allows recovered files to be compared against their original test data.

Example workflow:

```text
Original test file
        │
        ▼
SHA-256 hash recorded
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

This makes it possible to distinguish:

* exact recovery
* partial/corrupted recovery
* unrelated files
* files recovered from different runs

---

# PhotoRec Testing

The generated files are intended to allow controlled recovery experiments.

A typical test workflow is:

1. Run this tool.
2. Wait for the selected profile to finish.
3. Record the generated report and manifest.
4. Use a separate recovery environment where possible.
5. Run PhotoRec against the test filesystem/device.
6. Search recovered files for `WIPE-TEST` markers.
7. Compare recovered files against the generated SHA-256 manifest.
8. Identify which Run/Pattern survived.

Example recovery marker:

```text
WIPE-TEST
LEVEL: PARANOIA
RUN: 07
FILE: 0427
PATTERN: RANDOM
```

This makes recovery results much easier to interpret than generic filenames.

---

# Installation on Arch Linux

Install the required packages:

```bash
sudo pacman -S imagemagick smartmontools
```

For additional NVMe health information:

```bash
sudo pacman -S nvme-cli
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

Run it as the normal user:

```bash
./ssd-recovery-resistance.sh
```

> **Do not start the entire script with `sudo`.**

The script requests elevated privileges only for operations that require them.

---

# Repository Structure

Recommended project structure:

```text
ssd-recovery-resistance/
├── README.md
├── LICENSE
├── .gitignore
├── ssd-recovery-resistance.sh
└── reports/
    └── .gitkeep
```

Runtime reports should remain local and should not be committed to a public repository.

Recommended `.gitignore` entries:

```gitignore
reports/*
!reports/.gitkeep

wipe-test/
```

---

# Reports and Logs

All generated reports are stored **relative to the location of the script**.

Example:

```text
ssd-recovery-resistance/
├── ssd-recovery-resistance.sh
└── reports/
    └── 2026-08-13-132300/
        ├── report.txt
        ├── manifest.txt
        └── report.log
```

This keeps multiple test runs organized and prevents personal SSD information from automatically being stored in the user's home directory.

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
* percentage used
* available spare
* controller statistics
* free space before/after
* temporary free-space fill
* estimated write workload
* controller-reported write statistics when available
* TRIM statistics
* run-by-run results

---

# Execution Flow

The tool follows this general sequence:

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

The tool does not intentionally delete user files outside its own test directory.

Interrupting the program attempts to clean up only its own temporary test directory.

---

# TRIM Behavior

TRIM availability is checked before the actual workload begins.

If the filesystem cannot be trimmed, the test is aborted rather than continuing under conditions that do not match the intended recovery-resistance workflow.

The first **real** TRIM is performed after generated test data has been written, synchronized and deleted.

Later TRIM operations are performed after appropriate test phases.

This avoids an unnecessary real TRIM immediately before the first test run.

---

# Write Workload vs. Free Space

The tool distinguishes between:

### Temporary storage requirement

How much free disk space needs to be available **at the same time**.

### Cumulative write workload

How much data is written over the entire test.

These are not the same quantity.

For example:

```text
Free space:               344 GiB
Temporary safe fill:      306 GiB
Cumulative workload:     1+ TiB
```

This is possible because test data is deleted and the same free space can be reused by later runs.

The cumulative write workload is therefore an indicator of SSD write activity, not a requirement for that amount of free space.

---

# Endurance and SSD Wear

The tool reports both:

* NVMe `Percentage Used`
* controller-reported write statistics where available

`Percentage Used` is a controller estimate of consumed endurance.

It is not the same as filesystem disk usage.

For example:

```text
Percentage Used: 4%

Interpretation:
  Endurance consumed: ~4%
  Status:              EXCELLENT
  Estimated remainder: ~96%
```

The remaining percentage is only an estimate based on the SSD controller's endurance reporting.

The actual physical wear of NAND cells cannot be observed directly from the operating system.

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

> **TRIM + controlled writes + garbage collection can improve recovery resistance, but cannot provide a mathematical guarantee of physical NAND erasure.**

---

# Secure Erase and Sanitize

For guaranteed device-level destruction, manufacturer-supported SSD Secure Erase or NVMe Sanitize procedures are generally more appropriate.

Those operations are intentionally **not included** in this project because they can destroy currently existing data across the whole device.

This project specifically focuses on the different situation where:

> **existing files should remain intact while previously deleted data is subjected to additional recovery-resistance activity.**

---

# Recommended Usage

This project is best suited for:

* SSD recovery experiments
* PhotoRec testing
* filesystem/TRIM experiments
* studying SSD garbage collection behavior
* testing recovery resistance of deleted test data
* comparing different SSD/filesystem configurations
* documenting SSD recovery experiments

It should **not** be treated as a cryptographic erasure standard.

---

# Example

A typical analysis might report:

```text
SSD:                  Samsung NVMe
Filesystem:           ext4
Mountpoint:           /home
TRIM:                 AVAILABLE
Temperature:          44 °C [NORMAL]
Endurance Used:       4% [EXCELLENT]
Available Spare:      100%
Free Space:           344.6 GiB
Reserved Space:       38.6 GiB
Safe Temporary Fill:  306.0 GiB

Estimated workload:

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
```

The user can accept the recommendation or select another profile.

---

# License

This project is licensed under the MIT License.

See [`LICENSE`](LICENSE) for details.

---

# Disclaimer

Use this software at your own risk.

The author does not guarantee that deleted data will become unrecoverable.

The software performs filesystem-intensive operations and may generate substantial SSD write traffic.

Always maintain backups of important data before running filesystem-intensive experiments.

Do not run this tool against a system or filesystem containing data you cannot afford to lose.

The user is responsible for selecting an appropriate execution profile and understanding the potential consequences of substantial SSD write activity.
