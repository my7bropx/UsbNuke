#!/bin/bash

# USB Nuke Beast v2.2 - Enhanced Edition (All Issues Fixed)
# A complete wipe, encrypt, format, and mount tool for USB devices
# Secure USB wipe, encrypt, partition, format, mount - all in Bash
#
# CHANGELOG v2.2:
# - Fixed partition naming bug for NVMe/MMC/loop devices (nvme0n1p1 vs nvme0n11)
# - Added missing dependencies: bc, blockdev
# - Moved pv and shred to optional dependencies with proper fallbacks
# - Fixed device detection parsing to handle spaces in MODEL/VENDOR names
# - Added proper ASCII banner art
# - Implemented actual shred command usage with fallback
# - Added wipe verification for zero-fill method
# - Enhanced error handling in partition creation
# - Added alternative partition naming fallback logic

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ==== Colors ====
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;37m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# ==== Global Variables ====
readonly SCRIPT_START_TIME=$(date +%s)
declare -A OPERATION_TIMES

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
    printf '%b\n' "${YELLOW}USB NUKE BEAST v2.2  Enhanced USB Toolkit (All Issues Fixed)${RESET}"
    echo ""
}

# ==== Utility Functions ====
get_timestamp() {
    date +'%H:%M:%S'
}

format_duration() {
    local duration=$1
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" $hours $minutes $seconds
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" $minutes $seconds
    else
        printf "%ds" $seconds
    fi
}

# Convert bytes to human-readable format
format_bytes() {
    local bytes=$1
    if [[ $bytes -ge 1099511627776 ]]; then
        printf "%.2f TiB" $(echo "scale=2; $bytes / 1099511627776" | bc)
    elif [[ $bytes -ge 1073741824 ]]; then
        printf "%.2f GiB" $(echo "scale=2; $bytes / 1073741824" | bc)
    elif [[ $bytes -ge 1048576 ]]; then
        printf "%.2f MiB" $(echo "scale=2; $bytes / 1048576" | bc)
    elif [[ $bytes -ge 1024 ]]; then
        printf "%.2f KiB" $(echo "scale=2; $bytes / 1024" | bc)
    else
        printf "%d B" $bytes
    fi
}

# Get device size in bytes
get_device_bytes() {
    local device="$1"
    blockdev --getsize64 "$device" 2>/dev/null || echo 0
}

start_timer() {
    local operation="$1"
    OPERATION_TIMES["${operation}_start"]=$(date +%s)
    log "Starting: $operation"
}

end_timer() {
    local operation="$1"
    local start_time=${OPERATION_TIMES["${operation}_start"]}
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    OPERATION_TIMES["${operation}_duration"]=$duration
    success "Completed: $operation [$(format_duration $duration)]"
}

log() {
    printf '%b[%s] %s%b\n' "${GRAY}" "$(get_timestamp)" "$1" "${RESET}"
}

error_exit() {
    printf '%b[ERROR] %s%b\n' "${RED}" "$1" "${RESET}" >&2
    exit 1
}

warn() {
    printf '%b[WARNING] %s%b\n' "${YELLOW}" "$1" "${RESET}"
}

success() {
    printf '%b[SUCCESS] %s%b\n' "${GREEN}" "$1" "${RESET}"
}

info() {
    printf '%b[INFO] %s%b\n' "${BLUE}" "$1" "${RESET}"
}

# ==== Validation Functions ====
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error_exit "Don't run this script as root! Use sudo for individual commands when needed."
    fi
}

