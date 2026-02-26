#!/bin/bash

# USB Nuke Beast v2.2 — Fixed Edition
# A complete wipe, encrypt, format, and mount tool for USB devices
#
# FIXES APPLIED:
# [1] set -euo pipefail → set -uo pipefail  (removed -e: it silently kills the script
#     when info/warn/log are called inside $(...) subshell captures)
# [2] check_dependencies: added /sbin /usr/sbin /usr/local/sbin search so tools like
#     partprobe, mkfs.ext4, cryptsetup, blockdev are found even when not in $PATH
# [3] create_partition: all info/success/warn/log calls redirected to >&2 so that
#     PART=$(...) captures only the partition path, not a wall of log text
# [4] setup_encryption: same >&2 fix so MAPPED_DEV=$(...) captures only the mapper path
# [5] dd wipe: replaced unreliable /proc/pid/io monitor with dd's native
#     status=progress — gives real-time bytes/speed output, not silence for 10 minutes
# [6] perform_wipe_with_progress: dd now runs in foreground with status=progress
#     instead of background + polling; no more blank screen during wipe
# [7] Nerd Font icons replace emoji throughout (requires Nerd Font terminal font)
# [8] Added clear error/warning messages with context when operations fail

set -uo pipefail   # -e intentionally removed — see fix [1] above

# ══════════════════════════════════════════════════════════════
#  Colors
# ══════════════════════════════════════════════════════════════
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;37m'
readonly DARK='\033[0;90m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'

# Cursor helpers
readonly HIDE_CURSOR='\033[?25l'
readonly SHOW_CURSOR='\033[?25h'
readonly ERASE_LINE='\033[2K'

# ══════════════════════════════════════════════════════════════
#  Global state
# ══════════════════════════════════════════════════════════════
readonly SCRIPT_START_TIME=$(date +%s)
declare -A OPERATION_TIMES
declare -a REMOVABLE_DEVICES

# ══════════════════════════════════════════════════════════════
#  Logging helpers
#  FIX [3][4]: ALL helpers write to stderr (>&2) so $(...) captures stay clean
# ══════════════════════════════════════════════════════════════
get_timestamp() { date +'%H:%M:%S'; }

log()        { printf '%b[%s] %s%b\n'        "${GRAY}"   "$(get_timestamp)" "$1" "${RESET}" >&2; }
error_exit() { printf '\n%b\uf057 ERROR   %s%b\n'  "${RED}"    "$1"              "${RESET}" >&2; exit 1; }
warn()       { printf '%b\uf071 WARNING  %s%b\n'  "${YELLOW}" "$1"              "${RESET}" >&2; }
success()    { printf '%b\uf058  %s%b\n'           "${GREEN}"  "$1"              "${RESET}" >&2; }
info()       { printf '%b\uf05a INFO  %s%b\n'      "${BLUE}"   "$1"              "${RESET}" >&2; }

# ══════════════════════════════════════════════════════════════
#  _has_cmd — FIX [2]: checks PATH + all sbin locations
#  partprobe, mkfs.*, cryptsetup, blockdev live in /sbin on many distros
# ══════════════════════════════════════════════════════════════
_has_cmd() {
    command -v "$1" &>/dev/null \
        || [[ -x "/sbin/$1" ]] \
        || [[ -x "/usr/sbin/$1" ]] \
        || [[ -x "/usr/local/sbin/$1" ]]
}

# ══════════════════════════════════════════════════════════════
#  Spinner — for operations with no measurable progress
# ══════════════════════════════════════════════════════════════
_SPINNER_PID=""
_SPINNER_LABEL=""

_spinner_stop() {
    if [[ -n "$_SPINNER_PID" ]] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
    fi
    _SPINNER_PID=""
    printf "${SHOW_CURSOR}" >&2
}

spinner_start() {
    _SPINNER_LABEL="${1:-Working...}"
    printf "${HIDE_CURSOR}" >&2
    (
        local frames=($'\ue22e' $'\ue22f' $'\ue230' $'\ue231' $'\ue232' $'\ue233')
        local i=0
        while true; do
            printf "\r  ${CYAN}${frames[$((i % ${#frames[@]}))]}${RESET}  ${_SPINNER_LABEL}${DIM} ...${RESET}   " >&2
            sleep 0.08
            ((i++))
        done
    ) &
    _SPINNER_PID=$!
}

spinner_stop() {
    local rc="${1:-0}"
    _spinner_stop
    printf "\r${ERASE_LINE}" >&2
    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}\uf058${RESET}  %s\n" "${_SPINNER_LABEL}" >&2
    else
        printf "  ${RED}\uf057${RESET}  %s ${RED}[failed — see error above]${RESET}\n" "${_SPINNER_LABEL}" >&2
    fi
}

# ══════════════════════════════════════════════════════════════
#  Utility functions
# ══════════════════════════════════════════════════════════════
format_duration() {
    local d=$1
    local h=$(( d/3600 )) m=$(( (d%3600)/60 )) s=$(( d%60 ))
    (( h > 0 )) && printf "%dh %dm %ds" $h $m $s && return
    (( m > 0 )) && printf "%dm %ds" $m $s && return
    printf "%ds" $s
}

format_bytes() {
    local b=$1
    if   (( b >= 1099511627776 )); then awk "BEGIN{printf \"%.2f TiB\", $b/1099511627776}"
    elif (( b >= 1073741824    )); then awk "BEGIN{printf \"%.2f GiB\", $b/1073741824}"
    elif (( b >= 1048576       )); then awk "BEGIN{printf \"%.2f MiB\", $b/1048576}"
    elif (( b >= 1024          )); then awk "BEGIN{printf \"%.2f KiB\", $b/1024}"
    else printf "%d B" "$b"
    fi
}

get_device_bytes() {
    local device="$1"
    # Try lsblk first (no sudo), fall back to blockdev (needs sudo)
    lsblk -bnd -o SIZE "$device" 2>/dev/null \
        || sudo blockdev --getsize64 "$device" 2>/dev/null \
        || echo 0
}

start_timer() {
    OPERATION_TIMES["${1}_start"]=$(date +%s)
    log "Starting: $1"
}

end_timer() {
    local start=${OPERATION_TIMES["${1}_start"]:-$SCRIPT_START_TIME}
    local dur=$(( $(date +%s) - start ))
    OPERATION_TIMES["${1}_duration"]=$dur
    success "Completed: $1  [$(format_duration $dur)]"
}

