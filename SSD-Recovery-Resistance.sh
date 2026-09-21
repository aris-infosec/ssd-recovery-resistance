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
# v1.9  Verbose phase transitions: timestamps on every section header,
#       live elapsed-time spinner during sync, file-count + size shown
#       before rm -rf, fstrim output surfaced per pass, post-TRIM free
#       space delta shown, cooldown countdown printed second-by-second.
# v1.10 New interactive questions before the final confirmation:
#       (a) "How many times should the whole level be run?" - repeats
#       the complete level (e.g. Paranoia = 6 runs) N times back to
#       back; each repetition restarts the level's pattern sequence.
#       (b) "Power off the computer when everything is finished?" -
#       with a 30 s abortable countdown. CLI: --repeat=N, --poweroff,
#       --no-poweroff. Poweroff only happens after a normal finish,
#       never after Ctrl-C / abort / error.
#       Break between runs/passes is now ADAPTIVE and temperature
#       based: it ends as soon as the drive is back near its own idle
#       temperature (idle at launch + 5 C, steady for 10 s, after at
#       least 30 s) and NEVER lasts longer than 7 minutes - if the
#       drive is still warm at the limit the next run just starts
#       (workers are reduced automatically). Without a temperature
#       sensor a fixed 5 min break is used. The in-run thermal PAUSE
#       is bounded too (7 min): if the drive will not cool, that run
#       ends gracefully (delete + TRIM, exit code 2) instead of
#       waiting forever. Settings: COOLDOWN_MIN_SECONDS,
#       COOLDOWN_MAX_SECONDS, COOLDOWN_TARGET_C, COOLDOWN_SECONDS,
#       THERMAL_PAUSE_MAX_SECONDS. Fixes: early EXIT trap so a failed
#       start can't orphan the sudo keepalive loop; config validation
#       runs before sudo starts; ETA no longer counts a break after
#       the last run.
#       IMPORTANT FIX (present in earlier versions): the wait for
#       background workers after each fill also counted the thermal
#       monitor as a "worker". Every run therefore idled 180 s and
#       then SIGTERMed the monitor, so from run 2 on there was NO
#       thermal monitoring. The monitor is now excluded (worker_pids).
#       IMPORTANT FIX 2 (present in earlier versions): a REAL Ctrl-C on a
#       terminal killed the `tee` that logs the output (same process
#       group), the abort handler's next write failed under `set -e`
#       and the script exited with status 1 WITHOUT running cleanup -
#       test files stayed on the drive, swap stayed disabled. tee now
#       ignores INT/TERM/HUP and the handler survives write errors.
#       v1.10 (continued):
#       - Sleep inhibitor: the run holds a systemd sleep:idle:handle-lid-switch
#         lock (--no-inhibit to skip); warns when it is unavailable and when
#         running over SSH without tmux/screen.
#       - Push notifications (ntfy): asked after the mode is chosen (yes/no,
#         then the channel name, remembered for next time), or --notify=NAME /
#         --no-notify. Messages: started, and finished / aborted / failed with
#         runtime, temperatures, data written and wear status - sent BEFORE a
#         requested power-off. Env: NOTIFY_SERVER, NOTIFY_CHANNEL, NOTIFY_TOKEN.
#       - --cleanup: removes leftovers of a crashed run (test-data folders,
#         disabled swap) and optionally runs TRIM.
#       - Peak temperature is tracked per run by the monitor (was cumulative and
#         sampled only in the thermal gate).
#       - A thermal PAUSE now ends at TEMP_RESUME (62 C), not at 69 C.
#       - ImageMagick 6 (convert) works as a fallback for v7 (magick).
#       - SIGHUP (closed terminal / dropped SSH) has its own handler (exit 129);
#         the exit trap no longer depends on $? (bash reports 0 there after death
#         by an untrapped signal), so a FAILED message is always sent.
#       - The abort handler ignores further signals while it cleans up.
#       - FIX: worker_pids was used on the left of a pipe, where bash hides the
#         job table: stalled workers were never killed. WORKER_WAIT_MAX_SECONDS.
#       - tests/: automated test suite (run tests/run-all.sh, see README).
#       Also: env values with leading zeros ("08") are read as decimal;
#       the live break line is cut to the terminal width; a momentary
#       empty sensor read no longer forces the fixed-break fallback.
# ============================================================

# ------------------------- CLI flags ---------------------------
CLI_LEVEL="PARANOIA"   # fallback used only when --level isn't given AND the interactive picker is skipped (i.e. --yes with no --level).
CLI_LEVEL_EXPLICIT=0
CLI_YES=0
DRY_RUN=0
CLI_AGGRESSIVE=""   # "" = not set, 1 = force on, 0 = force off
CLI_SWAPOFF=1        # default ON: swapoff -a automatically, no prompt, if swap warning fires. Use --no-swapoff to disable.
CLI_MENU=0           # 1 = force the interactive picker even if --level was also given
CLI_JOBS=""          # if set via --jobs=N, pins JPG_JOBS and skips adapt_settings analysis
CLI_NO_MANIFEST_HASH=0  # 1 = skip per-file hashing in manifest.txt (see --no-manifest-hash)
CLI_REPEAT=""        # if set via --repeat=N, run the whole level N times and skip the question
CLI_POWEROFF=""      # "" = ask (or off with --yes), 1 = --poweroff, 0 = --no-poweroff
CLI_CLEANUP=0        # 1 = --cleanup: remove leftovers of an interrupted run, then exit
CLI_NOTIFY_MODE=""   # "" = ask (off with --yes), on = --notify[=NAME], off = --no-notify
CLI_NOTIFY_CHANNEL=""
NOTIFY_ENABLED=0
NOTIFY_CHANNEL_DEFAULT=${NOTIFY_CHANNEL:-}   # channel from the environment (captured BEFORE it is reset)
NOTIFY_CHANNEL=""
NOTIFY_SENT=0        # 1 once the final/abort/failure message went out (never send twice)
RUN_STARTED=0        # 1 once the real test began (only then are end/abort messages sent)
COMPLETED_RUNS=0
ABORTED_RUNS=0
PLAN_ETA_SECONDS=""
CLI_NO_INHIBIT=0     # 1 = --no-inhibit: don't block suspend/idle/lid-close during the run
INHIBIT_PID=""       # helper process holding the systemd sleep inhibitor
INHIBIT_STATE="not started"
REPEAT_COUNT=1       # how many times the complete level is run back to back
POWEROFF_REQUESTED=0 # 1 = power off the computer after a normal, complete finish
BASE_RUNS=1          # runs of ONE pass of the chosen level (before repeating)
SWAP_WARNING=""
SWAPOFF_REQUESTED=0
SWAP_WAS_DISABLED_BY_SCRIPT=0
print_usage() {
    cat <<EOF
Usage: $(basename -- "${BASH_SOURCE[0]}") [options]

  --level=normal|restricted|secret|paranoia   Skip the interactive picker,
                                    pick this level directly.
  --menu                           Force the interactive picker even if
                                    --level was also given.
  --yes, -y                        Skip confirmation prompts and the
                                    interactive picker (falls back to
                                    --level, or paranoia if not given).
  --aggressive                     Force aggressive allocation mode on.
  --no-aggressive                  Force aggressive allocation mode off.
  --swapoff                        (default) If unencrypted swap is detected,
                                    run 'swapoff -a' automatically, no prompt.
                                    Swap is re-enabled ('swapon -a') when the
                                    script exits, including on Ctrl-C.
  --no-swapoff                     Prompt instead (or leave swap alone if
                                    combined with --yes).
  --jobs=N                          Pin worker count to N and skip the CPU/temp/
                                    free-space adaptive analysis entirely (thermal
                                    safety pause/abort still applies).
  --no-manifest-hash                Skip per-file SHA/BLAKE2 hashing in manifest.txt.
                                    Once cumulative data written exceeds RAM, the
                                    post-write re-read needed to hash each file
                                    falls out of page cache and becomes a real
                                    second disk read per file - this avoids that
                                    at the cost of the manifest's integrity hashes.
                                    Does NOT affect the overwrite/TRIM test itself.
  --repeat=N                       Run the complete level N times in a row (N = 1..99)
                                    (e.g. paranoia --repeat=2 = 2 x 6 runs).
                                    Skips the interactive "how many times?"
                                    question. Default: ask (1 with --yes).
  --poweroff                       Power off the computer after a normal,
                                    complete finish (30 s abortable countdown).
                                    Skips the interactive question.
  --no-poweroff                    Never power off (skips the question).
                                    Default: ask (no poweroff with --yes).
  --notify[=NAME]                  Send push notifications (ntfy.sh) to channel
                                    NAME: one when the test starts and one when
                                    it ends / aborts / fails, with runtime,
                                    temperatures, wear status and more. With
                                    --poweroff the message goes out BEFORE the
                                    shutdown. Without =NAME the saved channel
                                    (or env NOTIFY_CHANNEL) is used. Server:
                                    env NOTIFY_SERVER (default
                                    https://ntfy.sh), optional NOTIFY_TOKEN.
                                    Default: ask (off with --yes).
  --no-notify                      Never send notifications (skips the question).
  --cleanup                        Find and remove leftovers of an interrupted
                                    run (script-owned test-data folders, and
                                    switch swap back on if the script had
                                    disabled it), optionally TRIM, then exit.
                                    Use after a power cut / kill -9.
  --no-inhibit                     Don't block suspend / idle / lid-close
                                    (by default the run holds a systemd
                                    sleep inhibitor so the computer cannot
                                    fall asleep mid-test).
  --dry-run                        Run analysis + show the execution plan,
                                    write NO files, exit before the actual test.
  -h, --help                       Show this help and exit.

Environment overrides: RESERVE_MB, SECRET_RUNS, PARANOIA_RUNS,
WORKER_WAIT_MAX_SECONDS (180: stalled background workers are killed after this),
COOLDOWN_MIN_SECONDS (30) / COOLDOWN_MAX_SECONDS (420 = hard 7 min limit,
0 = no break) / COOLDOWN_TARGET_C (auto = idle+5C) / COOLDOWN_SECONDS (300,
fixed break used only when no temperature sensor exists) /
THERMAL_PAUSE_MAX_SECONDS (420, 0 = unlimited),
PARANOIA_RESERVE_FLOOR_MB, SOUND_ENABLED (0/1), VERBOSE (0/1 - per-file/
per-worker detail: JPG dispatch/skip/complete, adapt_settings decisions,
dashboard refreshed every file instead of every 10), DEBUG (0/1 - full
'set -x' trace written to <run-dir>/trace.log).
EOF
}
for arg in "$@"; do
    case "$arg" in
        --level=*) CLI_LEVEL="${arg#--level=}"; CLI_LEVEL="${CLI_LEVEL^^}"; CLI_LEVEL_EXPLICIT=1 ;;
        --yes|-y) CLI_YES=1 ;;
        --aggressive) CLI_AGGRESSIVE=1 ;;
        --no-aggressive) CLI_AGGRESSIVE=0 ;;
        --swapoff) CLI_SWAPOFF=1 ;;
        --no-swapoff) CLI_SWAPOFF=0 ;;
        --menu) CLI_MENU=1 ;;
        --jobs=*) CLI_JOBS="${arg#--jobs=}" ;;
        --no-manifest-hash) CLI_NO_MANIFEST_HASH=1 ;;
        --repeat=*) CLI_REPEAT="${arg#--repeat=}"; [[ -n "$CLI_REPEAT" ]] || CLI_REPEAT="(empty)" ;;
        --poweroff) CLI_POWEROFF=1 ;;
        --no-poweroff) CLI_POWEROFF=0 ;;
        --notify) CLI_NOTIFY_MODE=on ;;
        --notify=*) CLI_NOTIFY_MODE=on; CLI_NOTIFY_CHANNEL="${arg#--notify=}"; [[ -n "$CLI_NOTIFY_CHANNEL" ]] || CLI_NOTIFY_CHANNEL="(empty)" ;;
        --no-notify) CLI_NOTIFY_MODE=off ;;
        --cleanup) CLI_CLEANUP=1 ;;
        --no-inhibit) CLI_NO_INHIBIT=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "Unknown option: $arg"; print_usage; exit 1 ;;
    esac
done
if [[ -n "$CLI_LEVEL" && "$CLI_LEVEL" != "NORMAL" && "$CLI_LEVEL" != "RESTRICTED" && "$CLI_LEVEL" != "SECRET" && "$CLI_LEVEL" != "PARANOIA" ]]; then
    echo "Invalid --level: '$CLI_LEVEL' (must be normal, restricted, secret, or paranoia)."
    exit 1
fi
if [[ -n "$CLI_JOBS" && ! "$CLI_JOBS" =~ ^[0-9]+$ ]]; then
    echo "Invalid --jobs: '$CLI_JOBS' (must be a positive integer)."
    exit 1
fi

