#!/usr/bin/env bash
set -Eeuo pipefail

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
TEST_DIR="$HOME/Documents/wipe-test"
REPORT_PREFIX="$HOME/ssd-remnant-wipe"

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

MAX_TOTAL_WRITE_GIB=500

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

LOG_FILE=""
REPORT_FILE=""
MANIFEST_FILE=""
OUTPUT_STAMP=""

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
    [[ "$TEST_DIR" == "$HOME/Documents/wipe-test" ]] || return 1
    [[ "$TEST_DIR" != "$HOME" ]] || return 1
    [[ "$TEST_DIR" != "/" ]] || return 1
    [[ "$TEST_DIR" != "$HOME/Documents" ]] || return 1
    return 0
}

cleanup() {
    if safe_test_dir && [[ -d "$TEST_DIR" ]]; then
        echo
        echo "Cleanup: Entferne ausschließlich den eigenen Testordner..."
        rm -rf -- "$TEST_DIR"
        echo "Cleanup abgeschlossen."
    fi
}

handle_interrupt() {
    trap - INT TERM
    echo
    echo
    echo "============================================================"
    echo "ABBRUCH ANGEFORDERT"
    echo "============================================================"
    cleanup
    if [[ -n "$LOG_FILE" ]]; then
        echo "Abbruch: $(date)" >> "$LOG_FILE"
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
    LOG_FILE="${REPORT_PREFIX}-${OUTPUT_STAMP}.log"
    REPORT_FILE="${REPORT_PREFIX}-${OUTPUT_STAMP}-report.txt"
    MANIFEST_FILE="${REPORT_PREFIX}-${OUTPUT_STAMP}-manifest.txt"
}

