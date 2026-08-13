#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# ============================================================
# SSD REMNANT WIPE / RECOVERY-RESISTANCE TEST
# ============================================================
# Purpose:
#   Create controlled test data, sync it, delete only that test data,
#   then TRIM the filesystem. The goal is to make already-deleted data
#   harder to recover while leaving existing user files untouched.
#
# This is NOT:
#   - ATA Secure Erase
#   - NVMe Sanitize
#   - whole-device blkdiscard
#   - whole-device overwrite
#   - a guarantee of physical NAND erasure
#
# The SSD controller remains responsible for wear-leveling,
# garbage collection and physical NAND management.
# ============================================================

# ------------------------- Configuration --------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_ROOT="$SCRIPT_DIR/runs"
OUTPUT_STAMP=""
RUN_DIR=""
TEST_DIR=""

HTML_BASE_SIZE=$((2 * 1024 * 1024))
TXT_BASE_SIZE=$((2 * 1024 * 1024))
JPG_TARGET_BYTES=$((10 * 1024 * 1024))

JPG_JOBS_DEFAULT=4
JPG_JOBS_MAX=6

RESERVE_PERCENT=10
RESERVE_MIN_GIB=20

TEMP_NORMAL=60
TEMP_WARM=70
TEMP_HIGH=80
TEMP_RESUME=65

DEFAULT_COOLDOWN=30
HOT_COOLDOWN=60
POST_TRIM_IDLE=10


TOTAL_RUNS=0
LEVEL_NAME=""
ANALYSIS_RECOMMENDATION=""
ANALYSIS_REASON=""

SCRIPT_START=$(date +%s)
NOMINAL_WRITTEN_BYTES=0
MAX_TEMP=0
TRIM_COUNT=0
TRIM_BYTES_APPROX=0

SMARTCTL_AVAILABLE=0
NVME_AVAILABLE=0
SMART_DEVICE=""
NVME_DEVICE=""

HOME_TARGET=""
HOME_SOURCE=""
HOME_FS=""
TRANSPORT=""
ROOT_DEVICE=""

START_FREE_BYTES=0
END_FREE_BYTES=0
START_TEMP=""
END_TEMP=""
START_HEALTH=""
END_HEALTH=""
START_PERCENT_USED=""
END_PERCENT_USED=""
START_AVAILABLE_SPARE=""
END_AVAILABLE_SPARE=""
START_CRITICAL_WARNING=""
END_CRITICAL_WARNING=""
START_MEDIA_ERRORS=""
END_MEDIA_ERRORS=""
START_UNSAFE_SHUTDOWNS=""
END_UNSAFE_SHUTDOWNS=""
START_POWER_CYCLES=""
END_POWER_CYCLES=""
START_DATA_WRITTEN_BYTES=""
END_DATA_WRITTEN_BYTES=""

CPU_THREADS=$(nproc)
JPG_JOBS=$JPG_JOBS_DEFAULT
RUN_COOLDOWN=$DEFAULT_COOLDOWN
RESERVE_BYTES=0
SAFE_FILL_BYTES=0
AGGRESSIVE_ALLOC=0
FILESYSTEM_PROFILE="GENERIC"
ALLOC_PATTERN="GENERIC"
BINARY_MODE="CONTIGUOUS"
PER_RUN_START_DATA_WRITTEN_BYTES=""
PER_RUN_END_DATA_WRITTEN_BYTES=""
PER_RUN_HOST_WRITE_DELTA=""


# ------------------------- General helpers ------------------
format_time() {
    local seconds="$1"
    printf "%02d:%02d:%02d" \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

format_gib() {
    awk -v b="$1" 'BEGIN { printf "%.1f", b/1024/1024/1024 }'
}

format_pct() {
    awk -v a="$1" -v b="$2" 'BEGIN { if (b>0) printf "%.1f", 100*a/b; else print "0.0" }'
}

add_written() {
    NOMINAL_WRITTEN_BYTES=$((NOMINAL_WRITTEN_BYTES + $1))
}

get_free_bytes() {
    df -B1 --output=avail "$HOME" | tail -n 1 | tr -d ' '
}

get_total_bytes() {
    df -B1 --output=size "$HOME" | tail -n 1 | tr -d ' '
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Fehlendes Programm: $1"
        exit 1
    }
}

safe_test_dir() {
    [[ -n "$RUN_DIR" && -n "$TEST_DIR" ]] || return 1
    [[ "$RUN_DIR" == "$RUN_ROOT/"* ]] || return 1
    [[ "$TEST_DIR" == "$RUN_DIR/test-data" ]] || return 1
    [[ "$TEST_DIR" != "/" ]] || return 1
    [[ "$TEST_DIR" != "$HOME" ]] || return 1
    return 0
}

cleanup() {
    if safe_test_dir && [[ -d "$TEST_DIR" ]]; then
        echo
        echo "Cleanup: removing only the script-owned test directory..."
        rm -rf -- "$TEST_DIR"
        echo "Cleanup complete."
    fi
}

handle_interrupt() {
    trap - INT TERM
    echo
    echo
    echo "============================================================"
    echo "ABORT REQUESTED"
    echo "============================================================"
    echo "Cleaning temporary test data..."
    cleanup
    if [[ -n "$LOG_FILE" ]]; then
        echo "Aborted: $(date)" >> "$LOG_FILE"
    fi
    exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT


# ------------------------- Logging ----------------------------
prepare_output_names() {
    if [[ -z "$OUTPUT_STAMP" ]]; then
        OUTPUT_STAMP=$(date +%Y%m%d-%H%M%S)
    fi

    RUN_DIR="$RUN_ROOT/$OUTPUT_STAMP"
    TEST_DIR="$RUN_DIR/test-data"
    REPORT_FILE="$RUN_DIR/report.txt"
    MANIFEST_FILE="$RUN_DIR/manifest.txt"
    LOG_FILE="$RUN_DIR/run.log"

    # Avoid timestamp collisions without writing anything during analysis.
    if [[ -e "$RUN_DIR" ]]; then
        local suffix=1
        local candidate_stamp candidate

        while :; do
            candidate_stamp="${OUTPUT_STAMP}-${suffix}"
            candidate="$RUN_ROOT/$candidate_stamp"
            if [[ ! -e "$candidate" ]]; then
                OUTPUT_STAMP="$candidate_stamp"
                RUN_DIR="$candidate"
                TEST_DIR="$RUN_DIR/test-data"
                REPORT_FILE="$RUN_DIR/report.txt"
                MANIFEST_FILE="$RUN_DIR/manifest.txt"
                LOG_FILE="$RUN_DIR/run.log"
                break
            fi
            suffix=$((suffix + 1))
        done
    fi
}

setup_logging() {
    mkdir -p "$RUN_DIR"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}


# ------------------------- Device detection ------------------
detect_system() {
    local mount_info parent_device

    mount_info=$(findmnt -T "$HOME" -no TARGET,SOURCE,FSTYPE 2>/dev/null || true)
    [[ -n "$mount_info" ]] || {
        echo "Could not determine the filesystem for $HOME."
        exit 1
    }

    HOME_TARGET=$(awk '{print $1}' <<< "$mount_info")
    HOME_SOURCE=$(awk '{print $2}' <<< "$mount_info")
    HOME_FS=$(awk '{print $3}' <<< "$mount_info")

    parent_device=$(lsblk -no PKNAME "$HOME_SOURCE" 2>/dev/null | head -n 1 || true)
    if [[ -n "$parent_device" ]]; then
        ROOT_DEVICE="/dev/$parent_device"
    else
        ROOT_DEVICE="$HOME_SOURCE"
    fi

    TRANSPORT=$(lsblk -no TRAN "$HOME_SOURCE" 2>/dev/null | head -n 1 || true)

    if [[ "$TRANSPORT" == "nvme" ]]; then
        if [[ "$parent_device" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
            NVME_DEVICE="/dev/$parent_device"
        elif [[ "$ROOT_DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
            NVME_DEVICE="$ROOT_DEVICE"
        fi
    fi

    if [[ -n "$NVME_DEVICE" ]]; then
        SMART_DEVICE="$NVME_DEVICE"
    else
        SMART_DEVICE="$ROOT_DEVICE"
    fi

    case "$HOME_FS" in
        ext4) FILESYSTEM_PROFILE="EXT4" ;;
        btrfs) FILESYSTEM_PROFILE="BTRFS" ;;
        xfs) FILESYSTEM_PROFILE="XFS" ;;
        f2fs) FILESYSTEM_PROFILE="F2FS" ;;
        *) FILESYSTEM_PROFILE="GENERIC" ;;
    esac
}