# Validated here (before sudo/keepalive/lock exist) so a bad value can never
# leave a background helper behind.
# Break between runs/passes is ADAPTIVE and temperature based:
#   - it ends as soon as the drive is back at COOLDOWN_TARGET_C (and has
#     stayed there a few seconds), but never before COOLDOWN_MIN_SECONDS;
#   - it NEVER lasts longer than COOLDOWN_MAX_SECONDS (default 7 minutes),
#     even if the drive has not cooled down - the run then simply starts
#     (with reduced load if the drive is still warm) instead of waiting;
#   - without a temperature sensor it falls back to a fixed
#     COOLDOWN_SECONDS break (capped by the maximum).
COOLDOWN_MIN_SECONDS=${COOLDOWN_MIN_SECONDS:-30}
COOLDOWN_MAX_SECONDS=${COOLDOWN_MAX_SECONDS:-420}
COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-300}
COOLDOWN_TARGET_C=${COOLDOWN_TARGET_C:-auto}
THERMAL_PAUSE_MAX_SECONDS=${THERMAL_PAUSE_MAX_SECONDS:-420}
WORKER_WAIT_MAX_SECONDS=${WORKER_WAIT_MAX_SECONDS:-180}   # background workers still running this long after a fill get SIGTERM/SIGKILL
# (10# forces decimal: a value like "08" or "0420" must not be read as octal.)
for _cv in COOLDOWN_MIN_SECONDS COOLDOWN_MAX_SECONDS COOLDOWN_SECONDS THERMAL_PAUSE_MAX_SECONDS WORKER_WAIT_MAX_SECONDS; do
    _v=${!_cv}
    if ! [[ "$_v" =~ ^[0-9]{1,5}$ ]] || (( 10#$_v > 86400 )); then
        echo "Invalid $_cv: '$_v' (must be 0..86400 seconds)."
        exit 1
    fi
    printf -v "$_cv" '%d' "$(( 10#$_v ))"
done
if [[ "$COOLDOWN_TARGET_C" != "auto" ]]; then
    if ! [[ "$COOLDOWN_TARGET_C" =~ ^[0-9]{1,3}$ ]] || (( 10#$COOLDOWN_TARGET_C < 20 || 10#$COOLDOWN_TARGET_C > 90 )); then
        echo "Invalid COOLDOWN_TARGET_C: '$COOLDOWN_TARGET_C' (must be 'auto' or 20..90 degrees C)."
        exit 1
    fi
    COOLDOWN_TARGET_C=$(( 10#$COOLDOWN_TARGET_C ))
fi
if (( COOLDOWN_MIN_SECONDS > COOLDOWN_MAX_SECONDS )); then
    echo "Invalid config: COOLDOWN_MIN_SECONDS ($COOLDOWN_MIN_SECONDS) is larger than COOLDOWN_MAX_SECONDS ($COOLDOWN_MAX_SECONDS)."
    exit 1
fi
# Notification settings (ntfy). The channel name is effectively a password:
# anyone who knows it can read the messages, so it is never written to reports.
NOTIFY_SERVER=${NOTIFY_SERVER:-https://ntfy.sh}
NOTIFY_TOKEN=${NOTIFY_TOKEN:-}
NOTIFY_CONF="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/ssd-recovery-resistance/notify.conf"
if ! [[ "$NOTIFY_SERVER" =~ ^https?://[^[:space:]\"]+$ ]]; then
    echo "Invalid NOTIFY_SERVER: '$NOTIFY_SERVER' (must start with http:// or https://)."
    exit 1
fi
if [[ -n "$NOTIFY_TOKEN" && ! "$NOTIFY_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "Invalid NOTIFY_TOKEN (allowed characters: A-Z a-z 0-9 . _ ~ + / = -)."
    exit 1
fi
if [[ -n "$CLI_NOTIFY_CHANNEL" && ! "$CLI_NOTIFY_CHANNEL" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    echo "Invalid --notify channel: '$CLI_NOTIFY_CHANNEL' (1-64 characters: A-Z a-z 0-9 _ -)."
    exit 1
fi
# Upper bound (1..99) also protects the TOTAL_RUNS arithmetic from overflow.
if [[ -n "$CLI_REPEAT" && ! "$CLI_REPEAT" =~ ^[1-9][0-9]?$ ]]; then
    echo "Invalid --repeat: '$CLI_REPEAT' (must be a whole number from 1 to 99, e.g. 2)."
    exit 1
fi

# ------------------------- Configuration --------------------
# Everything happens inside a folder named after this script, created in the
# directory it was launched from (not the script's own location, e.g. if
# called via a symlink or from $PATH).
LAUNCH_DIR="$(pwd -P)"
PROJECT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
PROJECT_NAME="${PROJECT_NAME%.*}"
PROJECT_DIR="$LAUNCH_DIR/$PROJECT_NAME"
RUN_ROOT="$PROJECT_DIR/runs"
# Written while swap is disabled by this script, removed when it is re-enabled.
# If the script is killed hard (power loss, kill -9) the marker survives so
# "--cleanup" knows that swap still has to be switched back on.
SWAP_MARKER="$PROJECT_DIR/.swap-disabled-by-script"
# Learned write-rate history, keyed per level, persisted across script
# invocations - lives in PROJECT_DIR (not RUN_DIR/TEST_DIR, which get
# deleted) so it accumulates real-world data over time on this machine.
HISTORY_FILE="$PROJECT_DIR/.eta_history"
HISTORY_MAX_SAMPLES=15
# The filesystem under test: the project dir itself (so df/findmnt/fstrim
# all operate on whatever disk you actually launched the script from).
TARGET_DIR="$PROJECT_DIR"
OUTPUT_STAMP=""
RUN_DIR=""
TEST_DIR=""
SUDO_KEEPALIVE_PID=""

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
    # Keep the sudo credential alive for the whole run. Without this, a
    # long unattended run (hours - TRIM/fill cycles, cooldowns) can outlast
    # sudo's cached-credential timeout, hit a re-auth prompt with nobody at
    # the terminal to answer it, time out, and abort mid-run.
    ( while true; do sudo -n -v 2>/dev/null || true; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    # Early safety net: until the full cleanup trap is installed further
    # down, any early exit (lock held, bad config, ...) must still stop the
    # keepalive loop instead of leaving it running forever.
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
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
# VERBOSE=1 prints per-file/per-worker detail (JPG dispatch/skip/complete,
# adapt_settings decisions, dashboard refresh every file instead of every
# 10). Default stays concise; set VERBOSE=1 before running for full detail.
VERBOSE=${VERBOSE:-0}
DEBUG=${DEBUG:-0}
TRACE_FILE=""
DASHBOARD_INTERVAL=${DASHBOARD_INTERVAL:-10}
(( VERBOSE == 1 )) && DASHBOARD_INTERVAL=1
# Hard floor on redraw rate regardless of DASHBOARD_INTERVAL/dispatch speed.
# The iteration-count interval alone isn't enough: at high worker counts,
# tiny HTML/TXT/BIN files dispatch almost instantly (the parent loop just
# forks a worker and moves on), so even interval=10 can still fire many
# redraws per second. Terminal scrollback/logs record every redraw as
# literal text (cursor-up only affects what's currently on screen, not
# history), so an uncapped redraw rate shows up as a huge wall of near-
# identical repeated frames when scrolling back or copy-pasting.
DASHBOARD_MIN_INTERVAL_S=1
LAST_DASHBOARD_TS=0
vlog() { if (( VERBOSE == 1 )); then printf '    [%s] [v] %s\n' "$(date '+%H:%M:%S')" "$1"; fi; return 0; }
PARANOIA_RESERVE_FLOOR_MB=${PARANOIA_RESERVE_FLOOR_MB:-50}
# Number of full fill/delete/TRIM runs per level. Paranoia must stay the
# most thorough level, i.e. PARANOIA_RUNS > SECRET_RUNS > RESTRICTED_RUNS >
# NORMAL_RUNS(=1) -- this is enforced by config_sanity_checks below.
# Override on the command line, e.g.: SECRET_RUNS=5 PARANOIA_RUNS=8 ./SSD-Recovery-Resistance.sh
RESTRICTED_RUNS=${RESTRICTED_RUNS:-2}
SECRET_RUNS=${SECRET_RUNS:-3}
PARANOIA_RUNS=${PARANOIA_RUNS:-6}
RESERVE_BYTES=$((RESERVE_MB * 1024 * 1024))
# Headroom kept above RESERVE_BYTES before dispatching new JPG workers, so
# ImageMagick always has a little scratch space and isn't racing other
# writers for literally the last few MiB of disk (root cause of hangs
# observed right as free space bottomed out at the reserve floor).
JPG_SAFETY_MARGIN_MB=20
JPG_SAFETY_MARGIN_BYTES=$((JPG_SAFETY_MARGIN_MB * 1024 * 1024))

# File sizes used while cycling.
HTML_BASE_SIZE=$((2 * 1024 * 1024))
TXT_BASE_SIZE=$((2 * 1024 * 1024))
BIN_BASE_MIB=10
# JPG_JOBS_DEFAULT / JPG_JOBS_MAX are derived below from the actual core
# count (nproc), not hardcoded - see CPU_THREADS section.

# --- Temperature ampel (fein, aus fill-ssd.sh) ---
TEMP_WARNING=${TEMP_WARNING:-65}
TEMP_PAUSE=${TEMP_PAUSE:-70}
TEMP_RESUME=${TEMP_RESUME:-62}
TEMP_CRITICAL=${TEMP_CRITICAL:-80}
TEMP_EMERGENCY=${TEMP_EMERGENCY:-85}
TEMP_INTERVAL=1     # seconds between background temperature polls
COOL_TIME=5         # seconds <= TEMP_RESUME required before resuming

# Adaptive break settings are validated near the top of the script.
COOLDOWN_STABLE_SECONDS=10   # drive must stay <= target this long (ignores sensor blips)
COOLDOWN_TARGET_EFF=""       # effective target in degrees C, resolved once START_TEMP is known
BREAK_COUNT=0; BREAK_EARLY=0; BREAK_CAPPED=0; BREAK_FIXED=0; SUM_BREAK_SECONDS=0
THERMAL_PAUSE_TIMEOUTS=0
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
SCRIPT_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
declare -a RUN_START_HUMAN_LOG=()
declare -a RUN_END_HUMAN_LOG=()
NOMINAL_WRITTEN_BYTES=0
WRITTEN_LOG=""
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
# Leave headroom for the OS, the thermal monitor thread, and the shell
# itself; cap comfortably below full core count rather than a fixed
# number so laptops with more threads actually get to use them.
JPG_JOBS_MAX=$(( CPU_THREADS > 3 ? CPU_THREADS - 2 : 2 ))
(( JPG_JOBS_MAX < 2 )) && JPG_JOBS_MAX=2
JPG_JOBS_DEFAULT=$(( JPG_JOBS_MAX / 2 ))
(( JPG_JOBS_DEFAULT < 2 )) && JPG_JOBS_DEFAULT=2
JPG_JOBS=$JPG_JOBS_DEFAULT
RUN_COOLDOWN=$COOLDOWN_SECONDS   # ESTIMATE of one break (for plan/ETA); refined once START_TEMP is known and after each real break
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
PEAK_TEMP=0        # highest temperature seen in the whole session
RUN_PEAK_TEMP=0    # highest temperature seen in the current run
CURRENT_RUN_ID=0

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
add_written() {
    # BUG FIX: this used to do `NOMINAL_WRITTEN_BYTES=$((NOMINAL_WRITTEN_BYTES + $1))`.
    # add_written() is only ever called from inside create_html_txt/create_jpg/
    # create_binary_test_file, and every one of those is dispatched with a
    # trailing `&` (background job = forked subshell). A subshell's variable
    # changes are invisible to the parent once it exits, so NOMINAL_WRITTEN_BYTES
    # in the main script never actually changed - "Nominal data written" stayed
    # near 0, and the TRIM-vs-written safety warning below never fired because
    # `(( NOMINAL_WRITTEN_BYTES > 0 ))` was never true. Route through a real
    # file instead (actual disk I/O, not shell state) and sum it in the parent.
    [[ -n "$WRITTEN_LOG" ]] && echo "$1" >> "$WRITTEN_LOG" 2>/dev/null
    return 0
}
recompute_written_bytes() {
    [[ -n "$WRITTEN_LOG" && -f "$WRITTEN_LOG" ]] || return 0
    NOMINAL_WRITTEN_BYTES=$(awk '{s+=$1} END{print s+0}' "$WRITTEN_LOG" 2>/dev/null || echo "$NOMINAL_WRITTEN_BYTES")
}
get_free_bytes()  { df -B1 --output=avail "$TARGET_DIR" | tail -n 1 | tr -d ' '; }
get_total_bytes() { df -B1 --output=size  "$TARGET_DIR" | tail -n 1 | tr -d ' '; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing program: $1"; exit 1; }; }

# ImageMagick: v7 provides "magick", v6 only "convert" (same arguments for
# everything this script does). Use whichever exists.
IM_CMD=()
if command -v magick >/dev/null 2>&1; then
    IM_CMD=(magick)
elif command -v convert >/dev/null 2>&1 && convert -version 2>/dev/null | grep -qi imagemagick; then
    IM_CMD=(convert)
fi

# Accepts y / yes (and j / ja for German keyboards), any case.
is_yes() { case "${1,,}" in y|yes|j|ja) return 0 ;; *) return 1 ;; esac; }

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
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
    if [[ -n "$INHIBIT_PID" ]]; then
        kill "$INHIBIT_PID" 2>/dev/null || true
        INHIBIT_PID=""
    fi
    if safe_test_dir && [[ -d "$TEST_DIR" ]]; then
        echo
        echo "Cleanup: removing only the script-owned test directory..."
        rm -rf -- "$TEST_DIR"
        echo "Cleanup complete."
    fi
    if (( SWAP_WAS_DISABLED_BY_SCRIPT == 1 )); then
        vlog "Re-enabling swap ($SUDO swapon -a)..."
        if $SUDO swapon -a 2>/dev/null; then vlog "Swap re-enabled."; rm -f -- "$SWAP_MARKER" 2>/dev/null
        else echo "!! swapon -a failed - re-enable swap manually if needed."; fi
        SWAP_WAS_DISABLED_BY_SCRIPT=0
    fi
    stop_thermal_monitor
}

# ------------------------- Notifications (ntfy) ---------------
notify_saved_channel() {
    local line
    [[ -r "$NOTIFY_CONF" ]] || return 0
    while IFS= read -r line; do
        if [[ "$line" == channel=* && "${line#channel=}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
            printf '%s' "${line#channel=}"
            return 0
        fi
    done < "$NOTIFY_CONF"
    return 0
}
notify_save_channel() {
    mkdir -p -- "$(dirname -- "$NOTIFY_CONF")" 2>/dev/null || return 0
    ( umask 077; printf 'channel=%s\n' "$1" > "$NOTIFY_CONF" ) 2>/dev/null || true
    return 0
}

# notify_send TITLE PRIORITY TAGS BODY - never fatal, never blocks > ~12 s.
notify_send() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local title prio="$2" tags="$3" body="$4" url rc=0
    title=$(printf '%s' "$1" | tr -cd '[:print:]' | cut -c1-120)
    url="${NOTIFY_SERVER%/}/$NOTIFY_CHANNEL"
    # The token (if any) goes through curl's config on stdin, not the argument
    # list, so it never shows up in `ps`.
    printf '%s' "${NOTIFY_TOKEN:+header = \"Authorization: Bearer $NOTIFY_TOKEN\"}" | \
        curl -sSf -K - --connect-timeout 5 --max-time 12 -o /dev/null \
            -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
            --data-binary "$body" "$url" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        echo "  Notification sent (\"$title\")."
    else
        echo "  !! Notification could not be sent (curl exit $rc) - check network / server / channel. Continuing."
    fi
    return 0
}

notify_wear_text() {
    local s="$1" e="$2" sn="" en=""
    if [[ "$s" =~ ^([0-9]+)% ]]; then sn=${BASH_REMATCH[1]}; fi
    if [[ "$e" =~ ^([0-9]+)% ]]; then en=${BASH_REMATCH[1]}; fi
    if [[ -n "$sn" && -n "$en" ]]; then printf '%s%% -> %s%% used (%+d pp)' "$sn" "$en" "$(( en - sn ))"
    elif [[ -n "$en" ]]; then printf '%s%% used' "$en"
    elif [[ -n "$sn" ]]; then printf '%s%% used at start' "$sn"
    else printf 'n/a'; fi
}

# Message body. kind=final: uses the END_* values already collected.
# kind=partial (abort / failure): reads the CURRENT drive values instead.
build_notify_message() {
    local kind="$1" headline="$2" elapsed now_temp now_wear now_health host_w ends
    local passes_txt runs_txt
    if [[ "$kind" == final ]]; then
        elapsed=$TOTAL_TIME
        now_wear=$END_PERCENT_USED; now_health=$END_HEALTH; now_temp=$END_TEMP; host_w=$HOST_WRITE_DELTA
        ends="ended $SCRIPT_END_HUMAN"
    else
        elapsed=$(( $(date +%s) - SCRIPT_START ))
        recompute_written_bytes
        sample_peak
        now_temp=$(get_temperature 2>/dev/null || true)
        now_wear=$(get_percentage_used 2>/dev/null || true)
        now_health=$(get_health 2>/dev/null || true)
        host_w=""
        local now_dw
        now_dw=$(get_data_written_bytes 2>/dev/null || true)
        if [[ "$START_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$now_dw" =~ ^[0-9]+$ ]] && (( now_dw >= START_DATA_WRITTEN_BYTES )); then
            host_w=$(( now_dw - START_DATA_WRITTEN_BYTES ))
        fi
        ends="stopped $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    if (( REPEAT_COUNT > 1 )); then passes_txt="$REPEAT_COUNT passes x $BASE_RUNS runs"; else passes_txt="$BASE_RUNS run(s)"; fi
    runs_txt="$COMPLETED_RUNS/$TOTAL_RUNS runs completed"
    if [[ "$kind" != final ]] && (( COMPLETED_RUNS < TOTAL_RUNS )) && [[ -n "${run:-}" ]] && (( ${run:-0} > COMPLETED_RUNS )); then
        runs_txt="$runs_txt, was in run ${run:-0} (pass ${SWEEP_NO:-1}/$REPEAT_COUNT)"
    fi
    printf '%s\n' "Result: $headline"
    printf '%s\n' "Level: $LEVEL_NAME - $passes_txt ($runs_txt)"
    printf '%s\n' "Runtime: $(format_time "$elapsed") (started $SCRIPT_START_HUMAN, $ends)"
    printf 'Data written: %s GiB nominal | %s\n' "$(format_gib "$NOMINAL_WRITTEN_BYTES")" \
        "$( [[ -n "$host_w" ]] && echo "$(format_gib "$host_w") GiB host writes (controller)" || echo "host writes n/a" )"
    printf 'Temperature: %s | peak %s C | start %s C\n' \
        "$( [[ "$now_temp" =~ ^[0-9]+$ ]] && echo "$([[ $kind == final ]] && echo end || echo now) ${now_temp} C" || echo "n/a" )" \
        "${PEAK_TEMP:-n/a}" "${START_TEMP:-n/a}"
    printf 'Wear: %s | health %s\n' "$(notify_wear_text "$START_PERCENT_USED" "$now_wear")" "${now_health:-n/a}"
    if [[ "$kind" == final ]]; then
        [[ -n "$START_AVAILABLE_SPARE$END_AVAILABLE_SPARE" ]] && printf 'Available spare: %s -> %s\n' "${START_AVAILABLE_SPARE:-n/a}" "${END_AVAILABLE_SPARE:-n/a}"
        printf 'Media errors: %s -> %s | Unsafe shutdowns: %s -> %s\n' "${START_MEDIA_ERRORS:-n/a}" "${END_MEDIA_ERRORS:-n/a}" "${START_UNSAFE_SHUTDOWNS:-n/a}" "${END_UNSAFE_SHUTDOWNS:-n/a}"
        printf 'Breaks: %s (%s early, %s at limit) | thermal cut-offs: %s run(s), %s pause timeout(s)\n' \
            "$BREAK_COUNT" "$BREAK_EARLY" "$BREAK_CAPPED" "$ABORTED_RUNS" "$THERMAL_PAUSE_TIMEOUTS"
        printf 'TRIM: %s operation(s), %s reported\n' "$TRIM_COUNT" "$(human "$TRIM_BYTES_APPROX")"
        if (( POWEROFF_REQUESTED == 1 )); then
            printf '%s\n' "Power off: YES - shutting down in 30 s (this is the last message; Ctrl-C at the terminal cancels)"
        else
            printf '%s\n' "Power off: no"
        fi
    else
        printf '%s\n' "Cleanup: test data removed, swap restored, helpers stopped. Power off: NOT done."
    fi
    return 0
}

notify_start() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local eta_txt body passes_txt
    if (( REPEAT_COUNT > 1 )); then passes_txt="$REPEAT_COUNT passes x $BASE_RUNS runs = $TOTAL_RUNS runs"; else passes_txt="$TOTAL_RUNS run(s)"; fi
    if [[ "$PLAN_ETA_SECONDS" =~ ^[0-9]+$ ]]; then
        eta_txt="~$(format_time "$PLAN_ETA_SECONDS") (finish about $(date -d "+${PLAN_ETA_SECONDS} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo n/a))"
    else
        eta_txt="n/a (no history yet)"
    fi
    body="Level: $LEVEL_NAME - $passes_txt
Estimated duration: $eta_txt
Drive now: wear ${START_PERCENT_USED:-n/a} | temp ${START_TEMP:-n/a} C | health ${START_HEALTH:-n/a}
Power off when done: $([[ $POWEROFF_REQUESTED -eq 1 ]] && echo YES || echo no)
You get another message when it ends, aborts or fails."
    notify_send "SSD test STARTED on $(hostname 2>/dev/null || echo host)" default arrow_forward "$body"
    return 0
}

notify_final() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local headline prio=default tags=white_check_mark body
    if (( ANY_ABORTED == 1 )); then
        headline="FINISHED, but $ABORTED_RUNS run(s) were cut short by thermal limits"; prio=high; tags=warning
    else
        headline="FINISHED OK"
    fi
    body=$(build_notify_message final "$headline")
    NOTIFY_SENT=1
    notify_send "SSD test $([[ $ANY_ABORTED -eq 1 ]] && echo "FINISHED (thermal cut-off)" || echo FINISHED) on $(hostname 2>/dev/null || echo host)" "$prio" "$tags" "$body"
    return 0
}

# ---- Compact per-run / per-TRIM notifications (low priority, one-liners) ----
# These are extra "heartbeat" pings on top of notify_start / notify_final, so
# you can follow along without watching the terminal. Kept to a single short
# line each: never fatal, never blocks (same notify_send under the hood).

notify_run_start() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local r="$1" total="$2" body
    body=$(printf 'Run %d/%d starting | %s/%s | temp %s C | wear %s | free %s GiB' \
        "$r" "$total" "$LEVEL_NAME" "${PATTERN:-n/a}" "${TEMP_NOW:-n/a}" \
        "${START_PERCENT_USED:-n/a}" "$(format_gib "$(get_free_bytes)")")
    notify_send "Run $r/$total started" low fast_forward "$body"
}

notify_run_finish() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local r="$1" total="$2" body pct
    pct=$(( r * 100 / total ))
    body=$(printf 'Run %d/%d done (%d%%) in %s | files %d | free %s GiB | peak %s C%s' \
        "$r" "$total" "$pct" "$(format_time "$RUN_TIME")" "$INDEX" \
        "$(format_gib "$CURRENT_FREE")" "${RUN_PEAK_TEMP:-n/a}" \
        "$([[ $ABORTED -eq 1 ]] && echo " | ABORTED (thermal)" || echo "")")
    notify_send "Run $r/$total finished" low white_check_mark "$body"
}

notify_trim_start() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local label="$1" free_b="$2" body
    body=$(printf 'TRIM #%d starting (%s) | free before %s GiB' \
        "$TRIM_COUNT" "$label" "$(format_gib "$free_b")")
    notify_send "TRIM #$TRIM_COUNT started" low recycle "$body"
}

notify_trim_finish() {
    (( NOTIFY_ENABLED == 1 )) || return 0
    local label="$1" elapsed="$2" free_a="$3" bytes="${4:-0}" body
    body=$(printf 'TRIM #%d done (%s) in %ds | trimmed %s | free after %s GiB' \
        "$TRIM_COUNT" "$label" "$elapsed" "$(human "$bytes")" \
        "$(format_gib "$free_a")")
    notify_send "TRIM #$TRIM_COUNT finished" low recycle "$body"
}

# Final exit trap: cleanup, plus a "FAILED" message if the script dies after the
# test started without having sent its final message (set -e error, SIGHUP, ...).
# shellcheck disable=SC2329  # invoked indirectly via trap
on_exit() {
    local rc=$? nbody="" reason
    trap - EXIT
    trap '' INT TERM HUP     # a late signal must not cut the cleanup short
    set +e
    # NOTE: after death by an untrapped signal bash runs this trap with $?=0, so
    # the exit code cannot be used to detect "abnormal end". Every normal finish
    # sends its final message first (NOTIFY_SENT=1); a test that started but never
    # sent one ended abnormally.
    if (( RUN_STARTED == 1 && NOTIFY_SENT == 0 && NOTIFY_ENABLED == 1 )); then
        if (( rc != 0 )); then reason="script stopped unexpectedly (exit code $rc)"
        else reason="script was killed by a signal (no exit code available)"; fi
        nbody=$(build_notify_message partial "FAILED - $reason")
    fi
    cleanup
    if [[ -n "$nbody" ]]; then
        NOTIFY_SENT=1
        notify_send "SSD test FAILED on $(hostname 2>/dev/null || echo host)" high rotating_light "$nbody"
    fi
    exit "$rc"
}

# Hold a systemd "sleep:idle:handle-lid-switch" inhibitor for the whole run, so
# the computer cannot suspend / hibernate / idle-sleep / lid-close-sleep in the
# middle of a multi-hour test (timers and temperature logic would go wrong).
# The lock lives as long as a helper process; that helper exits by itself when
# this script's PID disappears (tail --pid), even after kill -9, so it can never
# keep the machine awake forever. Never fatal: if it can't be obtained we warn.
start_sleep_inhibitor() {
    local what
    INHIBIT_STATE="disabled (--no-inhibit)"
    (( CLI_NO_INHIBIT == 1 )) && return 0
    if ! command -v systemd-inhibit >/dev/null 2>&1; then
        INHIBIT_STATE="UNAVAILABLE (systemd-inhibit not installed) - make sure the computer cannot suspend!"
        return 0
    fi
    for what in "sleep:idle:handle-lid-switch" "sleep:idle"; do
        systemd-inhibit --what="$what" --who="SSD-Recovery-Resistance" --why="probe" --mode=block true >/dev/null 2>&1 || continue
        systemd-inhibit --what="$what" --who="SSD-Recovery-Resistance" \
            --why="Long-running SSD fill/TRIM test in progress" --mode=block \
            tail --pid="$$" -f /dev/null >/dev/null 2>&1 < /dev/null &
        INHIBIT_PID=$!
        disown "$INHIBIT_PID" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$INHIBIT_PID" 2>/dev/null; then
            INHIBIT_STATE="active ($what)"
        else
            INHIBIT_PID=""
            INHIBIT_STATE="UNAVAILABLE (inhibitor process exited) - make sure the computer cannot suspend!"
        fi
        return 0
    done
    INHIBIT_STATE="UNAVAILABLE (not permitted / no systemd-logind) - make sure the computer cannot suspend!"
    return 0
}

# A dropped SSH connection sends SIGHUP: the run is then ABORTED (cleanup runs,
# results are incomplete). tmux/screen keep the session alive.
session_risk_warning() {
    if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" && -z "${TMUX:-}${STY:-}" ]]; then
        echo "WARNING: SSH session without tmux/screen - if the connection drops, this"
        echo "         run is ABORTED and its results are incomplete. Recommended:"
        echo "         start it inside 'tmux new -s ssdtest' (or 'screen')."
    fi
    return 0
}

# PIDs of running background WORKERS (html/txt/jpg/bin writers) only.
# `jobs -rp` alone also lists the thermal monitor subshell, which runs for the
# whole session: waiting for "no running jobs" therefore never succeeded, cost
# a full 180 s idle wait after EVERY run and then SIGTERMed the monitor (so
# from run 2 on there was no thermal monitoring at all). The monitor is
# excluded here; the disowned sudo keepalive is not in the job table.
#
# IMPORTANT: call it ONLY as a plain command substitution, x=$(worker_pids).
# Bash's job table is invisible when it sits on the left of a pipe or in a
# nested subshell ($(worker_pids | tr ...) silently returned nothing, so the
# straggler kill below never killed anything). Post-process the captured text
# in the caller instead.
worker_pids() {
    jobs -rp 2>/dev/null | grep -vxF -- "${THERMAL_PID:-0}" || true
}

kill_background_jobs() {
    # Kill any still-running JPG-generation background jobs spawned by this
    # shell so nothing keeps writing to TEST_DIR after we start cleaning up.
    local pids
    pids=$(jobs -pr 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086  # word splitting of the PID list is intended
        kill $pids 2>/dev/null || true
        # shellcheck disable=SC2086
        wait $pids 2>/dev/null || true
    fi
}

# shellcheck disable=SC2329  # invoked indirectly via trap
handle_interrupt() {
    local sig="${1:-INT}" headline title tags exit_code=130
    # Ignore further Ctrl-C / TERM / HUP while cleaning up (a second signal used
    # to kill the cleanup half-way), and disarm the EXIT trap.
    trap '' INT TERM HUP
    trap - EXIT
    # We are exiting anyway: a failing write (closed terminal / pipe) must never
    # abort the handler before cleanup() has run.
    set +e
    trap '' PIPE
    echo
    echo "============================================================"
    if [[ "$sig" == HUP ]]; then
        echo "ABORT REQUESTED (SIGHUP: terminal closed / connection lost)"
        headline="FAILED - terminal / connection closed (SIGHUP)"
        title="SSD test FAILED (connection lost)"; tags=rotating_light; exit_code=129
    else
        echo "ABORT REQUESTED"
        headline="ABORTED by user / signal ($sig)"
        title="SSD test ABORTED"; tags=octagonal_sign
    fi
    echo "============================================================"
    echo "(cleaning up - further Ctrl-C is ignored until this has finished)"
    local nbody=""
    if (( RUN_STARTED == 1 && NOTIFY_SENT == 0 && NOTIFY_ENABLED == 1 )); then
        nbody=$(build_notify_message partial "$headline")
    fi
    cleanup
    [[ -n "${LOG_FILE:-}" ]] && echo "Aborted: $(date)" >> "$LOG_FILE"
    if [[ -n "$nbody" ]]; then
        NOTIFY_SENT=1
        notify_send "$title on $(hostname 2>/dev/null || echo host)" high "$tags" "$nbody"
    fi
    exit "$exit_code"
}
trap 'handle_interrupt INT' INT
trap 'handle_interrupt TERM' TERM
trap 'handle_interrupt HUP' HUP
trap on_exit EXIT

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
setup_logging() {
    mkdir -p "$RUN_DIR"; touch "$LOG_FILE"
    # tee must IGNORE Ctrl-C/TERM/HUP: it shares the terminal's foreground process
    # group, so a real Ctrl-C used to kill it together with the shell's children.
    # The handler's very next echo then failed under `set -e`, the shell exited
    # with status 1 and cleanup() NEVER ran (test files, disabled swap and helper
    # processes were left behind). Ignored signals survive the exec into tee.
    exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
    init_csv
    WRITTEN_LOG="$RUN_DIR/.written_bytes.log"; : > "$WRITTEN_LOG"
    if (( DEBUG == 1 )); then
        TRACE_FILE="$RUN_DIR/trace.log"
        exec 9>"$TRACE_FILE"
        BASH_XTRACEFD=9
        PS4='+ [\D{%H:%M:%S}] ${BASH_SOURCE##*/}:${LINENO}: '
        set -x
        echo "DEBUG=1: full command trace being written to $TRACE_FILE" >&2
    fi
}

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
# between. This walks the FULL device-mapper stack under $HOME_SOURCE
# (arbitrary depth) and checks LUKS/dm-crypt "discards" and LVM
# "issue_discards" at every layer found.
#
# BUG FIX: this used to check ONLY the single top-level $HOME_SOURCE
# device. The two most common encrypted-Linux layouts each hide one
# layer from a single-device check:
#   - LUKS -> LVM PV -> LV -> filesystem (e.g. Ubuntu's "encrypted LVM"
#     installer option): $HOME_SOURCE is the LV. An LV is not a crypt
#     device, so the LUKS/allow_discards check never ran at all - a
#     missing allow_discards on the LUKS container underneath was never
#     reported.
#   - LVM PV -> LV -> LUKS (each LV encrypted separately): $HOME_SOURCE
#     is the crypt device. `lvs` doesn't recognize a crypt device as an
#     LV, so the LVM/issue_discards check never ran - a missing
#     issue_discards on the LV underneath was never reported.
# Now every device in the stack (found via /sys/block/*/slaves, which
# works regardless of stacking order) is checked for both.
DISCARD_WARNINGS=()

check_discard_passthrough() {
    local src="$HOME_SOURCE"
    # Not a device-mapper device -> nothing to check here.
    if [[ ! "$src" =~ ^/dev/(dm-|mapper/) ]]; then
        return 0
    fi
    _check_discard_layer "$src" 0
}

_check_discard_layer() {
    local dev="$1" depth="$2" name slaves_dir slave dm_uuid crypt_check lvm_conf
    (( depth > 10 )) && return 0   # guard against pathological/cyclic stacks
    name=$(basename -- "$dev")

    # ---- LUKS / dm-crypt at this layer ----
    if command -v dmsetup >/dev/null 2>&1; then
        dm_uuid=$($SUDO dmsetup info -c --noheadings -o uuid "$dev" 2>/dev/null || true)
        if [[ "$dm_uuid" == CRYPT-* ]]; then
            crypt_check=$($SUDO dmsetup table "$dev" 2>/dev/null || true)
            if [[ "$crypt_check" == *allow_discards* ]]; then
                echo "    LUKS/dm-crypt ($dev): discard passthrough ENABLED (allow_discards)."
            else
                DISCARD_WARNINGS+=("LUKS/dm-crypt device '$dev' does NOT have allow_discards set. TRIM will silently NOT reach the physical SSD through this layer. Fix: add 'discard' to /etc/crypttab (and cryptsetup --allow-discards / cryptsetup refresh --allow-discards), then reboot or re-open the container.")
            fi
        fi
    fi

    # ---- LVM at this layer ----
    if command -v lvs >/dev/null 2>&1 && lvs "$dev" >/dev/null 2>&1; then
        lvm_conf=$(grep -REi '^\s*issue_discards\s*=\s*1' /etc/lvm/lvm.conf 2>/dev/null || true)
        if [[ -n "$lvm_conf" ]]; then
            echo "    LVM ($dev): issue_discards = 1 (passthrough enabled)."
        else
            DISCARD_WARNINGS+=("LVM is in the stack for '$dev' but issue_discards is not enabled in /etc/lvm/lvm.conf. TRIM may not reach the physical SSD through the LVM layer. Fix: set issue_discards = 1 in /etc/lvm/lvm.conf.")
        fi
    fi

    # ---- Recurse into whatever this device is actually built on top of ----
    slaves_dir="/sys/block/$name/slaves"
    if [[ -d "$slaves_dir" ]]; then
        for slave in "$slaves_dir"/*; do
            [[ -e "$slave" ]] || continue
            _check_discard_layer "/dev/$(basename -- "$slave")" $((depth + 1))
        done
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

# Shared with check_swap: true (exit 0) if $1 or anything it's built on top
# of (walking /sys/block/*/slaves) is a LUKS/dm-crypt device.
_stack_has_luks() {
    local dev="$1" depth="$2" name uuid slaves_dir slave
    (( depth > 10 )) && return 1
    if command -v dmsetup >/dev/null 2>&1; then
        uuid=$($SUDO dmsetup info -c --noheadings -o uuid "$dev" 2>/dev/null || true)
        [[ "$uuid" == CRYPT-* ]] && return 0
    fi
    name=$(basename -- "$dev")
    slaves_dir="/sys/block/$name/slaves"
    if [[ -d "$slaves_dir" ]]; then
        for slave in "$slaves_dir"/*; do
            [[ -e "$slave" ]] || continue
            _stack_has_luks "/dev/$(basename -- "$slave")" $((depth + 1)) && return 0
        done
    fi
    return 1
}

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
                # BUG FIX: this used to only check whether $src ITSELF has a
                # CRYPT- dm-uuid. Same blind spot as the discard-passthrough
                # check: if swap lives on an LV that sits on top of a LUKS
                # container (a swap LV in a standard "encrypted LVM" layout),
                # $src is the LV - not a crypt device - so this reported
                # "swap not encrypted" even when it actually is, one layer
                # down. Now walks the whole stack via /sys/block/*/slaves.
                if _stack_has_luks "$src" 0; then
                    :
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
        is_yes "$MIN_FREE_CONFIRM" || exit 0
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
    line=$(grep -E '^177 |Wear_Leveling_Count' <<< "$dump" | head -n 1 || true)
    if [[ -n "$line" ]]; then
        raw=$(awk '{print $NF}' <<< "$line")
        [[ "$raw" =~ ^[0-9]+$ ]] && { echo "${raw}% (est., Wear_Leveling_Count raw)"; return 0; }
    fi
    line=$(grep -E '^233 |Media_Wearout_Indicator|^231 |SSD_Life_Left' <<< "$dump" | head -n 1 || true)
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
    RUN_ID_STATE="$STATE_DIR/runid"
    PEAK_STATE="$STATE_DIR/peak"
    echo "N/A" > "$TEMP_STATE"
    echo "NORMAL" > "$THERMAL_STATE"
    echo "0" > "$STOP_STATE"
    echo "0" > "$RUN_ID_STATE"
    echo "0 0" > "$PEAK_STATE"

    (
        # The monitor is the only ~1 Hz sampler, so IT tracks the peak
        # temperature (per run: the main loop announces the run number in
        # RUN_ID_STATE, the peak restarts whenever that changes). The main
        # shell used to sample the peak only inside thermal_gate, so short
        # spikes were missed and the "peak" was cumulative over all runs.
        # All state files are written atomically (tmp + mv): a reader can
        # never catch a half-written / empty file.
        mpeak=0; last_rid=""
        while true; do
            temp=$(get_temperature)
            printf '%s\n' "$temp" > "$TEMP_STATE.tmp" && mv -f "$TEMP_STATE.tmp" "$TEMP_STATE"

            read -r rid < "$RUN_ID_STATE" 2>/dev/null || rid=0
            if [[ "$rid" != "$last_rid" ]]; then last_rid=$rid; mpeak=0; fi
            if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > mpeak )); then mpeak=$temp; fi
            printf '%s %s\n' "$rid" "$mpeak" > "$PEAK_STATE.tmp" && mv -f "$PEAK_STATE.tmp" "$PEAK_STATE"

            if [[ "$temp" =~ ^[0-9]+$ ]]; then
                if   (( temp >= TEMP_EMERGENCY )); then new_state="EMERGENCY"
                elif (( temp >= TEMP_CRITICAL ));  then new_state="CRITICAL"
                elif (( temp >= TEMP_PAUSE ));     then new_state="PAUSE"
                elif (( temp >= TEMP_WARNING ));   then new_state="WARNING"
                else                                    new_state="NORMAL"
                fi
                printf '%s\n' "$new_state" > "$THERMAL_STATE.tmp" && mv -f "$THERMAL_STATE.tmp" "$THERMAL_STATE"
            fi
            sleep "$TEMP_INTERVAL"
        done
    ) &
    THERMAL_PID=$!
}

# Main-shell side of the peak tracking (see start_thermal_monitor).
sample_peak() {
    local rid p
    [[ -r "${PEAK_STATE:-}" ]] || return 0
    read -r rid p < "$PEAK_STATE" 2>/dev/null || return 0
    [[ "$p" =~ ^[0-9]+$ && "$rid" == "$CURRENT_RUN_ID" ]] || return 0
    (( p > RUN_PEAK_TEMP )) && RUN_PEAK_TEMP=$p
    (( p > PEAK_TEMP )) && PEAK_TEMP=$p
    return 0
}
begin_run_peak() {
    CURRENT_RUN_ID=$1
    RUN_PEAK_TEMP=0
    [[ -n "${RUN_ID_STATE:-}" ]] && echo "$1" > "$RUN_ID_STATE"
    return 0
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
    local temp thermal cool_counter=0 pause_start="" in_pause=0
    while true; do
        temp=$(<"$TEMP_STATE")
        thermal=$(<"$THERMAL_STATE")
        sample_peak

        case "$thermal" in
            EMERGENCY|CRITICAL)
                echo
                echo "    !!! ${thermal}: SSD ${temp}°C - stopping write, cooling down !!!"
                if [[ "$thermal" == EMERGENCY ]]; then beep 5; else beep 3; fi
                return 1
                ;;
            PAUSE) in_pause=1 ;;
        esac

        if (( in_pause == 0 )); then
            [[ "$thermal" == WARNING ]] && vlog "thermal WARNING at ${temp}C (writes continue, JPG workers may be throttled)"
            return 0
        fi

        # ---- a PAUSE episode has started: stay here until the drive is back
        # at TEMP_RESUME (not merely below the PAUSE threshold: the monitor's
        # state flips PAUSE -> WARNING at 69 C, which used to end the pause
        # at 69 C although the message promised TEMP_RESUME) ----
        [[ -z "$pause_start" ]] && pause_start=$SECONDS
        # Bounded pause: if the drive cannot cool down within
        # THERMAL_PAUSE_MAX_SECONDS, give up on this run gracefully (same
        # path as CRITICAL: the run ends, test data is deleted, TRIM runs,
        # exit code 2) instead of waiting forever.
        if (( THERMAL_PAUSE_MAX_SECONDS > 0 && SECONDS - pause_start >= THERMAL_PAUSE_MAX_SECONDS )); then
            echo
            echo "    !!! Thermal PAUSE lasted $(( SECONDS - pause_start ))s (limit ${THERMAL_PAUSE_MAX_SECONDS}s) at ${temp}°C - ending this run early instead of waiting forever !!!"
            THERMAL_PAUSE_TIMEOUTS=$((THERMAL_PAUSE_TIMEOUTS + 1))
            beep 3
            return 1
        fi
        printf '\r    Thermal PAUSE at %s°C - waiting for <= %s°C (%s) ... ' "$temp" "$TEMP_RESUME" \
            "$( (( THERMAL_PAUSE_MAX_SECONDS > 0 )) && echo "gives up after ${THERMAL_PAUSE_MAX_SECONDS}s" || echo "no time limit" )"
        sleep 1
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp <= TEMP_RESUME )); then
            cool_counter=$((cool_counter + 1))
        else
            cool_counter=0
        fi
        if (( cool_counter >= COOL_TIME )); then echo; echo "    -> Cooled down to ${temp}°C, resuming."; return 0; fi
    done
}

# Current drive temperature (integer) as last sampled by the background
# thermal monitor - no extra nvme/smartctl call. Prints nothing if unknown.
current_temp() {
    local t=""
    # A dead monitor would leave a stale value behind - report "unknown".
    if [[ -n "${THERMAL_PID:-}" ]] && ! kill -0 "$THERMAL_PID" 2>/dev/null; then return 0; fi
    if [[ -n "${TEMP_STATE:-}" && -r "$TEMP_STATE" ]]; then t=$(<"$TEMP_STATE"); fi
    if [[ "$t" =~ ^[0-9]+$ ]]; then printf '%s' "$t"; fi
    return 0
}
fmt_ms() { printf '%d:%02d' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; }

# Temperature-based break between runs/passes.
#   ends EARLY : drive <= COOLDOWN_TARGET_EFF for COOLDOWN_STABLE_SECONDS in a
#                row AND at least COOLDOWN_MIN_SECONDS have passed;
#   ends AT CAP: COOLDOWN_MAX_SECONDS reached, drive still warm -> the next run
#                just starts (adapt_settings/thermal_gate handle a warm drive);
#   no sensor  : fixed COOLDOWN_SECONDS break (never above the max).
# It can therefore never wait longer than COOLDOWN_MAX_SECONDS.
adaptive_cooldown() {
    local next=$1 total=$2 mode cap started elapsed t stable=0 reason line cols
    (( COOLDOWN_MAX_SECONDS > 0 )) || return 0
    started=$SECONDS
    t=$(current_temp)
    # The monitor rewrites its state file every second, so a single read can
    # catch it empty for an instant. Only conclude "no sensor" after a few
    # tries, otherwise one unlucky read would silently force the fixed break.
    for _try in 1 2 3; do
        [[ -n "$t" ]] && break
        sleep 1
        t=$(current_temp)
    done
    if [[ -n "$t" ]]; then
        mode=adaptive; cap=$COOLDOWN_MAX_SECONDS
    else
        mode=fixed
        cap=$(( COOLDOWN_SECONDS < COOLDOWN_MAX_SECONDS ? COOLDOWN_SECONDS : COOLDOWN_MAX_SECONDS ))
        echo "  No drive temperature available - using a fixed $(fmt_ms "$cap") break."
    fi
    (( cap > 0 )) || return 0
    cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols >= 40 )) || cols=80
    while true; do
        elapsed=$(( SECONDS - started ))
        t=$(current_temp)
        if [[ "$mode" == adaptive ]]; then
            if [[ -n "$t" ]] && (( t <= COOLDOWN_TARGET_EFF )); then stable=$(( stable + 1 )); else stable=0; fi
            if (( elapsed >= COOLDOWN_MIN_SECONDS && stable >= COOLDOWN_STABLE_SECONDS )); then reason=cooled; break; fi
        fi
        if (( elapsed >= cap )); then
            if [[ "$mode" == fixed ]]; then reason=fixed; else reason=capped; fi
            break
        fi
        if [[ "$mode" == adaptive ]]; then
            printf -v line '  Break before run %d/%d  %s | drive %sC -> <=%sC | steady %d/%ds | limit %s' \
                "$next" "$total" "$(fmt_ms "$elapsed")" "${t:-n/a}" "$COOLDOWN_TARGET_EFF" "$stable" "$COOLDOWN_STABLE_SECONDS" "$(fmt_ms "$cap")"
        else
            printf -v line '  Break before run %d/%d  %s of %s (fixed)' "$next" "$total" "$(fmt_ms "$elapsed")" "$(fmt_ms "$cap")"
        fi
        # Cut to the terminal width and pad: a wrapped line would make every
        # \r redraw scroll a fresh line instead of updating in place.
        printf '\r%-*s' "$(( cols - 1 ))" "${line:0:$(( cols - 1 ))}"
        sleep 1
    done
    elapsed=$(( SECONDS - started ))
    t=$(current_temp)
    BREAK_COUNT=$(( BREAK_COUNT + 1 ))
    SUM_BREAK_SECONDS=$(( SUM_BREAK_SECONDS + elapsed ))
    RUN_COOLDOWN=$(( SUM_BREAK_SECONDS / BREAK_COUNT ))   # real average replaces the estimate (ETA)
    printf '\r%*s\r' "$(( cols - 1 ))" ''
    case "$reason" in
        cooled)
            BREAK_EARLY=$(( BREAK_EARLY + 1 ))
            echo "  Break over after $(fmt_ms "$elapsed"): drive cooled to ${t:-n/a}°C (target <= ${COOLDOWN_TARGET_EFF}°C). Starting run $next/$total." ;;
        capped)
            BREAK_CAPPED=$(( BREAK_CAPPED + 1 ))
            if [[ -n "$t" ]] && (( t <= COOLDOWN_TARGET_EFF )); then
                echo "  Break limit of $(fmt_ms "$cap") reached; drive is at ${t}°C but never stayed <= ${COOLDOWN_TARGET_EFF}°C for ${COOLDOWN_STABLE_SECONDS}s in a row."
            else
                echo "  Break limit of $(fmt_ms "$cap") reached, drive at ${t:-n/a}°C (target <= ${COOLDOWN_TARGET_EFF}°C)."
            fi
            echo "  Not waiting any longer - starting run $next/$total (worker count is reduced automatically if the drive is still warm)." ;;
        *)
            BREAK_FIXED=$(( BREAK_FIXED + 1 ))
            echo "  Fixed break of $(fmt_ms "$elapsed") over. Starting run $next/$total." ;;
    esac
    return 0
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