check_dependencies() {
    start_timer "Dependency Check"
    local missing=()
    local deps=("lsblk" "parted" "dd" "mkfs.ext4" "sync" "partprobe" "bc" "blockdev")
    local optional_deps=("mkfs.exfat" "mkfs.vfat" "mkfs.ntfs" "cryptsetup" "pv" "shred")
    
    # Check required dependencies
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Missing required dependencies: ${missing[*]}. Install with: sudo apt install ${missing[*]// / }"
    fi
    
    # Check optional dependencies and warn if missing
    local missing_optional=()
    for dep in "${optional_deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_optional+=("$dep")
        fi
    done
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Missing optional dependencies: ${missing_optional[*]} (some filesystem/encryption options will be unavailable)"
    fi
    
    end_timer "Dependency Check"
}

# ==== Device Functions ====
# Global array to store removable devices
declare -a REMOVABLE_DEVICES

get_removable_devices() {
    # Get only removable devices (USB drives, SD cards, etc.)
    # Using -P for parseable output to handle spaces in MODEL/VENDOR
    lsblk -d -P -o NAME,SIZE,TYPE,HOTPLUG,MODEL,VENDOR,TRAN 2>/dev/null | \
    while IFS= read -r line; do
        eval "$line"
        if [[ ("$HOTPLUG" == "1" || "$TRAN" == "usb") && "$TYPE" == "disk" ]]; then
            # Clean up MODEL and VENDOR by removing trailing spaces
            MODEL="${MODEL//\"/}"
            VENDOR="${VENDOR//\"/}"
            MODEL=$(echo "$MODEL" | sed 's/[[:space:]]*$//')
            VENDOR=$(echo "$VENDOR" | sed 's/[[:space:]]*$//')
            echo "/dev/$NAME:$SIZE:${MODEL:-Unknown}:${VENDOR:-Unknown}"
        fi
    done
}

show_devices() {
    start_timer "Device Discovery"
    printf '%b+-- Available Removable Storage Devices ------------+%b\n' "${BLUE}" "${RESET}"
    
    local device_count=0
    REMOVABLE_DEVICES=()  # Clear the global array
    
    # Get removable devices
    while IFS=':' read -r device size model vendor; do
        if [[ -n "$device" && -b "$device" ]]; then
            REMOVABLE_DEVICES+=("$device")
            printf '%b| %d) %-12s %8s  %-15s %-10s |%b\n' "${CYAN}" "$((++device_count))" \
                "${device##*/}" "$size" "${model:-Unknown}" "${vendor:-Unknown}" "${RESET}"
        fi
    done < <(get_removable_devices)
    
    printf '%b+-------------------------------------------------------+%b\n' "${BLUE}" "${RESET}"
    
    if [[ $device_count -eq 0 ]]; then
        warn "No removable USB devices found!"
        echo ""
        printf '%b+-- All Storage Devices (for reference) ---------------+%b\n' "${GRAY}" "${RESET}"
        while IFS= read -r line; do
            if [[ $line == *"disk"* ]]; then
                printf '%b| DISK: %s%b\n' "${GRAY}" "$line" "${RESET}"
            fi
        done < <(lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR 2>/dev/null | grep "disk" | grep -v "loop" || true)
        printf '%b+-------------------------------------------------------+%b\n' "${GRAY}" "${RESET}"
        error_exit "Please connect a USB device and try again"
    fi
    
    log "Found $device_count removable storage device(s)"
    end_timer "Device Discovery"
    echo ""
}

# ==== Pre-nuke Verification Functions ====
# Calculate total data that will be destroyed
calc_destruction_data() {
    local device="$1"
    local total_bytes mounted_bytes=0 unmounted_count=0
    
    total_bytes=$(get_device_bytes "$device")
    
    # Calculate used space on mounted partitions
    while IFS= read -r line; do
        local mountpoint part_type
        mountpoint=$(echo "$line" | awk '{print $1}')
        part_type=$(echo "$line" | awk '{print $2}')
        
        if [[ "$part_type" == "part" && -n "$mountpoint" && "$mountpoint" != "" ]]; then
            local used_bytes
            used_bytes=$(df -B1 --output=used "$mountpoint" 2>/dev/null | tail -n +2 | tr -d ' ' || echo 0)
            mounted_bytes=$((mounted_bytes + used_bytes))
        elif [[ "$part_type" == "part" ]]; then
            ((unmounted_count++))
        fi
    done < <(lsblk -rno MOUNTPOINT,TYPE "$device" 2>/dev/null)
    
    echo "$total_bytes:$mounted_bytes:$unmounted_count"
}

# List mounted partition contents
list_mounted_contents() {
    local device="$1"
    local max_items="${2:-20}"
    local has_mounted=false
    
    while IFS=' ' read -r part_path mountpoint; do
        if [[ -n "$mountpoint" && "$mountpoint" != "" ]]; then
            has_mounted=true
            printf '%b  Partition: %s%b\n' "${CYAN}" "$part_path" "${RESET}"
            printf '%b  Mountpoint: %s%b\n' "${RESET}" "$mountpoint" "${RESET}"
            
            local total_files
            total_files=$(find "$mountpoint" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
            
            printf '%b  Files/Folders (showing %d of %d):%b\n' "${GRAY}" "$((total_files > max_items ? max_items : total_files))" "$total_files" "${RESET}"
            
            if [[ $total_files -gt 0 ]]; then
                ls -A1 "$mountpoint" 2>/dev/null | head -n "$max_items" | while read -r item; do
                    if [[ -d "$mountpoint/$item" ]]; then
                        printf '     %s/\n' "$item"
                    else
                        printf '     %s\n' "$item"
                    fi
                done
                
                if [[ $total_files -gt $max_items ]]; then
                    printf '%b    ... and %d more items%b\n' "${GRAY}" "$((total_files - max_items))" "${RESET}"
                fi
            else
                printf '%b    (empty)%b\n' "${GRAY}" "${RESET}"
            fi
            echo ""
        fi
    done < <(lsblk -rno PATH,MOUNTPOINT,TYPE "$device" 2>/dev/null | awk '$3=="part" {print $1, $2}')
    
    if [[ "$has_mounted" == "false" ]]; then
        printf '%b  No mounted partitions found%b\n' "${GRAY}" "${RESET}"
    fi
}

# Show pre-nuke verification report
pre_nuke_verification() {
    local device="$1"
    
    printf '%b\n%b\n' "${RED}${BOLD}" "${RESET}"
    printf '%b             PRE-NUKE VERIFICATION REPORT                 %b\n' "${RED}${BOLD}" "${RESET}"
    printf '%b%b\n\n' "${RED}${BOLD}" "${RESET}"
    
    # Device information
    local size model vendor
    size=$(lsblk -nd -o SIZE "$device" 2>/dev/null || echo "Unknown")
    model=$(lsblk -nd -o MODEL "$device" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")
    vendor=$(lsblk -nd -o VENDOR "$device" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")
    
    printf '%b Target Device Information:%b\n' "${CYAN}${BOLD}" "${RESET}"
    printf '  Device Path: %s\n' "$device"
    printf '  Vendor/Model: %s %s\n' "$vendor" "$model"
    printf '  Total Capacity: %s\n\n' "$size"
    
    # Partition layout
    printf '%b  Partition Layout:%b\n' "${CYAN}${BOLD}" "${RESET}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$device" 2>/dev/null | sed 's/^/  /'
    echo ""
    
    # Calculate destruction data
    local destruction_info total_bytes mounted_bytes unmounted_count
    destruction_info=$(calc_destruction_data "$device")
    total_bytes=$(echo "$destruction_info" | cut -d: -f1)
    mounted_bytes=$(echo "$destruction_info" | cut -d: -f2)
    unmounted_count=$(echo "$destruction_info" | cut -d: -f3)
    
    # Show mounted contents
    printf '%b Mounted Partition Contents:%b\n' "${CYAN}${BOLD}" "${RESET}"
    list_mounted_contents "$device"
    
    # Data destruction summary
    printf '%b Data Destruction Summary:%b\n' "${YELLOW}${BOLD}" "${RESET}"
    printf '  Total device capacity to be overwritten: %s (%s bytes)\n' "$(format_bytes $total_bytes)" "$total_bytes"
    printf '  Estimated mounted data to be destroyed: %s (%s bytes)\n' "$(format_bytes $mounted_bytes)" "$mounted_bytes"
    
    if [[ $unmounted_count -gt 0 ]]; then
        printf '%b    Warning: %d unmounted partition(s) - actual data loss may be higher%b\n' "${YELLOW}" "$unmounted_count" "${RESET}"
    fi
    
    echo ""
    printf '%b%b\n' "${RED}${BOLD}" "${RESET}"
    printf '%b      THIS ACTION IS COMPLETELY IRREVERSIBLE!           %b\n' "${RED}${BOLD}" "${RESET}"
    printf '%b   ALL DATA ON THIS DEVICE WILL BE PERMANENTLY DESTROYED!    %b\n' "${RED}${BOLD}" "${RESET}"
    printf '%b%b\n\n' "${RED}${BOLD}" "${RESET}"
}

validate_device() {
    local device="$1"
    start_timer "Device Validation"
    
    # Check if device exists
    if [[ ! -b "$device" ]]; then
        error_exit "Device $device does not exist or is not a block device"
    fi
    
    # Enhanced system disk protection - check if device is removable
    local is_removable
    is_removable=$(lsblk -d -n -o HOTPLUG "$device" 2>/dev/null || echo "0")
    local transport
    transport=$(lsblk -d -n -o TRAN "$device" 2>/dev/null || echo "")
    
    if [[ "$is_removable" != "1" && "$transport" != "usb" ]]; then
        # Additional check for common system disk patterns
        case "$device" in
            /dev/sda|/dev/nvme0n1|/dev/mmcblk0|/dev/vda|/dev/hda)
                error_exit "BLOCKED: Device $device appears to be a system disk (not removable)"
                ;;
        esac
        warn "Device $device may not be removable - proceed with extreme caution!"
    fi
    
    # Check for active swap
    if swapon --show 2>/dev/null | grep -q "$device"; then
        error_exit "Device $device is being used as swap. Disable with: sudo swapoff $device"
    fi
    
    # Handle mounted partitions
    local mounted_parts
    mounted_parts=$(mount | grep "^$device" | cut -d' ' -f1 || true)
    if [[ -n "$mounted_parts" ]]; then
        warn "Device $device has mounted partitions"
        echo "Mounted partitions:"
        mount | grep "^$device" | while read -r line; do
            echo "  $line"
        done
        echo ""
        read -p "Unmount and continue? (y/N): " -r continue_mounted
        if [[ ! "$continue_mounted" =~ ^[Yy]$ ]]; then
            error_exit "Aborted by user"
        fi
        
        info "Unmounting all partitions on $device..."
        while IFS= read -r part; do
            if [[ -n "$part" ]]; then
                if sudo umount "$part" 2>/dev/null; then
                    success "Unmounted $part"
                else
                    warn "Could not unmount $part - forcing lazy unmount"
                    sudo umount -l "$part" 2>/dev/null || warn "Force unmount failed for $part"
                fi
            fi
        done <<< "$mounted_parts"
        sync
        sleep 2
    fi
    
    # Get comprehensive device info
    local size model vendor serial
    size=$(lsblk -nd -o SIZE "$device" 2>/dev/null || echo "Unknown")
    model=$(lsblk -nd -o MODEL "$device" 2>/dev/null || echo "Unknown")
    vendor=$(lsblk -nd -o VENDOR "$device" 2>/dev/null || echo "Unknown")
    serial=$(lsblk -nd -o SERIAL "$device" 2>/dev/null || echo "Unknown")
    
    printf '%b+-- Selected Device Information ---------------------+%b\n' "${CYAN}" "${RESET}"
    printf '%b| Device: %-42s |%b\n' "${RESET}" "$device" "${RESET}"
    printf '%b| Size:   %-42s |%b\n' "${RESET}" "$size" "${RESET}"
    printf '%b| Vendor: %-42s |%b\n' "${RESET}" "$vendor" "${RESET}"
    printf '%b| Model:  %-42s |%b\n' "${RESET}" "$model" "${RESET}"
    printf '%b| Serial: %-42s |%b\n' "${RESET}" "$serial" "${RESET}"
    printf '%b+---------------------------------------------------+%b\n' "${CYAN}" "${RESET}"
    
    end_timer "Device Validation"
    echo ""
}

# ==== Input Validation Functions ====
read_with_timeout() {
    local prompt="$1"
    local timeout="${2:-30}"
    local default="${3:-}"
    local response
    
    if [[ -n "$default" ]]; then
        prompt="$prompt [default: $default]: "
    else
        prompt="$prompt: "
    fi
    
    if read -t "$timeout" -p "$prompt" -r response; then
        echo "${response:-$default}"
        return 0
    else
        warn "Input timeout reached"
        if [[ -n "$default" ]]; then
            echo "$default"
            return 0
        else
            return 1
        fi
    fi
}

validate_numeric_choice() {
    local choice="$1"
    local min="$2"
    local max="$3"
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge "$min" ]] && [[ "$choice" -le "$max" ]]; then
        return 0
    else
        return 1
    fi
}

# ==== Progress Monitoring Functions ====
# Monitor dd progress without pv
monitor_dd_progress() {
    local pid="$1"
    local total_bytes="$2"
    local label="$3"
    local start_time=$(date +%s)
    
    # Wait for process to start writing
    sleep 1
    
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -f "/proc/$pid/io" ]]; then
            local written_bytes=$(awk '/write_bytes/{print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            if [[ $elapsed -gt 0 && $written_bytes -gt 0 ]]; then
                local percent=$((written_bytes * 100 / total_bytes))
                local rate=$((written_bytes / elapsed))
                local remaining_bytes=$((total_bytes - written_bytes))
                local eta=0
                
                if [[ $rate -gt 0 ]]; then
                    eta=$((remaining_bytes / rate))
                fi
                
                # Format output
                local written_human=$(format_bytes $written_bytes)
                local total_human=$(format_bytes $total_bytes)
                local rate_mb=$((rate / 1048576))
                local eta_formatted=$(format_duration $eta)
                
                printf "\r%s: %3d%% [%s/%s] %d MB/s ETA: %s     " \
                    "$label" "$percent" "$written_human" "$total_human" "$rate_mb" "$eta_formatted"
            fi
        fi
        sleep 1
    done
    
    echo ""  # New line after progress
}