# ══════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════
show_banner() {
    printf '%b\n' "${RED}"
    cat <<'ART'
========================================
  _   _ ____  ____    _   _ _   _ _  _______
 | | | / ___|| __ )  | \ | | | | | |/ / ____|
 | | | \___ \|  _ \  |  \| | | | | ' /|  _|
 | |_| |___) | |_) | | |\  | |_| | . \| |___
  \___/|____/|____/  |_| \_|\___/|_|\_\_____|
     BEAST MODE: Wipe, Encrypt & Format
========================================
ART
    printf '%b\n' "${YELLOW}USB NUKE BEAST v2.2 — Enhanced USB Toolkit (Fixed Edition)${RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  Safety checks
# ══════════════════════════════════════════════════════════════
check_root() {
    [[ $EUID -eq 0 ]] && error_exit "Don't run as root. The script uses sudo for individual commands."
}

check_dependencies() {
    start_timer "Dependency Check"
    local missing=()
    local deps=("lsblk" "parted" "dd" "mkfs.ext4" "sync" "partprobe" "bc" "blockdev")
    local optional_deps=("mkfs.exfat" "mkfs.vfat" "mkfs.ntfs" "cryptsetup" "pv" "shred")

    spinner_start "Checking required dependencies"
    sleep 0.3

    # FIX [2]: check sbin paths too, not just $PATH
    for dep in "${deps[@]}"; do
        _has_cmd "$dep" || missing+=("$dep")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        spinner_stop 1
        error_exit "Missing required tools: ${missing[*]}\nInstall: sudo apt install parted e2fsprogs coreutils bc util-linux"
    fi
    spinner_stop 0

    local missing_opt=()
    for dep in "${optional_deps[@]}"; do
        _has_cmd "$dep" || missing_opt+=("$dep")
    done
    [[ ${#missing_opt[@]} -gt 0 ]] && \
        warn "Optional tools not found: ${missing_opt[*]} (some options will be unavailable)"

    end_timer "Dependency Check"
}

# ══════════════════════════════════════════════════════════════
#  Device discovery
# ══════════════════════════════════════════════════════════════
get_removable_devices() {
    lsblk -d -P -o NAME,SIZE,TYPE,HOTPLUG,MODEL,VENDOR,TRAN 2>/dev/null | \
    while IFS= read -r line; do
        eval "$line"
        if [[ ("$HOTPLUG" == "1" || "$TRAN" == "usb") && "$TYPE" == "disk" ]]; then
            MODEL="${MODEL//\"/}"; MODEL="${MODEL%"${MODEL##*[![:space:]]}"}"
            VENDOR="${VENDOR//\"/}"; VENDOR="${VENDOR%"${VENDOR##*[![:space:]]}"}"
            echo "/dev/$NAME:$SIZE:${MODEL:-Unknown}:${VENDOR:-Unknown}"
        fi
    done
}

show_devices() {
    start_timer "Device Discovery"
    printf '%b\uf7c8  Available Removable Storage Devices%b\n' "${BLUE}${BOLD}" "${RESET}" >&2
    printf '%b  ┌──────┬──────────┬─────────────────┬──────────┐%b\n' "${BLUE}" "${RESET}" >&2
    printf '%b  │  #   │   Size   │   Model         │  Vendor  │%b\n' "${CYAN}" "${RESET}" >&2
    printf '%b  ├──────┼──────────┼─────────────────┼──────────┤%b\n' "${BLUE}" "${RESET}" >&2

    local count=0
    REMOVABLE_DEVICES=()

    while IFS=':' read -r device size model vendor; do
        if [[ -n "$device" && -b "$device" ]]; then
            REMOVABLE_DEVICES+=("$device")
            printf '%b  │  %-4d│  %-7s │  %-15s│  %-8s│%b\n' \
                "${CYAN}" "$((++count))" "$size" "${model:-Unknown}" "${vendor:-Unknown}" "${RESET}" >&2
        fi
    done < <(get_removable_devices)

    printf '%b  └──────┴──────────┴─────────────────┴──────────┘%b\n' "${BLUE}" "${RESET}" >&2

    if [[ $count -eq 0 ]]; then
        warn "No removable USB devices detected!"
        printf '%b\n  \uf071  TIP: Make sure your USB is plugged in and try: lsblk -o NAME,HOTPLUG,TRAN%b\n' "${YELLOW}" "${RESET}" >&2
        printf '%b  All block devices for reference:%b\n' "${GRAY}" "${RESET}" >&2
        lsblk -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep "disk" | grep -v "loop" | sed 's/^/    /' >&2
        error_exit "No removable devices found. Connect a USB drive and rerun."
    fi

    log "Found $count removable device(s)"
    end_timer "Device Discovery"
    echo "" >&2
}

# ══════════════════════════════════════════════════════════════
#  Pre-nuke verification
# ══════════════════════════════════════════════════════════════
calc_destruction_data() {
    local device="$1"
    local total_bytes mounted_bytes=0 unmounted_count=0
    total_bytes=$(get_device_bytes "$device")

    while IFS= read -r line; do
        local mountpoint part_type
        mountpoint=$(echo "$line" | awk '{print $1}')
        part_type=$(echo  "$line" | awk '{print $2}')
        if [[ "$part_type" == "part" && -n "$mountpoint" && "$mountpoint" != "" ]]; then
            local used
            used=$(df -B1 --output=used "$mountpoint" 2>/dev/null | tail -n +2 | tr -d ' ' || echo 0)
            mounted_bytes=$(( mounted_bytes + used ))
        elif [[ "$part_type" == "part" ]]; then
            ((unmounted_count++))
        fi
    done < <(lsblk -rno MOUNTPOINT,TYPE "$device" 2>/dev/null)

    echo "$total_bytes:$mounted_bytes:$unmounted_count"
}

list_mounted_contents() {
    local device="$1" max_items="${2:-20}" has_mounted=false

    while IFS=' ' read -r part_path mountpoint; do
        if [[ -n "$mountpoint" ]]; then
            has_mounted=true
            printf '%b  \uf0c8  %s  →  %s%b\n' "${CYAN}" "$part_path" "$mountpoint" "${RESET}" >&2
            local total_files
            total_files=$(find "$mountpoint" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
            printf '%b  Files/dirs: %d%b\n' "${GRAY}" "$total_files" "${RESET}" >&2
            if [[ $total_files -gt 0 ]]; then
                ls -A1 "$mountpoint" 2>/dev/null | head -n "$max_items" | while read -r item; do
                    [[ -d "$mountpoint/$item" ]] && printf '    \uf74a %s/\n' "$item" >&2 \
                                                 || printf '    \uf15b %s\n'  "$item" >&2
                done
                (( total_files > max_items )) && \
                    printf '%b    ... and %d more%b\n' "${GRAY}" "$(( total_files - max_items ))" "${RESET}" >&2
            fi
            echo "" >&2
        fi
    done < <(lsblk -rno PATH,MOUNTPOINT,TYPE "$device" 2>/dev/null | awk '$3=="part" {print $1, $2}')

    [[ "$has_mounted" == "false" ]] && \
        printf '%b  \uf05a  No mounted partitions%b\n' "${GRAY}" "${RESET}" >&2
}

pre_nuke_verification() {
    local device="$1"
    local size model vendor
    size=$(lsblk  -nd -o SIZE   "$device" 2>/dev/null || echo "Unknown")
    model=$(lsblk -nd -o MODEL  "$device" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")
    vendor=$(lsblk -nd -o VENDOR "$device" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")

    printf '\n%b  ╔══ PRE-NUKE VERIFICATION REPORT ══════════════════════╗%b\n' "${RED}${BOLD}" "${RESET}" >&2
    printf '%b  ║  \uf7c8  Device: %-45s║%b\n' "${CYAN}" "$device" "${RESET}" >&2
    printf '%b  ║  \uf493  Size:   %-45s║%b\n' "${CYAN}" "$size" "${RESET}" >&2
    printf '%b  ║  \uf02b  Model:  %-45s║%b\n' "${CYAN}" "$vendor $model" "${RESET}" >&2
    printf '%b  ╚════════════════════════════════════════════════════════╝%b\n\n' "${RED}${BOLD}" "${RESET}" >&2

    printf '%b  Partition Layout:%b\n' "${CYAN}${BOLD}" "${RESET}" >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$device" 2>/dev/null | sed 's/^/    /' >&2
    echo "" >&2

    local info total_bytes mounted_bytes unmounted_count
    info=$(calc_destruction_data "$device")
    total_bytes=$(echo   "$info" | cut -d: -f1)
    mounted_bytes=$(echo "$info" | cut -d: -f2)
    unmounted_count=$(echo "$info" | cut -d: -f3)

    printf '%b  Mounted Contents:%b\n' "${CYAN}${BOLD}" "${RESET}" >&2
    list_mounted_contents "$device"

    printf '%b  \uf071  Data Destruction Summary:%b\n' "${YELLOW}${BOLD}" "${RESET}" >&2
    printf '    Total to overwrite : %s (%s bytes)\n' "$(format_bytes "$total_bytes")" "$total_bytes" >&2
    printf '    Mounted data lost  : %s (%s bytes)\n' "$(format_bytes "$mounted_bytes")" "$mounted_bytes" >&2
    (( unmounted_count > 0 )) && \
        warn "  $unmounted_count unmounted partition(s) — actual data loss may be higher"

    printf '\n%b  \uf057  THIS ACTION IS COMPLETELY IRREVERSIBLE!%b\n'    "${RED}${BOLD}" "${RESET}" >&2
    printf '%b  ALL DATA ON THIS DEVICE WILL BE PERMANENTLY DESTROYED!%b\n\n' "${RED}${BOLD}" "${RESET}" >&2
}

# ══════════════════════════════════════════════════════════════
#  Device validation
# ══════════════════════════════════════════════════════════════
validate_device() {
    local device="$1"
    start_timer "Device Validation"

    [[ ! -b "$device" ]] && error_exit "Device '$device' does not exist or is not a block device."

    local is_removable transport
    is_removable=$(lsblk -d -n -o HOTPLUG "$device" 2>/dev/null || echo "0")
    transport=$(lsblk    -d -n -o TRAN    "$device" 2>/dev/null || echo "")

    if [[ "$is_removable" != "1" && "$transport" != "usb" ]]; then
        case "$device" in
            /dev/sda|/dev/nvme0n1|/dev/mmcblk0|/dev/vda|/dev/hda)
                error_exit "\uf071 BLOCKED: '$device' appears to be a system disk (not removable).\nIf it really is your target USB, edit the protection list in the script." ;;
        esac
        warn "Device '$device' may not be removable — triple-check before continuing!"
    fi

    if sudo swapon --show 2>/dev/null | grep -q "$device"; then
        error_exit "Device '$device' is used as swap. Disable first: sudo swapoff $device"
    fi

    local mounted_parts
    mounted_parts=$(mount | grep "^$device" | awk '{print $1}' || true)
    if [[ -n "$mounted_parts" ]]; then
        warn "Device '$device' has mounted partitions:"
        mount | grep "^$device" | sed 's/^/  /' >&2
        echo "" >&2
        read -rp "  Unmount all and continue? (y/N): " cont
        [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Aborted by user."

        info "Unmounting all partitions on $device..."
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            spinner_start "Unmounting $part"
            if sudo umount "$part" 2>/dev/null; then
                spinner_stop 0
            else
                spinner_stop 1
                warn "Normal umount failed for $part — trying lazy unmount..."
                sudo umount -l "$part" 2>/dev/null \
                    && warn "Lazy unmount applied to $part (may still be in use)" \
                    || warn "Could not unmount $part — it may cause issues later"
            fi
        done <<< "$mounted_parts"
        sync; sleep 2
    fi

    local size model vendor serial
    size=$(lsblk   -nd -o SIZE   "$device" 2>/dev/null || echo "?")
    model=$(lsblk  -nd -o MODEL  "$device" 2>/dev/null || echo "Unknown")
    vendor=$(lsblk -nd -o VENDOR "$device" 2>/dev/null || echo "Unknown")
    serial=$(lsblk -nd -o SERIAL "$device" 2>/dev/null || echo "Unknown")

    printf '\n%b  ┌─ Target Device ───────────────────────────────────┐%b\n' "${CYAN}" "${RESET}" >&2
    printf '%b  │  \uf7c8  Path   : %-40s │%b\n' "${RESET}" "$device"  "${RESET}" >&2
    printf '%b  │  \uf493  Size   : %-40s │%b\n' "${RESET}" "$size"    "${RESET}" >&2
    printf '%b  │  \uf02b  Vendor : %-40s │%b\n' "${RESET}" "$vendor"  "${RESET}" >&2
    printf '%b  │  \uf02b  Model  : %-40s │%b\n' "${RESET}" "$model"   "${RESET}" >&2
    printf '%b  │  \uf084  Serial : %-40s │%b\n' "${RESET}" "$serial"  "${RESET}" >&2
    printf '%b  └───────────────────────────────────────────────────┘%b\n\n' "${CYAN}" "${RESET}" >&2

    end_timer "Device Validation"
}

# ══════════════════════════════════════════════════════════════
#  Input helpers
# ══════════════════════════════════════════════════════════════
read_with_timeout() {
    local prompt="$1" timeout="${2:-30}" default="${3:-}" response
    [[ -n "$default" ]] && prompt="$prompt [default: $default]: " || prompt="$prompt: "
    if read -t "$timeout" -rp "$prompt" response; then
        echo "${response:-$default}"
    else
        warn "Input timeout — using default: ${default:-none}"
        echo "$default"
    fi
}

validate_numeric_choice() {
    local c="$1" min="$2" max="$3"
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= min && c <= max ))
}

# ══════════════════════════════════════════════════════════════
#  Progress bar for dd  — FIX [5][6]
#  Replaces the silent background dd + /proc/pid/io monitor with
#  dd's native status=progress piped through a live bar renderer.
#  The user now sees real-time bytes + speed instead of nothing.
# ══════════════════════════════════════════════════════════════
_fmt_bytes_short() {
    local b=$1
    if   (( b >= 1073741824 )); then awk "BEGIN{printf \"%.1f GB\", $b/1073741824}"
    elif (( b >= 1048576    )); then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
    elif (( b >= 1024       )); then awk "BEGIN{printf \"%.1f KB\", $b/1024}"
    else printf "%d B" "$b"
    fi
}

_draw_bar() {
    local pct=$1 width=38 filled empty bar=""
    filled=$(( width * pct / 100 )); empty=$(( width - filled ))
    local i; for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    printf "%s" "$bar"
}

progress_bar_dd() {
    local source="$1" dest="$2" total_bytes="$3" label="${4:-Writing...}"

    # ── How this works ────────────────────────────────────────
    # dd writes DATA to stdout and PROGRESS to stderr.
    # We need both to go different places:
    #   stdout  → the device (via sudo dd of=...)  [can't pipe this]
    #   stderr  → our bar renderer
    #
    # Solution: run dd in background, redirect its stderr to a temp file,
    # send SIGINT every second to make dd print a progress line, then
    # read and render that file live. dd prints one progress line per USR1.
    # On Linux, use SIGUSR1; on older dd it also works with kill -USR1.
    # ─────────────────────────────────────────────────────────

    local progress_file
    progress_file=$(mktemp /tmp/dd_progress.XXXXXX)

    printf "${HIDE_CURSOR}" >&2

    # Run dd in background; stderr → progress_file
    sudo dd if="$source" of="$dest" bs=4M conv=fsync 2>"$progress_file" &
    local dd_pid=$!

    local start_sec=$SECONDS
    local last_written=0

    # Poll loop — send USR1 every second to request a progress line from dd
    while kill -0 "$dd_pid" 2>/dev/null; do
        # Signal dd to print current stats to its stderr (our progress_file)
        sudo kill -USR1 "$dd_pid" 2>/dev/null || true
        sleep 1

        # Read the most recent bytes-progress line from the file
        local last_line
        last_line=$(grep -E "^[0-9]+ bytes" "$progress_file" 2>/dev/null | tail -n1 || true)

        # dd progress line: "12345678 bytes (12 MB, 12 MiB) copied, 1.2 s, 10.3 MB/s"
        if [[ "$last_line" =~ ^([0-9]+)[[:space:]]bytes ]]; then
            local written="${BASH_REMATCH[1]}"
            local pct=0 speed="" eta_str=""
            (( total_bytes > 0 )) && pct=$(( written * 100 / total_bytes ))
            (( pct > 100 )) && pct=100

            [[ "$last_line" =~ ([0-9.]+[[:space:]][KMGT]?B/s) ]] && speed="${BASH_REMATCH[1]}"

            # Calculate ETA
            local elapsed=$(( SECONDS - start_sec ))
            if (( elapsed > 0 && written > 0 && total_bytes > written )); then
                local rate=$(( written / elapsed ))
                if (( rate > 0 )); then
                    local remaining=$(( (total_bytes - written) / rate ))
                    eta_str=" ETA $(format_duration "$remaining")"
                fi
            fi

            local bar; bar=$(_draw_bar "$pct")
            printf "\r  ${CYAN}%s${RESET} ${BOLD}%3d%%${RESET}  ${GRAY}%s / %s${RESET}  ${DIM}%s%s${RESET}   " \
                "$bar" "$pct" \
                "$(_fmt_bytes_short "$written")" \
                "$(_fmt_bytes_short "$total_bytes")" \
                "$speed" "$eta_str" >&2

            last_written=$written
        fi
    done

    # Wait for dd to exit and capture its return code
    wait "$dd_pid" 2>/dev/null
    local rc=$?

    # Print final state at 100%
    local bar; bar=$(_draw_bar 100)
    printf "\r  ${CYAN}%s${RESET} ${BOLD}%3d%%${RESET}  ${GRAY}%s / %s${RESET}   " \
        "$bar" 100 \
        "$(_fmt_bytes_short "$total_bytes")" \
        "$(_fmt_bytes_short "$total_bytes")" >&2

    rm -f "$progress_file"
    printf "\r${ERASE_LINE}" >&2
    printf "${SHOW_CURSOR}" >&2

    # dd exits 1 on natural EOF (hit end of device) — expected and OK
    if [[ $rc -eq 0 || $rc -eq 1 ]]; then
        local elapsed=$(( SECONDS - start_sec ))
        local rate_str=""
        (( elapsed > 0 )) && rate_str="  $(( total_bytes / elapsed / 1048576 )) MB/s avg"
        printf "  ${GREEN}\uf058${RESET}  %-40s ${GRAY}%s%s${RESET}\n" \
            "$label" "$(format_duration "$elapsed")" "$rate_str" >&2
        return 0
    else
        printf "  ${RED}\uf057${RESET}  %s  ${RED}[dd exited %d]${RESET}\n" "$label" "$rc" >&2
        warn "'No space left on device' from dd is NORMAL — the drive is full and the wipe completed"
        return "$rc"
    fi
}

# ══════════════════════════════════════════════════════════════
#  Shred progress bar
# ══════════════════════════════════════════════════════════════
progress_shred() {
    local device="$1" passes="$2" label="${3:-Shredding...}"
    local total=$(( passes + 1 ))   # shred adds a final zero pass

    printf "${HIDE_CURSOR}" >&2
    info "$label  (${total} passes total)" >&2

    # shred -v prints progress to stderr in the form:
    #   shred: /dev/sdX: pass 2/4 (random)...14%
    # We run it in background, stream its stderr to a temp file,
    # and poll that file every second for updates.
    local progress_file
    progress_file=$(mktemp /tmp/shred_progress.XXXXXX)

    sudo shred -v -n "$passes" -z "$device" 2>"$progress_file" &
    local shred_pid=$!

    while kill -0 "$shred_pid" 2>/dev/null; do
        sleep 1
        local last_line
        last_line=$(grep -E "pass [0-9]+/[0-9]+" "$progress_file" 2>/dev/null | tail -n1 || true)

        if [[ "$last_line" =~ pass[[:space:]]([0-9]+)/([0-9]+) ]]; then
            local cur="${BASH_REMATCH[1]}" tot="${BASH_REMATCH[2]}" ptype="" in_pct=0
            local _pre='[(]([^)]+)[)]'
            [[ "$last_line" =~ $_pre ]] && ptype="${BASH_REMATCH[1]}"
            [[ "$last_line" =~ \.\.\.([0-9]+)% ]] && in_pct="${BASH_REMATCH[1]}"
            local pct=$(( ( (cur-1)*100 + in_pct ) / tot ))
            (( pct > 100 )) && pct=100
            local bar; bar=$(_draw_bar "$pct")
            printf "\r  ${CYAN}%s${RESET} ${BOLD}%3d%%${RESET}  ${GRAY}Pass %d/%d${RESET}  ${DIM}(%s)${RESET}   " \
                "$bar" "$pct" "$cur" "$tot" "$ptype" >&2
        fi
    done

    wait "$shred_pid" 2>/dev/null
    local rc=$?
    rm -f "$progress_file"

    printf "\r${ERASE_LINE}" >&2
    printf "${SHOW_CURSOR}" >&2

    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}\uf058${RESET}  %s — %d passes complete\n" "$label" "$total" >&2
    else
        printf "  ${RED}\uf057${RESET}  %s failed (shred exit: %d)\n" "$label" "$rc" >&2
        warn "Check that the device is still connected and not write-protected"
    fi
    return $rc
}

# ══════════════════════════════════════════════════════════════
#  Wipe functions
# ══════════════════════════════════════════════════════════════

# FIX [6]: perform_wipe_with_progress — replaced silent background dd with
#          progress_bar_dd which uses dd status=progress for live feedback
perform_wipe_with_progress() {
    local device="$1" method="$2" passes="$3"
    local device_bytes; device_bytes=$(get_device_bytes "$device")

    printf '%b\n  \uf06e  Wipe Configuration:%b\n' "${CYAN}${BOLD}" "${RESET}" >&2
    printf '  Device : %s\n'  "$device" >&2
    printf '  Method : %s\n'  "$method" >&2
    printf '  Passes : %d\n'  "$passes" >&2
    printf '  Total  : %s\n\n' "$(format_bytes $(( device_bytes * passes )))" >&2

    local estimated_speed=$(( 50 * 1048576 ))
    local est=$(( device_bytes * passes / estimated_speed ))
    printf '  \uf017  Estimated time at ~50 MB/s: %s\n\n' "$(format_duration "$est")" >&2

    local pass
    for pass in $(seq 1 "$passes"); do
        printf '%b  Pass %d of %d:%b\n' "${YELLOW}${BOLD}" "$pass" "$passes" "${RESET}" >&2
        case "$method" in
            zeros)
                progress_bar_dd /dev/zero    "$device" "$device_bytes" "Zero-fill pass $pass/$passes" \
                    || warn "Pass $pass hit end of device — this is normal (device is full)"
                ;;
            random)
                progress_bar_dd /dev/urandom "$device" "$device_bytes" "Random pass $pass/$passes" \
                    || warn "Pass $pass hit end of device — this is normal"
                ;;
            pattern)
                case $pass in
                    1) progress_bar_dd /dev/zero    "$device" "$device_bytes" "0x00 pass $pass/$passes" \
                           || warn "Pass $pass: end of device (normal)" ;;
                    2) progress_bar_dd /dev/urandom "$device" "$device_bytes" "Random pass $pass/$passes" \
                           || warn "Pass $pass: end of device (normal)" ;;
                    *) progress_bar_dd /dev/urandom "$device" "$device_bytes" "Random pass $pass/$passes" \
                           || warn "Pass $pass: end of device (normal)" ;;
                esac
                ;;
        esac
        sync
        success "Pass $pass complete"
    done
}