DASHBOARD_LINES=4
DASHBOARD_INITIALIZED=0
reset_dashboard() { DASHBOARD_INITIALIZED=0; LAST_DASHBOARD_TS=0; }

render_dashboard() {
    local elapsed rate_bps rate_human temp thermal color pct free_now used_since_start
    local overall_pct run_pct_x100 worker_color eta_seconds eta_human remaining_bytes
    elapsed=$(( $(date +%s) - FILL_START ))
    (( elapsed < 1 )) && elapsed=1
    # Reuse the main loop's already-throttled free-space reading instead of
    # spawning another df here - this used to call get_free_bytes() fresh
    # on every dashboard refresh, duplicating the exact df-in-hot-path cost
    # that was already fixed for the main dispatch loop.
    free_now=$FREE_NOW
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
    sample_peak
    case "$thermal" in
        EMERGENCY|CRITICAL) color="$RED" ;;
        PAUSE|WARNING) color="$YELLOW" ;;
        *) color="$GREEN" ;;
    esac
    worker_color="$GREEN"
    (( JPG_ACTIVE >= JPG_JOBS )) && worker_color="$YELLOW"

    remaining_bytes=$(( FILL_TARGET_BYTES - used_since_start ))
    (( remaining_bytes < 0 )) && remaining_bytes=0
    if (( rate_bps > 0 )); then
        eta_seconds=$(( remaining_bytes / rate_bps ))
        eta_human=$(format_time "$eta_seconds")
    else
        eta_human="n/a"
    fi

    if (( DASHBOARD_INITIALIZED == 0 )); then
        printf '\n\n\n\n'
        DASHBOARD_INITIALIZED=1
    fi
    printf '\033[%dA' "$DASHBOARD_LINES"
    # Disable terminal auto-wrap (DECAWM) while drawing so a line longer
    # than the current window width gets clipped instead of soft-wrapping
    # onto an extra physical row - that extra row is what desyncs the
    # cursor-up count above on narrow terminals, causing the redraw to
    # drift downward and pile up instead of overwriting in place.
    printf '\033[?7l'
    printf '\r\033[K    [%s] Overall: %s   Run %d/%d: %s   ETA to reserve: %s\n' \
        "$LEVEL_NAME" "$(render_progress_bar "$overall_pct")" "$run" "$TOTAL_RUNS" "$(render_progress_bar "$pct")" "$eta_human"
    printf '\r\033[K    files:%-6d  free:%6sGiB  rate:%10s  temp:%s%3s°C[%s]%s (peak:%s°C)  trim:%d\n' \
        "$INDEX" "$(format_gib "$free_now")" "$rate_human" \
        "$color" "$temp" "$thermal" "$RESET" "$PEAK_TEMP" "$TRIM_COUNT"
    printf '\r\033[K    workers:%s%d/%d active%s  |  dispatched -> html/txt:%-5d jpg:%-5d bin:%-5d\n' \
        "$worker_color" "$JPG_ACTIVE" "$JPG_JOBS" "$RESET" "$N_HTMLTXT" "$N_JPG" "$N_BIN"
    printf '\r\033[K    elapsed:%s   notify:%s  poweroff:%s\n' "$(format_time "$elapsed")" \
        "$([[ $NOTIFY_ENABLED -eq 1 ]] && echo on || echo off)" "$([[ $POWEROFF_REQUESTED -eq 1 ]] && echo on || echo off)"
    printf '\033[?7h'
}