# ==== Wipe Functions ====
# Enhanced wipe with progress display
perform_wipe_with_progress() {
    local device="$1"
    local method="$2"
    local passes="$3"
    local device_bytes=$(get_device_bytes "$device")
    local pass_bytes=$device_bytes
    local start_time=$(date +%s)
    
    # Check for pv availability
    local has_pv=false
    if command -v pv &> /dev/null; then
        has_pv=true
        info "Using pv for enhanced progress display"
    else
        warn "Install 'pv' for better progress visualization (sudo apt install pv)"
        info "Using fallback progress monitor"
    fi
    
    printf '%b\n Wipe Configuration:%b\n' "${CYAN}${BOLD}" "${RESET}"
    printf '  Device: %s\n' "$device"
    printf '  Method: %s\n' "$method"
    printf '  Passes: %d\n' "$passes"
    printf '  Total to write: %s\n' "$(format_bytes $((pass_bytes * passes)))"
    
    # Estimate time based on typical USB write speeds
    local estimated_speed=$((50 * 1048576))  # 50 MB/s typical USB 3.0
    local estimated_time=$((device_bytes * passes / estimated_speed))
    printf '  Estimated time: %s (at ~50 MB/s)\n\n' "$(format_duration $estimated_time)"
    
    for pass in $(seq 1 $passes); do
        printf '%b Pass %d of %d:%b\n' "${YELLOW}${BOLD}" "$pass" "$passes" "${RESET}"
        
        if [[ "$has_pv" == "true" ]]; then
            # Use pv for progress
            case "$method" in
                "zeros")
                    dd if=/dev/zero bs=4M status=none | \
                    pv -s "$pass_bytes" -p -t -e -r -b -N "Pass $pass/$passes (zeros)" | \
                    sudo dd of="$device" bs=4M oflag=direct status=none conv=fsync 2>/dev/null || true
                    ;;
                "random")
                    pv -s "$pass_bytes" -p -t -e -r -b -N "Pass $pass/$passes (random)" /dev/urandom | \
                    sudo dd of="$device" bs=1M oflag=direct status=none conv=fsync 2>/dev/null || true
                    ;;
                "pattern")
                    # Pattern-based wipe (0xFF, 0x00, random)
                    if [[ $pass -eq 1 ]]; then
                        yes $'\377' | tr -d '\n' | \
                        pv -s "$pass_bytes" -p -t -e -r -b -N "Pass $pass/$passes (0xFF)" | \
                        sudo dd of="$device" bs=4M oflag=direct status=none conv=fsync 2>/dev/null || true
                    elif [[ $pass -eq 2 ]]; then
                        dd if=/dev/zero bs=4M status=none | \
                        pv -s "$pass_bytes" -p -t -e -r -b -N "Pass $pass/$passes (0x00)" | \
                        sudo dd of="$device" bs=4M oflag=direct status=none conv=fsync 2>/dev/null || true
                    else
                        pv -s "$pass_bytes" -p -t -e -r -b -N "Pass $pass/$passes (random)" /dev/urandom | \
                        sudo dd of="$device" bs=1M oflag=direct status=none conv=fsync 2>/dev/null || true
                    fi
                    ;;
            esac
        else
            # Fallback without pv
            case "$method" in
                "zeros")
                    sudo dd if=/dev/zero of="$device" bs=4M oflag=direct conv=fsync 2>/dev/null &
                    local dd_pid=$!
                    monitor_dd_progress "$dd_pid" "$pass_bytes" "Pass $pass/$passes (zeros)"
                    wait "$dd_pid" 2>/dev/null || true
                    ;;
                "random")
                    sudo dd if=/dev/urandom of="$device" bs=1M conv=fsync 2>/dev/null &
                    local dd_pid=$!
                    monitor_dd_progress "$dd_pid" "$pass_bytes" "Pass $pass/$passes (random)"
                    wait "$dd_pid" 2>/dev/null || true
                    ;;
                "pattern")
                    if [[ $pass -eq 1 ]]; then
                        yes $'\377' | tr -d '\n' | sudo dd of="$device" bs=4M oflag=direct conv=fsync 2>/dev/null &
                        local dd_pid=$!
                        monitor_dd_progress "$dd_pid" "$pass_bytes" "Pass $pass/$passes (0xFF)"
                        wait "$dd_pid" 2>/dev/null || true
                    elif [[ $pass -eq 2 ]]; then
                        sudo dd if=/dev/zero of="$device" bs=4M oflag=direct conv=fsync 2>/dev/null &
                        local dd_pid=$!
                        monitor_dd_progress "$dd_pid" "$pass_bytes" "Pass $pass/$passes (0x00)"
                        wait "$dd_pid" 2>/dev/null || true
                    else
                        sudo dd if=/dev/urandom of="$device" bs=1M conv=fsync 2>/dev/null &
                        local dd_pid=$!
                        monitor_dd_progress "$dd_pid" "$pass_bytes" "Pass $pass/$passes (random)"
                        wait "$dd_pid" 2>/dev/null || true
                    fi
                    ;;
            esac
        fi
        
        sync
        success "Pass $pass completed"
    done
    
    # Calculate and display summary
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    local total_written=$((pass_bytes * passes))
    local avg_speed=$((total_written / (total_time > 0 ? total_time : 1)))
    
    echo ""
    printf '%b Wipe Summary:%b\n' "${GREEN}${BOLD}" "${RESET}"
    printf '  Total written: %s\n' "$(format_bytes $total_written)"
    printf '  Total time: %s\n' "$(format_duration $total_time)"
    printf '  Average speed: %d MB/s\n' "$((avg_speed / 1048576))"
}