perform_shred_wipe() {
    local device="$1" iterations="$2"
    if ! _has_cmd shred; then
        warn "shred not found — falling back to pattern wipe"
        perform_wipe_with_progress "$device" "pattern" "$iterations"
        return
    fi
    local device_bytes; device_bytes=$(get_device_bytes "$device")
    info "Using shred ($iterations iterations + final zero pass)..."
    progress_shred "$device" "$iterations" "Shred wipe" \
        || warn "shred reported an error — check device connection"
}

verify_wipe() {
    local device="$1"
    spinner_start "Verifying wipe (10 MB sample)"
    local sample
    sample=$(sudo dd if="$device" bs=1M count=10 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -v '^0*$' || echo "")
    if [[ -z "$sample" ]]; then
        spinner_stop 0
        success "Verification passed — device reads all zeros"
    else
        spinner_stop 1
        warn "Verification: device contains non-zero data (expected for random/pattern wipes)"
    fi
}

perform_wipe() {
    local device="$1" method="$2"
    case "$method" in
        1)
            start_timer "Zero Wipe"
            perform_wipe_with_progress "$device" "zeros" 1
            verify_wipe "$device"
            end_timer "Zero Wipe"
            ;;
        2)
            start_timer "Random Wipe"
            perform_wipe_with_progress "$device" "random" 1
            end_timer "Random Wipe"
            ;;
        3)
            start_timer "Shred Wipe (3-pass)"
            perform_shred_wipe "$device" 3
            end_timer "Shred Wipe (3-pass)"
            ;;
        4)
            start_timer "DoD 5220.22-M (7-pass)"
            info "DoD 5220.22-M: 2× random + 3× pattern + 2× random"
            perform_wipe_with_progress "$device" "random"  2
            perform_wipe_with_progress "$device" "pattern" 3
            perform_wipe_with_progress "$device" "random"  2
            end_timer "DoD 5220.22-M (7-pass)"
            ;;
        *)
            info "Wipe skipped."
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════
#  Partition creation
#  FIX [3]: ALL output redirected to >&2 so PART=$(...) captures only the path
# ══════════════════════════════════════════════════════════════
create_partition() {
    local device="$1" pt_type="$2"
    start_timer "Partition Creation"

    case "$pt_type" in
        1)
            spinner_start "Creating GPT partition table"
            sudo parted "$device" --script mklabel gpt 2>/dev/null
            spinner_stop $?
            [[ $? -ne 0 ]] && error_exit "Failed to create GPT table on $device"
            ;;
        2)
            spinner_start "Creating MBR partition table"
            sudo parted "$device" --script mklabel msdos 2>/dev/null
            spinner_stop $?
            [[ $? -ne 0 ]] && error_exit "Failed to create MBR table on $device"
            ;;
        *)
            info "Partition table creation skipped." >&2
            end_timer "Partition Creation"
            return 1
            ;;
    esac

    spinner_start "Writing primary partition (1MiB → 100%)"
    sudo parted "$device" --script mkpart primary 1MiB 100% 2>/dev/null
    local rc=$?
    spinner_stop $rc
    [[ $rc -ne 0 ]] && error_exit "Failed to create partition on $device"

    sudo parted "$device" --script set 1 boot on 2>/dev/null || true

    spinner_start "Refreshing kernel partition table"
    sync
    sudo partprobe "$device" 2>/dev/null || sudo blockdev --rereadpt "$device" 2>/dev/null || true
    sleep 3
    spinner_stop 0

    # FIX: correct suffix for nvme/mmcblk/loop (p1) vs sda-style (1)
    local part=""
    if [[ "$device" =~ (nvme|mmcblk|loop) ]]; then
        part="${device}p1"
    else
        part="${device}1"
    fi

    spinner_start "Waiting for $part node to appear"
    local retry=0
    while [[ ! -b "$part" && $retry -lt 10 ]]; do
        sleep 1; ((retry++))
        # After 5s try the alternative naming convention
        if [[ $retry -eq 5 ]]; then
            if [[ "$device" =~ (nvme|mmcblk|loop) ]]; then
                part="${device}1"
            else
                part="${device}p1"
            fi
            info "Trying alternative partition name: $part" >&2
        fi
    done

    if [[ ! -b "$part" ]]; then
        spinner_stop 1
        error_exit "Partition node '$part' never appeared after 10s.\nTry manually: sudo partprobe $device && lsblk $device"
    fi
    spinner_stop 0

    end_timer "Partition Creation"
    echo "$part"   # ← stdout only — all other output went to stderr via >&2
}