status_line() {
    local temp thermal color
    temp=$(<"$TEMP_STATE"); thermal=$(<"$THERMAL_STATE")
    sample_peak
    case "$thermal" in
        EMERGENCY|CRITICAL) color="$RED" ;;
        PAUSE|WARNING) color="$YELLOW" ;;
        *) color="$GREEN" ;;
    esac
    printf "    SSD: ${color}%s°C [%s]${RESET}" "$temp" "$thermal"
}

# Print a timestamped phase header so the user can see exactly when
# each sub-step starts and how long the previous one took.
phase_header() {
    local label="$1"
    printf '\n    [%s] %s\n' "$(date '+%H:%M:%S')" "$label"
}

# ------------------------- TRIM -------------------------------
trim_dry_run() { $SUDO fstrim --dry-run -v "$TARGET_DIR"; }

record_trim() {
    local label="${1:-run ${run:-?}/${TOTAL_RUNS:-?}}"
    local out number unit factor free_before free_after free_delta trim_pass_label
    local trim_start_ts=$(date +%s) this_trim_bytes=0
    free_before=$(get_free_bytes)
    TRIM_COUNT=$((TRIM_COUNT + 1))
    trim_pass_label="TRIM pass #${TRIM_COUNT}"
    notify_trim_start "$label" "$free_before"
    printf '    -> [%s] %s: running fstrim...\n' "$(date '+%H:%M:%S')" "$trim_pass_label"
    if ! out=$($SUDO fstrim -v "$TARGET_DIR" 2>&1); then
        echo "$out"; echo "TRIM failed. Aborting."; exit 1
    fi
    printf '    -> %s\n' "$out"
    if (( POST_TRIM_IDLE > 0 )); then
        printf '    -> Post-TRIM idle: %ds  ' "$POST_TRIM_IDLE"
        local i
        for (( i = POST_TRIM_IDLE; i > 0; i-- )); do
            printf '\r    -> Post-TRIM idle: %ds remaining...  ' "$i"
            sleep 1
        done
        printf '\r    -> Post-TRIM idle: done.              \n'
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
            this_trim_bytes=$((number * factor))
            TRIM_BYTES_APPROX=$((TRIM_BYTES_APPROX + this_trim_bytes))
        fi
    fi
    # Post-TRIM verification: free space as seen by the filesystem should not
    # have dropped after a TRIM (TRIM only ever discards already-free extents;
    # a drop here would indicate something wrote to TARGET_DIR concurrently,
    # e.g. a second instance of this script or an unrelated process).
    # NOTE on interpretation: `df`-visible free space is freed by the
    # preceding delete, not by fstrim itself - fstrim only issues a discard
    # to the block device and does not change filesystem-level free-space
    # accounting. So a delta of ~0 here is NORMAL and does NOT mean TRIM
    # failed. This check only catches a DECREASE (something else wrote to
    # $TARGET_DIR concurrently). The real "did TRIM do anything" signal is
    # the trimmed-bytes line fstrim itself printed above (TRIM_BYTES_APPROX)
    # and the TRIM-vs-written ratio in the final report.
    free_after=$(get_free_bytes)
    if [[ "$free_before" =~ ^[0-9]+$ && "$free_after" =~ ^[0-9]+$ ]]; then
        if (( free_after >= free_before )); then
            free_delta=$(( free_after - free_before ))
            printf '    -> Free space after TRIM (sanity check, not a TRIM-effect measure): %s GiB (delta vs. pre-TRIM: +%s GiB)\n' \
                "$(format_gib "$free_after")" "$(format_gib "$free_delta")"
        else
            printf '    WARNING: Free space dropped by %s GiB during TRIM.\n' \
                "$(format_gib "$(( free_before - free_after ))")"
            echo "    Something else may be writing to $TARGET_DIR concurrently."
        fi
    fi
    notify_trim_finish "$label" "$(( $(date +%s) - trim_start_ts ))" "$free_after" "$this_trim_bytes"
}

