#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# ============================================================
# SSD RECOVERY-RESISTANCE / FILL TEST (COMBINED)
# ============================================================
# Combines:
#   - ssd-recovery-resistance.sh   (levels, patterns, SMART/NVMe
#                                    logging, report/manifest, TRIM)
#   - fill-ssd.sh                  (fine-grained thermal traffic
#                                    light with background monitor
#                                    thread, live dashboard)
#
# Behaviour change vs. the original recovery-resistance script:
#   Instead of writing a FIXED number of files per phase
#   (1000 HTML + 1000 TXT + 1000 JPG + 1000 BIN + fixed fill),
#   this script cycles through file types (HTML/TXT/JPG/BIN)
#   continuously until the detected filesystem is almost full
#   (free space <= RESERVE_BYTES, default 100 MiB), then deletes
#   everything it created and runs TRIM. That is repeated for
#   TOTAL_RUNS according to the chosen level.
#
# This is NOT ATA Secure Erase / NVMe Sanitize / blkdiscard and
# is not a guarantee of physical NAND erasure.
#
# Tool by Aris.Infosec
#
# ------------------------- Version / changelog -----------------
# v1.0  Initial combined script (levels, patterns, SMART/NVMe logging,
#       report/manifest, TRIM, thermal-aware background monitor).
# v1.1  Root/sudo pre-check, TRIM-vs-written sanity warning, compact
#       per-run report, project folder created at launch location.
# v1.2  ETA display, thermal-abort exit code (2), per-run CSV export.
# v1.3  Lockfile against double-runs, kill orphaned JPG jobs on abort,
#       post-TRIM free-space verification, config sanity checks,
#       NAND wear warning + wear% display, SATA wear fallback.
# v1.4  ASCII banner, live two-line dashboard (overall + per-run
#       progress bars, write rate, temp/thermal state), sound alerts
#       on CRITICAL/EMERGENCY thermal events.
# v1.5  Fixed adapt_settings() silently aborting the script under
#       `set -e` on common low-free-space + low-thread-count systems.
#       Fixed unsafe `local x=... y=...($x)` patterns (shellcheck).
#       Guarded destructive `rm -rf .../*` against an empty TEST_DIR.
# v1.6  Secret/Paranoia run counts made independently configurable
#       (SECRET_RUNS, PARANOIA_RUNS) with an automatic consistency
#       check so Paranoia can never be weaker than Secret.
# v1.7  Levels now differ qualitatively, not just by run count:
#       Paranoia always uses aggressive/fragmented allocation, a
#       tighter reserve, an extra verification TRIM pass per run,
#       and shreds its own manifest at the end. Per-level rationale
#       shown before starting. Prominent "GiB written / free space
#       left" summary at the end.
# v1.8  CLI flags (--level, --yes, --dry-run, --aggressive/--no-
#       aggressive), free-space warning re-checked against the
#       level's actual effective reserve, level name shown in the
#       live dashboard, endurance delta (wear%/spare) at the end.
# ============================================================

# ------------------------- CLI flags ---------------------------
CLI_LEVEL=""
CLI_YES=0
DRY_RUN=0
CLI_AGGRESSIVE=""   # "" = not set, 1 = force on, 0 = force off
print_usage() {
    cat <<EOF
Usage: $(basename -- "${BASH_SOURCE[0]}") [options]

  --level=normal|secret|paranoia   Skip the menu, pick this level directly.
  --yes, -y                        Skip confirmation prompts (implies
                                    accepting the free-space/wear warnings).
  --aggressive                     Force aggressive allocation mode on.
  --no-aggressive                  Force aggressive allocation mode off.
  --dry-run                        Run analysis + show the execution plan,
                                    write NO files, exit before the actual test.
  -h, --help                       Show this help and exit.

Environment overrides: RESERVE_MB, SECRET_RUNS, PARANOIA_RUNS,
PARANOIA_RESERVE_FLOOR_MB, SOUND_ENABLED (0/1).
EOF
}
for arg in "$@"; do
    case "$arg" in
        --level=*) CLI_LEVEL="${arg#--level=}"; CLI_LEVEL="${CLI_LEVEL^^}" ;;
        --yes|-y) CLI_YES=1 ;;
        --aggressive) CLI_AGGRESSIVE=1 ;;
        --no-aggressive) CLI_AGGRESSIVE=0 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "Unknown option: $arg"; print_usage; exit 1 ;;
    esac
done
if [[ -n "$CLI_LEVEL" && "$CLI_LEVEL" != "NORMAL" && "$CLI_LEVEL" != "SECRET" && "$CLI_LEVEL" != "PARANOIA" ]]; then
    echo "Invalid --level: '$CLI_LEVEL' (must be normal, secret, or paranoia)."
    exit 1
fi

# ------------------------- Configuration --------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Everything happens inside a folder named after this script, created in the
# directory it was launched from (not necessarily SCRIPT_DIR, e.g. if called
# via a symlink or from $PATH).
LAUNCH_DIR="$(pwd -P)"
PROJECT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
PROJECT_NAME="${PROJECT_NAME%.*}"
PROJECT_DIR="$LAUNCH_DIR/$PROJECT_NAME"
RUN_ROOT="$PROJECT_DIR/runs"
# The filesystem under test: the project dir itself (so df/findmnt/fstrim
# all operate on whatever disk you actually launched the script from).
TARGET_DIR="$PROJECT_DIR"
OUTPUT_STAMP=""
RUN_DIR=""
TEST_DIR=""

# ------------------------- Root/sudo pre-check ---------------
# Fail fast instead of dying mid-run after hours of filling the disk.
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    if ! sudo -v 2>/dev/null; then
        echo "This script needs root privileges (fstrim, smartctl, nvme, dmsetup, btrfs)."
        echo "Run it as root, or make sure 'sudo' works non-interactively / you can authenticate."
        exit 1
    fi
    SUDO="sudo"
else
    echo "Neither running as root nor is 'sudo' installed."
    echo "This script needs root privileges (fstrim, smartctl, nvme, dmsetup, btrfs)."
    exit 1
fi
mkdir -p -- "$PROJECT_DIR"

# ------------------------- Lockfile ---------------------------
# Prevent two instances from running against the same project dir at once
# (would corrupt each other's TEST_DIR and metrics).
if ! command -v flock >/dev/null 2>&1; then
    echo "Missing program: flock (usually part of util-linux). Install it to continue."
    exit 1
fi
LOCK_FILE="$PROJECT_DIR/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another instance of this script already appears to be running against:"
    echo "  $PROJECT_DIR"
    echo "(lock held on $LOCK_FILE). Wait for it to finish or remove the lock"
    echo "manually if you're sure no other instance is active."
    exit 1
fi

# Reserve kept free at all times (stop filling once free <= this).
RESERVE_MB=${RESERVE_MB:-100}
PARANOIA_RESERVE_FLOOR_MB=${PARANOIA_RESERVE_FLOOR_MB:-50}
# Number of full fill/delete/TRIM runs per level. Paranoia must stay the
# most thorough level, i.e. PARANOIA_RUNS > SECRET_RUNS > NORMAL_RUNS(=1) --
# this is enforced by config_sanity_checks below.
# Override on the command line, e.g.: SECRET_RUNS=5 PARANOIA_RUNS=8 ./SSD-Recovery-Resistance.sh
SECRET_RUNS=${SECRET_RUNS:-2}
PARANOIA_RUNS=${PARANOIA_RUNS:-3}
RESERVE_BYTES=$((RESERVE_MB * 1024 * 1024))

# File sizes used while cycling.
HTML_BASE_SIZE=$((2 * 1024 * 1024))
TXT_BASE_SIZE=$((2 * 1024 * 1024))
BIN_BASE_MIB=10
JPG_JOBS_DEFAULT=4
JPG_JOBS_MAX=6

# --- Temperature ampel (fein, aus fill-ssd.sh) ---
TEMP_WARNING=${TEMP_WARNING:-65}
TEMP_PAUSE=${TEMP_PAUSE:-70}
TEMP_RESUME=${TEMP_RESUME:-62}
TEMP_CRITICAL=${TEMP_CRITICAL:-80}
TEMP_EMERGENCY=${TEMP_EMERGENCY:-85}
TEMP_INTERVAL=1     # seconds between background temperature polls
COOL_TIME=5         # seconds <= TEMP_RESUME required before resuming

DEFAULT_COOLDOWN=30
HOT_COOLDOWN=60
POST_TRIM_IDLE=10

RESET=$'\033[0m'; BOLD=$'\033[1m'
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'

print_banner() {
    printf '%s' "$GREEN"
    cat <<'EOF'

    ░██████╗░██████╗██████╗░  ██████╗░███████╗░██████╗██╗░██████╗████████╗
    ██╔════╝██╔════╝██╔══██╗  ██╔══██╗██╔════╝██╔════╝██║██╔════╝╚══██╔══╝
    ╚█████╗░╚█████╗░██║░░██║  ██████╔╝█████╗░░╚█████╗░██║╚█████╗░░░░██║░░░
    ░╚═══██╗░╚═══██╗██║░░██║  ██╔══██╗██╔══╝░░░╚═══██╗██║░╚═══██╗░░░██║░░░
    ██████╔╝██████╔╝██████╔╝  ██║░░██║███████╗██████╔╝██║██████╔╝░░░██║░░░
    ╚═════╝░╚═════╝░╚═════╝░  ╚═╝░░╚═╝╚══════╝╚═════╝░╚═╝╚═════╝░░░░╚═╝░░░
EOF
    printf '%s' "$CYAN"
    cat <<'EOF'
       [ RECOVERY-RESISTANCE TESTER ]  ::  fill // delete // trim // verify
EOF
    printf '%s' "$RESET$BOLD"
    echo "                        by Aris.Infosec"
    printf '%s\n' "$RESET"
}
print_banner

TOTAL_RUNS=0
LEVEL_NAME=""
ANALYSIS_RECOMMENDATION=""
ANALYSIS_REASON=""

SCRIPT_START=$(date +%s)
NOMINAL_WRITTEN_BYTES=0
MAX_TEMP=0
TRIM_COUNT=0
TRIM_BYTES_APPROX=0
ANY_ABORTED=0
CSV_FILE=""
SUM_RUN_TIME=0

SMARTCTL_AVAILABLE=0
NVME_AVAILABLE=0
SMART_DEVICE=""
NVME_DEVICE=""

HOME_TARGET=""; HOME_SOURCE=""; HOME_FS=""; TRANSPORT=""; ROOT_DEVICE=""