# ------------------------- SMART / NVMe ----------------------
nvme_dump() {
    if (( NVME_AVAILABLE == 0 )) || [[ -z "$NVME_DEVICE" ]]; then
        return 0
    fi
    sudo nvme smart-log -H "$NVME_DEVICE" 2>/dev/null || true
}

smart_dump() {
    if (( SMARTCTL_AVAILABLE == 0 )) || [[ -z "$SMART_DEVICE" ]]; then
        return 0
    fi
    sudo smartctl -a "$SMART_DEVICE" 2>/dev/null || true
}

get_nvme_field() {
    local field="$1"
    local dump
    [[ -n "$NVME_DEVICE" ]] || return 0
    dump=$(nvme_dump)
    grep -Ei "^${field}[[:space:]]*:" <<< "$dump" |
        sed -nE 's/^[^:]+:[[:space:]]*([^[:space:]]+).*/\1/p' |
        head -n 1 || true
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
    [[ -n "$temp" ]] && printf '%s\n' "$temp"
}

get_health() {
    local dump critical

    if [[ -n "$NVME_DEVICE" ]]; then
        dump=$(nvme_dump)
        critical=$(grep -Ei '^critical_warning[[:space:]]*:' <<< "$dump" | sed -nE 's/.*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || true)
        if [[ "$critical" == "0" ]]; then
            echo "OK"
            return 0
        elif [[ -n "$critical" ]]; then
            echo "WARNING"
            return 0
        fi
    fi

    dump=$(smart_dump)
    if grep -Eiq 'PASSED' <<< "$dump"; then
        echo "PASSED"
    elif grep -Eiq 'FAILED' <<< "$dump"; then
        echo "FAILED"
    else
        echo "UNKNOWN"
    fi
}

get_percentage_used() {
    get_nvme_field "percentage_used" | sed 's/%$//' | awk 'NF {print $1 "%"}'
}

get_available_spare() {
    get_nvme_field "available_spare" | awk 'NF {print $1 "%"}'
}

get_critical_warning() {
    get_nvme_field "critical_warning"
}

get_data_written_units() {
    local dump
    [[ -n "$NVME_DEVICE" ]] || return 0
    dump=$(nvme_dump)
    grep -Ei '^Data Units Written' <<< "$dump" |
        sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' |
        tr -d ',' |
        head -n 1 || true
}

get_data_written_bytes() {
    local units
    units=$(get_data_written_units || true)
    if [[ "$units" =~ ^[0-9]+$ ]]; then
        # NVMe Data Units Written: one unit = 1000 * 512 bytes.
        echo $((units * 512000))
    else
        echo ""
    fi
}

get_media_errors() {
    get_nvme_field "media_errors"
}

get_unsafe_shutdowns() {
    get_nvme_field "unsafe_shutdowns"
}

get_power_cycles() {
    get_nvme_field "power_cycles"
}

status_for_temperature() {
    local temp="$1"
    if (( temp <= TEMP_NORMAL )); then
        echo "NORMAL"
    elif (( temp <= TEMP_WARM )); then
        echo "WARM"
    elif (( temp <= TEMP_HIGH )); then
        echo "HIGH"
    else
        echo "CRITICAL"
    fi
}

monitor_ssd() {
    local detail="${1:-0}"
    local temp="" health="" pct="" spare="" critical="" written="" media="" unsafe="" power="" status=""
    local nvme_data="" smart_data=""

    if [[ -n "$NVME_DEVICE" ]]; then
        nvme_data=$(nvme_dump)
        temp=$(grep -Ei '^temperature[[:space:]]*:' <<< "$nvme_data" | grep -oE '[0-9]+' | head -n 1 || true)
        critical=$(grep -Ei '^critical_warning[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || true)
        [[ "$critical" == "0" ]] && health="OK"
        [[ -n "$critical" && "$critical" != "0" ]] && health="WARNING"

        pct=$(grep -Ei '^percentage_used[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9]+)%?.*/\1/p' | head -n 1 || true)
        [[ -n "$pct" ]] && pct="${pct}%"

        spare=$(grep -Ei '^available_spare[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9]+)%?.*/\1/p' | head -n 1 || true)
        [[ -n "$spare" ]] && spare="${spare}%"

        written=$(grep -Ei '^Data Units Written[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' | tr -d ',' | head -n 1 || true)
        media=$(grep -Ei '^media_errors[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' | tr -d ',' | head -n 1 || true)
        unsafe=$(grep -Ei '^unsafe_shutdowns[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' | tr -d ',' | head -n 1 || true)
        power=$(grep -Ei '^power_cycles[[:space:]]*:' <<< "$nvme_data" |
            sed -nE 's/.*:[[:space:]]*([0-9,]+).*/\1/p' | tr -d ',' | head -n 1 || true)
    else
        smart_data=$(smart_dump)
        temp=$(grep -Ei 'Temperature:|Composite Temperature|Temperature Sensor 1' <<< "$smart_data" |
            grep -oE '[0-9]+' | head -n 1 || true)

        if grep -Eiq 'PASSED' <<< "$smart_data"; then
            health="PASSED"
        elif grep -Eiq 'FAILED' <<< "$smart_data"; then
            health="FAILED"
        else
            health="UNKNOWN"
        fi
    fi

    if [[ -n "$temp" ]]; then
        (( temp > MAX_TEMP )) && MAX_TEMP="$temp"
        status=$(status_for_temperature "$temp")

        echo "    SSD: ${temp} °C [$status] | Health: ${health:-n/a} | Used: ${pct:-n/a} | Spare: ${spare:-n/a}"

        if (( detail == 1 )); then
            echo "    NVMe: Critical Warning=${critical:-n/a} | Data Units Written=${written:-n/a} | Media Errors=${media:-n/a} | Unsafe Shutdowns=${unsafe:-n/a} | Power Cycles=${power:-n/a}"
        fi

        if [[ -z "$START_TEMP" ]]; then
            START_TEMP="$temp"
            START_HEALTH="$health"
            START_PERCENT_USED="$pct"
            START_AVAILABLE_SPARE="$spare"
            START_CRITICAL_WARNING="$critical"
            START_MEDIA_ERRORS="$media"
            START_UNSAFE_SHUTDOWNS="$unsafe"
            START_POWER_CYCLES="$power"
            if [[ "$written" =~ ^[0-9]+$ ]]; then
                START_DATA_WRITTEN_BYTES=$((written * 512000))
            fi
        fi

        END_TEMP="$temp"
        END_HEALTH="$health"
        END_PERCENT_USED="$pct"
        END_AVAILABLE_SPARE="$spare"
        END_CRITICAL_WARNING="$critical"
        END_MEDIA_ERRORS="$media"
        END_UNSAFE_SHUTDOWNS="$unsafe"
        END_POWER_CYCLES="$power"
        if [[ "$written" =~ ^[0-9]+$ ]]; then
            END_DATA_WRITTEN_BYTES=$((written * 512000))
        fi

        if (( temp > TEMP_HIGH )); then
            echo
            echo "    !!! CRITICAL SSD TEMPERATURE !!!"
            echo "    Write operation paused. Waiting for <= ${TEMP_RESUME} °C ..."

            while true; do
                sleep 10

                local retry_data="" retry_temp=""
                if [[ -n "$NVME_DEVICE" ]]; then
                    retry_data=$(nvme_dump)
                    retry_temp=$(grep -Ei '^temperature[[:space:]]*:' <<< "$retry_data" |
                        grep -oE '[0-9]+' | head -n 1 || true)
                else
                    local retry_smart=""
                    retry_smart=$(smart_dump)
                    retry_temp=$(grep -Ei 'Temperature:|Composite Temperature|Temperature Sensor 1' <<< "$retry_smart" |
                        grep -oE '[0-9]+' | head -n 1 || true)
                fi

                if [[ "$retry_temp" =~ ^[0-9]+$ ]]; then
                    (( retry_temp > MAX_TEMP )) && MAX_TEMP="$retry_temp"
                    echo "    Current temperature: ${retry_temp} °C"
                    (( retry_temp <= TEMP_RESUME )) && break
                fi
            done

            echo "    Temperature is back in the safe range."
        fi
    else
        echo "    SSD temperature: unavailable"
    fi
}

# ------------------------- TRIM -------------------------------
trim_dry_run() {
    sudo fstrim --dry-run -v "$HOME"
}

record_trim() {
    local out number unit factor
    if ! out=$(sudo fstrim -v "$HOME" 2>&1); then
        echo "$out"
        echo "TRIM failed. Aborting."
        exit 1
    fi
    echo "$out"
    TRIM_COUNT=$((TRIM_COUNT + 1))

    if (( POST_TRIM_IDLE > 0 )); then
        echo "    -> Post-TRIM idle: ${POST_TRIM_IDLE}s"
        sleep "$POST_TRIM_IDLE"
    fi

    if [[ "$out" =~ :[[:space:]]([0-9.]+)[[:space:]](bytes|KiB|MiB|GiB) ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            bytes) factor=1 ;;
            KiB) factor=1024 ;;
            MiB) factor=$((1024 * 1024)) ;;
            GiB) factor=$((1024 * 1024 * 1024)) ;;
            *) factor=0 ;;
        esac
        if (( factor > 0 )); then
            number="${number%.*}"
            TRIM_BYTES_APPROX=$((TRIM_BYTES_APPROX + number * factor))
        fi
    fi
}