# ------------------------- Manifest / Report -----------------
# BLAKE2b is 3-5x faster than SHA-256 for this per-file re-read while
# remaining cryptographically strong - pure speedup for the manifest
# audit trail, has no bearing on the actual overwrite/TRIM test quality.
MANIFEST_HASH_CMD="sha256sum"
MANIFEST_HASH_LABEL="SHA256"
if command -v b2sum >/dev/null 2>&1; then
    MANIFEST_HASH_CMD="b2sum"
    MANIFEST_HASH_LABEL="BLAKE2B"
fi

manifest_file() {
    local path="$1" type="$2" run="$3" file="$4" pattern="$5" size hash relative_path
    size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    if (( CLI_NO_MANIFEST_HASH == 1 )); then
        hash="SKIPPED"
    else
        # Bounded: this re-read has no protection anywhere else in the
        # pipeline (unlike create_jpg's magick call, which has its own
        # 30s timeout). Right as free space bottoms out at the reserve
        # floor, disk read/write latency can spike badly - this used to
        # be an unbounded hang point for ANY file type, not just JPG,
        # making the outer 180s "still waiting" straggler harder to
        # diagnose since it looked JPG-specific but wasn't necessarily.
        hash=$(timeout 20 "$MANIFEST_HASH_CMD" "$path" 2>/dev/null | awk '{print $1}' || true)
        [[ -z "$hash" ]] && hash="TIMEOUT_OR_ERROR"
    fi
    if [[ "$path" == "$RUN_DIR/"* ]]; then relative_path="./${path#"$RUN_DIR/"}"; else relative_path="$path"; fi
    printf 'TYPE=%s\tLEVEL=%s\tRUN=%02d\tFILE=%s\tPATTERN=%s\tSIZE=%s\t%s=%s\tPATH=%s\n' \
        "$type" "$LEVEL_NAME" "$run" "$file" "$pattern" "$size" "$MANIFEST_HASH_LABEL" "$hash" "$relative_path" >> "$MANIFEST_FILE"
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
        echo "Runs:          $TOTAL_RUNS$([[ $REPEAT_COUNT -gt 1 ]] && echo " ($REPEAT_COUNT passes x $BASE_RUNS runs)")"
        echo "Power off:     $([[ $POWEROFF_REQUESTED -eq 1 ]] && echo "requested after finish" || echo "no")"
        echo "Sleep inhibit: $INHIBIT_STATE"
        echo "Notifications: $([[ $NOTIFY_ENABLED -eq 1 ]] && echo "on ($NOTIFY_SERVER)" || echo off)"
        echo "Recommendation: $ANALYSIS_RECOMMENDATION"
        echo "Reason:        $ANALYSIS_REASON"
        echo "Worker threads: $JPG_JOBS"
        echo "Cooldown:      adaptive, target <= ${COOLDOWN_TARGET_EFF}°C, min ${COOLDOWN_MIN_SECONDS}s, max ${COOLDOWN_MAX_SECONDS}s (fixed ${COOLDOWN_SECONDS}s without sensor)"
        echo "Reserve kept free per run: ${RESERVE_MB} MiB"
        echo "Temp limits: WARNING=$TEMP_WARNING PAUSE=$TEMP_PAUSE RESUME=$TEMP_RESUME CRITICAL=$TEMP_CRITICAL EMERGENCY=$TEMP_EMERGENCY"
        echo
        echo "This report documents the test only. It is not a guarantee of physical NAND erasure."
    } > "$REPORT_FILE"
}

# ------------------------- Analysis ---------------------------
# (removed: unused estimate_profile_runs() - dead code, never called)

# Reads the learned average fill rate (bytes/sec) and sample count for a
# level, if any history exists yet. Echoes "rate_bps samples", or nothing.
read_history() {
    local level="$1" line
    [[ -f "$HISTORY_FILE" ]] || return 0
    line=$(grep "^${level} " "$HISTORY_FILE" 2>/dev/null | tail -n 1 || true)
    [[ -n "$line" ]] && awk '{print $2, $3}' <<< "$line"
    return 0
}

# Rolling average, capped at HISTORY_MAX_SAMPLES so it stays adaptive to
# a machine/drive that changes over time (thermal paste degrading, drive
# filling up over its life, a different drive entirely) instead of
# permanently converging to one value from years-old runs.
update_history() {
    local level="$1" this_rate_bps="$2" existing old_rate="" old_samples=0 new_rate new_samples tmp_file
    [[ "$this_rate_bps" =~ ^[0-9]+$ ]] && (( this_rate_bps > 0 )) || return 0
    existing=$(read_history "$level")
    if [[ -n "$existing" ]]; then
        old_rate=$(awk '{print $1}' <<< "$existing")
        old_samples=$(awk '{print $2}' <<< "$existing")
    fi
    if [[ -z "$old_rate" || "$old_samples" -eq 0 ]]; then
        new_rate=$this_rate_bps
        new_samples=1
    else
        new_samples=$(( old_samples + 1 ))
        (( new_samples > HISTORY_MAX_SAMPLES )) && new_samples=$HISTORY_MAX_SAMPLES
        new_rate=$(( (old_rate * (new_samples - 1) + this_rate_bps) / new_samples ))
    fi
    tmp_file="$HISTORY_FILE.tmp.$$"
    {
        [[ -f "$HISTORY_FILE" ]] && grep -v "^${level} " "$HISTORY_FILE" 2>/dev/null || true
        echo "${level} ${new_rate} ${new_samples}"
    } > "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$HISTORY_FILE" 2>/dev/null || true
    return 0
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
    reason="TRIM is available, free space is ample, wear is low, and no health warning is present"
    endurance="UNKNOWN"
    [[ "$pct" =~ ^([0-9]+)%$ ]] && endurance=$(endurance_status "${BASH_REMATCH[1]}")

    local free_gb=$(( free / 1024 / 1024 / 1024 ))
    local wear_num=""
    [[ "$pct" =~ ^([0-9]+)%$ ]] && wear_num="${BASH_REMATCH[1]}"

    if [[ "$health" == "FAILED" ]]; then
        recommendation="STOP"; reason="SMART reports FAILED"
    elif [[ "$critical" =~ ^[1-9][0-9]*$ ]]; then
        recommendation="STOP"; reason="NVMe reports Critical Warning != 0"
    # SEVERE risk -> NORMAL (1 quick run, minimize additional stress/time)
    elif [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_CRITICAL )); then
        recommendation="NORMAL"; reason="SSD starts at a critical temperature"
    elif [[ -n "$wear_num" ]] && (( wear_num >= 80 )); then
        recommendation="NORMAL"; reason="high reported SSD endurance consumption (${pct})"
    elif (( free_gb < 5 )); then
        recommendation="NORMAL"; reason="very little free space (<5 GiB)"
    # MODERATE risk -> RESTRICTED (2 runs, still random data, less repetition)
    elif [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= TEMP_WARNING )); then
        recommendation="RESTRICTED"; reason="SSD starts at/above the warning temperature (${temp}C)"
    elif [[ -n "$wear_num" ]] && (( wear_num >= 50 )); then
        recommendation="RESTRICTED"; reason="moderate-to-high reported SSD endurance consumption (${pct})"
    elif (( free_gb < 20 )); then
        recommendation="RESTRICTED"; reason="limited free space (${free_gb} GiB < 20 GiB)"
    # MILD risk -> SECRET (3 runs, varied patterns, one tier below max)
    elif [[ -n "$wear_num" ]] && (( wear_num >= 21 )); then
        recommendation="SECRET"; reason="some reported SSD endurance consumption (${pct}), not yet high enough to limit further"
    elif (( free_gb < 50 )); then
        recommendation="SECRET"; reason="moderate free space (${free_gb} GiB < 50 GiB)"
    fi

    ANALYSIS_RECOMMENDATION="$recommendation"
    ANALYSIS_REASON="$reason"

    # ---- Color coding for at-a-glance status ----
    local health_color endurance_color critical_color rec_color temp_color
    case "$health" in
        PASSED) health_color="$GREEN" ;;
        FAILED) health_color="$RED" ;;
        *) health_color="$YELLOW" ;;
    esac
    case "$endurance" in
        EXCELLENT|GOOD) endurance_color="$GREEN" ;;
        MODERATE) endurance_color="$YELLOW" ;;
        HIGH|CRITICAL) endurance_color="$RED" ;;
        *) endurance_color="$YELLOW" ;;
    esac
    if [[ "$critical" =~ ^[1-9][0-9]*$ ]]; then critical_color="$RED"; else critical_color="$GREEN"; fi
    if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= TEMP_WARNING )); then temp_color="$YELLOW"; else temp_color="$GREEN"; fi
    case "$recommendation" in
        PARANOIA|SECRET) rec_color="$GREEN" ;;
        RESTRICTED|NORMAL) rec_color="$YELLOW" ;;
        STOP) rec_color="$RED" ;;
        *) rec_color="$RESET" ;;
    esac

    local bar="────────────────────────────────────────────────────"
    echo
    printf '%s' "$BOLD$CYAN"
    echo "┌${bar}┐"
    printf '│ %-52s │\n' "SYSTEM / SSD ANALYSIS"
    echo "├${bar}┤"
    printf '%s' "$RESET"

    printf '%s│%s Drive & filesystem\n' "$CYAN" "$RESET"
    printf '    %-20s %s\n' "Model:"       "$(lsblk -dno MODEL "$ROOT_DEVICE" 2>/dev/null || echo unknown)"
    printf '    %-20s %s\n' "Transport:"   "${TRANSPORT:-unknown}"
    printf '    %-20s %s\n' "Filesystem:"  "$HOME_FS"
    printf '    %-20s %s\n' "Mountpoint:"  "$HOME_TARGET"
    printf '    %-20s %s\n' "TRIM:"        "available"
    echo

    printf '%s│%s Capacity\n' "$CYAN" "$RESET"
    printf '    %-20s %s (%s%%)\n' "Free space:" "$(format_gib "$free") GiB" "$free_pct"
    printf '    %-20s %s\n' "Reserve/run:" "${RESERVE_MB} MiB (fill continues until only this remains free)"
    printf '    %-20s Normal=1  Secret=%s  Paranoia=%s\n' "Runs per level:" "$SECRET_RUNS" "$PARANOIA_RUNS"
    echo

    printf '%s│%s SSD health & degradation\n' "$CYAN" "$RESET"
    printf '    %-20s %s%s%s\n'   "Temperature:"       "$temp_color" "${temp:-n/a} °C" "$RESET"
    printf '    %-20s %s%s%s\n'   "SMART health:"      "$health_color" "${health:-n/a}" "$RESET"
    printf '    %-20s %s%s%s\n'   "Critical Warning:"  "$critical_color" "${critical:-n/a}" "$RESET"
    printf '    %-20s %s\n'       "Available Spare:"   "${spare:-n/a}"
    if [[ "$pct" =~ ^([0-9]+)%$ ]]; then
        local pct_num="${BASH_REMATCH[1]}" remaining
        remaining=$((100 - pct_num)); (( remaining < 0 )) && remaining=0
        printf '    %-20s ~%s%% used / ~%s%% remaining (controller estimate)\n' "Wear (Percentage Used):" "$pct_num" "$remaining"
        printf '        %s' "$(render_progress_bar "$pct_num")"; printf ' worn\n'
    else
        printf '    %-20s n/a\n' "Wear (Percentage Used):"
    fi
    printf '    %-20s %s%s%s\n' "Endurance status:" "$endurance_color" "$endurance" "$RESET"
    echo

    printf '%s│%s Recommendation\n' "$CYAN" "$RESET"
    printf '    %-20s %s%s%s\n' "Suggested level:" "$rec_color$BOLD" "$recommendation" "$RESET"
    printf '    %-20s %s\n' "Reason:" "$reason"

    printf '%s' "$BOLD$CYAN"
    echo "└${bar}┘"
    printf '%s\n' "$RESET"
}

# ------------------------- Adaptive settings -----------------
adapt_settings() {
    if [[ -n "$CLI_JOBS" ]]; then
        JPG_JOBS=$CLI_JOBS
        vlog "adapt_settings: skipped (--jobs=$CLI_JOBS pinned, no CPU/temp/free-space analysis)"
        return 0
    fi
    local temp=$1 free=$2 base prev_jobs=$JPG_JOBS reason=""
    CPU_THREADS=$(nproc)
    # Start at the full worker ceiling - only ever scale DOWN from here for
    # heat or low free space. Previously this started at half of the max
    # and never scaled back up, so the higher ceiling was never actually
    # reached in adaptive mode.
    base=$JPG_JOBS_MAX
    JPG_JOBS=$base

    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        if (( temp >= TEMP_PAUSE )); then
            JPG_JOBS=1; reason="temp ${temp}C >= pause threshold ${TEMP_PAUSE}C"
        elif (( temp >= TEMP_WARNING )); then
            JPG_JOBS=$(( JPG_JOBS_MAX / 2 )); (( JPG_JOBS < 2 )) && JPG_JOBS=2
            reason="temp ${temp}C >= warning threshold ${TEMP_WARNING}C"
        fi
    fi
    if (( free < 20 * 1024 * 1024 * 1024 )); then
        if (( JPG_JOBS > 2 )); then
            JPG_JOBS=2
            reason="${reason:+$reason, }low free space ($(format_gib "$free") GiB < 20 GiB)"
        fi
    fi
    if (( JPG_JOBS != prev_jobs )); then
        printf '    -> [%s] adapt_settings: JPG workers %d->%d%s\n' \
            "$(date '+%H:%M:%S')" "$prev_jobs" "$JPG_JOBS" \
            "${reason:+ ($reason)}"
    else
        vlog "adapt_settings: no change (JPG workers $JPG_JOBS, temp ${temp}C, free $(format_gib "$free") GiB)"
    fi
    return 0
}

# ------------------------- File generators ---------------------
# Append $bytes of incompressible filler from the pre-generated random pool
# (fast disk read) instead of reading /dev/urandom directly (CPU-bound,
# often slower than the NVMe write path it's meant to be feeding).
fill_from_pool() {
    local path="$1" bytes="$2" idx="$3" pool_bytes skip
    if [[ -n "$RANDOM_POOL" && -s "$RANDOM_POOL" ]]; then
        pool_bytes=$(stat -c%s "$RANDOM_POOL")
        if (( pool_bytes > bytes )); then
            skip=$(( (idx * bytes) % (pool_bytes - bytes) ))
        else
            skip=0
        fi
        # skip_bytes/count_bytes read exact byte offsets/lengths directly,
        # no piping through head needed (a dd|head pipe here previously
        # caused a SIGPIPE -> pipefail -> set -e -> silent script exit
        # the moment head closed the pipe early).
        dd if="$RANDOM_POOL" of="$path" bs=1M iflag=skip_bytes,count_bytes \
            skip="$skip" count="$bytes" conv=notrunc oflag=append status=none 2>/dev/null \
            || head -c "$bytes" /dev/urandom >> "$path"
    else
        # No pool means LEVEL_NAME is NORMAL (Restricted/Secret/Paranoia all
        # generate one) - NORMAL is documented to use zeros for speed, same
        # as create_binary_test_file's BIN files. This used to fall back to
        # /dev/urandom here, silently giving Normal-level HTML/TXT files
        # real random data while its BIN files stayed zero-filled -
        # inconsistent with the level's own stated design intent.
        head -c "$bytes" /dev/zero >> "$path"
    fi
}

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
    # Was: `head -c "$remaining" /dev/urandom` - direct /dev/urandom reads are
    # CPU-bound and were the actual bottleneck here, often slower than the
    # NVMe write path itself once several workers run concurrently. Now uses
    # the same pre-generated incompressible pool as TXT/BIN (fill_from_pool),
    # which is a fast disk/page-cache read instead of live CSPRNG output.
    (( remaining > 0 )) && fill_from_pool "$TEST_DIR/file-$i.html" "$remaining" "$i"
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
    (( remaining > 0 )) && fill_from_pool "$TEST_DIR/file-$i.txt" "$remaining" "$i"
    manifest_file "$TEST_DIR/file-$i.txt" TXT "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$TEST_DIR/file-$i.txt")"
}