START_FREE_BYTES=0; END_FREE_BYTES=0
START_TEMP=""; END_TEMP=""
START_HEALTH=""; END_HEALTH=""
START_PERCENT_USED=""; END_PERCENT_USED=""
START_AVAILABLE_SPARE=""; END_AVAILABLE_SPARE=""
START_CRITICAL_WARNING=""; END_CRITICAL_WARNING=""
START_MEDIA_ERRORS=""; END_MEDIA_ERRORS=""
START_UNSAFE_SHUTDOWNS=""; END_UNSAFE_SHUTDOWNS=""
START_POWER_CYCLES=""; END_POWER_CYCLES=""
START_DATA_WRITTEN_BYTES=""; END_DATA_WRITTEN_BYTES=""

CPU_THREADS=$(nproc)
JPG_JOBS=$JPG_JOBS_DEFAULT
RUN_COOLDOWN=$DEFAULT_COOLDOWN
AGGRESSIVE_ALLOC=0
FILESYSTEM_PROFILE="GENERIC"
ALLOC_PATTERN="GENERIC"
BINARY_MODE="CONTIGUOUS"
PER_RUN_START_DATA_WRITTEN_BYTES=""
PER_RUN_END_DATA_WRITTEN_BYTES=""
PER_RUN_HOST_WRITE_DELTA=""

# Background thermal monitor state
STATE_DIR=""
TEMP_STATE=""
THERMAL_STATE=""
STOP_STATE=""
THERMAL_PID=""
PEAK_TEMP=0

# ------------------------- General helpers ------------------
format_time() {
    local seconds="$1"
    printf "%02d:%02d:%02d" $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}
format_gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b/1024/1024/1024 }'; }
format_pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b>0) printf "%.1f", 100*a/b; else print "0.0" }'; }
human() {
    awk -v bytes="$1" '
    function human(x){
        if (x>=1099511627776) return sprintf("%.2f TiB", x/1099511627776)
        if (x>=1073741824)    return sprintf("%.2f GiB", x/1073741824)
        if (x>=1048576)       return sprintf("%.2f MiB", x/1048576)
        if (x>=1024)          return sprintf("%.2f KiB", x/1024)
        return sprintf("%d B", x)
    }
    BEGIN{ print human(bytes) }'
}
add_written() { NOMINAL_WRITTEN_BYTES=$((NOMINAL_WRITTEN_BYTES + $1)); }
get_free_bytes()  { df -B1 --output=avail "$TARGET_DIR" | tail -n 1 | tr -d ' '; }
get_total_bytes() { df -B1 --output=size  "$TARGET_DIR" | tail -n 1 | tr -d ' '; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlendes Programm: $1"; exit 1; }; }

safe_test_dir() {
    [[ -n "$RUN_DIR" && -n "$TEST_DIR" ]] || return 1
    [[ "$RUN_DIR" == "$RUN_ROOT/"* ]] || return 1
    [[ "$TEST_DIR" == "$RUN_DIR/test-data" ]] || return 1
    [[ "$TEST_DIR" != "/" && "$TEST_DIR" != "$TARGET_DIR" ]] || return 1
    return 0
}

stop_thermal_monitor() {
    if [[ -n "$THERMAL_PID" ]]; then
        kill "$THERMAL_PID" 2>/dev/null || true
        wait "$THERMAL_PID" 2>/dev/null || true
        THERMAL_PID=""
    fi
    [[ -n "$STATE_DIR" && -d "$STATE_DIR" ]] && rm -rf "$STATE_DIR"
    return 0
}

cleanup() {
    kill_background_jobs
    if safe_test_dir && [[ -d "$TEST_DIR" ]]; then
        echo
        echo "Cleanup: removing only the script-owned test directory..."
        rm -rf -- "$TEST_DIR"
        echo "Cleanup complete."
    fi
    stop_thermal_monitor
}

kill_background_jobs() {
    # Kill any still-running JPG-generation background jobs spawned by this
    # shell so nothing keeps writing to TEST_DIR after we start cleaning up.
    local pids
    pids=$(jobs -pr 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
        wait $pids 2>/dev/null || true
    fi
}

handle_interrupt() {
    trap - INT TERM
    echo
    echo "============================================================"
    echo "ABORT REQUESTED"
    echo "============================================================"
    cleanup
    [[ -n "${LOG_FILE:-}" ]] && echo "Aborted: $(date)" >> "$LOG_FILE"
    exit 130
}
trap handle_interrupt INT TERM
trap cleanup EXIT

# ------------------------- Logging ----------------------------
prepare_output_names() {
    [[ -z "$OUTPUT_STAMP" ]] && OUTPUT_STAMP=$(date +%Y%m%d-%H%M%S)
    RUN_DIR="$RUN_ROOT/$OUTPUT_STAMP"
    TEST_DIR="$RUN_DIR/test-data"
    REPORT_FILE="$RUN_DIR/report.txt"
    MANIFEST_FILE="$RUN_DIR/manifest.txt"
    LOG_FILE="$RUN_DIR/run.log"
    CSV_FILE="$RUN_DIR/runs.csv"

    if [[ -e "$RUN_DIR" ]]; then
        local suffix=1 candidate_stamp candidate
        while :; do
            candidate_stamp="${OUTPUT_STAMP}-${suffix}"
            candidate="$RUN_ROOT/$candidate_stamp"
            if [[ ! -e "$candidate" ]]; then
                OUTPUT_STAMP="$candidate_stamp"; RUN_DIR="$candidate"
                TEST_DIR="$RUN_DIR/test-data"; REPORT_FILE="$RUN_DIR/report.txt"
                MANIFEST_FILE="$RUN_DIR/manifest.txt"; LOG_FILE="$RUN_DIR/run.log"
                CSV_FILE="$RUN_DIR/runs.csv"
                break
            fi
            suffix=$((suffix + 1))
        done
    fi
}
init_csv() {
    echo "run,total_runs,level,pattern,filesystem,allocation,aggressive_alloc,files,duration_s,free_bytes_end,peak_temp_c,aborted_thermal,nominal_written_bytes,host_write_delta_bytes" > "$CSV_FILE"
}
setup_logging() { mkdir -p "$RUN_DIR"; touch "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1; init_csv; }

# ------------------------- Device detection ------------------
detect_system() {
    local mount_info parent_device
    mount_info=$(findmnt -T "$TARGET_DIR" -no TARGET,SOURCE,FSTYPE 2>/dev/null || true)
    [[ -n "$mount_info" ]] || { echo "Could not determine the filesystem for $TARGET_DIR."; exit 1; }

    HOME_TARGET=$(awk '{print $1}' <<< "$mount_info")
    HOME_SOURCE=$(awk '{print $2}' <<< "$mount_info")
    HOME_FS=$(awk '{print $3}' <<< "$mount_info")

    parent_device=$(lsblk -no PKNAME "$HOME_SOURCE" 2>/dev/null | head -n 1 || true)
    if [[ -n "$parent_device" ]]; then ROOT_DEVICE="/dev/$parent_device"; else ROOT_DEVICE="$HOME_SOURCE"; fi

    TRANSPORT=$(lsblk -no TRAN "$HOME_SOURCE" 2>/dev/null | head -n 1 || true)

    if [[ "$TRANSPORT" == "nvme" ]]; then
        if [[ "$parent_device" =~ ^nvme[0-9]+n[0-9]+$ ]]; then NVME_DEVICE="/dev/$parent_device"
        elif [[ "$ROOT_DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then NVME_DEVICE="$ROOT_DEVICE"; fi
    fi

    if [[ -n "$NVME_DEVICE" ]]; then SMART_DEVICE="$NVME_DEVICE"; else SMART_DEVICE="$ROOT_DEVICE"; fi

    case "$HOME_FS" in
        ext4) FILESYSTEM_PROFILE="EXT4" ;;
        btrfs) FILESYSTEM_PROFILE="BTRFS" ;;
        xfs) FILESYSTEM_PROFILE="XFS" ;;
        f2fs) FILESYSTEM_PROFILE="F2FS" ;;
        *) FILESYSTEM_PROFILE="GENERIC" ;;
    esac
}

# ------------------------- Discard passthrough check -----------
# fstrim can report success while the actual TRIM never reaches the
# physical SSD, if it's swallowed by an encryption or LVM layer in
# between. This walks the device-mapper stack under $HOME_SOURCE and
# checks LUKS/dm-crypt "discards" and LVM "issue_discards".
DISCARD_WARNINGS=()

check_discard_passthrough() {
    local src="$HOME_SOURCE" dm_uuid crypt_check lvm_conf

    # Not a device-mapper device -> nothing to check here.
    if [[ ! "$src" =~ ^/dev/(dm-|mapper/) ]]; then
        return 0
    fi

    # ---- LUKS / dm-crypt ----
    if command -v dmsetup >/dev/null 2>&1; then
        dm_uuid=$($SUDO dmsetup info -c --noheadings -o uuid "$src" 2>/dev/null || true)
        if [[ "$dm_uuid" == CRYPT-* ]]; then
            crypt_check=$($SUDO dmsetup table "$src" 2>/dev/null || true)
            if [[ "$crypt_check" == *allow_discards* ]]; then
                echo "    LUKS/dm-crypt: discard passthrough ENABLED (allow_discards)."
            else
                DISCARD_WARNINGS+=("LUKS/dm-crypt device '$src' does NOT have allow_discards set. TRIM will silently NOT reach the physical SSD. Fix: add 'discard' to /etc/crypttab (and cryptsetup --allow-discards / cryptsetup refresh --allow-discards), then reboot or re-open the container.")
            fi
        fi
    fi

    # ---- LVM ----
    if command -v lvs >/dev/null 2>&1 && lvs "$src" >/dev/null 2>&1; then
        lvm_conf=$(grep -REi '^\s*issue_discards\s*=\s*1' /etc/lvm/lvm.conf 2>/dev/null || true)
        if [[ -n "$lvm_conf" ]]; then
            echo "    LVM: issue_discards = 1 (passthrough enabled)."
        else
            DISCARD_WARNINGS+=("LVM is in the stack for '$src' but issue_discards is not enabled in /etc/lvm/lvm.conf. TRIM may not reach the physical SSD through the LVM layer. Fix: set issue_discards = 1 in /etc/lvm/lvm.conf.")
        fi
    fi
}

# ------------------------- btrfs snapshot check -----------------
# On btrfs, old file versions kept alive by snapshots (Snapper,
# Timeshift, manual `btrfs subvolume snapshot`) are NOT freed by
# deleting/overwriting files in the current subvolume, and TRIM will
# only ever discard truly unreferenced extents. This just warns; it
# never touches snapshots itself.
BTRFS_SNAPSHOT_WARNING=""