# ------------------------- Progress ---------------------------
show_progress() {
    local current="$1" total="$2" start_time="$3" current_run="$4"
    local now elapsed remaining total_elapsed estimated_total total_remaining

    now=$(date +%s)
    elapsed=$((now - start_time))
    if (( current > 0 )); then remaining=$((elapsed * (total - current) / current)); else remaining=0; fi
    total_elapsed=$((now - SCRIPT_START))
    if (( current_run > 0 )); then estimated_total=$((total_elapsed * TOTAL_RUNS / current_run)); total_remaining=$((estimated_total - total_elapsed)); else total_remaining=0; fi

    printf "\r    -> %4d / %4d | elapsed %s | remaining %s | total remaining %s" \
        "$current" "$total" "$(format_time "$elapsed")" "$(format_time "$remaining")" "$(format_time "$total_remaining")"
}

# ------------------------- Manifest / Report -----------------
manifest_file() {
    local path="$1" type="$2" run="$3" file="$4" pattern="$5"
    local size hash
    size=$(stat -c%s "$path")
    hash=$(sha256sum "$path" | awk '{print $1}')
    local relative_path
    if [[ "$path" == "$RUN_DIR/"* ]]; then
        relative_path="./${path#"$RUN_DIR/"}"
    else
        relative_path="$path"
    fi

    printf 'TYPE=%s\tLEVEL=%s\tRUN=%02d\tFILE=%s\tPATTERN=%s\tSIZE=%s\tSHA256=%s\tPATH=%s\n' \
        "$type" "$LEVEL_NAME" "$run" "$file" "$pattern" "$size" "$hash" "$relative_path" >> "$MANIFEST_FILE"
}

write_report_header() {
    {
        echo "============================================================"
        echo "SSD RECOVERY RESISTANCE REPORT"
        echo "============================================================"
        echo "Date:          $(date)"
        echo "Home:          $HOME"
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
        echo
        echo "This report documents the test only. It is not a guarantee of physical NAND erasure."
    } > "$REPORT_FILE"
}

# ------------------------- Analysis ---------------------------
calculate_reserve() {
    local total=$1
    RESERVE_BYTES=$((total * RESERVE_PERCENT / 100))
    local min_bytes=$((RESERVE_MIN_GIB * 1024 * 1024 * 1024))
    if (( RESERVE_BYTES < min_bytes )); then RESERVE_BYTES=$min_bytes; fi
}

estimate_profile_gib() {
    local profile="$1"
    local total=$2 free=$3 safe
    safe=0
    if (( free > RESERVE_BYTES )); then safe=$((free - RESERVE_BYTES)); fi

    case "$profile" in
        NORMAL)
            echo 35
            ;;
        SECRET)
            # Five base runs + one 50% safe-space fill.
            echo $((35 * 5 + safe / 2 / 1024 / 1024 / 1024))
            ;;
        PARANOIA)
            # Ten base runs + 25% + 25% + 50% safe-space fills.
            echo $((35 * 10 + safe / 1024 / 1024 / 1024))
            ;;
    esac
}