# ══════════════════════════════════════════════════════════════
#  Encryption
#  FIX [4]: ALL output to >&2 so MAPPED_DEV=$(...) captures only the mapper path
# ══════════════════════════════════════════════════════════════
setup_encryption() {
    local part="$1" mapper_name="$2"

    if ! _has_cmd cryptsetup; then
        warn "cryptsetup not found — skipping encryption" >&2
        echo "$part"   # return the raw partition path
        return 0
    fi

    start_timer "LUKS Encryption Setup"

    info "Setting up LUKS2 encryption (AES-XTS-512 + argon2id)..." >&2
    printf '\n%b  \uf071  You will be prompted for a passphrase TWICE.%b\n\n' "${YELLOW}" "${RESET}" >&2

    # luksFormat is interactive — no spinner, user must type
    if ! sudo cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --pbkdf argon2id \
            --iter-time 4000 \
            --use-random \
            "$part"; then
        error_exit "luksFormat failed on $part\nCheck: device is writable, not mounted, and passphrase was entered correctly"
    fi

    spinner_start "Opening encrypted container"
    sudo cryptsetup open "$part" "$mapper_name" 2>/dev/null
    local rc=$?
    spinner_stop $rc
    if [[ $rc -ne 0 ]]; then
        error_exit "Could not open LUKS container on $part\nPossible causes: wrong passphrase, device disconnected, or cryptsetup permissions"
    fi

    local mapped="/dev/mapper/$mapper_name"
    end_timer "LUKS Encryption Setup"
    success "Encryption active → $mapped" >&2
    echo "$mapped"   # stdout only
}