check_btrfs_snapshots() {
    [[ "$HOME_FS" == "btrfs" ]] || return 0
    local snap_count=""

    if command -v btrfs >/dev/null 2>&1; then
        snap_count=$($SUDO btrfs subvolume list -s "$TARGET_DIR" 2>/dev/null | grep -c . || true)
    fi

    if [[ -n "$snap_count" && "$snap_count" -gt 0 ]]; then
        BTRFS_SNAPSHOT_WARNING="Found $snap_count btrfs snapshot(s) touching this filesystem. Old versions of overwritten/deleted files may still be referenced by those snapshots and will NOT be freed by this test's overwrite+TRIM cycle. For a real wipe, delete relevant snapshots first (snapper/timeshift/'btrfs subvolume delete') and confirm they're gone before trusting the result."
    fi
}

# ------------------------- Swap check ---------------------------
# Sensitive data (passwords in memory, hibernation image contents,
# decrypted file fragments) can end up on swap. This script never
# touches swap; if it's active and not encrypted, that's a gap the
# person running the test should know about.
SWAP_WARNING=""

check_swap() {
    local swap_lines swap_devices encrypted_ok=1 dev src
    command -v swapon >/dev/null 2>&1 || return 0

    swap_lines=$(swapon --show=NAME --noheadings 2>/dev/null || true)
    [[ -n "$swap_lines" ]] || return 0

    swap_devices="$swap_lines"

    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        src="$dev"
        # Resolve to a real block device path where possible.
        if [[ -e "$src" ]]; then
            if [[ ! "$src" =~ ^/dev/(dm-|mapper/) ]]; then
                encrypted_ok=0
            else
                # It's a dm device - only "safe" if it's a crypt mapping.
                if command -v dmsetup >/dev/null 2>&1; then
                    local uuid
                    uuid=$($SUDO dmsetup info -c --noheadings -o uuid "$src" 2>/dev/null || true)
                    [[ "$uuid" == CRYPT-* ]] || encrypted_ok=0
                else
                    encrypted_ok=0
                fi
            fi
        fi
    done <<< "$swap_devices"

    if (( encrypted_ok == 1 )); then
        echo "    Swap is active but appears to be on an encrypted (dm-crypt) device."
    else
        SWAP_WARNING="Active swap detected ($(tr '\n' ' ' <<< "$swap_devices")) that does not appear to be fully encrypted. Sensitive data (memory contents, hibernation image) can be written there and this script does not touch swap at all. Consider: '$SUDO swapoff -a' before sensitive work, using encrypted swap (dm-crypt), or disabling hibernation."
    fi
}

# ------------------------- Minimum free space check --------------
# If free space is already close to RESERVE_BYTES, the cycle-fill
# loop would do almost nothing useful (a handful of files, then
# immediately hit the reserve). Warn/abort rather than silently
# running a near-empty, pointless test.
MIN_USEFUL_FREE_BYTES=$((1024 * 1024 * 1024))  # 1 GiB

check_min_free_space() {
    local free; free=$(get_free_bytes)
    if (( free <= RESERVE_BYTES )); then
        echo
        echo "ERROR: Free space ($(format_gib "$free") GiB) is already at or below"
        echo "the reserve (${RESERVE_MB} MiB). There is nothing meaningful to fill."
        exit 1
    fi
    if (( free - RESERVE_BYTES < MIN_USEFUL_FREE_BYTES )); then
        echo
        echo "WARNING: Only $(format_gib "$((free - RESERVE_BYTES))") GiB of usable fill"
        echo "space is available above the ${RESERVE_MB} MiB reserve. The overwrite"
        echo "test will barely touch the drive and is unlikely to be meaningful."
        if (( CLI_YES == 1 )); then
            echo "(--yes given: continuing anyway.)"
            return 0
        fi
        read -rp "Continue anyway? [y/N]: " MIN_FREE_CONFIRM
        [[ "$MIN_FREE_CONFIRM" =~ ^[YyJj]$ ]] || exit 0
    fi
}

# ------------------------- SMART / NVMe ----------------------
nvme_dump()  { (( NVME_AVAILABLE == 1 )) && [[ -n "$NVME_DEVICE" ]] && $SUDO nvme smart-log -H "$NVME_DEVICE" 2>/dev/null || true; }
smart_dump() { (( SMARTCTL_AVAILABLE == 1 )) && [[ -n "$SMART_DEVICE" ]] && $SUDO smartctl -a "$SMART_DEVICE" 2>/dev/null || true; }

get_nvme_field() {
    local field="$1" dump
    [[ -n "$NVME_DEVICE" ]] || return 0
    dump=$(nvme_dump)
    grep -Ei "^${field}[[:space:]]*:" <<< "$dump" | sed -nE 's/^[^:]+:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n 1 || true
}

get_temperature() {
    local dump temp
    if [[ -n "$NVME_DEVICE" ]]; then
        dump=$(nvme_dump)
        temp=$(grep -Ei '^temperature[[:space:]]*:' <<< "$dump" | grep -oE '[0-9]+' | head -n 1 || true)
        [[ -n "$temp" ]] && { printf '%s\n' "$temp"; return 0; }
    fi
    dump=$(smart_dump)
    temp=$(grep -Ei 'Temperature:|Composite Temperature|Temperature Sensor 1' <<< "$dump" | grep -oE '[0-9]+' | head -n 1 || true)
    if [[ -n "$temp" ]]; then printf '%s\n' "$temp"; else printf 'N/A\n'; fi
}

get_health() {
    local dump critical
    if [[ -n "$NVME_DEVICE" ]]; then
        dump=$(nvme_dump)
        critical=$(grep -Ei '^critical_warning[[:space:]]*:' <<< "$dump" | sed -nE 's/.*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || true)
        if [[ "$critical" == "0" ]]; then echo "OK"; return 0
        elif [[ -n "$critical" ]]; then echo "WARNING"; return 0; fi
    fi
    dump=$(smart_dump)
    if grep -Eiq 'PASSED' <<< "$dump"; then echo "PASSED"
    elif grep -Eiq 'FAILED' <<< "$dump"; then echo "FAILED"
    else echo "UNKNOWN"; fi
}

get_percentage_used()  {
    local val
    val=$(get_nvme_field "percentage_used" | sed 's/%$//' | awk 'NF {print $1 "%"}')
    if [[ -n "$val" ]]; then echo "$val"; return 0; fi
    # SATA SSD fallback via SMART attributes (ID 177 Wear_Leveling_Count,
    # 233 Media_Wearout_Indicator, 231 SSD_Life_Left -- vendor-dependent,
    # "raw value" or "normalized value" semantics differ, so this is a
    # best-effort estimate, not an authoritative figure.
    (( SMARTCTL_AVAILABLE == 1 )) || return 0
    local dump line raw
    dump=$(smart_dump)
    line=$(grep -E '^177 |Wear_Leveling_Count' <<< "$dump" | head -n 1)
    if [[ -n "$line" ]]; then
        raw=$(awk '{print $NF}' <<< "$line")
        [[ "$raw" =~ ^[0-9]+$ ]] && { echo "${raw}% (est., Wear_Leveling_Count raw)"; return 0; }
    fi
    line=$(grep -E '^233 |Media_Wearout_Indicator|^231 |SSD_Life_Left' <<< "$dump" | head -n 1)
    if [[ -n "$line" ]]; then
        raw=$(awk '{print $4}' <<< "$line")
        [[ "$raw" =~ ^[0-9]+$ ]] && { echo "$((100 - raw))% (est., from life-left indicator)"; return 0; }
    fi
    return 0
}
get_available_spare()  { get_nvme_field "available_spare" | awk 'NF {print $1 "%"}'; }
get_critical_warning() { get_nvme_field "critical_warning"; }
get_data_written_units() {
    local dump
    [[ -n "$NVME_DEVICE" ]] || return 0
    dump=$(nvme_dump)
    grep -Ei '^Data Units Written' <<< "$dump" | sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' | tr -d ',' | head -n 1 || true
}
get_data_written_bytes() {
    local units; units=$(get_data_written_units || true)
    if [[ "$units" =~ ^[0-9]+$ ]]; then echo $((units * 512000)); else echo ""; fi
}
get_media_errors()     { get_nvme_field "media_errors"; }
get_unsafe_shutdowns() { get_nvme_field "unsafe_shutdowns"; }
get_power_cycles()     { get_nvme_field "power_cycles"; }

# ------------------------- Background thermal monitor ---------
# Ported from fill-ssd.sh: a background thread continuously polls
# temperature (via SMART/NVMe, same as ssd-recovery-resistance.sh)
# and classifies it into NORMAL / WARNING / PAUSE / CRITICAL / EMERGENCY.
# The main loop only reads $THERMAL_STATE / $TEMP_STATE - no blocking
# calls to smartctl/nvme happen in the hot write path.
start_thermal_monitor() {
    STATE_DIR=$(mktemp -d)
    TEMP_STATE="$STATE_DIR/temp"
    THERMAL_STATE="$STATE_DIR/thermal"
    STOP_STATE="$STATE_DIR/stop"
    echo "N/A" > "$TEMP_STATE"
    echo "NORMAL" > "$THERMAL_STATE"
    echo "0" > "$STOP_STATE"

    (
        while true; do
            temp=$(get_temperature)
            echo "$temp" > "$TEMP_STATE"

            if [[ "$temp" =~ ^[0-9]+$ ]]; then
                (( temp > MAX_TEMP )) 2>/dev/null || true
                if   (( temp >= TEMP_EMERGENCY )); then echo "EMERGENCY" > "$THERMAL_STATE"
                elif (( temp >= TEMP_CRITICAL ));  then echo "CRITICAL"  > "$THERMAL_STATE"
                elif (( temp >= TEMP_PAUSE ));     then echo "PAUSE"     > "$THERMAL_STATE"
                elif (( temp >= TEMP_WARNING ));   then echo "WARNING"   > "$THERMAL_STATE"
                else                                     echo "NORMAL"    > "$THERMAL_STATE"
                fi
            fi
            sleep "$TEMP_INTERVAL"
        done
    ) &
    THERMAL_PID=$!
}

# ------------------------- Sound ------------------------------
SOUND_ENABLED=${SOUND_ENABLED:-1}
beep() {
    local times="${1:-1}" i
    (( SOUND_ENABLED == 1 )) || return 0
    for ((i = 0; i < times; i++)); do
        printf '\a'
        (( i < times - 1 )) && sleep 0.2
    done
}

# Waits here if the SSD is in PAUSE state; returns 1 if CRITICAL/EMERGENCY
# was hit (caller must abort the current fill run).
thermal_gate() {
    local temp thermal cool_counter=0
    while true; do
        temp=$(<"$TEMP_STATE")
        thermal=$(<"$THERMAL_STATE")

        [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > PEAK_TEMP )) && PEAK_TEMP=$temp
        [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > MAX_TEMP ))  && MAX_TEMP=$temp

        case "$thermal" in
            EMERGENCY)
                echo
                echo "    !!! ${thermal}: SSD ${temp}°C - stopping write, cooling down !!!"
                beep 5
                return 1
                ;;
            CRITICAL)
                echo
                echo "    !!! ${thermal}: SSD ${temp}°C - stopping write, cooling down !!!"
                beep 3
                return 1
                ;;
            PAUSE)
                printf '\r    Thermal PAUSE at %s°C - waiting for <= %s°C ... ' "$temp" "$TEMP_RESUME"
                sleep 1
                if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp <= TEMP_RESUME )); then
                    cool_counter=$((cool_counter + 1))
                else
                    cool_counter=0
                fi
                if (( cool_counter >= COOL_TIME )); then echo; echo "    -> Cooled down, resuming."; return 0; fi
                ;;
            *)
                return 0
                ;;
        esac
    done
}