setup_logging() {
    prepare_output_names
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ------------------------- Device detection ------------------
detect_system() {
    local mount_info parent_device

    mount_info=$(findmnt -T "$HOME" -no TARGET,SOURCE,FSTYPE 2>/dev/null || true)
    [[ -n "$mount_info" ]] || {
        echo "Konnte das Dateisystem von $HOME nicht bestimmen."
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
        echo "HOCH"
    else
        echo "KRITISCH"
    fi
}

monitor_ssd() {
    local temp health pct spare critical written media unsafe power status

    temp=$(get_temperature || true)
    health=$(get_health || true)
    pct=$(get_percentage_used || true)
    spare=$(get_available_spare || true)
    critical=$(get_critical_warning || true)
    written=$(get_data_written_units || true)
    media=$(get_media_errors || true)
    unsafe=$(get_unsafe_shutdowns || true)
    power=$(get_power_cycles || true)

    if [[ -n "$temp" ]]; then
        if (( temp > MAX_TEMP )); then MAX_TEMP="$temp"; fi
        status=$(status_for_temperature "$temp")
        echo "    SSD: ${temp} °C [$status] | Health: ${health:-n/a} | Used: ${pct:-n/a} | Spare: ${spare:-n/a}"
        echo "    NVMe: Critical Warning=${critical:-n/a} | Data Units Written=${written:-n/a} | Media Errors=${media:-n/a} | Unsafe Shutdowns=${unsafe:-n/a} | Power Cycles=${power:-n/a}"

        if [[ -z "$START_TEMP" ]]; then
            START_TEMP="$temp"
            START_HEALTH="$health"
            START_PERCENT_USED="$pct"
            START_AVAILABLE_SPARE="$spare"
            START_CRITICAL_WARNING="$critical"
            START_MEDIA_ERRORS="$media"
            START_UNSAFE_SHUTDOWNS="$unsafe"
            START_POWER_CYCLES="$power"
            START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
        fi

        END_TEMP="$temp"
        END_HEALTH="$health"
        END_PERCENT_USED="$pct"
        END_AVAILABLE_SPARE="$spare"
        END_CRITICAL_WARNING="$critical"
        END_MEDIA_ERRORS="$media"
        END_UNSAFE_SHUTDOWNS="$unsafe"
        END_POWER_CYCLES="$power"
        END_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)

        if (( temp > TEMP_HIGH )); then
            echo
            echo "    !!! KRITISCHE SSD-TEMPERATUR !!!"
            echo "    Schreibvorgang pausiert. Warte auf <= ${TEMP_RESUME} °C ..."
            while true; do
                sleep 10
                temp=$(get_temperature || true)
                [[ -n "$temp" ]] || continue
                if (( temp > MAX_TEMP )); then MAX_TEMP="$temp"; fi
                echo "    aktuell: ${temp} °C"
                if (( temp <= TEMP_RESUME )); then break; fi
            done
            echo "    Temperatur wieder im sicheren Bereich."
        fi
    else
        echo "    SSD-Temperatur: nicht verfügbar"
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
        echo "TRIM fehlgeschlagen. Abbruch."
        exit 1
    fi
    echo "$out"
    TRIM_COUNT=$((TRIM_COUNT + 1))

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

    printf "\r    -> %4d / %4d | vergangen %s | Rest %s | Gesamt-Rest %s" \
        "$current" "$total" "$(format_time "$elapsed")" "$(format_time "$remaining")" "$(format_time "$total_remaining")"
}

# ------------------------- Manifest / Report -----------------
manifest_file() {
    local path="$1" type="$2" run="$3" file="$4" pattern="$5"
    local size hash
    size=$(stat -c%s "$path")
    hash=$(sha256sum "$path" | awk '{print $1}')
    printf 'TYPE=%s\tLEVEL=%s\tRUN=%02d\tFILE=%s\tPATTERN=%s\tSIZE=%s\tSHA256=%s\tPATH=%s\n' \
        "$type" "$LEVEL_NAME" "$run" "$file" "$pattern" "$size" "$hash" "$path" >> "$MANIFEST_FILE"
}

write_report_header() {
    {
        echo "============================================================"
        echo "SSD REMNANT WIPE REPORT"
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
        echo "Recommendation:$ANALYSIS_RECOMMENDATION"
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
        NORMAL) echo 35 ;;
        SECRET) echo $((35 * 5 + safe / 2 / 1024 / 1024 / 1024)) ;;
        PARANOIA) echo $((35 * 10 + safe / 1024 / 1024 / 1024)) ;;
    esac
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
    reason="TRIM verfügbar, ausreichend freier Speicher und keine offensichtliche Gesundheitswarnung"

    if [[ "$health" == "FAILED" ]]; then
        recommendation="STOP"
        reason="SMART meldet FAILED"
    elif [[ "$critical" =~ ^[1-9][0-9]*$ ]]; then
        recommendation="STOP"
        reason="NVMe meldet Critical Warning != 0"
    elif [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_HIGH )); then
        recommendation="NORMAL"
        reason="SSD startet bereits mit kritischer Temperatur"
    elif [[ "$pct" =~ ^([0-9]+)%$ ]] && (( ${BASH_REMATCH[1]} >= 80 )); then
        recommendation="NORMAL"
        reason="hoher gemeldeter SSD-Verschleiß"
    elif (( free < 40 * 1024 * 1024 * 1024 )); then
        recommendation="NORMAL"
        reason="wenig freier Speicher; Free-Space-Fill wird vermieden"
    elif (( free < 120 * 1024 * 1024 * 1024 )); then
        recommendation="SECRET"
        reason="ausreichend Platz für mehrere Runs, aber wenig Reserve für maximale Füllung"
    fi

    ANALYSIS_RECOMMENDATION="$recommendation"
    ANALYSIS_REASON="$reason"

    echo
    echo "---------------- SYSTEM-ANALYSE ----------------"
    echo "SSD:                $(lsblk -dno MODEL "$ROOT_DEVICE" 2>/dev/null || echo unknown)"
    echo "Transport:          ${TRANSPORT:-unknown}"
    echo "Filesystem:         $HOME_FS"
    echo "Mountpoint:         $HOME_TARGET"
    echo "TRIM:               verfügbar"
    echo "Free space:         $(format_gib "$free") GiB (${free_pct}%)"
    echo "Temperature:        ${temp:-n/a} °C"
    echo "Health:             ${health:-n/a}"
    echo "Percentage Used:    ${pct:-n/a}"
    echo "Available Spare:    ${spare:-n/a}"
    echo "Critical Warning:   ${critical:-n/a}"
    echo
    echo "Geschätzte Schreiblast:"
    echo "  Normal:           ~${normal_est} GiB"
    echo "  Secret:           ~${secret_est} GiB"
    echo "  Paranoia:         ~${paranoia_est} GiB"
    echo
    echo "EMPFEHLUNG:         $recommendation"
    echo "GRUND:              $reason"
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
safe_test_dir || { echo "Unsicherer Testpfad."; exit 1; }

if [[ -e "$TEST_DIR" ]]; then
    echo
    echo "$TEST_DIR existiert bereits. Aus Sicherheitsgründen wird abgebrochen."
    echo "Prüfen mit: ls -lah \"$TEST_DIR\""
    exit 1