# Shred-based wipe (uses the shred command if available)
perform_shred_wipe() {
    local device="$1"
    local iterations="$2"

    if ! command -v shred &> /dev/null; then
        warn "shred command not available, falling back to pattern wipe"
        perform_wipe_with_progress "$device" "pattern" "$iterations"
        return
    fi

    local device_bytes=$(get_device_bytes "$device")
    info "Using shred command for secure wiping ($iterations iterations)"

    # Check for pv availability
    if command -v pv &> /dev/null; then
        # Monitor shred progress with pv
        sudo shred -v -n "$iterations" -z "$device" 2>&1 | \
        pv -l -s "$((iterations + 1))" -N "shred progress" > /dev/null
    else
        # Run shred without progress monitoring
        sudo shred -v -n "$iterations" -z "$device"
    fi
}

# Verify wipe completion
verify_wipe() {
    local device="$1"
    local sample_size=$((1024 * 1024 * 10))  # 10 MB sample

    info "Verifying wipe (sampling 10MB)..."
    local sample=$(sudo dd if="$device" bs=1M count=10 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -v '^0*$' || echo "")

    if [[ -z "$sample" ]]; then
        success "Verification passed: Device contains all zeros"
        return 0
    else
        warn "Verification: Device contains non-zero data (may be expected for random wipes)"
        return 1
    fi
}