endurance_status() {
    local pct="$1"
    if [[ ! "$pct" =~ ^[0-9]+$ ]]; then
        echo "UNKNOWN"
    elif (( pct <= 20 )); then
        echo "EXCELLENT"
    elif (( pct <= 50 )); then
        echo "GOOD"
    elif (( pct <= 75 )); then
        echo "MODERATE"
    elif (( pct <= 90 )); then
        echo "HIGH"
    else
        echo "CRITICAL"
    fi
}

run_analysis() {
    local total free free_pct temp health pct spare critical
    local normal_est secret_est paranoia_est
    local recommendation reason

    total=$(get_total_bytes)
    free=$(get_free_bytes)
    free_pct=$(format_pct "$free" "$total")
    temp=$(get_temperature || true)
    health=$(get_health || true)
    pct=$(get_percentage_used || true)
    spare=$(get_available_spare || true)
    critical=$(get_critical_warning || true)

    normal_est=$(estimate_profile_gib NORMAL "$total" "$free")
    secret_est=$(estimate_profile_gib SECRET "$total" "$free")
    paranoia_est=$(estimate_profile_gib PARANOIA "$total" "$free")

    recommendation="PARANOIA"
    reason="TRIM is available, free space is sufficient, and no obvious health warning is present"
    endurance="UNKNOWN"
    if [[ "$pct" =~ ^([0-9]+)%$ ]]; then
        endurance=$(endurance_status "${BASH_REMATCH[1]}")
    fi

    if [[ "$health" == "FAILED" ]]; then
        recommendation="STOP"
        reason="SMART reports FAILED"
    elif [[ "$critical" =~ ^[1-9][0-9]*$ ]]; then
        recommendation="STOP"
        reason="NVMe reports Critical Warning != 0"
    elif [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_HIGH )); then
        recommendation="NORMAL"
        reason="SSD starts at a critical temperature"
    elif [[ "$pct" =~ ^([0-9]+)%$ ]] && (( ${BASH_REMATCH[1]} >= 80 )); then
        recommendation="NORMAL"
        reason="high reported SSD endurance consumption"
    elif (( free < 40 * 1024 * 1024 * 1024 )); then
        recommendation="NORMAL"
        reason="little free space; free-space fill will be avoided"
    elif (( free < 120 * 1024 * 1024 * 1024 )); then
        recommendation="SECRET"
        reason="enough space for multiple runs, but limited reserve for maximum filling"
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
    echo "Temperature:        ${temp:-n/a} °C"
    echo "Health:             ${health:-n/a}"
    echo "Percentage Used:    ${pct:-n/a}"
    echo "Available Spare:    ${spare:-n/a}"
    echo "Critical Warning:   ${critical:-n/a}"
    echo
    echo "Estimated write load:"
    echo "  Normal:           ~${normal_est} GiB"
    echo "  Secret:           ~${secret_est} GiB"
    echo "  Paranoia:         ~${paranoia_est} GiB"
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
        echo "Endurance remaining:n/a"
    fi
    echo
    echo "Recommendation:     $recommendation"
    echo "Reason:              $reason"
    echo "--------------------------------------------------"
}

# ------------------------- Adaptive settings -----------------
adapt_settings() {
    local temp=$1 free=$2
    local base

    CPU_THREADS=$(nproc)
    if (( CPU_THREADS <= 4 )); then
        base=2
    elif (( CPU_THREADS <= 8 )); then
        base=4
    else
        base=6
    fi
    (( base > JPG_JOBS_MAX )) && base=$JPG_JOBS_MAX
    JPG_JOBS=$base
    RUN_COOLDOWN=$DEFAULT_COOLDOWN

    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        if (( temp >= TEMP_WARM )); then
            JPG_JOBS=1
            RUN_COOLDOWN=$HOT_COOLDOWN
        elif (( temp >= TEMP_NORMAL && JPG_JOBS > 2 )); then
            JPG_JOBS=2
            RUN_COOLDOWN=45
        fi
    fi

    # Limited free space -> reduce concurrency and never use fill.
    if (( free < 80 * 1024 * 1024 * 1024 )); then
        (( JPG_JOBS > 2 )) && JPG_JOBS=2
    fi
}

# ------------------------- System checks ----------------------
for cmd in bash magick fstrim findmnt lsblk df stat dd sync awk grep head tail sed sha256sum tee nproc; do
    require_cmd "$cmd"
done

command -v smartctl >/dev/null 2>&1 && SMARTCTL_AVAILABLE=1 || true
command -v nvme >/dev/null 2>&1 && NVME_AVAILABLE=1 || true

detect_system
prepare_output_names
safe_test_dir || { echo "Unsafe test path."; exit 1; }

if [[ -e "$RUN_DIR" ]]; then
    echo
    echo "$RUN_DIR already exists. Aborting for safety."
    echo "Check with: ls -lah \"$RUN_DIR\""
    exit 1
fi

# ------------------------- Initial warning --------------------
echo
echo "============================================================"
echo "               SSD RECOVERY RESISTANCE TEST"
echo "============================================================"
echo
echo "WARNING"
echo
echo "- Existing user files are not intentionally deleted."
echo "- Only script-generated test data is created and removed."
echo "- No Secure Erase / NVMe Sanitize / blkdiscard is used."
echo "- No method here can guarantee physical 100% erasure."
echo "- Secret/Paranoia generate substantial SSD write traffic."
echo
echo "Path:        $HOME"
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
    echo
    echo "============================================================"
    echo "TRIM NOT AVAILABLE – ABORTED"
    echo "============================================================"
    echo
    echo "$TRIM_DRY"
    exit 1
fi
echo "$TRIM_DRY"
echo "TRIM is available."

# Initial read-only metrics
START_FREE_BYTES=$(get_free_bytes)
START_HEALTH=$(get_health || true)
START_PERCENT_USED=$(get_percentage_used || true)
START_AVAILABLE_SPARE=$(get_available_spare || true)
START_CRITICAL_WARNING=$(get_critical_warning || true)
START_MEDIA_ERRORS=$(get_media_errors || true)
START_UNSAFE_SHUTDOWNS=$(get_unsafe_shutdowns || true)
START_POWER_CYCLES=$(get_power_cycles || true)
START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
monitor_ssd

TOTAL_BYTES_NOW=$(get_total_bytes)
calculate_reserve "$TOTAL_BYTES_NOW"

# ------------------------- Menu -------------------------------
while true; do
    run_analysis
    echo
    echo "[0] Run analysis again"
    echo "[1] Normal       – 1 run, low write load"
    echo "[2] Secret       – 5 runs, varied patterns + controlled free-space fill"
    echo "[3] Paranoia     – 10 runs, highest test workload + free-space fill"
    echo "[4] Use recommendation ($ANALYSIS_RECOMMENDATION)"
    echo "[5] Show analysis and exit"
    echo "[6] Abort"
    echo
    read -rp "Selection [0-6]: " choice

    case "$choice" in
        0) continue ;;
        1) LEVEL_NAME=NORMAL; TOTAL_RUNS=1; break ;;
        2) LEVEL_NAME=SECRET; TOTAL_RUNS=5; break ;;
        3) LEVEL_NAME=PARANOIA; TOTAL_RUNS=10; break ;;
        4)
            case "$ANALYSIS_RECOMMENDATION" in
                NORMAL) LEVEL_NAME=NORMAL; TOTAL_RUNS=1 ;;
                SECRET) LEVEL_NAME=SECRET; TOTAL_RUNS=5 ;;
                PARANOIA) LEVEL_NAME=PARANOIA; TOTAL_RUNS=10 ;;
                STOP) echo "The analysis recommends not starting the test."; exit 1 ;;
            esac
            break
            ;;
        5) echo "Analysis finished. No test data was written."; exit 0 ;;
        6) exit 0 ;;
        *) echo "Invalid selection." ;;
    esac