fi

# ------------------------- Initial warning --------------------
echo
echo "============================================================"
echo "                    SSD REMNANT WIPE"
echo "============================================================"
echo
echo "WARNUNG"
echo
echo "- Bestehende Nutzdateien werden nicht gezielt gelöscht."
echo "- Nur eigene Testdaten werden erzeugt und entfernt."
echo "- Kein Secure Erase / NVMe Sanitize / blkdiscard."
echo "- Das Verfahren kann keine physische 100%-Garantie geben."
echo "- Secret/Paranoia erzeugen erhebliche SSD-Schreiblast."
echo
echo "Pfad:        $HOME"
echo "Mountpoint:  $HOME_TARGET"
echo "Quelle:      $HOME_SOURCE"
echo "Filesystem:  $HOME_FS"
echo "Transport:   ${TRANSPORT:-unknown}"
echo
echo "Discard-Fähigkeit:"
lsblk -o NAME,MODEL,TRAN,SIZE,DISC-GRAN,DISC-MAX "$ROOT_DEVICE" 2>/dev/null || true

echo
echo "TRIM-Prüfung..."
if ! TRIM_DRY=$(trim_dry_run 2>&1); then
    echo
    echo "============================================================"
    echo "TRIM NICHT VERFÜGBAR – ABGEBROCHEN"
    echo "============================================================"
    echo
    echo "$TRIM_DRY"
    exit 1
fi
echo "$TRIM_DRY"
echo "TRIM ist verfügbar."

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
    echo "[0] Analyse erneut"
    echo "[1] Normal       – 1 Run, geringe Schreiblast"
    echo "[2] Secret       – 5 Runs, wechselnde Muster + kontrolliertes Füllen"
    echo "[3] Paranoia     – 10 Runs, maximale Testlast + Füllen"
    echo "[4] Empfehlung übernehmen ($ANALYSIS_RECOMMENDATION)"
    echo "[5] Analyse anzeigen und beenden"
    echo "[6] Abbrechen"
    echo
    read -rp "Auswahl [0-6]: " choice

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
                STOP) echo "Die Analyse empfiehlt, nicht zu starten."; exit 1 ;;
            esac
            break
            ;;
        5) echo "Analyse beendet. Keine Testdaten geschrieben."; exit 0 ;;
        6) exit 0 ;;
        *) echo "Ungültige Auswahl." ;;
    esac
done

# ------------------------- Adaptive execution -----------------
prepare_output_names
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
echo "                    AUSFÜHRUNGSPLAN"
echo "============================================================"
echo
echo "Level:               $LEVEL_NAME"
echo "Runs:                $TOTAL_RUNS"
echo "CPU Threads:         $CPU_THREADS"
echo "JPG Worker:           $JPG_JOBS"
echo "SSD Temperatur:       ${TEMP_NOW:-n/a} °C"
echo "Freier Speicher:      $(format_gib "$FREE_BYTES") GiB"
echo "Reserve:              $(format_gib "$RESERVE_BYTES") GiB"
echo "Sicherer Free-Fill:   $(format_gib "$SAFE_FILL_BYTES") GiB"
echo "Geschätzte Last:      ~${EXPECTED_WRITE_GIB} GiB"
echo "Run-Cooldown:         ${RUN_COOLDOWN}s"
echo
echo "Reports werden gespeichert als:"
echo "  $REPORT_FILE"
echo "  $MANIFEST_FILE"
echo "  $LOG_FILE"
echo

if (( EXPECTED_WRITE_GIB > MAX_TOTAL_WRITE_GIB )); then
    echo "WARNUNG: Die geschätzte Schreiblast überschreitet ${MAX_TOTAL_WRITE_GIB} GiB."
    echo "Dieses Limit ist nur ein Sicherheitspuffer, kein SSD-Limit."
    echo
    read -rp "Trotzdem fortfahren? [y/N]: " budget_confirm
    [[ "$budget_confirm" =~ ^[YyJj]$ ]] || exit 0
fi

echo "Der eigentliche Test beginnt erst nach der letzten Bestätigung."
read -rp "Starten? [y/N]: " confirm
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
 echo "5-Sekunden-Countdown..."
for n in 5 4 3 2 1; do echo "$n"; sleep 1; done
echo "START"