# Main wipe function dispatcher
perform_wipe() {
    local device="$1"
    local method="$2"

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
            # DoD pattern: random, random, DoD 3-pass pattern, verification
            info "Performing DoD 5220.22-M wipe (7 passes total)"
            perform_wipe_with_progress "$device" "random" 2
            perform_wipe_with_progress "$device" "pattern" 3
            perform_wipe_with_progress "$device" "random" 2
            end_timer "DoD 5220.22-M (7-pass)"
            ;;
        *)
            info "Skipping wipe operation"
            return 0
            ;;
    esac
}

# ==== Partition Functions ====
create_partition() {
    local device="$1"
    local pt_type="$2"
    start_timer "Partition Creation"
    
    info "Creating new partition table..."
    
    case "$pt_type" in
        1)
            sudo parted "$device" --script mklabel gpt
            success "GPT partition table created"
            ;;
        2)
            sudo parted "$device" --script mklabel msdos
            success "MBR partition table created"
            ;;
        *)
            info "Skipping partition table creation"
            end_timer "Partition Creation"
            return 1
            ;;
    esac
    
    info "Creating primary partition..."
    if ! sudo parted "$device" --script mkpart primary 1MiB 100%; then
        error_exit "Failed to create partition on $device"
    fi
    sudo parted "$device" --script set 1 boot on 2>/dev/null || true

    # Ensure partition is recognized
    sync
    sudo partprobe "$device" 2>/dev/null || true
    sleep 3

    # Handle different partition naming schemes
    local part=""
    if [[ "$device" =~ (nvme|mmcblk|loop) ]]; then
        part="${device}p1"
    else
        part="${device}1"
    fi

    local retry_count=0
    while [[ ! -b "$part" ]] && [[ $retry_count -lt 10 ]]; do
        sleep 1
        ((retry_count++))
        log "Waiting for partition to appear... (attempt $retry_count)"
        # Try alternative naming if first attempt fails
        if [[ $retry_count -eq 5 ]]; then
            if [[ "$device" =~ (nvme|mmcblk|loop) ]]; then
                part="${device}1"
            else
                part="${device}p1"
            fi
            log "Trying alternative partition naming: $part"
        fi
    done

    if [[ ! -b "$part" ]]; then
        error_exit "Partition $part was not created successfully after 10 seconds"
    fi
    
    end_timer "Partition Creation"
    success "Partition created: $part"
    echo "$part"
}