done

# ------------------------- Adaptive execution -----------------
FREE_BYTES=$(get_free_bytes)
if (( FREE_BYTES > RESERVE_BYTES )); then SAFE_FILL_BYTES=$((FREE_BYTES - RESERVE_BYTES)); else SAFE_FILL_BYTES=0; fi
TEMP_NOW=$(get_temperature || true)
adapt_settings "$TEMP_NOW" "$FREE_BYTES"

NORMAL_EST=$(estimate_profile_gib NORMAL "$TOTAL_BYTES_NOW" "$FREE_BYTES")
SECRET_EST=$(estimate_profile_gib SECRET "$TOTAL_BYTES_NOW" "$FREE_BYTES")
PARANOIA_EST=$(estimate_profile_gib PARANOIA "$TOTAL_BYTES_NOW" "$FREE_BYTES")
case "$LEVEL_NAME" in
    NORMAL) EXPECTED_WRITE_GIB=$NORMAL_EST ;;
    SECRET) EXPECTED_WRITE_GIB=$SECRET_EST ;;
    PARANOIA) EXPECTED_WRITE_GIB=$PARANOIA_EST ;;
esac

clear

echo "============================================================"
echo "                    EXECUTION PLAN"
echo "============================================================"
echo
echo "Level:               $LEVEL_NAME"
echo "Runs:                $TOTAL_RUNS"
echo "CPU Threads:         $CPU_THREADS"
echo "JPG workers:           $JPG_JOBS"
echo "SSD Temperature:       ${TEMP_NOW:-n/a} °C"
echo "Free space:           $(format_gib "$FREE_BYTES") GiB"
echo "Reserved free space:  $(format_gib "$RESERVE_BYTES") GiB"
echo "Safe temporary fill:  $(format_gib "$SAFE_FILL_BYTES") GiB"
echo "Estimated workload:    ~${EXPECTED_WRITE_GIB} GiB total"
echo "Run cooldown:         ${RUN_COOLDOWN}s"
echo
echo "Run directory:         $RUN_DIR"
echo
echo "Output files:"
echo "  $REPORT_FILE"
echo "  $MANIFEST_FILE"
echo "  $LOG_FILE"
echo

echo "Estimated workload:"
echo "  Per run base activity: ~35 GiB"
echo "  Total cumulative:      ~${EXPECTED_WRITE_GIB} GiB"
echo
echo "This is cumulative write activity, not the amount of free space"
echo "required at one time."
echo "Temporary free-space use is limited by the configured reserve."
echo

if [[ "$LEVEL_NAME" == "SECRET" || "$LEVEL_NAME" == "PARANOIA" ]]; then
    echo "Aggressive allocation mode can increase allocation turnover and runtime."
    echo "It uses smaller temporary fill chunks and more varied file allocation patterns."
    read -rp "Enable aggressive allocation mode? [y/N]: " AGG_CONFIRM
    case "$AGG_CONFIRM" in
        y|Y|j|J) AGGRESSIVE_ALLOC=1 ;;
        *) AGGRESSIVE_ALLOC=0 ;;
    esac
else
    AGGRESSIVE_ALLOC=0
fi

echo "The actual write test starts only after the final confirmation."
read -rp "Start? [y/N]: " confirm
[[ "$confirm" =~ ^[YyJj]$ ]] || exit 0

setup_logging
write_report_header
: > "$MANIFEST_FILE"
{
    echo "# SSD Remnant Wipe manifest"
    echo "# Created: $(date)"
    echo "# Level: $LEVEL_NAME"
    echo "# Recommendation: $ANALYSIS_RECOMMENDATION"
    echo "# Reason: $ANALYSIS_REASON"
    echo
} > "$MANIFEST_FILE"

echo
 echo "5-second countdown..."
for n in 5 4 3 2 1; do echo "$n"; sleep 1; done
echo "START"

# ------------------------- Allocation helpers -----------------
create_binary_test_file() {
    local path="$1"
    local size_mib="$2"
    local run="$3"
    local file_id="$4"
    local pattern="$5"

    case "$BINARY_MODE" in
        CONTIGUOUS)
            dd if=/dev/zero of="$path" bs=1M count="$size_mib" status=none
            ;;
        MIXED_SIZES)
            local first=$((size_mib / 2))
            local second=$((size_mib - first))
            dd if=/dev/zero of="$path" bs=1M count="$first" status=none
            dd if=/dev/zero of="$path" bs=256K seek=$((first * 4)) count=$((second * 4)) conv=notrunc status=none
            ;;
        FRAGMENTED)
            : > "$path"
            local offset=0
            local chunk=1
            while (( offset < size_mib )); do
                local take=$chunk
                (( offset + take > size_mib )) && take=$((size_mib - offset))
                dd if=/dev/zero of="$path" bs=1M seek="$offset" count="$take" conv=notrunc status=none
                offset=$((offset + take + 1))
                chunk=$((chunk % 4 + 1))
            done
            ;;
        *)
            dd if=/dev/zero of="$path" bs=1M count="$size_mib" status=none
            ;;
    esac

    printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=%s | PATTERN=%s | FS=%s | ALLOC=%s\n' \
        "$LEVEL_NAME" "$run" "$file_id" "$pattern" "$FILESYSTEM_PROFILE" "$BINARY_MODE" \
        | dd of="$path" bs=1 conv=notrunc status=none
}

# ------------------------- JPG worker ------------------------
create_jpg() {
    local i="$1" run="$2" quality="$3" pattern="$4"
    local file_id output
    file_id=$(printf '%04d' "$i")
    output="$TEST_DIR/file-$i.jpg"

    magick \
        -size 3840x2160 \
        xc:gray \
        -seed "$((run * 100000 + i))" \
        -attenuate 0.8 \
        +noise Random \
        -gravity center \
        -fill white \
        -stroke black \
        -strokewidth 3 \
        -pointsize 72 \
        -annotate 0 "WIPE-TEST\nLEVEL: $LEVEL_NAME\nRUN: $run\nFILE: $file_id\nPATTERN: $pattern" \
        -quality "$quality" \
        "$output"
}

export -f create_jpg
export TEST_DIR LEVEL_NAME