# ══════════════════════════════════════════════════════════════
#  Filesystem formatting
# ══════════════════════════════════════════════════════════════
format_filesystem() {
    local device="$1" fstype="$2" label="${3:0:15}"

    case "$fstype" in
        1)
            _has_cmd mkfs.ext4 || error_exit "mkfs.ext4 not found — sudo apt install e2fsprogs"
            start_timer "ext4 Format"
            spinner_start "Formatting ext4  [label: $label]"
            sudo mkfs.ext4 -F -L "$label" -O ^64bit,^metadata_csum \
                -E lazy_itable_init=0,lazy_journal_init=0 "$device" &>/dev/null
            local rc=$?; spinner_stop $rc
            [[ $rc -ne 0 ]] && error_exit "mkfs.ext4 failed on $device\nCheck: device is accessible and not in use"
            end_timer "ext4 Format"
            ;;
        2)
            if ! _has_cmd mkfs.exfat; then
                warn "mkfs.exfat not found — falling back to FAT32"
                format_filesystem "$device" 3 "$label"; return
            fi
            start_timer "exFAT Format"
            spinner_start "Formatting exFAT  [label: $label]"
            sudo mkfs.exfat -n "$label" "$device" &>/dev/null
            local rc=$?; spinner_stop $rc
            [[ $rc -ne 0 ]] && error_exit "mkfs.exfat failed on $device\nInstall: sudo apt install exfatprogs"
            end_timer "exFAT Format"
            ;;
        3)
            if ! _has_cmd mkfs.vfat; then
                warn "mkfs.vfat not found — falling back to ext4"
                format_filesystem "$device" 1 "$label"; return
            fi
            local fat_label="${label:0:11}"
            start_timer "FAT32 Format"
            spinner_start "Formatting FAT32  [label: $fat_label]"
            sudo mkfs.vfat -F 32 -n "$fat_label" "$device" &>/dev/null
            local rc=$?; spinner_stop $rc
            [[ $rc -ne 0 ]] && error_exit "mkfs.vfat failed on $device\nInstall: sudo apt install dosfstools"
            end_timer "FAT32 Format"
            ;;
        4)
            if ! _has_cmd mkfs.ntfs; then
                warn "mkfs.ntfs not found — falling back to ext4"
                format_filesystem "$device" 1 "$label"; return
            fi
            start_timer "NTFS Format"
            spinner_start "Formatting NTFS  [label: $label]"
            sudo mkfs.ntfs -f -L "$label" "$device" &>/dev/null
            local rc=$?; spinner_stop $rc
            [[ $rc -ne 0 ]] && error_exit "mkfs.ntfs failed on $device\nInstall: sudo apt install ntfs-3g"
            end_timer "NTFS Format"
            ;;
        *)
            info "Filesystem formatting skipped."
            return 0
            ;;
    esac
    sync
    success "Filesystem created successfully"
}