render_progress_bar() {
    local pct="$1" width=24 filled empty
    (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    printf '['
    printf '%0.s#' $(seq 1 "$filled") 2>/dev/null
    printf '%0.s.' $(seq 1 "$empty") 2>/dev/null
    printf '] %3d%%' "$pct"
}

DASHBOARD_LINES=2
DASHBOARD_INITIALIZED=0
reset_dashboard() { DASHBOARD_INITIALIZED=0; }

render_dashboard() {
    local elapsed rate_bps rate_human temp thermal color pct free_now used_since_start
    local overall_pct run_pct_x100
    elapsed=$(( $(date +%s) - FILL_START ))
    (( elapsed < 1 )) && elapsed=1
    free_now=$(get_free_bytes)
    used_since_start=$(( FILL_START_FREE - free_now ))
    (( used_since_start < 0 )) && used_since_start=0
    rate_bps=$(( used_since_start / elapsed ))
    rate_human="$(human "$rate_bps")/s"
    pct=$(format_pct "$used_since_start" "$FILL_TARGET_BYTES")
    pct="${pct%.*}"
    # Overall progress across all runs = completed runs + fraction of current run.
    run_pct_x100=$(( (run - 1) * 100 + pct ))
    overall_pct=$(( run_pct_x100 / TOTAL_RUNS ))
    temp=$(<"$TEMP_STATE"); thermal=$(<"$THERMAL_STATE")
    case "$thermal" in
        EMERGENCY|CRITICAL) color="$RED" ;;
        PAUSE|WARNING) color="$YELLOW" ;;
        *) color="$GREEN" ;;
    esac

    if (( DASHBOARD_INITIALIZED == 0 )); then
        printf '\n\n'
        DASHBOARD_INITIALIZED=1
    fi
    if command -v tput >/dev/null 2>&1; then
        tput cuu "$DASHBOARD_LINES" 2>/dev/null || true
    else
        printf '\033[%dA' "$DASHBOARD_LINES"
    fi
    printf '\r\033[K    [%s] Overall: %s   Run %d/%d: %s\n' \
        "$LEVEL_NAME" "$(render_progress_bar "$overall_pct")" "$run" "$TOTAL_RUNS" "$(render_progress_bar "$pct")"
    printf '\r\033[K    files:%-6d  free:%6sGiB  rate:%10s  temp:%s%3s°C[%s]%s  trim:%d  elapsed:%s\n' \
        "$INDEX" "$(format_gib "$free_now")" "$rate_human" \
        "$color" "$temp" "$thermal" "$RESET" "$TRIM_COUNT" "$(format_time "$elapsed")"
}

status_line() {
    local temp thermal color
    temp=$(<"$TEMP_STATE"); thermal=$(<"$THERMAL_STATE")
    case "$thermal" in
        EMERGENCY|CRITICAL) color="$RED" ;;
        PAUSE|WARNING) color="$YELLOW" ;;
        *) color="$GREEN" ;;
    esac
    printf "    SSD: ${color}%s°C [%s]${RESET}" "$temp" "$thermal"
}

# ------------------------- TRIM -------------------------------
trim_dry_run() { $SUDO fstrim --dry-run -v "$TARGET_DIR"; }

record_trim() {
    local out number unit factor free_before free_after
    free_before=$(get_free_bytes)
    if ! out=$($SUDO fstrim -v "$TARGET_DIR" 2>&1); then
        echo "$out"; echo "TRIM failed. Aborting."; exit 1
    fi
    echo "$out"
    TRIM_COUNT=$((TRIM_COUNT + 1))
    if (( POST_TRIM_IDLE > 0 )); then
        echo "    -> Post-TRIM idle: ${POST_TRIM_IDLE}s"
        sleep "$POST_TRIM_IDLE"
    fi
    if [[ "$out" =~ :[[:space:]]([0-9.]+)[[:space:]](bytes|KiB|MiB|GiB) ]]; then
        number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        case "$unit" in
            bytes) factor=1 ;; KiB) factor=1024 ;;
            MiB) factor=$((1024*1024)) ;; GiB) factor=$((1024*1024*1024)) ;;
            *) factor=0 ;;
        esac
        if (( factor > 0 )); then
            number="${number%.*}"
            TRIM_BYTES_APPROX=$((TRIM_BYTES_APPROX + number * factor))
        fi
    fi
    # Post-TRIM verification: free space as seen by the filesystem should not
    # have dropped after a TRIM (TRIM only ever discards already-free extents;
    # a drop here would indicate something wrote to TARGET_DIR concurrently,
    # e.g. a second instance of this script or an unrelated process).
    free_after=$(get_free_bytes)
    if [[ "$free_before" =~ ^[0-9]+$ && "$free_after" =~ ^[0-9]+$ ]] && (( free_after < free_before )); then
        echo "    WARNING: Free space dropped by $(format_gib "$((free_before - free_after))") GiB during TRIM."
        echo "    Something else may be writing to $TARGET_DIR concurrently."
    fi
}

# ------------------------- Manifest / Report -----------------
manifest_file() {
    local path="$1" type="$2" run="$3" file="$4" pattern="$5" size hash relative_path
    size=$(stat -c%s "$path")
    hash=$(sha256sum "$path" | awk '{print $1}')
    if [[ "$path" == "$RUN_DIR/"* ]]; then relative_path="./${path#"$RUN_DIR/"}"; else relative_path="$path"; fi
    printf 'TYPE=%s\tLEVEL=%s\tRUN=%02d\tFILE=%s\tPATTERN=%s\tSIZE=%s\tSHA256=%s\tPATH=%s\n' \
        "$type" "$LEVEL_NAME" "$run" "$file" "$pattern" "$size" "$hash" "$relative_path" >> "$MANIFEST_FILE"
}

write_report_header() {
    {
        echo "============================================================"
        echo "SSD RECOVERY RESISTANCE / FILL REPORT"
        echo "Tool by Aris.Infosec"
        echo "============================================================"
        echo "Date:          $(date)"
        echo "Target dir:    $TARGET_DIR"
        echo "Mountpoint:    $HOME_TARGET"
        echo "Source:        $HOME_SOURCE"
        echo "Filesystem:    $HOME_FS"
        echo "Transport:     ${TRANSPORT:-unknown}"
        echo "Root device:   $ROOT_DEVICE"
        echo "NVMe device:   ${NVME_DEVICE:-n/a}"
        echo "Level:         $LEVEL_NAME"
        echo "Runs:          $TOTAL_RUNS"
        echo "Recommendation: $ANALYSIS_RECOMMENDATION"
        echo "Reason:        $ANALYSIS_REASON"
        echo "JPG workers:   $JPG_JOBS"
        echo "Cooldown:      ${RUN_COOLDOWN}s"
        echo "Reserve kept free per run: ${RESERVE_MB} MiB"
        echo "Temp limits: WARNING=$TEMP_WARNING PAUSE=$TEMP_PAUSE RESUME=$TEMP_RESUME CRITICAL=$TEMP_CRITICAL EMERGENCY=$TEMP_EMERGENCY"
        echo
        echo "This report documents the test only. It is not a guarantee of physical NAND erasure."
    } > "$REPORT_FILE"
}

# ------------------------- Analysis ---------------------------
estimate_profile_runs() {
    case "$1" in
        NORMAL) echo 1 ;;
        SECRET) echo "$SECRET_RUNS" ;;
        PARANOIA) echo "$PARANOIA_RUNS" ;;
    esac
}

endurance_status() {
    local pct="$1"
    if [[ ! "$pct" =~ ^[0-9]+$ ]]; then echo "UNKNOWN"
    elif (( pct <= 20 )); then echo "EXCELLENT"
    elif (( pct <= 50 )); then echo "GOOD"
    elif (( pct <= 75 )); then echo "MODERATE"
    elif (( pct <= 90 )); then echo "HIGH"
    else echo "CRITICAL"; fi
}

run_analysis() {
    local total free free_pct temp health pct spare critical recommendation reason endurance
    total=$(get_total_bytes); free=$(get_free_bytes); free_pct=$(format_pct "$free" "$total")
    temp=$(get_temperature || true); health=$(get_health || true)
    pct=$(get_percentage_used || true); spare=$(get_available_spare || true); critical=$(get_critical_warning || true)

    recommendation="PARANOIA"
    reason="TRIM is available, free space is sufficient, and no obvious health warning is present"
    endurance="UNKNOWN"
    [[ "$pct" =~ ^([0-9]+)%$ ]] && endurance=$(endurance_status "${BASH_REMATCH[1]}")

    if [[ "$health" == "FAILED" ]]; then
        recommendation="STOP"; reason="SMART reports FAILED"
    elif [[ "$critical" =~ ^[1-9][0-9]*$ ]]; then
        recommendation="STOP"; reason="NVMe reports Critical Warning != 0"
    elif [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_CRITICAL )); then
        recommendation="NORMAL"; reason="SSD starts at a critical temperature"
    elif [[ "$pct" =~ ^([0-9]+)%$ ]] && (( ${BASH_REMATCH[1]} >= 80 )); then
        recommendation="NORMAL"; reason="high reported SSD endurance consumption"
    elif (( free < 5 * 1024 * 1024 * 1024 )); then
        recommendation="NORMAL"; reason="very little free space"
    fi

    ANALYSIS_RECOMMENDATION="$recommendation"
    ANALYSIS_REASON="$reason"

    echo
    echo "---------------- SYSTEM ANALYSIS ----------------"
    echo "SSD:                $(lsblk -dno MODEL "$ROOT_DEVICE" 2>/dev/null || echo unknown)"
    echo "Transport:          ${TRANSPORT:-unknown}"
    echo "Filesystem:         $HOME_FS"
    echo "Mountpoint:         $HOME_TARGET"
    echo "TRIM:               available"
    echo "Free space:         $(format_gib "$free") GiB (${free_pct}%)"
    echo "Reserve per run:    ${RESERVE_MB} MiB (fill continues until only this remains free)"
    echo "Temperature:        ${temp:-n/a} °C"
    echo "Health:             ${health:-n/a}"
    echo "Percentage Used:    ${pct:-n/a}"
    echo "Available Spare:    ${spare:-n/a}"
    echo "Critical Warning:   ${critical:-n/a}"
    echo
    echo "Runs per level:     Normal=1  Secret=${SECRET_RUNS}  Paranoia=${PARANOIA_RUNS}"
    echo "Each run fills the disk to (free space - ${RESERVE_MB} MiB), then deletes + TRIMs."
    echo
    echo "Endurance status:   $endurance"
    if [[ "$pct" =~ ^([0-9]+)%$ ]]; then
        local pct_num="${BASH_REMATCH[1]}"
        local remaining=$((100 - pct_num))
        (( remaining < 0 )) && remaining=0
        echo "Endurance consumed: ~${pct_num}%"
        echo "Endurance remaining: ~${remaining}% (controller estimate)"
    else
        echo "Endurance consumed: n/a"
    fi
    echo
    echo "Recommendation:     $recommendation"
    echo "Reason:              $reason"
    echo "--------------------------------------------------"
}