create_jpg() {
    local i="$1" run="$2" quality="$3" pattern="$4" file_id output
    file_id=$(printf '%06d' "$i")
    output="$TEST_DIR/file-$i.jpg"
    # Resource limits are critical here: without them, ImageMagick can spill
    # its pixel cache to a disk temp file once the default policy.xml
    # memory/map limits are hit. With several workers running concurrently
    # right as free space bottoms out at the reserve floor, that disk-cache
    # spill can stall/retry instead of failing cleanly, hanging the run.
    # -limit disk 0 forces a clean failure instead of a silent hang if the
    # image genuinely can't fit in memory/map budget.
    if ! timeout 30 "${IM_CMD[@]}" -limit memory 64MiB -limit map 128MiB -limit disk 0 \
        -size 1920x1080 xc:gray -seed "$((run * 1000000 + i))" -attenuate 0.8 +noise Random \
        -gravity center -fill white -stroke black -strokewidth 3 -pointsize 48 \
        -annotate 0 "WIPE-TEST\nLEVEL: $LEVEL_NAME\nRUN: $run\nFILE: $file_id\nPATTERN: $pattern" \
        -quality "$quality" "$output" 2>>"$RUN_DIR/run.log"; then
        echo "    !! WARNING: JPG worker $file_id timed out or failed (low disk/memory) - skipped." >&2
        rm -f -- "$output" 2>/dev/null
        return 1
    fi
    manifest_file "$output" JPG "$run" "$file_id" "$pattern"
    add_written "$(stat -c%s "$output")"
    vlog "file $i: JPG worker done ($(stat -c%s "$output" 2>/dev/null || echo '?') bytes)"
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
    local t0; t0=$(date +%s)
    printf '    -> [%s] Generating %d MiB incompressible random pool for this run...\n' "$(date '+%H:%M:%S')" "$RANDOM_POOL_SIZE_MIB"
    if command -v openssl >/dev/null 2>&1; then
        vlog "trying openssl AES-256-CTR keystream (faster than /dev/urandom)"
        openssl enc -aes-256-ctr -pbkdf2 -pass pass:"$(date +%s%N)-$$" -nosalt \
            < /dev/zero 2>/dev/null | head -c $((RANDOM_POOL_SIZE_MIB * 1024 * 1024)) > "$RANDOM_POOL" || true
    fi
    if [[ ! -s "$RANDOM_POOL" ]]; then
        vlog "openssl unavailable/failed - falling back to /dev/urandom (slower)"
        head -c $((RANDOM_POOL_SIZE_MIB * 1024 * 1024)) /dev/urandom > "$RANDOM_POOL"
    fi
    printf '    -> [%s] Random pool ready (%ds).\n' "$(date '+%H:%M:%S')" "$(( $(date +%s) - t0 ))"
    # BUG FIX: this 256 MiB/run of real, physically-written data was never
    # counted via add_written(), yet it lives in $TEST_DIR and gets deleted
    # + fstrim'd just like every other test file. That under-counted
    # NOMINAL_WRITTEN_BYTES relative to what fstrim actually reports as
    # trimmed, silently inflating the "TRIM vs. written ratio" in the final
    # report (sometimes past 100%) - i.e. it could mask a real TRIM problem
    # by making the ratio look better than it is.
    [[ -f "$RANDOM_POOL" ]] && add_written "$(stat -c%s "$RANDOM_POOL" 2>/dev/null || echo 0)"
}

create_binary_test_file() {
    local path="$1" size_mib="$2" run="$3" file_id="$4" pattern="$5"
    # Zeros are trivially compressible / some controllers (inline
    # compression, SandForce-style) may not actually commit them to
    # physical NAND, which defeats the point of an overwrite test.
    # Random data forces real, incompressible physical writes.
    # NORMAL keeps zeros for speed; RESTRICTED/SECRET/PARANOIA use random
    # data since maximizing real overwrite is the whole point there.
    local src="/dev/zero" pool_skip=0
    if [[ "$LEVEL_NAME" == "RESTRICTED" || "$LEVEL_NAME" == "SECRET" || "$LEVEL_NAME" == "PARANOIA" ]]; then
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
    # Was: `dd bs=1` - one syscall per byte to write ~100 bytes of marker
    # text. Harmless at small scale but wasteful and needless overhead per
    # BIN file. Same result (overwrite first N bytes, keep rest via
    # conv=notrunc), one write instead of ~100.
    local marker
    marker=$(printf 'WIPE-TEST | LEVEL=%s | RUN=%02d | FILE=%s | PATTERN=%s | FS=%s | ALLOC=%s\n' \
        "$LEVEL_NAME" "$run" "$file_id" "$pattern" "$FILESYSTEM_PROFILE" "$BINARY_MODE")
    printf '%s' "$marker" | dd of="$path" bs="${#marker}" count=1 conv=notrunc status=none
    manifest_file "$path" BIN "$run" "$file_id" "$pattern"
    # BUG FIX: FRAGMENTED mode seeks past 1 MiB gaps between chunks on
    # purpose (to fragment allocation), which makes the file's apparent
    # size (stat -c%s, including those unwritten sparse holes) bigger than
    # what was actually written. The real bytes written is exactly
    # size_mib (every chunk's `take` MiB sums to size_mib) - use that
    # instead of the inflated logical size, so it doesn't overstate real
    # write volume in the "Nominal data written" report.
    if [[ "$BINARY_MODE" == "FRAGMENTED" ]]; then
        add_written "$((size_mib * 1024 * 1024))"
    else
        add_written "$(stat -c%s "$path")"
    fi
}
export -f create_jpg
export TEST_DIR LEVEL_NAME