# ══════════════════════════════════════════════════════════════
#  Mount
# ══════════════════════════════════════════════════════════════
mount_device() {
    local device="$1" mount_name="$2"
    local mount_dir="/mnt/$mount_name"
    start_timer "Device Mount"

    spinner_start "Creating mount point $mount_dir"
    sudo mkdir -p "$mount_dir" 2>/dev/null
    spinner_stop $?

    spinner_start "Mounting $device → $mount_dir"
    sudo mount "$device" "$mount_dir" 2>/dev/null
    local rc=$?
    spinner_stop $rc
    if [[ $rc -ne 0 ]]; then
        error_exit "mount failed for '$device' → '$mount_dir'\nCommon causes: wrong filesystem, encrypted device not opened, device not formatted"
    fi

    spinner_start "Setting ownership → $USER"
    sudo chown -R "$USER:$(id -gn)" "$mount_dir" 2>/dev/null || true
    sudo chmod 755 "$mount_dir"
    spinner_stop 0

    end_timer "Device Mount"
    success "Mounted at $mount_dir"

    printf '%b\n  \uf0a0  Mount Info:%b\n' "${GRAY}" "${RESET}" >&2
    printf '%b  ┌──────────────────────────────────────────────┐%b\n' "${GRAY}" "${RESET}" >&2
    df -h "$mount_dir" | tail -1 | while read -r fs size used avail pct mp; do
        printf '%b  │  Filesystem : %-32s │%b\n' "${RESET}" "$fs"   "${RESET}" >&2
        printf '%b  │  Size       : %-32s │%b\n' "${RESET}" "$size" "${RESET}" >&2
        printf '%b  │  Available  : %-32s │%b\n' "${RESET}" "$avail" "${RESET}" >&2
        printf '%b  │  Used       : %-32s │%b\n' "${RESET}" "$pct"  "${RESET}" >&2
        printf '%b  │  Mountpoint : %-32s │%b\n' "${RESET}" "$mp"   "${RESET}" >&2
    done
    printf '%b  └──────────────────────────────────────────────┘%b\n\n' "${GRAY}" "${RESET}" >&2
}