# ------------------------- Adaptive settings -----------------
adapt_settings() {
    local temp=$1 free=$2 base
    CPU_THREADS=$(nproc)
    if (( CPU_THREADS <= 4 )); then base=2
    elif (( CPU_THREADS <= 8 )); then base=4
    else base=6; fi
    (( base > JPG_JOBS_MAX )) && base=$JPG_JOBS_MAX
    JPG_JOBS=$base
    RUN_COOLDOWN=$DEFAULT_COOLDOWN

    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        if (( temp >= TEMP_PAUSE )); then JPG_JOBS=1; RUN_COOLDOWN=$HOT_COOLDOWN
        elif (( temp >= TEMP_WARNING && JPG_JOBS > 2 )); then JPG_JOBS=2; RUN_COOLDOWN=45; fi
    fi
    if (( free < 20 * 1024 * 1024 * 1024 )); then
        (( JPG_JOBS > 2 )) && JPG_JOBS=2
    fi
    return 0
}

# ------------------------- File generators ---------------------
create_html_txt() {
    local i="$1" run="$2" pattern="$3"
    local file_id unique_id current_size remaining
    file_id=$(printf '%06d' "$i")
    unique_id="WIPE-TEST-${LEVEL_NAME}-RUN-$(printf '%02d' "$run")-FILE-${file_id}"

    {
        echo '<!DOCTYPE html>'
        echo '<html lang="en"><head><meta charset="UTF-8">'
        echo "<title>$unique_id</title></head><body>"
        echo '<h1>WIPE-TEST</h1>'
        echo "<p>LEVEL: $LEVEL_NAME</p><p>RUN: $run</p><p>FILE: $file_id</p>"
        echo "<p>PATTERN: $pattern</p><p>UNIQUE-ID: $unique_id</p>"
    } > "$TEST_DIR/file-$i.html"
    current_size=$(stat -c%s "$TEST_DIR/file-$i.html")
    remaining=$((HTML_BASE_SIZE - current_size))
    (( remaining > 0 )) && head -c "$remaining" /dev/urandom >> "$TEST_DIR/file-$i.html"
    echo '</body></html>' >> "$TEST_DIR/file-$i.html"
    manifest_file "$TEST_DIR/file-$i.html" HTML "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$TEST_DIR/file-$i.html")"

    {
        echo '============================================================'
        echo 'WIPE-TEST'
        echo '============================================================'
        echo "LEVEL:      $LEVEL_NAME"; echo "RUN:        $run"; echo "FILE:       $file_id"
        echo "PATTERN:    $pattern"; echo "UNIQUE-ID:  $unique_id"; echo
        echo 'This is synthetic test content.'
    } > "$TEST_DIR/file-$i.txt"
    current_size=$(stat -c%s "$TEST_DIR/file-$i.txt")
    remaining=$((TXT_BASE_SIZE - current_size))
    (( remaining > 0 )) && head -c "$remaining" /dev/urandom >> "$TEST_DIR/file-$i.txt"
    manifest_file "$TEST_DIR/file-$i.txt" TXT "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$TEST_DIR/file-$i.txt")"
}

create_jpg() {
    local i="$1" run="$2" quality="$3" pattern="$4" file_id output
    file_id=$(printf '%06d' "$i")
    output="$TEST_DIR/file-$i.jpg"
    magick -size 1920x1080 xc:gray -seed "$((run * 1000000 + i))" -attenuate 0.8 +noise Random \
        -gravity center -fill white -stroke black -strokewidth 3 -pointsize 48 \
        -annotate 0 "WIPE-TEST\nLEVEL: $LEVEL_NAME\nRUN: $run\nFILE: $file_id\nPATTERN: $pattern" \
        -quality "$quality" "$output"
    manifest_file "$output" JPG "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$output")"
}

RANDOM_POOL=""
RANDOM_POOL_SIZE_MIB=256

# /dev/urandom can become a CPU bottleneck ahead of a fast NVMe drive.
# If openssl is available, generate a large incompressible pool once
# per run via AES-256-CTR keystream (much faster than reading urandom
# per file) and read from it with a rotating offset. Falls back to
# /dev/urandom directly if openssl is unavailable.
generate_random_pool() {
    RANDOM_POOL="$TEST_DIR/.randpool"
    if command -v openssl >/dev/null 2>&1; then
        openssl enc -aes-256-ctr -pbkdf2 -pass pass:"$(date +%s%N)-$$" -nosalt \
            < /dev/zero 2>/dev/null | head -c $((RANDOM_POOL_SIZE_MIB * 1024 * 1024)) > "$RANDOM_POOL" || true
    fi
    if [[ ! -s "$RANDOM_POOL" ]]; then
        head -c $((RANDOM_POOL_SIZE_MIB * 1024 * 1024)) /dev/urandom > "$RANDOM_POOL"
    fi
}

random_source_for_file() {
    # Rotates through the pool so consecutive files don't start at the
    # same offset (still fine as an overwrite source; this is not meant
    # to be cryptographically unique per file, just incompressible).
    local idx="$1"
    echo "$RANDOM_POOL"
}

create_binary_test_file() {
    local path="$1" size_mib="$2" run="$3" file_id="$4" pattern="$5"
    # Zeros are trivially compressible / some controllers (inline
    # compression, SandForce-style) may not actually commit them to
    # physical NAND, which defeats the point of an overwrite test.
    # Random data forces real, incompressible physical writes.
    # NORMAL keeps zeros for speed; SECRET/PARANOIA use random data
    # since maximizing real overwrite is the whole point there.
    local src="/dev/zero" pool_skip=0
    if [[ "$LEVEL_NAME" == "SECRET" || "$LEVEL_NAME" == "PARANOIA" ]]; then
        if [[ -n "$RANDOM_POOL" && -s "$RANDOM_POOL" ]]; then
            src="$RANDOM_POOL"
            local pool_mib=$(( $(stat -c%s "$RANDOM_POOL") / 1024 / 1024 ))
            local file_id_num=$((10#$file_id))
            if (( pool_mib > size_mib )); then
                pool_skip=$(( (file_id_num * size_mib) % (pool_mib - size_mib) ))
            fi
        else
            src="/dev/urandom"
        fi
    fi

    case "$BINARY_MODE" in
        CONTIGUOUS)
            dd if="$src" of="$path" bs=1M skip="$pool_skip" count="$size_mib" status=none ;;
        MIXED_SIZES)
            local first=$((size_mib/2))
            local second=$((size_mib-first))
            dd if="$src" of="$path" bs=1M skip="$pool_skip" count="$first" status=none
            dd if="$src" of="$path" bs=256K seek=$((first*4)) skip=$((pool_skip*4)) count=$((second*4)) conv=notrunc status=none ;;
        FRAGMENTED)
            : > "$path"
            local offset=0 chunk=1 take
            while (( offset < size_mib )); do
                take=$chunk; (( offset+take > size_mib )) && take=$((size_mib-offset))
                dd if="$src" of="$path" bs=1M seek="$offset" skip="$pool_skip" count="$take" conv=notrunc status=none
                offset=$((offset+take+1)); chunk=$((chunk%4+1))
            done ;;
        *) dd if="$src" of="$path" bs=1M skip="$pool_skip" count="$size_mib" status=none ;;
    esac
    printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=%s | PATTERN=%s | FS=%s | ALLOC=%s\n' \
        "$LEVEL_NAME" "$run" "$file_id" "$pattern" "$FILESYSTEM_PROFILE" "$BINARY_MODE" \
        | dd of="$path" bs=1 conv=notrunc status=none
    manifest_file "$path" BIN "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$path")"
}
export -f create_jpg
export TEST_DIR LEVEL_NAME

# ------------------------- System checks ----------------------
for cmd in bash magick fstrim findmnt lsblk df stat dd sync awk grep head tail sed sha256sum tee nproc mktemp; do
    require_cmd "$cmd"
done
command -v smartctl >/dev/null 2>&1 && SMARTCTL_AVAILABLE=1 || true
command -v nvme >/dev/null 2>&1 && NVME_AVAILABLE=1 || true

detect_system
prepare_output_names
safe_test_dir || { echo "Unsafe test path."; exit 1; }

if [[ -e "$RUN_DIR" ]]; then
    echo; echo "$RUN_DIR already exists. Aborting for safety."; exit 1
fi

echo
echo "Checking discard passthrough (LUKS/dm-crypt, LVM)..."
check_discard_passthrough
echo "Checking for btrfs snapshots..."
check_btrfs_snapshots
echo "Checking swap..."
check_swap