# ------------------------- --cleanup --------------------------
# Recovery after a crash / power cut / kill -9: the normal cleanup never got
# to run, so test files may still fill the drive and swap may still be off.
run_leftover_cleanup() {
    local d sz total=0 n=0 answer removed=0
    local -a dirs=() sizes=()
    echo "Looking for leftovers of interrupted runs under: $RUN_ROOT"
    if [[ -d "$RUN_ROOT" ]]; then
        while IFS= read -r -d '' d; do
            # Only real (non-symlink) directories named exactly "test-data",
            # exactly one level below a run folder inside our own RUN_ROOT.
            [[ -L "$d" ]] && continue
            [[ "$d" == "$RUN_ROOT"/*/test-data ]] || continue
            sz=$(du -sb -- "$d" 2>/dev/null | cut -f1); sz=${sz:-0}
            dirs+=("$d"); sizes+=("$sz"); total=$(( total + sz )); n=$(( n + 1 ))
        done < <(find "$RUN_ROOT" -mindepth 2 -maxdepth 2 -type d -name test-data -print0 2>/dev/null)
    fi
    if (( n > 0 )); then
        echo "Found $n leftover test-data folder(s), $(human "$total") in total:"
        for (( d = 0; d < n; d++ )); do printf '  %s  (%s)\n' "${dirs[$d]}" "$(human "${sizes[$d]}")"; done
    else
        echo "No leftover test-data folders found."
    fi
    if [[ -e "$SWAP_MARKER" ]]; then
        echo "Swap was disabled by an earlier run of this script and never switched back on."
    fi
    if (( n == 0 )) && [[ ! -e "$SWAP_MARKER" ]]; then
        echo "Nothing to clean up."
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        echo "--dry-run given: nothing was changed."
        return 0
    fi
    if (( n > 0 )); then
        if (( CLI_YES == 1 )); then answer=y; else read -rp "Delete these $n folder(s)? Reports and logs are kept. [y/N]: " answer || answer=""; fi
        if is_yes "$answer"; then
            for (( d = 0; d < n; d++ )); do
                rm -rf -- "${dirs[$d]}" && removed=$(( removed + 1 ))
            done
            echo "Removed $removed folder(s)."
        else
            echo "Left the test data in place."
        fi
    fi
    if [[ -e "$SWAP_MARKER" ]]; then
        if (( CLI_YES == 1 )); then answer=y; else read -rp "Switch swap back on now ($SUDO swapon -a)? [y/N]: " answer || answer=""; fi
        if is_yes "$answer"; then
            if $SUDO swapon -a 2>/dev/null; then rm -f -- "$SWAP_MARKER"; echo "Swap re-enabled."
            else echo "!! swapon -a failed - re-enable swap manually."; fi
        fi
    fi
    if (( removed > 0 )); then
        if (( CLI_YES == 1 )); then answer=y; else read -rp "Run TRIM now so the freed space is discarded ($SUDO fstrim -v)? [y/N]: " answer || answer=""; fi
        if is_yes "$answer"; then sync; $SUDO fstrim -v "$TARGET_DIR" || echo "!! fstrim failed."; fi
    fi
    return 0
}
if (( CLI_CLEANUP == 1 )); then
    run_leftover_cleanup
    exit 0
fi

# ------------------------- System checks ----------------------
if (( ${#IM_CMD[@]} == 0 )); then
    echo "Missing program: ImageMagick (needs 'magick' (v7) or 'convert' (v6))."
    exit 1
fi
for cmd in bash fstrim findmnt lsblk df stat dd sync awk grep head tail sed sha256sum tee nproc mktemp; do
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
    printf '%s' "$BOLD$RED"
    echo "============================================================"
    echo "                  IMPORTANT WARNINGS"
    echo "============================================================"
    printf '%s' "$RESET$YELLOW"
    for w in "${DISCARD_WARNINGS[@]:-}"; do
        [[ -n "$w" ]] && { echo; echo "!! $w"; }
    done
    [[ -n "$BTRFS_SNAPSHOT_WARNING" ]] && { echo; echo "!! $BTRFS_SNAPSHOT_WARNING"; }
    [[ -n "$SWAP_WARNING" ]] && { echo; echo "!! $SWAP_WARNING"; }
    printf '%s\n' "$RESET"
    echo "If any of the above applies, TRIM may report success while"
    echo "leaving old data recoverable. Fix it first, or accept the risk."
    printf '%s' "$BOLD$RED"
    echo "============================================================"
    printf '%s\n' "$RESET"
    if (( CLI_YES == 1 )); then
        echo "(--yes given: continuing despite the warnings above.)"
    else
        read -rp "Continue anyway? [y/N]: " WARN_CONFIRM
        is_yes "$WARN_CONFIRM" || exit 0
    fi
    if [[ -n "$SWAP_WARNING" ]]; then
        if (( CLI_SWAPOFF == 1 )); then
            SWAPOFF_REQUESTED=1
        elif (( CLI_YES == 0 )); then
            read -rp "Run '$SUDO swapoff -a' now for this session (swapon -a restores it after)? [y/N]: " SWAPOFF_CONFIRM
            is_yes "$SWAPOFF_CONFIRM" && SWAPOFF_REQUESTED=1
        fi
        if (( SWAPOFF_REQUESTED == 1 )); then
            vlog "Disabling swap for this session ($SUDO swapoff -a)..."
            if $SUDO swapoff -a 2>/dev/null; then
                SWAP_WAS_DISABLED_BY_SCRIPT=1
                : > "$SWAP_MARKER" 2>/dev/null || true
                vlog "Swap disabled. Will be re-enabled automatically when the script exits."
            else
                echo "    !! swapoff -a failed - continuing with swap still active."
            fi
        fi
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

# Cool-down target: "auto" = the drive's own idle temperature at launch + 5 C,
# clamped so it is never absurdly low (35 C) or so high that it would not
# count as cooled (TEMP_WARNING - 5). A number in COOLDOWN_TARGET_C wins.
if [[ "$COOLDOWN_TARGET_C" != "auto" ]]; then
    COOLDOWN_TARGET_EFF=$COOLDOWN_TARGET_C
elif [[ "$START_TEMP" =~ ^[0-9]+$ ]]; then
    COOLDOWN_TARGET_EFF=$(( START_TEMP + 5 ))
    (( COOLDOWN_TARGET_EFF < 35 )) && COOLDOWN_TARGET_EFF=35
    (( COOLDOWN_TARGET_EFF > TEMP_WARNING - 5 )) && COOLDOWN_TARGET_EFF=$(( TEMP_WARNING - 5 ))
else
    COOLDOWN_TARGET_EFF=50
fi
# Planning estimate of ONE break (real breaks replace this as they happen).
if [[ "$START_TEMP" =~ ^[0-9]+$ ]]; then
    RUN_COOLDOWN=$(( (COOLDOWN_MIN_SECONDS + COOLDOWN_MAX_SECONDS) / 2 ))
else
    RUN_COOLDOWN=$(( COOLDOWN_SECONDS < COOLDOWN_MAX_SECONDS ? COOLDOWN_SECONDS : COOLDOWN_MAX_SECONDS ))
fi

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
    # Each level is supposed to be strictly more thorough than the one
    # below it -- if the ordering is broken (e.g. via env var overrides),
    # bump the higher level up automatically rather than silently shipping
    # a "Paranoia" mode that's weaker than "Secret", or a "Secret" that's
    # weaker than "Restricted".
    if (( RESTRICTED_RUNS <= 1 )); then
        echo "NOTE: RESTRICTED_RUNS ($RESTRICTED_RUNS) was <= 1 (Normal's run count)."
        echo "Restricted is meant to be more thorough than Normal, so it has been"
        echo "raised to 2 runs. Set RESTRICTED_RUNS explicitly to override."
        RESTRICTED_RUNS=2
    fi
    if (( SECRET_RUNS <= RESTRICTED_RUNS )); then
        echo "NOTE: SECRET_RUNS ($SECRET_RUNS) was <= RESTRICTED_RUNS ($RESTRICTED_RUNS)."
        echo "Secret is meant to be more thorough than Restricted, so it has been"
        echo "raised to $((RESTRICTED_RUNS + 1)) runs. Set SECRET_RUNS explicitly to override."
        SECRET_RUNS=$((RESTRICTED_RUNS + 1))
    fi
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
            is_yes "$WEAR_CONFIRM" || exit 0
        fi
    fi
fi

# ------------------------- Menu -------------------------------
# The numbered picker is now the default whenever --level wasn't given
# explicitly - --menu still works (forces the picker even over an
# explicit --level), it's just no longer required to reach it.
# Exception: --yes without --level also skips the picker (falls back to
# CLI_LEVEL's default) since the picker needs a real interactive read,
# which would hang forever in a non-interactive/scripted/cron context
# that passed --yes specifically to avoid needing a human at the keyboard.
if (( (CLI_LEVEL_EXPLICIT == 1 || CLI_YES == 1) && CLI_MENU == 0 )); then
    run_analysis
    case "$CLI_LEVEL" in
        NORMAL)     LEVEL_NAME=NORMAL;     TOTAL_RUNS=1 ;;
        RESTRICTED) LEVEL_NAME=RESTRICTED; TOTAL_RUNS=$RESTRICTED_RUNS ;;
        SECRET)     LEVEL_NAME=SECRET;     TOTAL_RUNS=$SECRET_RUNS ;;
        PARANOIA)   LEVEL_NAME=PARANOIA;   TOTAL_RUNS=$PARANOIA_RUNS ;;
    esac
    echo
    if (( CLI_LEVEL_EXPLICIT == 1 )); then
        echo "--level=$CLI_LEVEL given on the command line: skipping the interactive picker."
    else
        echo "--yes given without --level: defaulting to $CLI_LEVEL (skipping the interactive picker, which needs real input)."
    fi
    if [[ "$ANALYSIS_RECOMMENDATION" == "STOP" ]]; then
        echo
        echo "WARNING: Analysis recommends STOP ($ANALYSIS_REASON), but level"
        echo "$CLI_LEVEL will be honored anyway."
        if (( CLI_YES == 0 && DRY_RUN == 0 )); then
            read -rp "Really continue with --level=$CLI_LEVEL despite the STOP recommendation? [y/N]: " STOP_OVERRIDE_CONFIRM
            is_yes "$STOP_OVERRIDE_CONFIRM" || exit 1
        fi
    elif (( CLI_YES == 0 && DRY_RUN == 0 )); then
        read -rp "Press Enter to continue to the execution plan... " _
    fi
else
while true; do
    run_analysis
    echo
    echo "[0] Run analysis again"
    echo "[1] Normal       - 1 run, fastest baseline"
    echo "[2] Restricted   - ${RESTRICTED_RUNS} runs, random data"
    echo "[3] Secret       - ${SECRET_RUNS} runs, varied patterns"
    echo "[4] Paranoia     - ${PARANOIA_RUNS} runs, highest test workload"
    echo "[5] Use recommendation ($ANALYSIS_RECOMMENDATION)"
    echo "[6] Show analysis and exit"
    echo "[7] Abort"
    echo
    read -rp "Selection [0-7]: " choice
    case "$choice" in
        0) continue ;;
        1) LEVEL_NAME=NORMAL; TOTAL_RUNS=1; break ;;
        2) LEVEL_NAME=RESTRICTED; TOTAL_RUNS=$RESTRICTED_RUNS; break ;;
        3) LEVEL_NAME=SECRET; TOTAL_RUNS=$SECRET_RUNS; break ;;
        4) LEVEL_NAME=PARANOIA; TOTAL_RUNS=$PARANOIA_RUNS; break ;;
        5)
            case "$ANALYSIS_RECOMMENDATION" in
                NORMAL) LEVEL_NAME=NORMAL; TOTAL_RUNS=1 ;;
                RESTRICTED) LEVEL_NAME=RESTRICTED; TOTAL_RUNS=$RESTRICTED_RUNS ;;
                SECRET) LEVEL_NAME=SECRET; TOTAL_RUNS=$SECRET_RUNS ;;
                PARANOIA) LEVEL_NAME=PARANOIA; TOTAL_RUNS=$PARANOIA_RUNS ;;
                STOP) echo "Analysis recommends not starting."; exit 1 ;;
            esac
            break ;;
        6) echo "Analysis finished. No test data was written."; exit 0 ;;
        7) exit 0 ;;
        *) echo "Invalid selection." ;;
    esac
done
fi

# ------------------------- Repeat + power-off questions --------
# Asked HERE (before the plan / final confirmation) so the plan and ETA
# already show the real total, and so a long unattended run never stops
# at a prompt halfway through. Answers can also be given up front with
# --repeat=N / --poweroff / --no-poweroff; with --yes (or --dry-run)
# nothing is asked and the defaults apply (1 pass, no power-off).
BASE_RUNS=$TOTAL_RUNS

if [[ -n "$CLI_REPEAT" ]]; then
    REPEAT_COUNT=$CLI_REPEAT
elif (( CLI_YES == 0 && DRY_RUN == 0 )); then
    echo
    echo "------------------------------------------------------------"
    echo "How many times should the complete $LEVEL_NAME level be run?"
    echo "  One pass = $BASE_RUNS fill/delete/TRIM run(s). Every extra pass repeats"
    echo "  ALL of them again (with a cooldown in between)."
    echo "------------------------------------------------------------"
    while true; do
        read -rp "Number of passes [1]: " REPEAT_INPUT || REPEAT_INPUT=""
        REPEAT_INPUT=${REPEAT_INPUT:-1}
        if [[ "$REPEAT_INPUT" =~ ^[1-9][0-9]?$ ]]; then
            REPEAT_COUNT=$REPEAT_INPUT
            break
        fi
        echo "Please enter a whole number from 1 to 99."
    done
fi
TOTAL_RUNS=$(( BASE_RUNS * REPEAT_COUNT ))
if (( REPEAT_COUNT > 1 )); then
    echo
    echo "Repeat: $REPEAT_COUNT passes x $BASE_RUNS run(s) = $TOTAL_RUNS runs in total."
    echo "NOTE: every additional pass writes the (nearly) full free space again and"
    echo "      consumes real NAND endurance - see the wear notes in the README."
fi

if [[ -n "$CLI_POWEROFF" ]]; then
    POWEROFF_REQUESTED=$CLI_POWEROFF
elif (( CLI_YES == 0 && DRY_RUN == 0 )); then
    echo
    read -rp "Power off the computer automatically when everything has finished? [y/N]: " POWEROFF_CONFIRM || POWEROFF_CONFIRM=""
    if is_yes "$POWEROFF_CONFIRM"; then POWEROFF_REQUESTED=1; else POWEROFF_REQUESTED=0; fi
fi
if (( POWEROFF_REQUESTED == 1 )) && ! command -v systemctl >/dev/null 2>&1 \
        && ! command -v poweroff >/dev/null 2>&1 && ! command -v shutdown >/dev/null 2>&1; then
    echo "WARNING: no systemctl/poweroff/shutdown command found - automatic power-off disabled."
    POWEROFF_REQUESTED=0
fi
(( POWEROFF_REQUESTED == 1 )) && echo "Power-off after a normal finish: ENABLED (30 s abortable countdown; not done after Ctrl-C/abort/errors)."

# ---- push notifications: yes/no first, then the channel name ----
if [[ "$CLI_NOTIFY_MODE" == "off" ]]; then
    NOTIFY_ENABLED=0
elif [[ "$CLI_NOTIFY_MODE" == "on" ]]; then
    NOTIFY_CHANNEL=${CLI_NOTIFY_CHANNEL:-${NOTIFY_CHANNEL_DEFAULT:-$(notify_saved_channel)}}
    if ! [[ "$NOTIFY_CHANNEL" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        echo "--notify: no valid channel. Use --notify=NAME, set NOTIFY_CHANNEL=NAME, or run once interactively to save one."
        exit 1
    fi
    NOTIFY_ENABLED=1
elif (( CLI_YES == 0 && DRY_RUN == 0 )); then
    echo
    echo "------------------------------------------------------------"
    echo "Push notifications (ntfy: $NOTIFY_SERVER)"
    echo "  Get a message on your phone when the test starts and when it ends,"
    echo "  aborts or fails - with runtime, temperatures, data written and wear"
    echo "  status. If power-off is enabled, the message is sent BEFORE the"
    echo "  computer shuts down."
    echo "------------------------------------------------------------"
    read -rp "Send notifications? [y/N]: " NOTIFY_CONFIRM || NOTIFY_CONFIRM=""
    if is_yes "$NOTIFY_CONFIRM"; then
        NOTIFY_DEFAULT_CH=${NOTIFY_CHANNEL_DEFAULT:-$(notify_saved_channel)}
        echo "  Anyone who knows the channel name can read the messages - pick a"
        echo "  hard-to-guess name (e.g. ssdtest-k7x2q9) and subscribe to it in the ntfy app."
        for _attempt in 1 2 3 4 5; do
            read -rp "Channel name${NOTIFY_DEFAULT_CH:+ [$NOTIFY_DEFAULT_CH]}: " NOTIFY_INPUT || NOTIFY_INPUT=""
            NOTIFY_INPUT=${NOTIFY_INPUT:-$NOTIFY_DEFAULT_CH}
            if [[ "$NOTIFY_INPUT" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
                NOTIFY_CHANNEL=$NOTIFY_INPUT
                NOTIFY_ENABLED=1
                notify_save_channel "$NOTIFY_CHANNEL"
                break
            fi
            echo "  Please use 1-64 characters: letters, digits, _ or -"
        done
        (( NOTIFY_ENABLED == 1 )) || echo "  No valid channel given - notifications disabled."
    fi
fi
if (( NOTIFY_ENABLED == 1 )) && ! command -v curl >/dev/null 2>&1; then
    echo "WARNING: 'curl' is not installed - notifications disabled."
    NOTIFY_ENABLED=0
fi

if (( DRY_RUN == 0 )); then
    start_sleep_inhibitor
else
    INHIBIT_STATE="not started in --dry-run"
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
echo "Runs:                $TOTAL_RUNS$([[ $REPEAT_COUNT -gt 1 ]] && echo "  ($REPEAT_COUNT passes x $BASE_RUNS runs)")"
echo "Power off when done: $([[ $POWEROFF_REQUESTED -eq 1 ]] && echo "YES (30 s abortable countdown)" || echo "no")"
echo "Sleep inhibitor:     $INHIBIT_STATE"
echo "Notifications:       $([[ $NOTIFY_ENABLED -eq 1 ]] && echo "ON -> $NOTIFY_SERVER/$NOTIFY_CHANNEL (start + end/abort/fail; before power-off)" || echo off)"
session_risk_warning
echo "CPU Threads:         $CPU_THREADS"
echo "Worker threads:      $JPG_JOBS"
echo "Manifest hashing:    $([[ $CLI_NO_MANIFEST_HASH -eq 1 ]] && echo "OFF (--no-manifest-hash)" || echo "ON ($MANIFEST_HASH_LABEL)")"
echo "SSD Temperature:     ${TEMP_NOW:-n/a} °C"
echo "Free space now:      $(format_gib "$FREE_BYTES") GiB"
echo "Reserve kept free:   ${RESERVE_MB} MiB (per run, then delete+TRIM)"
if (( COOLDOWN_MAX_SECONDS == 0 )); then
    echo "Break between runs:  none (COOLDOWN_MAX_SECONDS=0)"
elif [[ "$START_TEMP" =~ ^[0-9]+$ ]]; then
    echo "Break between runs:  adaptive - until drive <= ${COOLDOWN_TARGET_EFF}°C, min $(fmt_ms "$COOLDOWN_MIN_SECONDS"), HARD LIMIT $(fmt_ms "$COOLDOWN_MAX_SECONDS")"
    echo "                     (idle at launch: ${START_TEMP}°C; in-run thermal pause: $( (( THERMAL_PAUSE_MAX_SECONDS > 0 )) && echo "gives up after $(fmt_ms "$THERMAL_PAUSE_MAX_SECONDS")" || echo "no time limit" ))"
else
    echo "Break between runs:  fixed $(fmt_ms "$RUN_COOLDOWN") (no drive temperature sensor available)"
fi
HIST_EXISTING=$(read_history "$LEVEL_NAME")
if [[ -n "$HIST_EXISTING" ]]; then
    HIST_RATE_BPS=$(awk '{print $1}' <<< "$HIST_EXISTING")
    HIST_SAMPLES=$(awk '{print $2}' <<< "$HIST_EXISTING")
    if [[ "$HIST_RATE_BPS" =~ ^[0-9]+$ ]] && (( HIST_RATE_BPS > 0 )); then
        HIST_PER_RUN_BYTES=$(( FREE_BYTES - RESERVE_BYTES ))
        (( HIST_PER_RUN_BYTES < 0 )) && HIST_PER_RUN_BYTES=0
        HIST_PER_RUN_SECONDS=$(( HIST_PER_RUN_BYTES / HIST_RATE_BPS ))
        HIST_TOTAL_SECONDS=$(( TOTAL_RUNS * HIST_PER_RUN_SECONDS + (TOTAL_RUNS - 1) * RUN_COOLDOWN ))
        PLAN_ETA_SECONDS=$HIST_TOTAL_SECONDS
        echo "Estimated total time: ~$(format_time "$HIST_TOTAL_SECONDS") (learned from $HIST_SAMPLES past run(s) at this level on this system)"
    fi
else
    echo "Estimated total time: n/a (no history yet for $LEVEL_NAME level - will learn after this run)"
fi
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
        if is_yes "$AGG_CONFIRM"; then AGGRESSIVE_ALLOC=1; else AGGRESSIVE_ALLOC=0; fi
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
    NORMAL)     LEVEL_RATIONALE="Normal: 1 fill/delete/TRIM cycle with zero-filled data. Fast baseline check that TRIM runs and free space is reclaimed." ;;
    RESTRICTED) LEVEL_RATIONALE="Restricted: ${TOTAL_RUNS} independent fill/delete/TRIM cycles with incompressible random data (fresh pool each run). More thorough than Normal without Secret's varied-pattern rotation or Paranoia's extras." ;;
    SECRET)     LEVEL_RATIONALE="Secret: ${TOTAL_RUNS} independent fill/delete/TRIM cycles with incompressible random data (fresh pool each run), guarding against a single incomplete TRIM pass." ;;
    PARANOIA)   LEVEL_RATIONALE="Paranoia: ${TOTAL_RUNS} independent fill/delete/TRIM cycles with incompressible random data (fresh pool each run), aggressive fragmented/mixed allocation always on, a tighter ${RESERVE_MB} MiB reserve to reach further into overprovisioned space, an extra verification TRIM pass per run, and secure deletion (shred) of the run's own manifest/log metadata at the end." ;;
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
is_yes "$confirm" || exit 0

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

RUN_STARTED=1
notify_start

echo
echo "5-second countdown..."
for n in 5 4 3 2 1; do echo "$n"; sleep 1; done
echo "START"

# ------------------------- Main runs --------------------------
for run in $(seq 1 "$TOTAL_RUNS"); do
    RUN_START=$(date +%s)
    RUN_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    begin_run_peak "$run"
    PER_RUN_START_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    PER_RUN_HOST_WRITE_DELTA=""
    # Position inside the current pass. Pattern/allocation selection below
    # uses SWEEP_RUN (not the global run counter) so every repeated pass
    # restarts the level's own sequence (e.g. Paranoia: RANDOM, HIGH, ...)
    # instead of continuing with the "later run" branch forever.
    SWEEP_NO=$(( (run - 1) / BASE_RUNS + 1 ))
    SWEEP_RUN=$(( (run - 1) % BASE_RUNS + 1 ))
    mkdir -p "$TEST_DIR"

    if [[ "$LEVEL_NAME" == "RESTRICTED" || "$LEVEL_NAME" == "SECRET" || "$LEVEL_NAME" == "PARANOIA" ]]; then
        echo "    -> Generating $(format_gib $((RANDOM_POOL_SIZE_MIB*1024*1024))) GiB incompressible random pool for this run..."
        generate_random_pool
    fi

    case "$LEVEL_NAME" in
        NORMAL) JPG_QUALITY=92; PATTERN=NORMAL ;;
        RESTRICTED) JPG_QUALITY=92; PATTERN=RANDOM ;;
        SECRET)
            case $((SWEEP_RUN % 3)) in
                1) JPG_QUALITY=92; PATTERN=MIXED ;;
                2) JPG_QUALITY=94; PATTERN=RANDOM ;;
                0) JPG_QUALITY=90; PATTERN=LARGE ;;
            esac ;;
        PARANOIA)
            # Fixed order for the 2 hardest patterns instead of a 4-way
            # rotation: run 1 = RANDOM, run 2 = HIGH.
            case "$SWEEP_RUN" in
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
            case "$SWEEP_RUN" in
                1) BINARY_MODE="FRAGMENTED"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_FRAGMENTED" ;;
                *) BINARY_MODE="MIXED_SIZES"; ALLOC_PATTERN="${FILESYSTEM_PROFILE}_MIXED" ;;
            esac
        else
            case $((SWEEP_RUN % 3)) in
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
    echo "RUN $run / $TOTAL_RUNS | $LEVEL_NAME | $PATTERN$([[ $REPEAT_COUNT -gt 1 ]] && echo " | pass $SWEEP_NO/$REPEAT_COUNT, run $SWEEP_RUN/$BASE_RUNS")"
    echo "============================================================"
    echo "Filesystem: $FILESYSTEM_PROFILE | Alloc: $ALLOC_PATTERN | Worker threads: $JPG_JOBS"
    status_line; echo
    notify_run_start "$run" "$TOTAL_RUNS"

    # -------- [1/3] Cycle-fill until only RESERVE_MB stays free --------
    phase_header "[1/3] Cycling HTML/TXT/JPG/BIN until free space <= ${RESERVE_MB} MiB..."
    FILL_START=$(date +%s)
    FILL_START_FREE=$(get_free_bytes)
    FILL_TARGET_BYTES=$(( FILL_START_FREE - RESERVE_BYTES ))
    (( FILL_TARGET_BYTES < 1 )) && FILL_TARGET_BYTES=1
    INDEX=0
    ABORTED=0
    JPG_ACTIVE=0
    JPG_SKIP_NOTED=0
    N_HTMLTXT=0; N_JPG=0; N_BIN=0
    FILL_PHASE_SECONDS=""; FILL_PHASE_BYTES=""
    FREE_POLL_INTERVAL=8
    FREE_POLL_COUNTER=0
    FREE_NOW=$FILL_START_FREE
    reset_dashboard

    while true; do
        if (( FREE_POLL_COUNTER % FREE_POLL_INTERVAL == 0 )); then
            FREE_NOW=$(get_free_bytes)
        fi
        FREE_POLL_COUNTER=$((FREE_POLL_COUNTER + 1))
        if (( FREE_NOW <= RESERVE_BYTES )); then
            # Confirm with a fresh read before actually stopping - the
            # cached value above can be up to FREE_POLL_INTERVAL dispatches
            # stale, and we don't want to end a run early on stale data.
            FREE_NOW=$(get_free_bytes)
            if (( FREE_NOW <= RESERVE_BYTES )); then
                printf '\n'; echo "    -> Reserve reached (free: $(format_gib "$FREE_NOW") GiB)."
                FILL_PHASE_SECONDS=$(( $(date +%s) - FILL_START ))
                (( FILL_PHASE_SECONDS < 1 )) && FILL_PHASE_SECONDS=1
                FILL_PHASE_BYTES=$(( FILL_START_FREE - FREE_NOW ))
                (( FILL_PHASE_BYTES < 0 )) && FILL_PHASE_BYTES=0
                break
            fi
        fi

        if ! thermal_gate; then
            ABORTED=1
            break
        fi

        INDEX=$((INDEX + 1))
        TYPE_SEL=$(( (INDEX - 1) % 4 ))
        case "$TYPE_SEL" in
            0|1)
                vlog "file $INDEX: dispatching html/txt worker ($((JPG_ACTIVE + 1))/$JPG_JOBS active)"
                create_html_txt "$INDEX" "$run" "$PATTERN" &
                # create_html_txt writes one .html AND one .txt per call, so
                # the dashboard counter needs +2 to reflect actual files,
                # not +1 per dispatch.
                ((JPG_ACTIVE++)) || true; ((N_HTMLTXT+=2)) || true
                if (( JPG_ACTIVE >= JPG_JOBS )); then wait -n || true; ((JPG_ACTIVE--)) || true; fi
                ;;
            2)
                # Give JPG workers headroom above the hard reserve floor so
                # ImageMagick isn't racing other writers for the very last
                # few MiB of disk (that's what caused the silent hang).
                if (( FREE_NOW > RESERVE_BYTES + JPG_SAFETY_MARGIN_BYTES )); then
                    vlog "file $INDEX: dispatching JPG worker ($((JPG_ACTIVE + 1))/$JPG_JOBS active)"
                    create_jpg "$INDEX" "$run" "$JPG_QUALITY" "$PATTERN" &
                    ((JPG_ACTIVE++)) || true; ((N_JPG++)) || true
                    if (( JPG_ACTIVE >= JPG_JOBS )); then wait -n || true; ((JPG_ACTIVE--)) || true; fi
                elif (( JPG_SKIP_NOTED != 1 )); then
                    printf '    -> [%s] Free space within %d MiB of reserve - pausing new JPG workers for rest of this run.\n' \
                        "$(date '+%H:%M:%S')" "$JPG_SAFETY_MARGIN_MB"
                    JPG_SKIP_NOTED=1
                fi
                ;;
            3)
                vlog "file $INDEX: dispatching bin worker ($((JPG_ACTIVE + 1))/$JPG_JOBS active)"
                create_binary_test_file "$TEST_DIR/file-$INDEX.bin" "$BIN_BASE_MIB" "$run" "$(printf '%06d' "$INDEX")" "$PATTERN" &
                ((JPG_ACTIVE++)) || true; ((N_BIN++)) || true
                if (( JPG_ACTIVE >= JPG_JOBS )); then wait -n || true; ((JPG_ACTIVE--)) || true; fi
                ;;
        esac

        if (( INDEX % DASHBOARD_INTERVAL == 0 )); then
            DASHBOARD_NOW_TS=$(date +%s)
            if (( DASHBOARD_NOW_TS - LAST_DASHBOARD_TS >= DASHBOARD_MIN_INTERVAL_S )); then
                { render_dashboard >/dev/tty; } 2>/dev/null || true
                LAST_DASHBOARD_TS=$DASHBOARD_NOW_TS
            fi
        fi
    done

    WORKER_LIST=$(worker_pids)
    # shellcheck disable=SC2086
    set -- $WORKER_LIST; WORKERS_NOW=$#
    if (( WORKERS_NOW > 0 )); then
        printf '    -> [%s] Waiting for %d background worker(s) to finish...\n' "$(date '+%H:%M:%S')" "$WORKERS_NOW"
    fi
    # Bare `wait` here used to block silently, sometimes for a very long
    # time, if a magick worker stalled. Poll instead so progress is always
    # visible, and give up on stragglers after a hard cap.
    WAIT_T0=$(date +%s)
    WAIT_MAX_SECONDS=$WORKER_WAIT_MAX_SECONDS
    while [[ -n "$(worker_pids)" ]]; do
        WAIT_ELAPSED=$(( $(date +%s) - WAIT_T0 ))
        if (( WAIT_ELAPSED > WAIT_MAX_SECONDS )); then
            STRAGGLER_PIDS=$(worker_pids); STRAGGLER_PIDS=${STRAGGLER_PIDS//$'\n'/ }
            printf '\n    !! Background JPG worker(s) exceeded %ds - sending SIGTERM: %s\n' "$WAIT_MAX_SECONDS" "$STRAGGLER_PIDS"
            # shellcheck disable=SC2086
            [[ -n "$STRAGGLER_PIDS" ]] && kill $STRAGGLER_PIDS 2>/dev/null || true
            sleep 5
            STRAGGLER_PIDS=$(worker_pids); STRAGGLER_PIDS=${STRAGGLER_PIDS//$'\n'/ }
            if [[ -n "$STRAGGLER_PIDS" ]]; then
                printf '    !! Still alive after SIGTERM - sending SIGKILL: %s\n' "$STRAGGLER_PIDS"
                # shellcheck disable=SC2086
                kill -9 $STRAGGLER_PIDS 2>/dev/null || true
            fi
            break
        fi
        printf '\r    -> still waiting on background JPG worker(s)... %ds elapsed  ' "$WAIT_ELAPSED"
        sleep 2
    done
    # Reap the finished workers - by PID: a bare `wait` would also wait for the
    # thermal monitor, which never exits, and block forever.
    WORKER_LEFT=$(worker_pids); WORKER_LEFT=${WORKER_LEFT//$'\n'/ }
    # shellcheck disable=SC2086
    [[ -z "$WORKER_LEFT" ]] || wait $WORKER_LEFT 2>/dev/null || true
    recompute_written_bytes
    echo
    echo "    -> $INDEX files created in this run."
    echo "    Test data:"; du -sh "$TEST_DIR" 2>/dev/null || true

    # -------- [2/3] sync + delete --------
    phase_header "[2/3] sync + delete generated files..."
    SYNC_FILE_COUNT=$(find "$TEST_DIR" -type f 2>/dev/null | wc -l || echo "?")
    SYNC_DATA_SIZE=$(du -sh "$TEST_DIR" 2>/dev/null | cut -f1 || echo "?")
    printf '    -> %s files / %s to flush and remove.\n' "$SYNC_FILE_COUNT" "$SYNC_DATA_SIZE"
    SYNC_T0=$(date +%s)
    printf '    -> [%s] sync: flushing kernel buffers to disk...\n' "$(date '+%H:%M:%S')"
    sync &
    SYNC_PID=$!
    while kill -0 "$SYNC_PID" 2>/dev/null; do
        printf '\r    -> sync in progress... %ds elapsed  ' "$(( $(date +%s) - SYNC_T0 ))"
        sleep 2
    done
    wait "$SYNC_PID" 2>/dev/null || true
    printf '\r    -> sync complete (%ds).                      \n' "$(( $(date +%s) - SYNC_T0 ))"
    safe_test_dir || { echo "REFUSING TO DELETE: unsafe TEST_DIR ('$TEST_DIR'). Aborting."; exit 1; }
    printf '    -> [%s] Deleting %s files...\n' "$(date '+%H:%M:%S')" "$SYNC_FILE_COUNT"
    # find -delete instead of a shell glob (rm -rf .../*): with 80k-130k+
    # files, glob expansion can hit ARG_MAX ("Argument list too long"),
    # which made rm fail immediately and silently do almost nothing -
    # masked at the time by the `|| true` needed to stop that failure
    # from killing the whole script under set -e. find walks the
    # directory internally instead of building one giant argument list.
    find "${TEST_DIR:?}" -mindepth 1 -delete 2>/dev/null || true
    DELETE_REMAINING=$(find "${TEST_DIR:?}" -mindepth 1 2>/dev/null | wc -l)
    if (( DELETE_REMAINING > 0 )); then
        printf '    !! WARNING: %d item(s) still remain in %s after delete - retrying...\n' "$DELETE_REMAINING" "$TEST_DIR"
        find "${TEST_DIR:?}" -mindepth 1 -delete 2>/dev/null || true
        DELETE_REMAINING=$(find "${TEST_DIR:?}" -mindepth 1 2>/dev/null | wc -l)
        if (( DELETE_REMAINING > 0 )); then
            printf '    !! ERROR: %d item(s) still remain after retry - this run''s free-space/TRIM results are unreliable.\n' "$DELETE_REMAINING"
            printf '    !! Check permissions or disk errors in %s manually.\n' "$TEST_DIR"
        fi
    fi
    printf '    -> [%s] Deleted (%d item(s) remaining).\n' "$(date '+%H:%M:%S')" "$DELETE_REMAINING"

    # -------- [3/3] TRIM --------
    phase_header "[3/3] TRIM"
    record_trim "run $run/$TOTAL_RUNS"
    if [[ "$LEVEL_NAME" == "PARANOIA" ]]; then
        printf '    -> [%s] Paranoia: waiting 5s before extra verification TRIM pass...\n' "$(date '+%H:%M:%S')"
        sleep 5
        record_trim "run $run/$TOTAL_RUNS, paranoia verify pass"
    fi
    status_line; echo

    sample_peak
    RUN_END=$(date +%s)
    RUN_END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_START_HUMAN_LOG+=("$RUN_START_HUMAN")
    RUN_END_HUMAN_LOG+=("$RUN_END_HUMAN")
    RUN_TIME=$((RUN_END - RUN_START))
    TOTAL_ELAPSED=$((RUN_END - SCRIPT_START))
    CURRENT_FREE=$(get_free_bytes)
    PER_RUN_END_DATA_WRITTEN_BYTES=$(get_data_written_bytes || true)
    if [[ "$PER_RUN_START_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" =~ ^[0-9]+$ && "$PER_RUN_END_DATA_WRITTEN_BYTES" -ge "$PER_RUN_START_DATA_WRITTEN_BYTES" ]]; then
        PER_RUN_HOST_WRITE_DELTA=$((PER_RUN_END_DATA_WRITTEN_BYTES - PER_RUN_START_DATA_WRITTEN_BYTES))
    else
        PER_RUN_HOST_WRITE_DELTA=""
    fi

    if (( ABORTED == 1 )); then ANY_ABORTED=1; ABORTED_RUNS=$(( ABORTED_RUNS + 1 )); fi
    SUM_RUN_TIME=$((SUM_RUN_TIME + RUN_TIME))

    {
        echo "------------------------------------------------------------"
        echo "RUN $run/$TOTAL_RUNS  |  $LEVEL_NAME  |  $PATTERN$([[ $REPEAT_COUNT -gt 1 ]] && echo " (pass $SWEEP_NO/$REPEAT_COUNT)")  |  fs=$FILESYSTEM_PROFILE alloc=$ALLOC_PATTERN aggr=$([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo on || echo off)"
        echo "  start=$RUN_START_HUMAN  end=$RUN_END_HUMAN"
        echo "  files=$INDEX  duration=$(format_time "$RUN_TIME")  free=$(format_gib "$CURRENT_FREE")GiB  peak=${RUN_PEAK_TEMP:-n/a}°C  aborted=$([[ $ABORTED -eq 1 ]] && echo yes || echo no)"
        echo "  nominal_total=$(format_gib "$NOMINAL_WRITTEN_BYTES")GiB  host_write_delta=${PER_RUN_HOST_WRITE_DELTA:+$(format_gib "$PER_RUN_HOST_WRITE_DELTA")GiB}${PER_RUN_HOST_WRITE_DELTA:-n/a}"
    } >> "$REPORT_FILE"

    printf '%d,%d,%s,%s,%s,%s,%s,%d,%d,%d,%s,%s,%d,%s\n' \
        "$run" "$TOTAL_RUNS" "$LEVEL_NAME" "$PATTERN" "$FILESYSTEM_PROFILE" "$ALLOC_PATTERN" \
        "$([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo true || echo false)" "$INDEX" "$RUN_TIME" \
        "$CURRENT_FREE" "${RUN_PEAK_TEMP:-}" "$([[ $ABORTED -eq 1 ]] && echo true || echo false)" \
        "$NOMINAL_WRITTEN_BYTES" "${PER_RUN_HOST_WRITE_DELTA:-}" >> "$CSV_FILE"

    COMPLETED_RUNS=$run
    notify_run_finish "$run" "$TOTAL_RUNS"
    echo
    echo "RUN $run / $TOTAL_RUNS complete"
    echo "  Start time:   $RUN_START_HUMAN"
    echo "  End time:     $RUN_END_HUMAN"
    echo "  Files:        $INDEX"
    echo "  Duration:     $(format_time "$RUN_TIME")  (total elapsed so far: $(format_time "$TOTAL_ELAPSED"))"
    echo "  Free space:   $(format_gib "$CURRENT_FREE") GiB"
    echo "  Peak temp:    ${RUN_PEAK_TEMP:-n/a} °C  (whole session so far: ${PEAK_TEMP:-n/a} °C)"
    echo "  Nominal total: $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"

    if [[ -n "$FILL_PHASE_SECONDS" && -n "$FILL_PHASE_BYTES" ]] && (( ABORTED == 0 )); then
        THIS_RUN_RATE_BPS=$(( FILL_PHASE_BYTES / FILL_PHASE_SECONDS ))
        update_history "$LEVEL_NAME" "$THIS_RUN_RATE_BPS"
    fi

    if (( run < TOTAL_RUNS )); then
        REMAINING_RUNS=$((TOTAL_RUNS - run))
        AVG_RUN_TIME=$((SUM_RUN_TIME / run))
        ETA_SECONDS=$((REMAINING_RUNS * (AVG_RUN_TIME + RUN_COOLDOWN)))   # one break per remaining run, incl. the one right now
        echo "  ETA remaining: ~$(format_time "$ETA_SECONDS") for $REMAINING_RUNS more run(s) (avg run time so far; breaks estimated at ~$(fmt_ms "$RUN_COOLDOWN") each)"
        echo
        adaptive_cooldown "$((run + 1))" "$TOTAL_RUNS"
    fi
done

# ------------------------- Final verification TRIM -------------
# One extra TRIM pass after all runs, in case the last run ended
# early (thermal abort) or the filesystem coalesced freed extents
# that weren't caught by a run-level TRIM.
echo
echo "============================================================"
printf 'FINAL VERIFICATION TRIM  [%s]\n' "$(date '+%H:%M:%S')"
echo "============================================================"
safe_test_dir || { echo "REFUSING TO DELETE: unsafe TEST_DIR ('$TEST_DIR'). Aborting."; exit 1; }
find "${TEST_DIR:?}" -mindepth 1 -delete 2>/dev/null || true
printf '    -> [%s] sync: flushing any remaining buffers...\n' "$(date '+%H:%M:%S')"
sync
printf '    -> [%s] sync done.\n' "$(date '+%H:%M:%S')"
record_trim "final verification"
status_line; echo

# ------------------------- Final metrics ----------------------
recompute_written_bytes
SCRIPT_END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
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
TEMP_ONESHOT_END=$(get_temperature || true)
[[ "$TEMP_ONESHOT_END" =~ ^[0-9]+$ ]] && END_TEMP="$TEMP_ONESHOT_END"

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
    echo "Runs:                     $TOTAL_RUNS$([[ $REPEAT_COUNT -gt 1 ]] && echo " ($REPEAT_COUNT passes x $BASE_RUNS runs)")"
    echo "Filesystem profile:       $FILESYSTEM_PROFILE"
    echo "Aggressive allocation:    $([[ $AGGRESSIVE_ALLOC -eq 1 ]] && echo ON || echo OFF)"
    echo "Reserve kept free/run:    ${RESERVE_MB} MiB"
    if (( BREAK_COUNT > 0 )); then
        echo "Cooldown breaks:          $BREAK_COUNT taken, avg $(fmt_ms $(( SUM_BREAK_SECONDS / BREAK_COUNT ))) ($BREAK_EARLY ended early = cooled, $BREAK_CAPPED hit the $(fmt_ms "$COOLDOWN_MAX_SECONDS") limit, $BREAK_FIXED fixed)"
    fi
    (( THERMAL_PAUSE_TIMEOUTS > 0 )) && echo "Thermal pause timeouts:   $THERMAL_PAUSE_TIMEOUTS (run(s) ended early because the drive would not cool within ${THERMAL_PAUSE_MAX_SECONDS}s)"
    echo "Total duration:           $(format_time "$TOTAL_TIME")"
    echo "Overall start time:       $SCRIPT_START_HUMAN"
    echo "Overall end time:         $SCRIPT_END_HUMAN"
    if (( ${#RUN_START_HUMAN_LOG[@]} > 0 )); then
        echo "Per-run start/end times:"
        for (( _rt_i = 0; _rt_i < ${#RUN_START_HUMAN_LOG[@]}; _rt_i++ )); do
            printf "  run %d: start %s -> end %s\n" \
                "$((_rt_i + 1))" "${RUN_START_HUMAN_LOG[$_rt_i]}" "${RUN_END_HUMAN_LOG[$_rt_i]}"
        done
    fi
    echo "Nominal data written:     $(format_gib "$NOMINAL_WRITTEN_BYTES") GiB"
    if [[ -n "$HOST_WRITE_DELTA" ]]; then
        echo "Controller host writes:   $(format_gib "$HOST_WRITE_DELTA") GiB"
    else
        echo "Controller host writes:   unavailable"
    fi
    echo "Peak temperature:         ${PEAK_TEMP:-n/a} °C"
    if [[ "$START_TEMP" =~ ^[0-9]+$ ]] && [[ "$END_TEMP" =~ ^[0-9]+$ ]]; then
        echo "Temperature (start->end): ${START_TEMP}°C -> ${END_TEMP}°C"
    fi
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
echo "Manifest: $MANIFEST_FILE$([[ $MANIFEST_SHREDDED -eq 1 ]] && echo " (content shredded per Paranoia policy)")"
echo "CSV:      $CSV_FILE"
echo "Log:      $LOG_FILE"

# ------------------------- Final notification -----------------
# Sent BEFORE the optional power-off below, so the message is out before the
# machine goes down. A failed send never blocks the shutdown (max ~12 s).
notify_final

# ------------------------- Optional power-off -----------------
# Only reached after a NORMAL, complete finish. Ctrl-C / SIGTERM go through
# handle_interrupt (exit 130) and errors abort via `set -e`, so neither can
# ever power the machine off. The countdown itself can be cancelled with
# Ctrl-C, which also just exits without powering off.
EXIT_CODE=0
(( ANY_ABORTED == 1 )) && EXIT_CODE=2

if (( POWEROFF_REQUESTED == 1 )); then
    echo
    echo "============================================================"
    printf 'POWER-OFF REQUESTED  [%s]\n' "$(date '+%H:%M:%S')"
    echo "============================================================"
    (( ANY_ABORTED == 1 )) && echo "NOTE: at least one run was cut short by thermal limits; powering off anyway (as requested)."
    echo "Press Ctrl-C within 30 seconds to CANCEL the power-off."
    echo "Power-off countdown started: $(date)" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
    # shellcheck disable=SC2329  # invoked indirectly via trap
    cancel_poweroff() {
        trap - INT TERM
        echo
        echo "Power-off CANCELLED by user. The test itself had already finished."
        echo "Power-off cancelled by user: $(date)" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
        exit "$EXIT_CODE"   # the EXIT trap (cleanup) still runs
    }
    trap cancel_poweroff INT TERM
    for (( po_i = 30; po_i > 0; po_i-- )); do
        printf '\r  Powering off in %2ds ... (Ctrl-C = cancel)  ' "$po_i"
        sleep 1
    done
    printf '\r  Powering off now.                                \n'
    trap - INT TERM
    echo "Powering off: $(date)" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
    sync
    # Run the normal cleanup first (re-enables swap, stops helpers), then
    # disarm the EXIT trap so it doesn't run a second time.
    cleanup
    trap - EXIT
    if command -v systemctl >/dev/null 2>&1 && $SUDO systemctl poweroff; then
        :
    elif command -v poweroff >/dev/null 2>&1 && $SUDO poweroff; then
        :
    elif command -v shutdown >/dev/null 2>&1 && $SUDO shutdown -h now; then
        :
    else
        echo "!! Power-off command failed - please shut the computer down manually."
    fi
fi

# Exit code semantics for scripting/cron:
#   0 = completed, no thermal aborts
#   2 = completed, but at least one run was cut short by thermal limits
exit "$EXIT_CODE"