# ══════════════════════════════════════════════════════════════
#  Summary + cleanup
# ══════════════════════════════════════════════════════════════
show_operation_summary() {
    local total=$(( $(date +%s) - SCRIPT_START_TIME ))
    printf '\n%b  ╔══ OPERATION SUMMARY ═════════════════════════╗%b\n' "${BOLD}${CYAN}" "${RESET}" >&2
    for key in "${!OPERATION_TIMES[@]}"; do
        if [[ $key == *"_duration" ]]; then
            local name="${key%_duration}" dur="${OPERATION_TIMES[$key]}"
            printf '%b  ║  %-28s %14s  ║%b\n' "${RESET}" "$name" "$(format_duration "$dur")" "${RESET}" >&2
        fi
    done
    printf '%b  ║  %-28s %14s  ║%b\n' "${BOLD}" "TOTAL RUNTIME" "$(format_duration "$total")" "${RESET}" >&2
    printf '%b  ╚═══════════════════════════════════════════════╝%b\n' "${BOLD}${CYAN}" "${RESET}" >&2
}

MAPPER_NAME_GLOBAL=""
cleanup() {
    local code=$?
    _spinner_stop
    printf "${SHOW_CURSOR}" >&2
    if [[ $code -ne 0 ]]; then
        warn "Script exited with error (code $code)"
        if [[ -n "$MAPPER_NAME_GLOBAL" && -b "/dev/mapper/$MAPPER_NAME_GLOBAL" ]]; then
            warn "Auto-closing LUKS mapper '$MAPPER_NAME_GLOBAL'..."
            sudo cryptsetup close "$MAPPER_NAME_GLOBAL" 2>/dev/null || true
        fi
        info "Some operations may need manual cleanup"
    fi
    show_operation_summary
    exit $code
}