if (( ${#DISCARD_WARNINGS[@]} > 0 )) || [[ -n "$BTRFS_SNAPSHOT_WARNING" ]] || [[ -n "$SWAP_WARNING" ]]; then
    echo
    echo "============================================================"
    echo "                  IMPORTANT WARNINGS"
    echo "============================================================"
    for w in "${DISCARD_WARNINGS[@]:-}"; do
        [[ -n "$w" ]] && { echo; echo "!! $w"; }
    done
    [[ -n "$BTRFS_SNAPSHOT_WARNING" ]] && { echo; echo "!! $BTRFS_SNAPSHOT_WARNING"; }
    [[ -n "$SWAP_WARNING" ]] && { echo; echo "!! $SWAP_WARNING"; }
    echo
    echo "If any of the above applies, TRIM may report success while"
    echo "leaving old data recoverable. Fix it first, or accept the risk."
    echo "============================================================"
    if (( CLI_YES == 1 )); then
        echo "(--yes given: continuing despite the warnings above.)"
    else
        read -rp "Continue anyway? [y/N]: " WARN_CONFIRM
        [[ "$WARN_CONFIRM" =~ ^[YyJj]$ ]] || exit 0
    fi
fi

check_min_free_space

# ------------------------- Initial warning --------------------
echo
echo "============================================================"
echo "          SSD RECOVERY RESISTANCE / FILL TEST"
echo "============================================================"
echo
echo "WARNING"
echo "- Existing user files are not intentionally deleted."
echo "- Only script-generated test data is created and removed."
echo "- No Secure Erase / NVMe Sanitize / blkdiscard is used."
echo "- No method here can guarantee physical 100% erasure."
echo "- Each run fills the disk down to ${RESERVE_MB} MiB free, which"
echo "  causes substantial SSD write traffic."
echo
echo "Path:        $TARGET_DIR"
echo "Mountpoint:  $HOME_TARGET"
echo "Source:      $HOME_SOURCE"
echo "Filesystem:  $HOME_FS"
echo "Transport:   ${TRANSPORT:-unknown}"
echo
echo "Discard capability:"
lsblk -o NAME,MODEL,TRAN,SIZE,DISC-GRAN,DISC-MAX "$ROOT_DEVICE" 2>/dev/null || true

echo
echo "Checking TRIM..."
if ! TRIM_DRY=$(trim_dry_run 2>&1); then
    echo; echo "TRIM NOT AVAILABLE - ABORTED"; echo; echo "$TRIM_DRY"; exit 1
fi
echo "$TRIM_DRY"
echo "TRIM is available."

START_FREE_BYTES=$(get_free_bytes)
START_HEALTH=$(get_health || true)
START_PERCENT_USED=$(get_percentage_used || true)
START_AVAILABLE_SPARE=$(get_available_spare || true)
START_CRITICAL_WARNING=$(get_critical_warning || true)
START_MEDIA_ERRORS=$(get_media_errors || true)
START_UNSAFE_SHUTDOWNS=$(get_unsafe_shutdowns || true)
START_POWER_CYCLES=$(get_power_cycles || true)
START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
TEMP_ONESHOT=$(get_temperature || true)
[[ "$TEMP_ONESHOT" =~ ^[0-9]+$ ]] && START_TEMP="$TEMP_ONESHOT" && END_TEMP="$TEMP_ONESHOT"

echo
echo "Drive wear:  ${START_PERCENT_USED:-n/a} used"

# ------------------------- Config sanity checks ----------------
config_sanity_checks() {
    local total
    if (( SECRET_RUNS <= 0 )); then
        echo "ERROR: SECRET_RUNS must be >= 1 (got: $SECRET_RUNS)."
        exit 1
    fi
    if (( PARANOIA_RUNS <= 0 )); then
        echo "ERROR: PARANOIA_RUNS must be >= 1 (got: $PARANOIA_RUNS)."
        exit 1
    fi
    # Paranoia is supposed to be the most thorough level -- if it isn't
    # configured to run at least as many passes as Secret, bump it up
    # automatically rather than silently shipping a "Paranoia" mode that's
    # weaker than "Secret".
    if (( PARANOIA_RUNS <= SECRET_RUNS )); then
        echo "NOTE: PARANOIA_RUNS ($PARANOIA_RUNS) was <= SECRET_RUNS ($SECRET_RUNS)."
        echo "Paranoia is meant to be the most thorough level, so it has been"
        echo "raised to $((SECRET_RUNS + 1)) runs. Set PARANOIA_RUNS explicitly to override."
        PARANOIA_RUNS=$((SECRET_RUNS + 1))
    fi
    if (( RESERVE_MB <= 0 )); then
        echo "ERROR: RESERVE_MB must be > 0 (got: $RESERVE_MB)."
        exit 1
    fi
    total=$(get_total_bytes)
    if [[ "$total" =~ ^[0-9]+$ ]] && (( RESERVE_BYTES >= total )); then
        echo "ERROR: RESERVE_MB (${RESERVE_MB} MiB) is >= the total capacity of"
        echo "$TARGET_DIR ($(format_gib "$total") GiB). Nothing could ever be filled."
        exit 1
    fi
}
config_sanity_checks

# ------------------------- Wear warning -------------------------
if [[ "$START_PERCENT_USED" =~ ^([0-9]+)% ]]; then
    WEAR_NUM="${BASH_REMATCH[1]}"
    if (( WEAR_NUM >= 80 )); then
        echo
        echo "WARNING: This drive reports ${START_PERCENT_USED} wear. Repeated full-disk"
        echo "fill/TRIM cycles (especially Paranoia with multiple runs) write a"
        echo "substantial amount of additional data and measurably consume more"
        echo "of the drive's remaining write endurance."
        if (( CLI_YES == 1 )); then
            echo "(--yes given: continuing anyway.)"
        else
            read -rp "Continue anyway? [y/N]: " WEAR_CONFIRM
            [[ "$WEAR_CONFIRM" =~ ^[YyJj]$ ]] || exit 0
        fi
    fi
fi

# ------------------------- Menu -------------------------------
if [[ -n "$CLI_LEVEL" ]]; then
    run_analysis
    case "$CLI_LEVEL" in
        NORMAL)   LEVEL_NAME=NORMAL;   TOTAL_RUNS=1 ;;
        SECRET)   LEVEL_NAME=SECRET;   TOTAL_RUNS=$SECRET_RUNS ;;
        PARANOIA) LEVEL_NAME=PARANOIA; TOTAL_RUNS=$PARANOIA_RUNS ;;
    esac
    echo
    echo "--level=$CLI_LEVEL given on the command line: skipping the menu."
    if [[ "$ANALYSIS_RECOMMENDATION" == "STOP" ]]; then
        echo
        echo "WARNING: Analysis recommends STOP ($ANALYSIS_REASON), but --level was"
        echo "given explicitly, so it will be honored anyway."
        if (( CLI_YES == 0 )); then
            read -rp "Really continue with --level=$CLI_LEVEL despite the STOP recommendation? [y/N]: " STOP_OVERRIDE_CONFIRM
            [[ "$STOP_OVERRIDE_CONFIRM" =~ ^[YyJj]$ ]] || exit 1
        fi
    fi
else
while true; do
    run_analysis
    echo
    echo "[0] Run analysis again"
    echo "[1] Normal       - 1 run"
    echo "[2] Secret       - ${SECRET_RUNS} runs, varied patterns"
    echo "[3] Paranoia     - ${PARANOIA_RUNS} runs, highest test workload"
    echo "[4] Use recommendation ($ANALYSIS_RECOMMENDATION)"
    echo "[5] Show analysis and exit"
    echo "[6] Abort"
    echo
    read -rp "Selection [0-6]: " choice
    case "$choice" in
        0) continue ;;
        1) LEVEL_NAME=NORMAL; TOTAL_RUNS=1; break ;;
        2) LEVEL_NAME=SECRET; TOTAL_RUNS=$SECRET_RUNS; break ;;
        3) LEVEL_NAME=PARANOIA; TOTAL_RUNS=$PARANOIA_RUNS; break ;;
        4)
            case "$ANALYSIS_RECOMMENDATION" in
                NORMAL) LEVEL_NAME=NORMAL; TOTAL_RUNS=1 ;;
                SECRET) LEVEL_NAME=SECRET; TOTAL_RUNS=$SECRET_RUNS ;;
                PARANOIA) LEVEL_NAME=PARANOIA; TOTAL_RUNS=$PARANOIA_RUNS ;;
                STOP) echo "Analysis recommends not starting."; exit 1 ;;
            esac
            break ;;
        5) echo "Analysis finished. No test data was written."; exit 0 ;;
        6) exit 0 ;;
        *) echo "Invalid selection." ;;
    esac
done
fi

FREE_BYTES=$(get_free_bytes)
TEMP_NOW=$(get_temperature || true)
adapt_settings "$TEMP_NOW" "$FREE_BYTES"

clear
print_banner
echo "============================================================"
echo "                    EXECUTION PLAN"
echo "============================================================"
echo
echo "Level:               $LEVEL_NAME"
echo "Runs:                $TOTAL_RUNS"
echo "CPU Threads:         $CPU_THREADS"
echo "JPG workers:         $JPG_JOBS"
echo "SSD Temperature:     ${TEMP_NOW:-n/a} °C"
echo "Free space now:      $(format_gib "$FREE_BYTES") GiB"
echo "Reserve kept free:   ${RESERVE_MB} MiB (per run, then delete+TRIM)"
echo "Run cooldown:        ${RUN_COOLDOWN}s"
echo
echo "Temperature limits:"
echo "  Warning:  ${TEMP_WARNING}°C   Pause: ${TEMP_PAUSE}°C   Resume: ${TEMP_RESUME}°C"
echo "  Critical: ${TEMP_CRITICAL}°C   Emergency: ${TEMP_EMERGENCY}°C"
echo
echo "Run directory:  $RUN_DIR"
echo "Output files:"
echo "  $REPORT_FILE"
echo "  $MANIFEST_FILE"
echo "  $LOG_FILE"
echo

if [[ -n "$CLI_AGGRESSIVE" ]]; then
    AGGRESSIVE_ALLOC=$CLI_AGGRESSIVE
    echo "Aggressive allocation mode: $([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo ON || echo OFF) (forced via CLI flag)."
elif [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
    AGGRESSIVE_ALLOC=1
    echo "Aggressive allocation mode: ON (always on for Paranoia -- fragmented/mixed layouts)."
elif [[ "$LEVEL_NAME" == "SECRET" ]]; then
    if (( CLI_YES == 1 )); then
        AGGRESSIVE_ALLOC=0
    else
        read -rp "Enable aggressive allocation mode (fragmented/mixed layouts)? [y/N]: " AGG_CONFIRM
        case "$AGG_CONFIRM" in y|Y|j|J) AGGRESSIVE_ALLOC=1 ;; *) AGGRESSIVE_ALLOC=0 ;; esac
    fi
else
    AGGRESSIVE_ALLOC=0
fi

