# ssd-recovery-resistance
Linux SSD remnant-wipe and recovery-resistance testing tool with TRIM

# SSD Remnant Wipe

A Linux-based SSD remnant-wipe and recovery-resistance testing tool designed to make **already deleted data harder to recover** while avoiding deliberate deletion of currently existing user files.

The tool combines controlled test-data generation, filesystem TRIM, free-space filling, SMART/NVMe monitoring, adaptive execution profiles and identifiable test markers for recovery testing with tools such as PhotoRec.

> **Important:** This is **not** a Secure Erase or SSD Sanitize tool. It cannot guarantee physical destruction of every previous NAND-cell copy of deleted data.

## Features

* TRIM availability check before starting
* Automatic filesystem and block-device detection
* NVMe and SATA SSD detection
* SMART monitoring
* Optional NVMe health monitoring through `nvme-cli`
* SSD temperature monitoring
* Automatic thermal pause when temperatures become critical
* Adaptive execution parameters
* Three wipe profiles:

  * Normal
  * Secret
  * Paranoia
* HTML test files
* TXT test files
* JPEG test files
* Large-file write tests
* Many-small-file write tests
* Controlled free-space filling
* Filesystem `sync` before deletion
* Full-filesystem TRIM through the user's filesystem mount
* Unique Run/File/Pattern identifiers
* SHA-256 test manifest
* Runtime and remaining-time estimation
* SSD health and write-statistics logging
* Final test report

## What this tool is designed for

The purpose of this project is **not** to actively delete personal files.

Instead, it creates temporary test data, writes it to the filesystem, synchronizes it, deletes the test data and then performs TRIM.

The intention is to increase the likelihood that SSD firmware garbage collection and block reclamation will remove previously freed blocks.

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
                 delete
                    │
                    ▼
                  TRIM
```

## Why SSDs are different

Traditional HDD wiping techniques cannot simply be transferred to SSDs.

SSDs use technologies such as:

* wear leveling
* garbage collection
* over-provisioning
* flash translation layers
* controller-managed block allocation

Because of this, the operating system cannot directly know which physical NAND cells contain historical copies of a deleted file.

Repeatedly overwriting a logical file does **not** provide a physical guarantee that every previous NAND cell was overwritten.

This tool therefore uses filesystem TRIM and additional controlled filesystem activity instead of pretending to provide guaranteed physical NAND erasure.

## Security profiles

### Normal

```text
1 run
```

A lightweight test with relatively low write amplification.

Suitable for basic testing.

### Secret

```text
5 runs
```

Uses multiple data patterns and controlled free-space filling.

Designed for a stronger recovery-resistance experiment while limiting unnecessary SSD write load.

### Paranoia

```text
10 runs
```

Uses more varied data patterns, additional write activity and more extensive free-space filling.

This profile produces substantially more SSD write traffic.

**More runs do not mean mathematically stronger physical erasure.**

## Temperature handling

The tool monitors SSD temperature whenever SMART/NVMe information is available.

| Temperature | Status   |
| ----------- | -------- |
| ≤ 60 °C     | NORMAL   |
| 61–70 °C    | WARM     |
| 71–80 °C    | HIGH     |
| > 80 °C     | CRITICAL |

At critical temperatures the write process pauses automatically and resumes after the SSD cools below the configured recovery threshold.

Exact thermal behavior is SSD-model dependent.

## Test file identification

Every generated test file contains an identifiable marker.

Example:

```text
WIPE-TEST
LEVEL: PARANOIA
RUN: 07
FILE: 0427
PATTERN: RANDOM
```

This makes later PhotoRec recovery testing much more useful because recovered files can be traced back to their original run.

## PhotoRec testing

The generated files are intended to allow controlled recovery experiments.

A typical test workflow is:

```text
1. Run this tool.
2. Wait for the selected profile to finish.
3. Boot/use a separate recovery environment if possible.
4. Run PhotoRec against the test filesystem/device.
5. Search recovered files for WIPE-TEST markers.
6. Compare recovered files against the generated manifest.
```

The project can maintain SHA-256 hashes for generated files so recovered files can be compared against their originals.

## Installation on Arch Linux

Install the required packages:

```bash
sudo pacman -S imagemagick smartmontools
```

For additional NVMe information:

```bash
sudo pacman -S nvme-cli
```

Clone the repository:

```bash
git clone https://github.com/YOUR-USERNAME/ssd-remnant-wipe.git
cd ssd-remnant-wipe
```

Make the script executable:

```bash
chmod +x ssd-remnant-wipe.sh
```

Run it as the normal user:

```bash
./ssd-remnant-wipe.sh
```

Do **not** start the entire script with `sudo`.

The script requests elevated privileges only for operations that require them.

## Analysis mode

The analysis mode performs system detection without running the test workload.

It checks:

```text
SSD model
Transport type
Filesystem
Mountpoint
TRIM availability
Free space
SMART health
NVMe health
Temperature
Estimated write load
```

The analysis then provides a recommended profile.

The recommendation is advisory; the user can still choose another profile.

## Safety model

The tool intentionally avoids destructive whole-device operations.

It does **not** perform:

```text
blkdiscard on the entire device
NVMe Sanitize
ATA Secure Erase
partition table changes
filesystem formatting
```

The generated test directory is validated before deletion.

If an unexpected existing test directory is detected, the tool stops instead of deleting it.

Interrupting the program attempts to clean up only its own test directory.

## Free-space filling

Secret and Paranoia profiles can temporarily consume part of the currently free filesystem space.

A configurable reserve is always maintained.

The tool does not intentionally fill the filesystem to 100%.

Free-space availability is rechecked during the fill operation.

## Reports

After a run, the tool can generate reports such as:

```text
~/wipe-report.txt
~/wipe-test.log
~/wipe-manifest.txt
```

The report may contain:

* SSD information
* filesystem information
* TRIM status
* selected profile
* run count
* data patterns
* execution time
* temperature
* maximum temperature
* SMART/NVMe health
* free space before/after
* estimated write volume
* controller-reported write statistics when available

## Limitations

This tool **cannot guarantee** that previously deleted information is physically impossible to recover.

In particular, it cannot directly control:

* NAND flash cells
* wear-leveling
* over-provisioned blocks
* SSD garbage collection
* controller firmware
* hidden/internal SSD mappings

For guaranteed device-level destruction, manufacturer-supported Secure Erase/Sanitize procedures are generally more appropriate.

Those operations are intentionally **not included** in this project because they can destroy currently existing data.

## Recommended usage

This project is best suited for:

* SSD recovery experiments
* PhotoRec testing
* filesystem/TRIM experiments
* studying SSD garbage collection behavior
* testing recovery resistance of deleted test data

It should not be treated as a cryptographic erasure standard.

## License

This project is licensed under the MIT License.

See `LICENSE` for details.

## Disclaimer

Use this software at your own risk.

The author does not guarantee that deleted data will become unrecoverable.

Always maintain backups of important data before running filesystem-intensive experiments.

Do not run this tool against a system or filesystem containing data you cannot afford to lose.