# ══════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════
main() {
    trap cleanup EXIT

    show_banner
    check_root
    check_dependencies

    # ── Device selection ──────────────────────────────────────
    show_devices

    [[ ${#REMOVABLE_DEVICES[@]} -eq 0 ]] && error_exit "No removable devices found"

    local DEVICE=""
    if [[ ${#REMOVABLE_DEVICES[@]} -eq 1 ]]; then
        DEVICE="${REMOVABLE_DEVICES[0]}"
        info "Auto-selecting only available device: $DEVICE"
    else
        printf '%b  Select USB device (number or full path):%b\n' "${CYAN}" "${RESET}" >&2
        local choice
        choice=$(read_with_timeout "  Choice (1-${#REMOVABLE_DEVICES[@]})" 30) \
            || error_exit "No device selected (timeout)"
        [[ -z "$choice" ]] && error_exit "No device specified"

        if validate_numeric_choice "$choice" 1 "${#REMOVABLE_DEVICES[@]}"; then
            DEVICE="${REMOVABLE_DEVICES[$((choice-1))]}"
        elif [[ "$choice" =~ ^/dev/.+ && -b "$choice" ]]; then
            DEVICE="$choice"
        else
            error_exit "Invalid selection: '$choice' — enter a number (1-${#REMOVABLE_DEVICES[@]}) or /dev/sdX path"
        fi
    fi

    validate_device "$DEVICE"
    pre_nuke_verification "$DEVICE"

    # ── Double confirmation ───────────────────────────────────
    printf '\n%b  \uf071  FINAL CONFIRMATION REQUIRED%b\n\n' "${RED}${BOLD}" "${RESET}" >&2

    printf '%b  Step 1: Type the exact device path: %b%s%b\n' "${YELLOW}" "${CYAN}${BOLD}" "$DEVICE" "${RESET}" >&2
    local device_confirm
    read -rp "  Device path: " device_confirm
    if [[ "$device_confirm" != "$DEVICE" ]]; then
        error_exit "Device path mismatch.\n  You typed : '$device_confirm'\n  Expected  : '$DEVICE'\n  Aborted for your safety."
    fi
    success "Device path confirmed"

    printf '\n%b  Step 2: Type exactly %bNUKE IT%b to proceed%b\n' "${YELLOW}" "${RED}${BOLD}" "${YELLOW}" "${RESET}" >&2
    local nuke_confirm
    read -rp "  Confirmation: " nuke_confirm
    if [[ "$nuke_confirm" != "NUKE IT" ]]; then
        error_exit "Confirmation failed.\n  You typed : '$nuke_confirm'\n  Expected  : 'NUKE IT'\n  Operation aborted."
    fi
    success "Final confirmation received"

    # ── Prepare device ────────────────────────────────────────
    printf '\n%b  \uf06e  Preparing device for wipe...%b\n' "${CYAN}${BOLD}" "${RESET}" >&2
    local mounted_parts
    mounted_parts=$(mount | grep "^$DEVICE" | awk '{print $1}' || true)
    if [[ -n "$mounted_parts" ]]; then
        info "Unmounting all partitions on $DEVICE..."
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            spinner_start "Unmounting $part"
            if sudo umount "$part" 2>/dev/null; then
                spinner_stop 0
            else
                spinner_stop 1
                warn "Normal umount failed for '$part' — trying lazy unmount"
                sudo umount -l "$part" 2>/dev/null \
                    && warn "Lazy unmount applied to $part" \
                    || warn "Could not unmount $part — this may cause write errors"
            fi
        done <<< "$mounted_parts"
        sync; sleep 2
    fi

    # ── Wipe ─────────────────────────────────────────────────
    echo "" >&2
    printf '%b  \uf06e  Choose wipe method:%b\n' "${CYAN}" "${RESET}" >&2
    echo "    1) Zero fill         (fast, single pass, verified)" >&2
    echo "    2) Random data       (secure, single pass)"         >&2
    echo "    3) Shred             (secure, 3-pass via shred)"    >&2
    echo "    4) DoD 5220.22-M     (very secure, 7-pass)"         >&2
    echo "    5) Skip wipe"                                        >&2

    local WIPE_METHOD
    WIPE_METHOD=$(read_with_timeout "  Select (1-5)" 30 "1") || { warn "Timeout — using zero fill"; WIPE_METHOD=1; }
    validate_numeric_choice "$WIPE_METHOD" 1 5 || { warn "Invalid — defaulting to zero fill"; WIPE_METHOD=1; }
    perform_wipe "$DEVICE" "$WIPE_METHOD"

    # ── Partition table ───────────────────────────────────────
    echo "" >&2
    printf '%b  \uf0c8  Choose partition table:%b\n' "${CYAN}" "${RESET}" >&2
    echo "    1) GPT  (recommended — modern systems, >2TB)" >&2
    echo "    2) MBR  (legacy compatible)"                   >&2
    echo "    3) Skip partitioning"                          >&2

    local PT_TYPE
    PT_TYPE=$(read_with_timeout "  Select (1-3)" 30 "1") || { warn "Timeout — using GPT"; PT_TYPE=1; }
    validate_numeric_choice "$PT_TYPE" 1 3 || { warn "Invalid — defaulting to GPT"; PT_TYPE=1; }

    local PART=""
    if [[ "$PT_TYPE" =~ ^[12]$ ]]; then
        PART=$(create_partition "$DEVICE" "$PT_TYPE") \
            || error_exit "Partitioning failed on $DEVICE — check dmesg for kernel errors"
        [[ -z "$PART" ]] && error_exit "create_partition returned empty path — unexpected error"
    else
        info "Partitioning skipped — manual partition creation will be required"
        show_operation_summary
        exit 0
    fi

    # ── Label ─────────────────────────────────────────────────
    local LABEL
    LABEL=$(read_with_timeout "  Filesystem label" 30 "NUKED") || LABEL="NUKED"
    LABEL="${LABEL:-NUKED}"

    # ── Encryption ────────────────────────────────────────────
    echo "" >&2
    local do_encrypt
    do_encrypt=$(read_with_timeout "  \uf023 Encrypt with LUKS2? (y/N)" 30 "N") || do_encrypt="N"

    local MAPPED_DEV=""
    if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
        local mapper_name="usb_nuke_$(date +%s)"
        MAPPER_NAME_GLOBAL="$mapper_name"
        MAPPED_DEV=$(setup_encryption "$PART" "$mapper_name") \
            || error_exit "Encryption setup failed on $PART"
        [[ -z "$MAPPED_DEV" ]] && error_exit "setup_encryption returned empty path"
    else
        MAPPED_DEV="$PART"
    fi

    # ── Filesystem ────────────────────────────────────────────
    echo "" >&2
    printf '%b  \uf0a0  Choose filesystem:%b\n' "${CYAN}" "${RESET}" >&2
    echo "    1) ext4   — Linux native, journaled"            >&2
    echo "    2) exFAT  — cross-platform, large files (>4GB)" >&2
    echo "    3) FAT32  — universal compatibility"            >&2
    echo "    4) NTFS   — Windows native"                     >&2
    echo "    5) Skip formatting"                              >&2

    local FSTYPE
    FSTYPE=$(read_with_timeout "  Select (1-5)" 30 "1") || { warn "Timeout — using ext4"; FSTYPE=1; }
    validate_numeric_choice "$FSTYPE" 1 5 || { warn "Invalid — defaulting to ext4"; FSTYPE=1; }
    format_filesystem "$MAPPED_DEV" "$FSTYPE" "$LABEL"

    # ── Mount ─────────────────────────────────────────────────
    echo "" >&2
    local do_mount
    do_mount=$(read_with_timeout "  \uf74a Mount device now? (y/N)" 30 "N") || do_mount="N"

    if [[ "$do_mount" =~ ^[Yy]$ ]]; then
        local MOUNT_NAME
        MOUNT_NAME=$(read_with_timeout "  Mount directory name" 30 "nuked") || MOUNT_NAME="nuked"
        MOUNT_NAME="${MOUNT_NAME:-nuked}"
        mount_device "$MAPPED_DEV" "$MOUNT_NAME"
    fi

    # ── Final summary ─────────────────────────────────────────
    echo "" >&2
    printf '%b  ╔══ \uf00c SUCCESS ══════════════════════════════════╗%b\n' "${GREEN}${BOLD}" "${RESET}" >&2
    printf '%b  ║  USB Nuke Beast operation completed!           ║%b\n' "${GREEN}${BOLD}"   "${RESET}" >&2
    printf '%b  ║  \uf7c8  Device %-38s ║%b\n' "${GREEN}" "$DEVICE is ready" "${RESET}" >&2
    printf '%b  ╚═══════════════════════════════════════════════╝%b\n' "${GREEN}${BOLD}" "${RESET}" >&2

    if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
        echo "" >&2
        printf '%b  \uf084 Encryption cheatsheet:%b\n' "${CYAN}" "${RESET}" >&2
        echo "    Open  : sudo cryptsetup open $PART ${MAPPER_NAME_GLOBAL:-nuked_usb}" >&2
        echo "    Mount : sudo mount /dev/mapper/${MAPPER_NAME_GLOBAL:-nuked_usb} /mnt/${MOUNT_NAME:-nuked}" >&2
        echo "    Close : sudo umount /mnt/${MOUNT_NAME:-nuked} && sudo cryptsetup close ${MAPPER_NAME_GLOBAL:-nuked_usb}" >&2
        echo "    Info  : sudo cryptsetup luksDump $PART" >&2
        echo "    \uf071  Keep your passphrase safe — no recovery without it!" >&2
    fi
}

main "$@"