# ------------------------- Main runs --------------------------
for run in $(seq 1 "$TOTAL_RUNS"); do
    RUN_START=$(date +%s)
    PER_RUN_START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    PER_RUN_HOST_WRITE_DELTA=""
    mkdir -p "$TEST_DIR"

    FREE_BYTES=$(get_free_bytes)
    if (( FREE_BYTES > RESERVE_BYTES )); then SAFE_FILL_BYTES=$((FREE_BYTES - RESERVE_BYTES)); else SAFE_FILL_BYTES=0; fi

    # Pattern per profile/run
    case "$LEVEL_NAME" in
        NORMAL)
            HTML_TARGET=$HTML_BASE_SIZE
            TXT_TARGET=$TXT_BASE_SIZE
            JPG_QUALITY=92
            PATTERN=NORMAL
            ;;
        SECRET)
            case $((run % 3)) in
                1) HTML_TARGET=$((2*1024*1024)); TXT_TARGET=$((2*1024*1024)); JPG_QUALITY=92; PATTERN=MIXED ;;
                2) HTML_TARGET=$((3*1024*1024)); TXT_TARGET=$((3*1024*1024)); JPG_QUALITY=94; PATTERN=RANDOM ;;
                0) HTML_TARGET=$((4*1024*1024)); TXT_TARGET=$((4*1024*1024)); JPG_QUALITY=90; PATTERN=LARGE ;;
            esac
            ;;
        PARANOIA)
            case $((run % 4)) in
                1) HTML_TARGET=$((2*1024*1024)); TXT_TARGET=$((2*1024*1024)); JPG_QUALITY=90; PATTERN=RANDOM ;;
                2) HTML_TARGET=$((3*1024*1024)); TXT_TARGET=$((4*1024*1024)); JPG_QUALITY=92; PATTERN=MIXED ;;
                3) HTML_TARGET=$((5*1024*1024)); TXT_TARGET=$((3*1024*1024)); JPG_QUALITY=95; PATTERN=HIGH ;;
                0) HTML_TARGET=$((4*1024*1024)); TXT_TARGET=$((5*1024*1024)); JPG_QUALITY=88; PATTERN=LARGE ;;
            esac
            ;;
    esac

    case "$FILESYSTEM_PROFILE" in
        EXT4)
            ALLOC_PATTERN="EXT4_EXTENTS"
            BINARY_MODE="CONTIGUOUS"
            ;;
        BTRFS)
            ALLOC_PATTERN="BTRFS_MIXED"
            BINARY_MODE="MIXED_SIZES"
            ;;
        XFS)
            ALLOC_PATTERN="XFS_EXTENTS"
            BINARY_MODE="CONTIGUOUS"
            ;;
        F2FS)
            ALLOC_PATTERN="F2FS_STREAM"
            BINARY_MODE="MIXED_SIZES"
            ;;
        *)
            ALLOC_PATTERN="GENERIC"
            BINARY_MODE="CONTIGUOUS"
            ;;
    esac

    if (( AGGRESSIVE_ALLOC == 1 )); then
        case $((run % 3)) in
            1) BINARY_MODE="FRAGMENTED"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_FRAGMENTED" ;;
            2) BINARY_MODE="MIXED_SIZES"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_MIXED" ;;
            0) BINARY_MODE="CONTIGUOUS"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_CONTIGUOUS" ;;
        esac
    elif (( run % 3 == 2 )); then
        BINARY_MODE="MIXED_SIZES"
        ALLOC_PATTERN="${FILESYSTEM_PROFILE}_MIXED"
    elif (( run % 3 == 0 )); then
        BINARY_MODE="CONTIGUOUS"
        ALLOC_PATTERN="${FILESYSTEM_PROFILE}_CONTIGUOUS"
    fi

    # Re-adapt concurrency on every run based on current temperature.
    TEMP_NOW=$(get_temperature || true)
    adapt_settings "$TEMP_NOW" "$FREE_BYTES"

    echo
    echo "============================================================"
    echo "RUN $run / $TOTAL_RUNS | $LEVEL_NAME | $PATTERN"
    echo "============================================================"
    echo "Filesystem profile: $FILESYSTEM_PROFILE | Allocation: $ALLOC_PATTERN"
    echo "HTML: ~$((HTML_TARGET/1024/1024)) MiB | TXT: ~$((TXT_TARGET/1024/1024)) MiB | JPG target: ~10 MiB"
    echo "JPG workers: $JPG_JOBS | Cooldown: ${RUN_COOLDOWN}s | Aggressive allocation: $([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo ON || echo OFF)"
    monitor_ssd

    FILE_START=$(date +%s)

    # 1. HTML + TXT
    echo
    echo "[1/9] Creating 1000 HTML + 1000 TXT files..."
    for i in $(seq 1 1000); do
        FILE_ID=$(printf '%04d' "$i")
        UNIQUE_ID="WIPE-TEST-${LEVEL_NAME}-RUN-$(printf '%02d' "$run")-FILE-${FILE_ID}"

        {
            echo '<!DOCTYPE html>'
            echo '<html lang="en"><head><meta charset="UTF-8">'
            echo "<title>$UNIQUE_ID</title></head><body>"
            echo '<h1>WIPE-TEST</h1>'
            echo "<p>LEVEL: $LEVEL_NAME</p>"
            echo "<p>RUN: $run</p>"
            echo "<p>FILE: $FILE_ID</p>"
            echo "<p>PATTERN: $PATTERN</p>"
            echo "<p>UNIQUE-ID: $UNIQUE_ID</p>"
        } > "$TEST_DIR/file-$i.html"
        current_size=$(stat -c%s "$TEST_DIR/file-$i.html")
        remaining=$((HTML_TARGET - current_size))
        (( remaining > 0 )) && head -c "$remaining" /dev/urandom >> "$TEST_DIR/file-$i.html"
        echo '</body></html>' >> "$TEST_DIR/file-$i.html"

        {
            echo '============================================================'
            echo 'WIPE-TEST'
            echo '============================================================'
            echo "LEVEL:      $LEVEL_NAME"
            echo "RUN:        $run"
            echo "FILE:       $FILE_ID"
            echo "PATTERN:    $PATTERN"
            echo "UNIQUE-ID:  $UNIQUE_ID"
            echo
            echo 'This is synthetic test content.'
        } > "$TEST_DIR/file-$i.txt"
        current_size=$(stat -c%s "$TEST_DIR/file-$i.txt")
        remaining=$((TXT_TARGET - current_size))
        (( remaining > 0 )) && head -c "$remaining" /dev/urandom >> "$TEST_DIR/file-$i.txt"

        if (( i % 250 == 0 )); then
            echo "    -> $i / 1000 HTML/TXT"
            monitor_ssd
        fi
    done
    monitor_ssd 1
    add_written $((1000 * (HTML_TARGET + TXT_TARGET)))

    # 2. JPG
    echo
    echo "[2/9] Creating 1000 JPG files with $JPG_JOBS workers..."
    active=0
    completed=0
    for i in $(seq 1 1000); do
        create_jpg "$i" "$run" "$JPG_QUALITY" "$PATTERN" &
        ((active++)) || true
        if (( active >= JPG_JOBS )); then
            wait -n
            ((active--)) || true
            ((completed++)) || true
            if (( completed % 100 == 0 )); then
                show_progress "$completed" 1000 "$FILE_START" "$run"
                monitor_ssd
            fi
        fi
    done
    while (( active > 0 )); do
        wait -n
        ((active--)) || true
        ((completed++)) || true
        if (( completed % 100 == 0 || completed == 1000 )); then
            show_progress "$completed" 1000 "$FILE_START" "$run"
            monitor_ssd
        fi
    done
    echo
    echo "    -> 1000 JPG files complete."
    monitor_ssd 1
    add_written "$JPG_TARGET_BYTES" # nominal estimate only

    echo "    -> Creating SHA-256 manifest..."
    for f in "$TEST_DIR"/*.html "$TEST_DIR"/*.txt "$TEST_DIR"/*.jpg; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        case "$base" in
            *.html) type=HTML ;;
            *.txt)  type=TXT ;;
            *.jpg)  type=JPG ;;
            *) continue ;;
        esac
        file_num=${base##*-}
        file_num=${file_num%%.*}
        manifest_file "$f" "$type" "$run" "$file_num" "$PATTERN"
    done

    echo "    Test data:"
    du -sh "$TEST_DIR"

    # 3. Sync
    echo
    echo "[3/9] sync"
    sync
    monitor_ssd 1

    # 4. Delete test files
    echo
    echo "[4/9] Deleting HTML + TXT + JPG files..."
    rm -f -- "$TEST_DIR"/*.html "$TEST_DIR"/*.txt "$TEST_DIR"/*.jpg
    echo "    -> Test files deleted."

    # 5. TRIM
    echo
    echo "[5/9] TRIM"
    record_trim
    monitor_ssd 1

    # 6. Large file
    echo
    echo "[6/9] Creating 10-GiB test file..."
    mkdir -p "$TEST_DIR"
    dd if=/dev/zero of="$TEST_DIR/large.bin" bs=1M count=10240 status=progress
    printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=LARGE | PATTERN=%s\n' "$LEVEL_NAME" "$run" "$PATTERN" |
        dd of="$TEST_DIR/large.bin" bs=1 conv=notrunc status=none
    add_written $((10 * 1024 * 1024 * 1024))
    manifest_file "$TEST_DIR/large.bin" "LARGE" "$run" "LARGE" "$PATTERN"
    sync
    rm -f -- "$TEST_DIR/large.bin"
    record_trim
    monitor_ssd 1

    # 7. 1000 x 10 MiB
    echo
    echo "[7/9] Creating 1000 x 10-MiB files..."
    BINARY_START=$(date +%s)
    for i in $(seq 1 1000); do
        create_binary_test_file "$TEST_DIR/file-$i.bin" 10 "$run" "$(printf '%04d' "$i")" "$PATTERN"
        if (( i % 100 == 0 )); then
            show_progress "$i" 1000 "$BINARY_START" "$run"
            monitor_ssd
        fi
    done
    monitor_ssd 1
    add_written $((1000 * 10 * 1024 * 1024))
    echo
    echo "    -> Creating binary manifest..."
    for f in "$TEST_DIR"/*.bin; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        if [[ "$base" == "large.bin" ]]; then
            continue
        fi
        file_num=${base#file-}
        file_num=${file_num%.bin}
        manifest_file "$f" "BIN" "$run" "$file_num" "$PATTERN"
    done
    sync
    rm -rf -- "$TEST_DIR"

    # 8. Adaptive free-space fill
    echo
    echo "[8/9] Controlled free-space fill..."
    FILL_THIS_RUN=0
    DO_FILL=0
    FILL_FRACTION=1
    FILL_SOURCE="/dev/zero"
    FILL_PATTERN="ZERO"

    case "$LEVEL_NAME" in
        NORMAL)
            DO_FILL=0
            ;;
        SECRET)
            # One 50% fill on the final run.
            if (( run == TOTAL_RUNS )); then
                DO_FILL=1
                FILL_FRACTION=2
            fi
            ;;
        PARANOIA)
            # Three smaller fills instead of repeatedly filling the whole
            # safe free-space range:
            # 25% on run 1, 25% in the middle, 50% on the final run.
            #
            # The other test phases already create varied/randomized data.
            # This phase mainly tests allocation, reuse and TRIM behavior,
            # so zeroes are used for speed.
            if (( run == 1 )); then
                DO_FILL=1
                FILL_FRACTION=4
            elif (( run == (TOTAL_RUNS + 1) / 2 )); then
                DO_FILL=1
                FILL_FRACTION=4
            elif (( run == TOTAL_RUNS )); then
                DO_FILL=1
                FILL_FRACTION=2
            fi
            ;;
    esac

    if (( DO_FILL == 0 )); then

        echo "    -> Disabled for this run."

    else

        FREE_BYTES_NOW=$(get_free_bytes)

        if (( FREE_BYTES_NOW > RESERVE_BYTES )); then
            SAFE_FILL_BYTES_NOW=$((FREE_BYTES_NOW - RESERVE_BYTES))
        else
            SAFE_FILL_BYTES_NOW=0
        fi

        FILL_BYTES=$((SAFE_FILL_BYTES_NOW / FILL_FRACTION))

        echo "    -> Pattern:             $FILL_PATTERN"
        echo "    -> Target:              $(format_gib "$FILL_BYTES") GiB"
        echo "    -> Free before fill:    $(format_gib "$FREE_BYTES_NOW") GiB"
        echo "    -> Reserved space:      $(format_gib "$RESERVE_BYTES") GiB"
        echo "    -> Temporary fill only; files are deleted afterwards."

        if (( FILL_BYTES <= 0 )); then

            echo "    -> No safe fill area available."

        else

            mkdir -p "$TEST_DIR"

            if (( AGGRESSIVE_ALLOC == 1 )); then
                FILL_CHUNK=$((256 * 1024 * 1024))
            else
                FILL_CHUNK=$((1024 * 1024 * 1024))
            fi

            CHUNK=$FILL_CHUNK
            INDEX=0

            while (( FILL_THIS_RUN + CHUNK <= FILL_BYTES )); do

                CURRENT_FREE=$(get_free_bytes)

                if (( CURRENT_FREE <= RESERVE_BYTES )); then
                    echo "    -> Safety reserve reached."
                    break
                fi

                REMAINING_SAFE=$((CURRENT_FREE - RESERVE_BYTES))

                if (( REMAINING_SAFE < CHUNK )); then
                    echo "    -> Less than 1 GiB remains above the reserve."
                    break
                fi

                INDEX=$((INDEX + 1))
                NEXT_FILE="$TEST_DIR/fill-$INDEX.bin"

                echo
                echo "    -> Fill block $INDEX | free: $(format_gib "$CURRENT_FREE") GiB"

                BLOCKS=$((CHUNK / (64 * 1024 * 1024)))
                dd \
                    if="$FILL_SOURCE" \
                    of="$NEXT_FILE" \
                    bs=64M \
                    count="$BLOCKS" \
                    status=progress

                printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=FILL-%03d | PATTERN=%s | FS=%s | ALLOC=%s\n' \
                    "$LEVEL_NAME" "$run" "$INDEX" "$FILL_PATTERN" "$FILESYSTEM_PROFILE" "$ALLOC_PATTERN" | \
                    dd of="$NEXT_FILE" bs=1 conv=notrunc status=none

                add_written "$CHUNK"
                FILL_THIS_RUN=$((FILL_THIS_RUN + CHUNK))

                manifest_file                     "$NEXT_FILE"                     "FILL"                     "$run"                     "FILL-$INDEX"                     "$FILL_PATTERN"

                monitor_ssd

            done

            sync

            echo
            echo "    -> Fill written: $(format_gib "$FILL_THIS_RUN") GiB"
            monitor_ssd 1

            rm -f -- "$TEST_DIR"/fill-*.bin

            echo "    -> Fill files deleted."

        fi
    fi

    # 9. Final TRIM
    echo
    echo "[9/9] Final TRIM"
    record_trim
    monitor_ssd 1

    # Run report
    RUN_END=$(date +%s)
    RUN_TIME=$((RUN_END - RUN_START))
    TOTAL_ELAPSED=$((RUN_END - SCRIPT_START))
    EST_TOTAL=$((TOTAL_ELAPSED * TOTAL_RUNS / run))
    EST_REMAINING=$((EST_TOTAL - TOTAL_ELAPSED))
    CURRENT_FREE=$(get_free_bytes)
    PER_RUN_END_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    if [[ "$PER_RUN_START_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" -ge "$PER_RUN_START_DATA_WRITTEN_BYTES" ]]; then
        PER_RUN_HOST_WRITE_DELTA=$((PER_RUN_END_DATA_WRITTEN_BYTES - PER_RUN_START_DATA_WRITTEN_BYTES))
    else
        PER_RUN_HOST_WRITE_DELTA=""
    fi

    {
        echo
        echo "------------------------------------------------------------"
        echo "RUN $run / $TOTAL_RUNS"
        echo "------------------------------------------------------------"
        echo "Level:            $LEVEL_NAME"
        echo "Pattern:          $PATTERN"
        echo "Filesystem:       $FILESYSTEM_PROFILE"
        echo "Allocation:       $ALLOC_PATTERN"
        echo "Aggressive alloc: $([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo ON || echo OFF)"
        echo "Run duration:      $(format_time "$RUN_TIME")"
        echo "Free space:        $(format_gib "$CURRENT_FREE") GiB"
        echo "Free-Fill:        $(format_gib "$FILL_THIS_RUN") GiB"
        echo "JPG-Worker:       $JPG_JOBS"
        echo "Run cooldown:     ${RUN_COOLDOWN}s"
        echo "Max temperature:   ${MAX_TEMP:-n/a} °C"
        echo "Nominal total:     $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
        if [[ -n "$PER_RUN_HOST_WRITE_DELTA" ]]; then
            echo "NVMe host-write delta: $(format_gib "$PER_RUN_HOST_WRITE_DELTA") GiB"
        else
            echo "NVMe host-write delta: unavailable"
        fi
    } >> "$REPORT_FILE"

    echo
    echo "RUN $run / $TOTAL_RUNS complete"
    echo "  Duration:     $(format_time "$RUN_TIME")"
    echo "  Remaining:    $(format_time "$EST_REMAINING")"
    echo "  Free space:   $(format_gib "$CURRENT_FREE") GiB"
    echo "  Max temp:     ${MAX_TEMP:-n/a} °C"
    echo "  Nominal total: $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    if [[ -n "$PER_RUN_HOST_WRITE_DELTA" ]]; then
        echo "  NVMe host-write delta: $(format_gib "$PER_RUN_HOST_WRITE_DELTA") GiB"
    else
        echo "  NVMe host-write delta: unavailable"
    fi

    if (( run < TOTAL_RUNS )); then
        echo
        echo "Cooldown: ${RUN_COOLDOWN}s"
        sleep "$RUN_COOLDOWN"
    fi
done

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
    if (( END_DATA_WRITTEN_BYTES >= START_DATA_WRITTEN_BYTES )); then
        HOST_WRITE_DELTA=$((END_DATA_WRITTEN_BYTES - START_DATA_WRITTEN_BYTES))
    fi
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
    echo "Post-TRIM idle:           ${POST_TRIM_IDLE}s"
    echo "Total duration:            $(format_time "$TOTAL_TIME")"
    echo "Nominal data written:     $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    if [[ -n "$HOST_WRITE_DELTA" ]]; then
        echo "Controller host writes:   $(format_gib "$HOST_WRITE_DELTA") GiB"
    else
        echo "Controller host writes:   unavailable"
    fi
    echo "Max temperature:          ${MAX_TEMP:-n/a} °C"
    echo "TRIM operations:          $TRIM_COUNT"
    echo "TRIM bytes reported:      $TRIM_BYTES_APPROX"
    echo
    echo "Free space at start:      $(format_gib "$START_FREE_BYTES") GiB"
    echo "Free space at end:        $(format_gib "$END_FREE_BYTES") GiB"
    echo
    echo "SMART/NVMe at start:"
    echo "  Temperature:             ${START_TEMP:-n/a} °C"
    echo "  Health:                 ${START_HEALTH:-n/a}"
    echo "  Percentage Used:        ${START_PERCENT_USED:-n/a}"
    echo "  Available Spare:        ${START_AVAILABLE_SPARE:-n/a}"
    echo "  Critical Warning:       ${START_CRITICAL_WARNING:-n/a}"
    echo "  Media Errors:           ${START_MEDIA_ERRORS:-n/a}"
    echo "  Unsafe Shutdowns:       ${START_UNSAFE_SHUTDOWNS:-n/a}"
    echo "  Power Cycles:           ${START_POWER_CYCLES:-n/a}"
    echo "  Data Units Written:     ${START_DATA_WRITTEN_BYTES:-n/a} bytes"
    echo
    echo "SMART/NVMe at end:"
    echo "  Temperature:             ${END_TEMP:-n/a} °C"
    echo "  Health:                 ${END_HEALTH:-n/a}"
    echo "  Percentage Used:        ${END_PERCENT_USED:-n/a}"
    echo "  Available Spare:        ${END_AVAILABLE_SPARE:-n/a}"
    echo "  Critical Warning:       ${END_CRITICAL_WARNING:-n/a}"
    echo "  Media Errors:           ${END_MEDIA_ERRORS:-n/a}"
    echo "  Unsafe Shutdowns:       ${END_UNSAFE_SHUTDOWNS:-n/a}"
    echo "  Power Cycles:           ${END_POWER_CYCLES:-n/a}"
    echo "  Data Units Written:     ${END_DATA_WRITTEN_BYTES:-n/a} bytes"
    echo
    echo "Files:"
    echo "  Report:                 $REPORT_FILE"
    echo "  Manifest:               $MANIFEST_FILE"
    echo "  Log:                    $LOG_FILE"
    echo
    echo "============================================================"
} | tee -a "$REPORT_FILE"

echo
echo "DONE."
echo "Report:   $REPORT_FILE"
echo "Manifest: $MANIFEST_FILE"
echo "Log:      $LOG_FILE"