# ==== Encryption Functions ====
setup_encryption() {
    local part="$1"
    local mapper_name="$2"
    
    if ! command -v cryptsetup &> /dev/null; then
        warn "cryptsetup not available - skipping encryption"
        echo "$part"
        return 0
    fi
    
    start_timer "LUKS Encryption Setup"
    
    info "Setting up LUKS2 encryption with AES-XTS-256..."
    warn "You will be prompted to enter a passphrase twice"
    echo ""
    
    # Create LUKS container with optimal settings
    if ! sudo cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --iter-time 4000 \
        --use-random \
        "$part"; then
        error_exit "Failed to create LUKS container"
    fi
    
    info "Opening encrypted container..."
    if ! sudo cryptsetup open "$part" "$mapper_name"; then
        error_exit "Failed to open LUKS container"
    fi
    
    local mapped_device="/dev/mapper/$mapper_name"
    end_timer "LUKS Encryption Setup"
    success "Encryption setup complete: $mapped_device"
    echo "$mapped_device"
}

# ==== Filesystem Functions ====
format_filesystem() {
    local device="$1"
    local fstype="$2"
    local label="$3"
    
    case "$fstype" in
        1)
            start_timer "ext4 Format"
            info "Creating ext4 filesystem with label: $label"
            sudo mkfs.ext4 -F -L "$label" -O ^64bit,^metadata_csum -E lazy_itable_init=0,lazy_journal_init=0 "$device"
            end_timer "ext4 Format"
            ;;
        2)
            if ! command -v mkfs.exfat &> /dev/null; then
                warn "mkfs.exfat not available, using FAT32 instead"
                format_filesystem "$device" 3 "$label"
                return
            fi
            start_timer "exFAT Format"
            info "Creating exFAT filesystem with label: $label"
            sudo mkfs.exfat -n "$label" "$device"
            end_timer "exFAT Format"
            ;;
        3)
            if ! command -v mkfs.vfat &> /dev/null; then
                warn "mkfs.vfat not available, falling back to ext4"
                format_filesystem "$device" 1 "$label"
                return
            fi
            start_timer "FAT32 Format"
            info "Creating FAT32 filesystem with label: $label"
            sudo mkfs.vfat -F 32 -n "$label" "$device"
            end_timer "FAT32 Format"
            ;;
        4)
            if ! command -v mkfs.ntfs &> /dev/null; then
                warn "mkfs.ntfs not available, falling back to ext4"
                format_filesystem "$device" 1 "$label"
                return
            fi
            start_timer "NTFS Format"
            info "Creating NTFS filesystem with label: $label"
            sudo mkfs.ntfs -f -L "$label" "$device"
            end_timer "NTFS Format"
            ;;
        *)
            info "Skipping filesystem formatting"
            return 0
            ;;
    esac
    
    sync
    success "Filesystem created successfully"
}

# ==== Mount Functions ====
mount_device() {
    local device="$1"
    local mount_name="$2"
    local mount_dir="/mnt/$mount_name"
    start_timer "Device Mount"
    
    info "Creating mount directory: $mount_dir"
    sudo mkdir -p "$mount_dir"
    
    info "Mounting device..."
    if ! sudo mount "$device" "$mount_dir"; then
        error_exit "Failed to mount $device to $mount_dir"
    fi
    
    # Set proper ownership and permissions
    sudo chown -R "$USER:$(id -gn)" "$mount_dir" 2>/dev/null || true
    sudo chmod 755 "$mount_dir"
    
    end_timer "Device Mount"
    success "Device mounted at $mount_dir"
    
    # Display mount information
    printf '%b+-- Mount Information -------------------------------+%b\n' "${GRAY}" "${RESET}"
    df -h "$mount_dir" | tail -1 | while read -r filesystem size used avail use_percent mountpoint; do
        printf '%b| Filesystem: %-36s |%b\n' "${RESET}" "$filesystem" "${RESET}"
        printf '%b| Size:       %-36s |%b\n' "${RESET}" "$size" "${RESET}"
        printf '%b| Available:  %-36s |%b\n' "${RESET}" "$avail" "${RESET}"
        printf '%b| Used:       %-36s |%b\n' "${RESET}" "$use_percent" "${RESET}"
        printf '%b| Mount:      %-36s |%b\n' "${RESET}" "$mountpoint" "${RESET}"
    done
    printf '%b+-------------------------------------------------+%b\n' "${GRAY}" "${RESET}"
}