echo "Erstes TRIM vor Testbeginn:"
record_trim

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

    # Re-adapt concurrency on every run based on current temperature.
    TEMP_NOW=$(get_temperature || true)
    adapt_settings "$TEMP_NOW" "$FREE_BYTES"

    echo
    echo "============================================================"
    echo "RUN $run / $TOTAL_RUNS | $LEVEL_NAME | $PATTERN"
    echo "============================================================"
    echo "HTML: ~$((HTML_TARGET/1024/1024)) MiB | TXT: ~$((TXT_TARGET/1024/1024)) MiB | JPG target: ~10 MiB"
    echo "JPG Worker: $JPG_JOBS | Cooldown: ${RUN_COOLDOWN}s"
    monitor_ssd

    FILE_START=$(date +%s)

    # 1. HTML + TXT
    echo
    echo "[1/9] Erstelle 1000 HTML + 1000 TXT..."
    for i in $(seq 1 1000); do
        FILE_ID=$(printf '%04d' "$i")
        UNIQUE_ID="WIPE-TEST-${LEVEL_NAME}-RUN-$(printf '%02d' "$run")-FILE-${FILE_ID}"

        {
            echo '<!DOCTYPE html>'
            echo '<html lang="de"><head><meta charset="UTF-8">'
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
            echo 'Dies ist künstlich erzeugter Testinhalt.'
        } > "$TEST_DIR/file-$i.txt"
        current_size=$(stat -c%s "$TEST_DIR/file-$i.txt")
        remaining=$((TXT_TARGET - current_size))
        (( remaining > 0 )) && head -c "$remaining" /dev/urandom >> "$TEST_DIR/file-$i.txt"

        if (( i % 100 == 0 )); then
            echo "    -> $i / 1000 HTML/TXT"
            monitor_ssd
        fi
    done
    add_written $((1000 * (HTML_TARGET + TXT_TARGET)))

    # 2. JPG
    echo
    echo "[2/9] Erstelle 1000 JPG-Dateien mit $JPG_JOBS Workern..."
    active=0
    completed=0
    for i in $(seq 1 1000); do
        create_jpg "$i" "$run" "$JPG_QUALITY" "$PATTERN" &
        ((active++)) || true
        if (( active >= JPG_JOBS )); then
            wait -n
            ((active--)) || true
            ((completed++)) || true
            if (( completed % 25 == 0 )); then
                show_progress "$completed" 1000 "$FILE_START" "$run"
                monitor_ssd
            fi
        fi
    done
    while (( active > 0 )); do
        wait -n
        ((active--)) || true
        ((completed++)) || true
        if (( completed % 25 == 0 || completed == 1000 )); then
            show_progress "$completed" 1000 "$FILE_START" "$run"
            monitor_ssd
        fi
    done
    echo
    echo "    -> 1000 JPG fertig."
    add_written "$JPG_TARGET_BYTES" # nominal estimate only

    echo "    -> SHA-256 Manifest wird erstellt..."
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

    echo "    Testdaten:"
    du -sh "$TEST_DIR"

    # 3. Sync
    echo
    echo "[3/9] sync"
    sync
    monitor_ssd

    # 4. Delete test files
    echo
    echo "[4/9] Lösche HTML + TXT + JPG..."
    rm -f -- "$TEST_DIR"/*.html "$TEST_DIR"/*.txt "$TEST_DIR"/*.jpg
    echo "    -> Testdateien gelöscht."

    # 5. TRIM
    echo
    echo "[5/9] TRIM"
    record_trim
    monitor_ssd

    # 6. Large file
    echo
    echo "[6/9] Erstelle 10-GiB-Testdatei..."
    mkdir -p "$TEST_DIR"
    dd if=/dev/zero of="$TEST_DIR/large.bin" bs=1M count=10240 status=progress
    printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=LARGE | PATTERN=%s\n' "$LEVEL_NAME" "$run" "$PATTERN" |
        dd of="$TEST_DIR/large.bin" bs=1 conv=notrunc status=none
    add_written $((10 * 1024 * 1024 * 1024))
    manifest_file "$TEST_DIR/large.bin" "LARGE" "$run" "LARGE" "$PATTERN"
    sync
    rm -f -- "$TEST_DIR/large.bin"
    record_trim
    monitor_ssd

    # 7. 1000 x 10 MiB
    echo
    echo "[7/9] Erstelle 1000 x 10-MiB-Dateien..."
    BINARY_START=$(date +%s)
    for i in $(seq 1 1000); do
        dd if=/dev/zero of="$TEST_DIR/file-$i.bin" bs=1M count=10 status=none
        printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=%04d | PATTERN=%s\n' "$LEVEL_NAME" "$run" "$i" "$PATTERN" |
            dd of="$TEST_DIR/file-$i.bin" bs=1 conv=notrunc status=none
        if (( i % 50 == 0 )); then
            show_progress "$i" 1000 "$BINARY_START" "$run"
            monitor_ssd
        fi
    done
    add_written $((1000 * 10 * 1024 * 1024))
    echo
    echo "    -> Erstelle Binär-Manifest..."
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
    echo "[8/9] Kontrolliertes Free-Space-Fill..."
    FILL_THIS_RUN=0
    DO_FILL=0
    FILL_FRACTION=2
    FILL_SOURCE="/dev/zero"
    FILL_PATTERN="ZERO"

    if [[ "$LEVEL_NAME" == "SECRET" && "$run" -eq "$TOTAL_RUNS" ]]; then
        DO_FILL=1
        FILL_FRACTION=2
        FILL_SOURCE=/dev/zero
        FILL_PATTERN=ZERO
    elif [[ "$LEVEL_NAME" == "PARANOIA" && ( "$run" -eq 1 || "$run" -eq $(( (TOTAL_RUNS + 1) / 2 )) || "$run" -eq "$TOTAL_RUNS" ) ]]; then
        DO_FILL=1
        FILL_FRACTION=1
        FILL_SOURCE=/dev/urandom
        FILL_PATTERN=RANDOM
    fi

    if (( DO_FILL == 0 )); then
        echo "    -> In diesem Run deaktiviert."
    else
        FREE_BYTES_NOW=$(get_free_bytes)
        if (( FREE_BYTES_NOW > RESERVE_BYTES )); then SAFE_FILL_BYTES_NOW=$((FREE_BYTES_NOW - RESERVE_BYTES)); else SAFE_FILL_BYTES_NOW=0; fi
        FILL_BYTES=$((SAFE_FILL_BYTES_NOW / FILL_FRACTION))
        echo "    -> Pattern: $FILL_PATTERN"
        echo "    -> Startziel: $(format_gib "$FILL_BYTES") GiB"

        if (( FILL_BYTES > 0 )); then
            mkdir -p "$TEST_DIR"
            CHUNK=$((1024 * 1024 * 1024))
            INDEX=0
            while (( FILL_THIS_RUN + CHUNK <= FILL_BYTES )); do
                CURRENT_FREE=$(get_free_bytes)
                if (( CURRENT_FREE <= RESERVE_BYTES )); then
                    echo "    -> Sicherheitsreserve erreicht."
                    break
                fi
                REMAINING_SAFE=$((CURRENT_FREE - RESERVE_BYTES))
                (( REMAINING_SAFE >= CHUNK )) || break

                INDEX=$((INDEX + 1))
                next_file="$TEST_DIR/fill-$INDEX.bin"
                echo "    -> Block $INDEX | frei: $(format_gib "$CURRENT_FREE") GiB"
                dd if="$FILL_SOURCE" of="$next_file" bs=16M count=64 status=progress
                printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=FILL-%03d | PATTERN=%s\n' "$LEVEL_NAME" "$run" "$INDEX" "$FILL_PATTERN" |
                    dd of="$next_file" bs=1 conv=notrunc status=none
                add_written "$CHUNK"
                FILL_THIS_RUN=$((FILL_THIS_RUN + CHUNK))
                manifest_file "$next_file" "FILL" "$run" "FILL-$INDEX" "$FILL_PATTERN"
                monitor_ssd
            done
            sync
            rm -f -- "$TEST_DIR"/fill-*.bin
            rmdir "$TEST_DIR" 2>/dev/null || true
            echo "    -> Fill geschrieben: $(format_gib "$FILL_THIS_RUN") GiB"
        else
            echo "    -> Kein sicher nutzbarer Fill-Bereich."
        fi
    fi

    # 9. Final TRIM
    echo
    echo "[9/9] Finales TRIM"
    record_trim
    monitor_ssd

    # Run report
    RUN_END=$(date +%s)
    RUN_TIME=$((RUN_END - RUN_START))
    TOTAL_ELAPSED=$((RUN_END - SCRIPT_START))
    EST_TOTAL=$((TOTAL_ELAPSED * TOTAL_RUNS / run))
    EST_REMAINING=$((EST_TOTAL - TOTAL_ELAPSED))
    CURRENT_FREE=$(get_free_bytes)

    {
        echo
        echo "------------------------------------------------------------"
        echo "RUN $run / $TOTAL_RUNS"
        echo "------------------------------------------------------------"
        echo "Level:            $LEVEL_NAME"
        echo "Pattern:          $PATTERN"
        echo "Run-Dauer:        $(format_time "$RUN_TIME")"
        echo "Freier Speicher:  $(format_gib "$CURRENT_FREE") GiB"
        echo "Free-Fill:        $(format_gib "$FILL_THIS_RUN") GiB"
        echo "JPG-Worker:       $JPG_JOBS"
        echo "Run-Cooldown:     ${RUN_COOLDOWN}s"
        echo "Max Temperatur:   ${MAX_TEMP:-n/a} °C"
        echo "Nominal ges.      $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    } >> "$REPORT_FILE"

    echo
    echo "RUN $run / $TOTAL_RUNS abgeschlossen"
    echo "  Dauer:        $(format_time "$RUN_TIME")"
    echo "  Rest:         $(format_time "$EST_REMAINING")"
    echo "  Freier Platz: $(format_gib "$CURRENT_FREE") GiB"
    echo "  Max Temp:     ${MAX_TEMP:-n/a} °C"
    echo "  Nominal:      $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"

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
    echo "GESAMTERGEBNIS"
    echo "============================================================"
    echo "Level:                    $LEVEL_NAME"
    echo "Runs:                     $TOTAL_RUNS"
    echo "Gesamtdauer:              $(format_time "$TOTAL_TIME")"
    echo "Nominal geschrieben:      $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    if [[ -n "$HOST_WRITE_DELTA" ]]; then
        echo "Controller Host-Writes:   $(format_gib "$HOST_WRITE_DELTA") GiB"
    else
        echo "Controller Host-Writes:   nicht verfügbar"
    fi
    echo "Max Temperatur:           ${MAX_TEMP:-n/a} °C"
    echo "TRIM-Aufrufe:             $TRIM_COUNT"
    echo "TRIM-Bytes laut fstrim:   $TRIM_BYTES_APPROX"
    echo
    echo "Freier Speicher Start:    $(format_gib "$START_FREE_BYTES") GiB"
    echo "Freier Speicher Ende:     $(format_gib "$END_FREE_BYTES") GiB"
    echo
    echo "SMART/NVMe Start:"
    echo "  Temperature:            ${START_TEMP:-n/a} °C"
    echo "  Health:                 ${START_HEALTH:-n/a}"
    echo "  Percentage Used:        ${START_PERCENT_USED:-n/a}"
    echo "  Available Spare:        ${START_AVAILABLE_SPARE:-n/a}"
    echo "  Critical Warning:       ${START_CRITICAL_WARNING:-n/a}"
    echo "  Media Errors:           ${START_MEDIA_ERRORS:-n/a}"
    echo "  Unsafe Shutdowns:       ${START_UNSAFE_SHUTDOWNS:-n/a}"
    echo "  Power Cycles:           ${START_POWER_CYCLES:-n/a}"
    echo "  Data Units Written:     ${START_DATA_WRITTEN_BYTES:-n/a} bytes"
    echo
    echo "SMART/NVMe Ende:"
    echo "  Temperature:            ${END_TEMP:-n/a} °C"
    echo "  Health:                 ${END_HEALTH:-n/a}"
    echo "  Percentage Used:        ${END_PERCENT_USED:-n/a}"
    echo "  Available Spare:        ${END_AVAILABLE_SPARE:-n/a}"
    echo "  Critical Warning:       ${END_CRITICAL_WARNING:-n/a}"
    echo "  Media Errors:           ${END_MEDIA_ERRORS:-n/a}"
    echo "  Unsafe Shutdowns:       ${END_UNSAFE_SHUTDOWNS:-n/a}"
    echo "  Power Cycles:           ${END_POWER_CYCLES:-n/a}"
    echo "  Data Units Written:     ${END_DATA_WRITTEN_BYTES:-n/a} bytes"
    echo
    echo "Dateien:"
    echo "  Report:                 $REPORT_FILE"
    echo "  Manifest:               $MANIFEST_FILE"
    echo "  Log:                    $LOG_FILE"
    echo
    echo "============================================================"
} | tee -a "$REPORT_FILE"

echo
echo "FERTIG."
echo "Report:   $REPORT_FILE"
echo "Manifest: $MANIFEST_FILE"
echo "Log:      $LOG_FILE"