# Paranoia fills closer to the absolute capacity limit than the other
# levels, to reach further into controller-managed overprovisioning space.
# A hard floor still applies so the filesystem itself never runs fully dry.
EFFECTIVE_RESERVE_MB=$RESERVE_MB
EFFECTIVE_RESERVE_BYTES=$RESERVE_BYTES
if [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
    PARANOIA_RESERVE_MB=$(( RESERVE_MB / 2 ))
    (( PARANOIA_RESERVE_MB < PARANOIA_RESERVE_FLOOR_MB )) && PARANOIA_RESERVE_MB=$PARANOIA_RESERVE_FLOOR_MB
    EFFECTIVE_RESERVE_MB=$PARANOIA_RESERVE_MB
    EFFECTIVE_RESERVE_BYTES=$((EFFECTIVE_RESERVE_MB * 1024 * 1024))
    echo "Paranoia reserve: ${EFFECTIVE_RESERVE_MB} MiB (tighter than the normal ${RESERVE_MB} MiB, floor: ${PARANOIA_RESERVE_FLOOR_MB} MiB)."
fi
RESERVE_MB=$EFFECTIVE_RESERVE_MB
RESERVE_BYTES=$EFFECTIVE_RESERVE_BYTES

# The initial free-space warning (before the menu) used the default
# RESERVE_MB. Paranoia's effective reserve is smaller (more usable space),
# so re-check now against the real, level-specific reserve.
check_min_free_space

case "$LEVEL_NAME" in
    NORMAL)   LEVEL_RATIONALE="Normal: 1 fill/delete/TRIM cycle with zero-filled data. Fast baseline check that TRIM runs and free space is reclaimed." ;;
    SECRET)   LEVEL_RATIONALE="Secret: ${TOTAL_RUNS} independent fill/delete/TRIM cycles with incompressible random data (fresh pool each run), guarding against a single incomplete TRIM pass." ;;
    PARANOIA) LEVEL_RATIONALE="Paranoia: ${TOTAL_RUNS} independent fill/delete/TRIM cycles with incompressible random data (fresh pool each run), aggressive fragmented/mixed allocation always on, a tighter ${RESERVE_MB} MiB reserve to reach further into overprovisioned space, an extra verification TRIM pass per run, and secure deletion (shred) of the run's own manifest/log metadata at the end." ;;
esac
echo
echo "$LEVEL_RATIONALE"

if (( DRY_RUN == 1 )); then
    echo
    echo "--dry-run given: stopping here. No files were written, no TRIM was run."
    exit 0
fi

echo "The actual write test starts only after the final confirmation."
if (( CLI_YES == 1 )); then
    echo "--yes given: skipping the Start confirmation."
    confirm="y"
else
    read -rp "Start? [y/N]: " confirm
fi
[[ "$confirm" =~ ^[YyJj]$ ]] || exit 0

setup_logging
write_report_header
{
    echo "# SSD Wipe/Fill manifest"
    echo "# Created: $(date)"
    echo "# Level: $LEVEL_NAME"
    echo "# $LEVEL_RATIONALE"
    echo "# Reserve per run: ${RESERVE_MB} MiB"
    echo
} > "$MANIFEST_FILE"

start_thermal_monitor

echo
echo "5-second countdown..."
for n in 5 4 3 2 1; do echo "$n"; sleep 1; done
echo "START"