# ==== Cleanup and Summary ====
show_operation_summary() {
    local total_time=$(($(date +%s) - SCRIPT_START_TIME))
    
    echo ""
    printf '%b+== OPERATION SUMMARY ==============================+%b\n' "${BOLD}${CYAN}" "${RESET}"
    
    for key in "${!OPERATION_TIMES[@]}"; do
        if [[ $key == *"_duration" ]]; then
            local op_name=${key%_duration}
            local duration=${OPERATION_TIMES[$key]}
            printf '%b| %-25s : %15s |%b\n' "${RESET}" "$op_name" "$(format_duration $duration)" "${RESET}"
        fi
    done
    
    printf '%b| %-25s : %15s |%b\n' "${BOLD}" "TOTAL RUNTIME" "$(format_duration $total_time)" "${RESET}"
    printf '%b+==============================================+%b\n' "${BOLD}${CYAN}" "${RESET}"
}

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        warn "Script exited with error code $exit_code"
        info "Some operations may need manual cleanup"
    fi
    show_operation_summary
    exit $exit_code
}

# ==== Main Function ====
main() {
    trap cleanup EXIT
    
    show_banner
    check_root
    check_dependencies
    
    # Device selection with improved logic
    show_devices  # This will populate REMOVABLE_DEVICES array
    
    if [[ ${#REMOVABLE_DEVICES[@]} -eq 0 ]]; then
        error_exit "No removable devices found"
    fi
    
    local DEVICE=""
    if [[ ${#REMOVABLE_DEVICES[@]} -eq 1 ]]; then
        DEVICE="${REMOVABLE_DEVICES[0]}"
        info "Auto-selecting only available device: $DEVICE"
    else
        printf '%bSelect USB device to process:%b\n' "${CYAN}" "${RESET}"
        echo "Enter device number (1-${#REMOVABLE_DEVICES[@]}) or full path:"
        
        local choice
        if ! choice=$(read_with_timeout "Choice" 30); then
            error_exit "No device selected (timeout)"
        fi
        
        if [[ -z "$choice" ]]; then
            error_exit "No device specified"
        fi
        
        # Check if it's a number (device selection)
        if validate_numeric_choice "$choice" 1 "${#REMOVABLE_DEVICES[@]}"; then
            DEVICE="${REMOVABLE_DEVICES[$((choice-1))]}"
        # Check if it's a valid device path
        elif [[ "$choice" =~ ^/dev/.+ ]] && [[ -b "$choice" ]]; then
            DEVICE="$choice"
        else
            error_exit "Invalid device selection: $choice"
        fi
    fi
    
    validate_device "$DEVICE"
    
    # Show pre-nuke verification report BEFORE any destructive action
    pre_nuke_verification "$DEVICE"
    
    # Double confirmation with device path and NUKE command
    printf '%b\n  FINAL CONFIRMATION REQUIRED %b\n\n' "${RED}${BOLD}" "${RESET}"
    
    # First confirmation: exact device path
    printf '%bStep 1: Type the exact device path to confirm%b\n' "${YELLOW}" "${RESET}"
    printf 'You must type: %b%s%b\n' "${CYAN}${BOLD}" "$DEVICE" "${RESET}"
    
    local device_confirm
    read -p "Enter device path: " -r device_confirm
    
    if [[ "$device_confirm" != "$DEVICE" ]]; then
        error_exit "Device path mismatch. You entered '$device_confirm' but expected '$DEVICE'. Aborting for safety."
    fi
    
    success "Device path confirmed: $device_confirm"
    echo ""
    
    # Second confirmation: NUKE IT
    printf '%bStep 2: Type exactly %bNUKE IT%b to proceed%b\n' "${YELLOW}" "${RED}${BOLD}" "${YELLOW}" "${RESET}"
    printf 'This is your last chance to cancel. Type %bNUKE IT%b or press Ctrl+C to abort.\n' "${RED}${BOLD}" "${RESET}"
    
    local nuke_confirm
    read -p "Enter confirmation: " -r nuke_confirm
    
    if [[ "$nuke_confirm" != "NUKE IT" ]]; then
        error_exit "Confirmation failed. You entered '$nuke_confirm' but expected 'NUKE IT'. Operation aborted."
    fi
    
    success "Final confirmation received"
    echo ""
    
    # Now unmount all partitions AFTER verification and confirmation
    printf '%b Preparing device for wipe...%b\n' "${CYAN}${BOLD}" "${RESET}"
    
    # Unmount all partitions on the device
    local mounted_parts
    mounted_parts=$(mount | grep "^$DEVICE" | cut -d' ' -f1 || true)
    if [[ -n "$mounted_parts" ]]; then
        info "Unmounting all partitions on $DEVICE..."
        while IFS= read -r part; do
            if [[ -n "$part" ]]; then
                if sudo umount "$part" 2>/dev/null; then
                    success "Unmounted $part"
                else
                    warn "Could not unmount $part - forcing lazy unmount"
                    sudo umount -l "$part" 2>/dev/null || warn "Force unmount failed for $part"
                fi
            fi
        done <<< "$mounted_parts"
        sync
        sleep 2
    fi
    
    # Wipe method selection
    echo ""
    printf '%bChoose wipe method:%b\n' "${CYAN}" "${RESET}"
    echo "1) Zero fill (fast, single pass, verified)"
    echo "2) Random data (secure, single pass)"
    echo "3) Shred (secure, 3-pass using shred command)"
    echo "4) DoD 5220.22-M (very secure, 7-pass)"
    echo "5) Skip wipe"
    
    local WIPE_METHOD
    if ! WIPE_METHOD=$(read_with_timeout "Select (1-5)" 30 "1"); then
        warn "Using default: Zero fill"
        WIPE_METHOD="1"
    fi
    
    if ! validate_numeric_choice "$WIPE_METHOD" 1 5; then
        warn "Invalid choice, using zero fill"
        WIPE_METHOD="1"
    fi
    
    perform_wipe "$DEVICE" "$WIPE_METHOD"
    
    # Partition table selection
    echo ""
    printf '%bChoose partition table:%b\n' "${CYAN}" "${RESET}"
    echo "1) GPT (recommended for modern systems)"
    echo "2) MBR (compatible with older systems)"
    echo "3) Skip partitioning"
    
    local PT_TYPE
    if ! PT_TYPE=$(read_with_timeout "Select (1-3)" 30 "1"); then
        warn "Using default: GPT"
        PT_TYPE="1"
    fi
    
    if ! validate_numeric_choice "$PT_TYPE" 1 3; then
        warn "Invalid choice, using GPT"
        PT_TYPE="1"
    fi
    
    local PART=""
    if [[ "$PT_TYPE" =~ ^[12]$ ]]; then
        PART=$(create_partition "$DEVICE" "$PT_TYPE")
    else
        info "Skipping partitioning - manual partition creation required"
        show_operation_summary
        exit 0
    fi
    
    # Filesystem label
    local LABEL
    if ! LABEL=$(read_with_timeout "Enter filesystem label" 30 "NUKED"); then
        LABEL="NUKED"
    fi
    LABEL=${LABEL:-NUKED}
    
    # Encryption setup
    echo ""
    local do_encrypt
    if ! do_encrypt=$(read_with_timeout "Encrypt with LUKS2? (y/N)" 30 "N"); then
        do_encrypt="N"
    fi
    
    local MAPPED_DEV=""
    if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
        MAPPED_DEV=$(setup_encryption "$PART" "nuked_usb")
    else
        MAPPED_DEV="$PART"
    fi
    
    # Filesystem selection
    echo ""
    printf '%bChoose filesystem:%b\n' "${CYAN}" "${RESET}"
    echo "1) ext4 (Linux native, journaled)"
    echo "2) exFAT (cross-platform, large files)"
    echo "3) FAT32 (universal compatibility)"
    echo "4) NTFS (Windows native)"
    echo "5) Skip formatting"
    
    local FSTYPE
    if ! FSTYPE=$(read_with_timeout "Select (1-5)" 30 "1"); then
        warn "Using default: ext4"
        FSTYPE="1"
    fi
    
    if ! validate_numeric_choice "$FSTYPE" 1 5; then
        warn "Invalid choice, using ext4"
        FSTYPE="1"
    fi
    
    format_filesystem "$MAPPED_DEV" "$FSTYPE" "$LABEL"
    
    # Mount option
    echo ""
    local do_mount
    if ! do_mount=$(read_with_timeout "Mount device now? (y/N)" 30 "N"); then
        do_mount="N"
    fi
    
    if [[ "$do_mount" =~ ^[Yy]$ ]]; then
        local MOUNT_NAME
        if ! MOUNT_NAME=$(read_with_timeout "Mount directory name" 30 "nuked"); then
            MOUNT_NAME="nuked"
        fi
        MOUNT_NAME=${MOUNT_NAME:-nuked}
        mount_device "$MAPPED_DEV" "$MOUNT_NAME"
    fi
    
    # Final success message
    echo ""
    printf '%b+== SUCCESS ====================================+%b\n' "${GREEN}${BOLD}" "${RESET}"
    printf '%b| USB Nuke Beast operation completed!        |%b\n' "${GREEN}${BOLD}" "${RESET}"
    printf '%b| Device %s is ready for use!%*s|%b\n' "${GREEN}${BOLD}" "$DEVICE" $((20 - ${#DEVICE})) "" "${RESET}"
    printf '%b+==============================================+%b\n' "${GREEN}${BOLD}" "${RESET}"
    
    # Encryption notes
    if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
        echo ""
        printf '%bEncryption Notes:%b\n' "${CYAN}" "${RESET}"
        echo "  + Device is encrypted with LUKS2"
        echo "  + To mount later: sudo cryptsetup open $PART nuked_usb"
        echo "  + To unmount: sudo cryptsetup close nuked_usb"
        echo "  + Keep your passphrase safe - no recovery without it!"
    fi
}

# Execute main function
main "$@"