# ------------------------- Main runs --------------------------
for run in $(seq 1 "$TOTAL_RUNS"); do
    RUN_START=$(date +%s)
    PER_RUN_START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    PER_RUN_HOST_WRITE_DELTA=""
    mkdir -p "$TEST_DIR"

    if [[ "$LEVEL_NAME" == "SECRET" || "$LEVEL_NAME" == "PARANOIA" ]]; then
        echo "    -> Generating $(format_gib $((RANDOM_POOL_SIZE_MIB*1024*1024))) GiB incompressible random pool for this run..."
        generate_random_pool
    fi

    case "$LEVEL_NAME" in
        NORMAL) JPG_QUALITY=92; PATTERN=NORMAL ;;
        SECRET)
            case $((run % 3)) in
                1) JPG_QUALITY=92; PATTERN=MIXED ;;
                2) JPG_QUALITY=94; PATTERN=RANDOM ;;
                0) JPG_QUALITY=90; PATTERN=LARGE ;;
            esac ;;
        PARANOIA)
            # Fixed order for the 2 hardest patterns instead of a 4-way
            # rotation: run 1 = RANDOM, run 2 = HIGH.
            case "$run" in
                1) JPG_QUALITY=90; PATTERN=RANDOM ;;
                2) JPG_QUALITY=95; PATTERN=HIGH ;;
                *) JPG_QUALITY=95; PATTERN=HIGH ;;
            esac ;;
    esac

    case "$FILESYSTEM_PROFILE" in
        EXT4) ALLOC_PATTERN="EXT4_EXTENTS"; BINARY_MODE="CONTIGUOUS" ;;
        BTRFS) ALLOC_PATTERN="BTRFS_MIXED"; BINARY_MODE="MIXED_SIZES" ;;
        XFS) ALLOC_PATTERN="XFS_EXTENTS"; BINARY_MODE="CONTIGUOUS" ;;
        F2FS) ALLOC_PATTERN="F2FS_STREAM"; BINARY_MODE="MIXED_SIZES" ;;
        *) ALLOC_PATTERN="GENERIC"; BINARY_MODE="CONTIGUOUS" ;;
    esac
    if (( AGGRESSIVE_ALLOC == 1 )); then
        if [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
            # Paranoia + aggressive allocation: bias towards FRAGMENTED,
            # which causes the most write-amplification / GC pressure.
            # run 1 = FRAGMENTED, run 2 = MIXED_SIZES (still harder than
            # plain CONTIGUOUS, avoids two back-to-back identical layouts).
            case "$run" in
                1) BINARY_MODE="FRAGMENTED"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_FRAGMENTED" ;;
                *) BINARY_MODE="MIXED_SIZES"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_MIXED" ;;
            esac
        else
            case $((run % 3)) in
                1) BINARY_MODE="FRAGMENTED"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_FRAGMENTED" ;;
                2) BINARY_MODE="MIXED_SIZES"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_MIXED" ;;
                0) BINARY_MODE="CONTIGUOUS"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_CONTIGUOUS" ;;
            esac
        fi
    fi

    TEMP_NOW=$(get_temperature || true)
    adapt_settings "$TEMP_NOW" "$(get_free_bytes)"

    echo
    echo "============================================================"
    echo "RUN $run / $TOTAL_RUNS | $LEVEL_NAME | $PATTERN"
    echo "============================================================"
    echo "Filesystem: $FILESYSTEM_PROFILE | Alloc: $ALLOC_PATTERN | JPG workers: $JPG_JOBS"
    status_line; echo

    # -------- [1/3] Cycle-fill until only RESERVE_MB stays free --------
    echo
    echo "[1/3] Cycling HTML/TXT/JPG/BIN until free space <= ${RESERVE_MB} MiB..."
    FILL_START=$(date +%s)
    FILL_START_FREE=$(get_free_bytes)
    FILL_TARGET_BYTES=$(( FILL_START_FREE - RESERVE_BYTES ))
    (( FILL_TARGET_BYTES < 1 )) && FILL_TARGET_BYTES=1
    INDEX=0
    ABORTED=0
    JPG_ACTIVE=0
    reset_dashboard

    while true; do
        FREE_NOW=$(get_free_bytes)
        if (( FREE_NOW <= RESERVE_BYTES )); then
            printf '\n'; echo "    -> Reserve reached (free: $(format_gib "$FREE_NOW") GiB)."
            break
        fi

        if ! thermal_gate; then
            ABORTED=1
            break
        fi

        INDEX=$((INDEX + 1))
        TYPE_SEL=$(( (INDEX - 1) % 4 ))
        case "$TYPE_SEL" in
            0|1) create_html_txt "$INDEX" "$run" "$PATTERN" ;;
            2)
                create_jpg "$INDEX" "$run" "$JPG_QUALITY" "$PATTERN" &
                ((JPG_ACTIVE++)) || true
                if (( JPG_ACTIVE >= JPG_JOBS )); then wait -n; ((JPG_ACTIVE--)) || true; fi
                ;;
            3) create_binary_test_file "$TEST_DIR/file-$INDEX.bin" "$BIN_BASE_MIB" "$run" "$(printf '%06d' "$INDEX")" "$PATTERN" ;;
        esac

        if (( INDEX % 10 == 0 )); then
            render_dashboard
        fi
    done
    wait || true
    echo
    echo "    -> $INDEX files created in this run."
    echo "    Test data:"; du -sh "$TEST_DIR" 2>/dev/null || true

    # -------- [2/3] sync + delete --------
    echo
    echo "[2/3] sync + delete generated files..."
    sync
    safe_test_dir || { echo "REFUSING TO DELETE: unsafe TEST_DIR ('$TEST_DIR'). Aborting."; exit 1; }
    rm -rf -- "${TEST_DIR:?}"/* "${TEST_DIR:?}"/.[!.]* 2>/dev/null
    echo "    -> Deleted."

    # -------- [3/3] TRIM --------
    echo
    echo "[3/3] TRIM"
    record_trim
    if [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
        echo "    -> Paranoia: extra verification TRIM pass (catches async controller GC stragglers)..."
        sleep 5
        record_trim
    fi
    status_line; echo

    RUN_END=$(date +%s)
    RUN_TIME=$((RUN_END - RUN_START))
    TOTAL_ELAPSED=$((RUN_END - SCRIPT_START))
    CURRENT_FREE=$(get_free_bytes)
    PER_RUN_END_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    if [[ "$PER_RUN_START_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" -ge "$PER_RUN_START_DATA_WRITTEN_BYTES" ]]; then
        PER_RUN_HOST_WRITE_DELTA=$((PER_RUN_END_DATA_WRITTEN_BYTES - PER_RUN_START_DATA_WRITTEN_BYTES))
    else
        PER_RUN_HOST_WRITE_DELTA=""
    fi

    (( ABORTED == 1 )) && ANY_ABORTED=1
    SUM_RUN_TIME=$((SUM_RUN_TIME + RUN_TIME))

    {
        echo "------------------------------------------------------------"
        echo "RUN $run/$TOTAL_RUNS  |  $LEVEL_NAME  |  $PATTERN  |  fs=$FILESYSTEM_PROFILE alloc=$ALLOC_PATTERN aggr=$([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo on || echo off)"
        echo "  files=$INDEX  duration=$(format_time "$RUN_TIME")  free=$(format_gib "$CURRENT_FREE")GiB  peak=${PEAK_TEMP:-n/a}°C  aborted=$([[ $ABORTED -eq 1 ]] && echo yes || echo no)"
        echo "  nominal_total=$(format_gib "$NOMINAL_WRITTEN_BYTES")GiB  host_write_delta=${PER_RUN_HOST_WRITE_DELTA:+$(format_gib "$PER_RUN_HOST_WRITE_DELTA")GiB}${PER_RUN_HOST_WRITE_DELTA:-n/a}"
    } >> "$REPORT_FILE"

    printf '%d,%d,%s,%s,%s,%s,%s,%d,%d,%d,%s,%s,%d,%s\n' \
        "$run" "$TOTAL_RUNS" "$LEVEL_NAME" "$PATTERN" "$FILESYSTEM_PROFILE" "$ALLOC_PATTERN" \
        "$([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo true || echo false)" "$INDEX" "$RUN_TIME" \
        "$CURRENT_FREE" "${PEAK_TEMP:-}" "$([[ $ABORTED -eq 1 ]] && echo true || echo false)" \
        "$NOMINAL_WRITTEN_BYTES" "${PER_RUN_HOST_WRITE_DELTA:-}" >> "$CSV_FILE"

    echo
    echo "RUN $run / $TOTAL_RUNS complete"
    echo "  Files:        $INDEX"
    echo "  Duration:     $(format_time "$RUN_TIME")"
    echo "  Free space:   $(format_gib "$CURRENT_FREE") GiB"
    echo "  Peak temp:    ${PEAK_TEMP:-n/a} °C"
    echo "  Nominal total: $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"

    if (( run < TOTAL_RUNS )); then
        REMAINING_RUNS=$((TOTAL_RUNS - run))
        AVG_RUN_TIME=$((SUM_RUN_TIME / run))
        ETA_SECONDS=$((REMAINING_RUNS * (AVG_RUN_TIME + RUN_COOLDOWN)))
        echo "  ETA remaining: ~$(format_time "$ETA_SECONDS") for $REMAINING_RUNS more run(s) (based on avg run time so far)"
        echo; echo "Cooldown: ${RUN_COOLDOWN}s"; sleep "$RUN_COOLDOWN"
    fi
done

# ------------------------- Final verification TRIM -------------
# One extra TRIM pass after all runs, in case the last run ended
# early (thermal abort) or the filesystem coalesced freed extents
# that weren't caught by a run-level TRIM.
echo
echo "============================================================"
echo "FINAL VERIFICATION TRIM"
echo "============================================================"
safe_test_dir || { echo "REFUSING TO DELETE: unsafe TEST_DIR ('$TEST_DIR'). Aborting."; exit 1; }
rm -rf -- "${TEST_DIR:?}"/* "${TEST_DIR:?}"/.[!.]* 2>/dev/null || true
sync
record_trim
status_line; echo

# ------------------------- Final metrics ----------------------
TOTAL_TIME=$(($(date +%s) - SCRIPT_START))
END_FREE_BYTES=$(get_free_bytes)
END_HEALTH=$(get_health || true)
END_PERCENT_USED=$(get_percentage_used || true)
END_AVAILABLE_SPARE=$(get_available_spare || true)
END_CRITICAL_WARNING=$(get_critical_warning || true)
END_MEDIA_ERRORS=$(get_media_errors || true)
END_UNSAFE_SHUTDOWNS=$(get_unsafe_shutdowns || true)
END_POWER_CYCLES=$(get_power_cycles || true)
END_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)

HOST_WRITE_DELTA=""
if [[ "$START_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$END_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ ]]; then
    (( END_DATA_WRITTEN_BYTES >= START_DATA_WRITTEN_BYTES )) && HOST_WRITE_DELTA=$((END_DATA_WRITTEN_BYTES - START_DATA_WRITTEN_BYTES))
fi

{
    echo
    echo "============================================================"
    echo "FINAL RESULT"
    echo "============================================================"
    echo "Level:                    $LEVEL_NAME"
    echo "Runs:                     $TOTAL_RUNS"
    echo "Filesystem profile:       $FILESYSTEM_PROFILE"
    echo "Aggressive allocation:    $([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo ON || echo OFF)"
    echo "Reserve kept free/run:    ${RESERVE_MB} MiB"
    echo "Total duration:           $(format_time "$TOTAL_TIME")"
    echo "Nominal data written:     $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    if [[ -n "$HOST_WRITE_DELTA" ]]; then
        echo "Controller host writes:   $(format_gib "$HOST_WRITE_DELTA") GiB"
    else
        echo "Controller host writes:   unavailable"
    fi
    echo "Peak temperature:         ${PEAK_TEMP:-n/a} °C"
    echo "TRIM operations:          $TRIM_COUNT"
    echo "TRIM bytes reported:      $(human "$TRIM_BYTES_APPROX") ($TRIM_BYTES_APPROX B)"
    if (( NOMINAL_WRITTEN_BYTES > 0 )); then
        TRIM_RATIO=$(format_pct "$TRIM_BYTES_APPROX" "$NOMINAL_WRITTEN_BYTES")
        echo "TRIM vs. written ratio:   ${TRIM_RATIO}%"
        if awk -v r="$TRIM_RATIO" 'BEGIN{exit !(r+0 < 50)}'; then
            echo "  WARNING: TRIM reported far less than was written. Discard may not be"
            echo "  fully passed through to the physical media on this storage stack"
            echo "  (e.g. LUKS/LVM/RAID layers not covered by the checks above, a"
            echo "  filesystem that doesn't call discard on delete, or a controller"
            echo "  that under-reports). Do not treat TRIM completion alone as proof"
            echo "  of recovery resistance on this device."
        fi
    fi
    echo
    echo "Free space:               $(format_gib "$START_FREE_BYTES") GiB -> $(format_gib "$END_FREE_BYTES") GiB"

    # Endurance delta: how much did THIS run actually cost the drive, per its
    # own controller-reported wear indicator (vendor-dependent, best-effort).
    if [[ "$START_PERCENT_USED" =~ ^([0-9]+)% ]] && [[ "$END_PERCENT_USED" =~ ^([0-9]+)% ]]; then
        [[ "$START_PERCENT_USED" =~ ^([0-9]+)% ]] && WEAR_START_NUM="${BASH_REMATCH[1]}"
        [[ "$END_PERCENT_USED" =~ ^([0-9]+)% ]] && WEAR_END_NUM="${BASH_REMATCH[1]}"
        WEAR_DELTA=$((WEAR_END_NUM - WEAR_START_NUM))
        echo "Endurance used by this run: ${WEAR_START_NUM}% -> ${WEAR_END_NUM}% (delta: ${WEAR_DELTA} percentage point(s))"
        if (( WEAR_DELTA >= 1 )); then
            echo "  NOTE: This single test measurably moved the drive's own wear indicator."
            echo "  Expected for Paranoia on smaller drives; if this keeps happening on"
            echo "  routine Normal/Secret runs, consider a larger RESERVE_MB."
        fi
    elif [[ -n "$START_PERCENT_USED" || -n "$END_PERCENT_USED" ]]; then
        echo "Endurance used by this run: n/a (percentage_used not comparable, e.g. estimated SATA fallback)"
    fi
    if [[ -n "$START_AVAILABLE_SPARE" && -n "$END_AVAILABLE_SPARE" ]]; then
        echo "Available spare:            ${START_AVAILABLE_SPARE:-n/a} -> ${END_AVAILABLE_SPARE:-n/a}"
    fi
    echo
    printf "%-22s %-18s %-18s\n" "SMART/NVMe" "start" "end"
    printf "%-22s %-18s %-18s\n" "Health"             "${START_HEALTH:-n/a}"             "${END_HEALTH:-n/a}"
    printf "%-22s %-18s %-18s\n" "Percentage Used"    "${START_PERCENT_USED:-n/a}"       "${END_PERCENT_USED:-n/a}"
    printf "%-22s %-18s %-18s\n" "Available Spare"    "${START_AVAILABLE_SPARE:-n/a}"    "${END_AVAILABLE_SPARE:-n/a}"
    printf "%-22s %-18s %-18s\n" "Critical Warning"   "${START_CRITICAL_WARNING:-n/a}"   "${END_CRITICAL_WARNING:-n/a}"
    printf "%-22s %-18s %-18s\n" "Media Errors"       "${START_MEDIA_ERRORS:-n/a}"       "${END_MEDIA_ERRORS:-n/a}"
    printf "%-22s %-18s %-18s\n" "Unsafe Shutdowns"   "${START_UNSAFE_SHUTDOWNS:-n/a}"   "${END_UNSAFE_SHUTDOWNS:-n/a}"
    printf "%-22s %-18s %-18s\n" "Power Cycles"       "${START_POWER_CYCLES:-n/a}"       "${END_POWER_CYCLES:-n/a}"
    printf "%-22s %-18s %-18s\n" "Data Units Written" "${START_DATA_WRITTEN_BYTES:-n/a}" "${END_DATA_WRITTEN_BYTES:-n/a}"
    echo
    if (( ANY_ABORTED == 1 )); then
        echo
        echo "NOTE: At least one run was aborted early due to thermal limits (see"
        echo "'aborted=yes' rows above / in runs.csv). Results are still valid TRIM"
        echo "passes, but coverage of this run may be smaller than intended."
    fi
    echo "Files: $REPORT_FILE | $MANIFEST_FILE | $CSV_FILE | $LOG_FILE"
    echo "============================================================"
} | tee -a "$REPORT_FILE"

# Paranoia: securely overwrite the manifest (it lists every generated
# filename, pattern and hash -- metadata worth not leaving readable even
# though the underlying test data itself is already gone). The live log
# file is left alone since it's still being written to via the tee above.
MANIFEST_SHREDDED=0
if [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
    if command -v shred >/dev/null 2>&1; then
        echo
        echo "Paranoia: securely overwriting manifest.txt (shred)..."
        if shred -u -z -n 3 -- "$MANIFEST_FILE" 2>/dev/null; then
            MANIFEST_SHREDDED=1
            echo "# manifest securely deleted (shred -u -z -n 3) at $(date)" > "$MANIFEST_FILE"
            echo "    -> Done. Manifest contents overwritten and removed."
        else
            echo "    -> shred failed; manifest left as-is."
        fi
    else
        echo
        echo "Paranoia: 'shred' not found, manifest.txt left as a plain deleted-on-request file."
    fi
fi

echo
echo "DONE."
printf '%s' "$BOLD$GREEN"
echo "Data written this session: $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
echo "Free space remaining:      $(format_gib "$END_FREE_BYTES") GiB"
printf '%s\n' "$RESET"
echo "Report:   $REPORT_FILE"
echo "Manifest: $MANIFEST_FILE"
echo "CSV:      $CSV_FILE"
echo "Log:      $LOG_FILE"

# Exit code semantics for scripting/cron:
#   0 = completed, no thermal aborts
#   2 = completed, but at least one run was cut short by thermal limits
if (( ANY_ABORTED == 1 )); then
    exit 2
fi
exit 0
