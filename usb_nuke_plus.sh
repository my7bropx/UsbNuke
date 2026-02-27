#!/bin/bash
# Requires: bash 4+, lsblk, parted, dd, mkfs.ext4, partprobe, bc
# Optional: cryptsetup shred mkfs.exfat mkfs.vfat mkfs.ntfs
set -o pipefail  

R='\033[0;31m';  G='\033[0;32m';  Y='\033[1;33m';  B='\033[0;34m'
C='\033[0;36m';  M='\033[0;35m';  W='\033[0;37m';  DK='\033[0;90m'
LR='\033[1;31m'; LG='\033[1;32m'; LC='\033[1;36m'; LW='\033[1;37m'
BO='\033[1m';    DIM='\033[2m';   IT='\033[3m';     UL='\033[4m'
RST='\033[0m'

BG_BLK='\033[40m'; BG_RED='\033[41m'; BG_GRN='\033[42m'
BG_YEL='\033[43m'; BG_BLU='\033[44m'; BG_MAG='\033[45m'
BG_CYN='\033[46m'; BG_WHT='\033[47m'; BG_DK='\033[100m'

HIDE='\033[?25l';       SHOW='\033[?25h'
ALT_ON='\033[?1049h';   ALT_OFF='\033[?1049l'
CLS='\033[2J';          HOME='\033[H'

_IN_ALT=0   

move()   { printf "\033[%d;%dH" "$1" "$2"; }
clreos() { printf '\033[J'; }


TW=80; TH=24

get_term_size() {
    if command -v tput &>/dev/null && [[ -n "${TERM:-}" ]]; then
        TW=$(tput cols  2>/dev/null || echo 80)
        TH=$(tput lines 2>/dev/null || echo 24)
        return
    fi
    local sz
    if sz=$(stty size 2>/dev/null); then
        TH=${sz%% *}; TW=${sz##* }
        return
    fi
    TW=${COLUMNS:-80}; TH=${LINES:-24}
}


readonly SCRIPT_START=$(date +%s)
declare -a USB_DEVICES=()

SEL_DEVICE=""
SEL_WIPE=0
SEL_PTABLE=1
SEL_FS=1
SEL_LABEL="NUKED"
SEL_ENCRYPT=0
SEL_MOUNT=0
SEL_MOUNTNAME="usb"
MAPPER_NAME=""
CONFIRMED=0


CFG_CUR_SECTION=0
CFG_CUR_ITEM=0
CFG_PANEL_R=4
CFG_PANEL_C=3
CFG_PANEL_W=80
CFG_LEFT_W=44
CFG_RIGHT_C=50
CFG_RIGHT_W=30
CFG_DEV_BYTES=0
CFG_DEV_SIZE="?"
CFG_DEV_MODEL="Unknown"

EXEC_LOG_ROW=10

_has_cmd() {
    command -v "$1" &>/dev/null \
        || [[ -x "/sbin/$1" ]] \
        || [[ -x "/usr/sbin/$1" ]] \
        || [[ -x "/usr/local/sbin/$1" ]]
}

fmt_dur() {
    local d=$1
    local h=$(( d/3600 )) m=$(( (d%3600)/60 )) s=$(( d%60 ))
    (( h > 0 )) && printf "%dh%02dm" "$h" "$m" && return
    (( m > 0 )) && printf "%dm%02ds" "$m" "$s" && return
    printf "%ds" "$s"
}

fmt_bytes() {
    local b="${1:-0}"
    if   (( b >= 1099511627776 )); then awk "BEGIN{printf \"%.1fT\",$b/1099511627776}"
    elif (( b >= 1073741824    )); then awk "BEGIN{printf \"%.1fG\",$b/1073741824}"
    elif (( b >= 1048576       )); then awk "BEGIN{printf \"%.1fM\",$b/1048576}"
    elif (( b >= 1024          )); then awk "BEGIN{printf \"%.1fK\",$b/1024}"
    else printf "%dB" "$b"
    fi
}

get_device_bytes() {
    local out
    out=$(lsblk -bnd -o SIZE "$1" 2>/dev/null | tr -d ' \n') \
        || out=$(sudo blockdev --getsize64 "$1" 2>/dev/null | tr -d ' \n')
    printf '%s' "${out:-0}"
}

repeat_char() {
    local ch="$1" n="${2:-0}"
    local i
    for (( i=0; i<n; i++ )); do printf '%s' "$ch"; done
}

hline() {
    local row=$1 col=$2 w=$3 ch="${4:-─}" color="${5:-$DK}"
    move "$row" "$col"
    printf "%b" "$color"
    repeat_char "$ch" "$w"
    printf "%b" "$RST"
}

draw_box() {
    local r=$1 c=$2 h=$3 w=$4 col="${5:-$C}" title="${6:-}"
    local inner=$(( w - 2 ))

    move "$r" "$c"
    printf "%b╭" "$col"
    if [[ -n "$title" ]]; then
        local tlen=${#title}
        local avail=$(( inner - tlen - 2 ))
        (( avail < 0 )) && avail=0
        local lpad=$(( avail / 2 ))
        local rpad=$(( avail - lpad ))
        repeat_char '─' "$lpad"
        printf "┤ %b%b%s%b%b ├" "$BO" "$LW" "$title" "$RST" "$col"
        repeat_char '─' "$rpad"
    else
        repeat_char '─' "$inner"
    fi
    printf "╮%b" "$RST"

    local i
    for (( i=1; i<h-1; i++ )); do
        move $(( r+i )) "$c"
        printf "%b│%b%*s%b│%b" "$col" "$RST" "$inner" '' "$col" "$RST"
    done

    move $(( r+h-1 )) "$c"
    printf "%b╰" "$col"
    repeat_char '─' "$inner"
    printf "╯%b" "$RST"
}

clear_region() {
    local r=$1 c=$2 h=$3 w=$4
    local blank
    blank=$(printf '%*s' "$w" '')
    local i
    for (( i=0; i<h; i++ )); do
        move $(( r+i )) "$c"
        printf '%s' "$blank"
    done
}

draw_chrome() {
    get_term_size
    printf "%b%b%b" "$HIDE" "$CLS" "$HOME"

    move 1 1
    printf "%b%b%b" "$BG_DK" "$LC" "$BO"
    printf '%*s' "$TW" '' | tr ' ' ' '
    move 1 1
    local title="  ☢  USB NUKE BEAST  v3.1  ─  Wipe · Encrypt · Format · Mount  ☢"
    printf "%b%b%b%s%b" "$BG_DK" "$LC" "$BO" "$title" "$RST"
    move 1 $(( TW - 19 ))
    printf "%b%b%s%b" "$BG_DK" "$DK" "bash TUI  $(date +'%H:%M')" "$RST"

    move "$TH" 1
    printf "%b%b" "$BG_DK" "$DK"
    printf '%*s' "$TW" '' | tr ' ' ' '
    move "$TH" 1
    printf "%b%b  ↑↓ navigate   Enter select   Tab toggle   Esc/q quit%b" "$BG_DK" "$DK" "$RST"
    move "$TH" $(( TW - 24 ))
    printf "%b%bCtrl+C to abort at any time%b" "$BG_DK" "$DK" "$RST"

    move 2 1
    printf "%b" "$DK"
    repeat_char '─' "$TW"
    printf "%b" "$RST"
}

screen_splash() {
    draw_chrome

    local art_row=4
    local art=(
        "  ███╗   ██╗██╗   ██╗██╗  ██╗███████╗    ██████╗ ███████╗ █████╗ ███████╗████████╗"
        "  ████╗  ██║██║   ██║██║ ██╔╝██╔════╝    ██╔══██╗██╔════╝██╔══██╗██╔════╝╚══██╔══╝"
        "  ██╔██╗ ██║██║   ██║█████╔╝ █████╗      ██████╔╝█████╗  ███████║███████╗   ██║   "
        "  ██║╚██╗██║██║   ██║██╔═██╗ ██╔══╝      ██╔══██╗██╔══╝  ██╔══██║╚════██║   ██║   "
        "  ██║ ╚████║╚██████╔╝██║  ██╗███████╗    ██████╔╝███████╗██║  ██║███████║   ██║   "
        "  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝    ╚═════╝ ╚══════╝╚═╝  ╚═╝╚══════╝   ╚═╝  "
    )

    for line in "${art[@]}"; do
        move "$art_row" 1
        printf "%b%b%s%b" "$R" "$BO" "$line" "$RST"
        (( art_row++ ))
    done

    move $(( art_row + 1 )) 1
    printf "%b" "$DK"; repeat_char '─' "$TW"; printf "%b" "$RST"

    move $(( art_row + 2 )) 4
    printf "%b%bSecure USB wipe · encrypt · partition · format · mount%b" "$Y" "$BO" "$RST"
    move $(( art_row + 3 )) 4
    printf "%bAll operations run with sudo. You will be prompted when needed.%b" "$DK" "$RST"

    local chk_row=$(( art_row + 5 ))
    draw_box "$chk_row" 3 8 $(( TW - 4 )) "$C" "Startup Checks"
    local r=$(( chk_row + 1 ))

    # Root check
    move "$r" 5; (( r++ ))
    if [[ $EUID -eq 0 ]]; then
        printf "%b%b ✗  Running as root%b  — re-run as a normal user (sudo is used per-command)" "$R" "$BO" "$RST"
        move "$TH" 1
        printf "%b%b  ERROR: Do not run as root. Exiting.  %b" "$BG_RED" "$LW" "$RST"
        sleep 2; tui_quit 1
    else
        printf "%b ✓  Not root%b  — %bgood, sudo will be requested for individual commands%b" \
            "$LG" "$RST" "$DK" "$RST"
    fi

    # Required deps
    move "$r" 5; (( r++ ))
    local missing=() ok=()
    local deps=("lsblk" "parted" "dd" "mkfs.ext4" "partprobe" "blockdev")
    local d
    for d in "${deps[@]}"; do
        _has_cmd "$d" && ok+=("$d") || missing+=("$d")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf "%b ✗  Missing: %s%b" "$R" "${missing[*]}" "$RST"
        move "$r" 5; (( r++ ))
        printf "%b    Install: sudo apt install parted e2fsprogs util-linux%b" "$Y" "$RST"
    else
        printf "%b ✓  Required tools found%b  — %b%s%b" "$LG" "$RST" "$DK" "${ok[*]}" "$RST"
    fi

    move "$r" 5; (( r++ ))
    local opt_miss=()
    local opt=("cryptsetup" "shred" "mkfs.exfat" "mkfs.vfat" "mkfs.ntfs")
    for d in "${opt[@]}"; do
        _has_cmd "$d" || opt_miss+=("$d")
    done
    if [[ ${#opt_miss[@]} -gt 0 ]]; then
        printf "%b ⚠  Optional missing: %b%s%b  (some features unavailable)" \
            "$Y" "$DK" "${opt_miss[*]}" "$RST"
    else
        printf "%b ✓  All optional tools found%b" "$LG" "$RST"
    fi

    # Kernel info
    move "$r" 5
    local kver; kver=$(uname -r 2>/dev/null || echo "unknown")
    printf "%b ℹ  Kernel %s   │   %s%b" "$DK" "$kver" "$(date)" "$RST"

    if [[ ${#missing[@]} -gt 0 ]]; then
        move $(( chk_row + 8 )) 5
        printf "%b%b Cannot continue — fix missing dependencies above.%b" "$R" "$BO" "$RST"
        move "$TH" 1
        printf "%b%b  Press any key to exit...%b" "$BG_DK" "$Y" "$RST"
        read -rsn1; tui_quit 1
    fi

    move $(( chk_row + 7 )) 1
    printf "%b" "$DK"; repeat_char '─' "$TW"; printf "%b" "$RST"
    move $(( TH - 1 )) 1
    printf "%b  Press %b%bEnter%b%b to continue...%b" "$C" "$RST" "$BO" "$RST" "$C" "$RST"
    read -rsn1
}

scan_devices() {
    USB_DEVICES=()
    local line NAME SIZE MODEL TRAN HOTPLUG dev
    while IFS= read -r line; do
        NAME=""   SIZE=""   MODEL=""   TRAN=""   HOTPLUG=""
        [[ "$line" =~ NAME=\"([^\"]*)\" ]]    && NAME="${BASH_REMATCH[1]}"
        [[ "$line" =~ SIZE=\"([^\"]*)\" ]]    && SIZE="${BASH_REMATCH[1]}"
        [[ "$line" =~ MODEL=\"([^\"]*)\" ]]   && MODEL="${BASH_REMATCH[1]}"
        [[ "$line" =~ TRAN=\"([^\"]*)\" ]]    && TRAN="${BASH_REMATCH[1]}"
        [[ "$line" =~ HOTPLUG=\"([^\"]*)\" ]] && HOTPLUG="${BASH_REMATCH[1]}"

        dev="/dev/$NAME"
        [[ -b "$dev" ]]                                  || continue
        [[ "$TRAN" == "usb" || "$HOTPLUG" == "1" ]]     || continue
        [[ "$NAME" =~ ^(loop|sr) ]]                      && continue

        MODEL="${MODEL%"${MODEL##*[![:space:]]}"}"
        USB_DEVICES+=("$dev:$SIZE:${MODEL:-Unknown}:${TRAN:-?}:${HOTPLUG:-0}")
    done < <(lsblk -d -P -o NAME,SIZE,MODEL,TRAN,HOTPLUG 2>/dev/null)
}

_DS_SELECTED=0
_DS_LIST_W=0
_DS_LIST_START=0
_DS_INNER_R=0
_DS_INNER_H=0
_DS_PANEL_C=0
_DS_DETAIL_C=0
_DS_DETAIL_W=0
_DS_PANEL_H=0
_DS_PANEL_R=0

_ds_draw_device_list() {
    local idx dev size model tran hotplug
    for (( idx=0; idx<${#USB_DEVICES[@]}; idx++ )); do
        IFS=: read -r dev size model tran hotplug <<< "${USB_DEVICES[$idx]}"
        move $(( _DS_LIST_START + idx )) $(( _DS_PANEL_C + 1 ))
        if [[ $idx -eq $_DS_SELECTED ]]; then
            printf "%b%b%b" "$BG_DK" "$LC" "$BO"
        else
            printf "%b" "$RST"
        fi
        printf " %-7s %-8s %-17s %-5s%b" \
            "${dev##*/}" "$size" "${model:0:17}" "$tran" "$RST"
    done
    for (( idx=${#USB_DEVICES[@]}; idx<_DS_INNER_H-3; idx++ )); do
        move $(( _DS_LIST_START + idx )) $(( _DS_PANEL_C + 1 ))
        printf '%*s' $(( _DS_LIST_W - 1 )) ''
    done
}

_ds_draw_device_detail() {
    local dr=$(( _DS_INNER_R ))
    local dev_entry="${USB_DEVICES[$_DS_SELECTED]:-}"
    local dw=$(( _DS_DETAIL_W - 1 ))

    local di
    for (( di=0; di<_DS_INNER_H-2; di++ )); do
        move $(( dr + di )) "$_DS_DETAIL_C"
        printf '%*s' "$dw" ''
    done

    if [[ -z "$dev_entry" ]]; then
        move "$dr" "$_DS_DETAIL_C"
        printf "%b  No USB drives detected.%b" "$DK" "$RST"
        move $(( dr+1 )) "$_DS_DETAIL_C"
        printf "%b  Plug in a drive and press %br%b to rescan.%b" "$DK" "$LC" "$DK" "$RST"
        return
    fi

    local dev size model tran hotplug
    IFS=: read -r dev size model tran hotplug <<< "$dev_entry"
    local bytes; bytes=$(get_device_bytes "$dev")
    local serial vendor
    serial=$(lsblk -nd -o SERIAL "$dev" 2>/dev/null | tr -d ' \n' || echo "—")
    vendor=$(lsblk -nd -o VENDOR "$dev" 2>/dev/null | tr -d ' \n'  || echo "—")
    [[ -z "$serial" ]] && serial="—"
    [[ -z "$vendor" ]] && vendor="—"

    move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
    printf "%b%b  Device Details%b" "$C" "$BO" "$RST"
    move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
    printf "%b  ─────────────────────────────────────%b" "$DK" "$RST"

    local _kv_items=("Path:$dev" "Size:$size  ($(fmt_bytes "$bytes"))" "Model:$model" "Vendor:$vendor" "Serial:$serial" "Bus:$tran")
    local _kv_item _kv_key _kv_val
    for _kv_item in "${_kv_items[@]}"; do
        _kv_key="${_kv_item%%:*}"
        _kv_val="${_kv_item#*:}"
        move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
        printf "  %b%-10s%b  %b%s%b" "$DK" "$_kv_key" "$RST" "$LW" "$_kv_val" "$RST"
    done

    move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
    printf "%b  ─────────────────────────────────────%b" "$DK" "$RST"
    move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
    printf "%b  Partitions%b" "$C" "$RST"

    local pline
    while IFS= read -r pline; do
        move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
        printf "  %b%s%b" "$DK" "$pline" "$RST"
        (( dr > _DS_PANEL_R + _DS_PANEL_H - 3 )) && break
    done < <(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" 2>/dev/null | tail -n +2)

    if [[ "$hotplug" != "1" && "$tran" != "usb" ]]; then
        move "$dr" "$_DS_DETAIL_C"; (( dr++ ))
        printf "%b%b  ⚠  Not a removable drive!%b" "$Y" "$BO" "$RST"
        move "$dr" "$_DS_DETAIL_C"
        printf "%b  Proceed with extreme caution.%b" "$Y" "$RST"
    fi
}

_ds_draw_list_hint() {
    local hint_r=$(( _DS_PANEL_R + _DS_PANEL_H - 2 ))
    move "$hint_r" $(( _DS_PANEL_C + 1 ))
    printf "%b  ↑↓ navigate   Enter select   r rescan   q quit%b" "$DK" "$RST"
    printf '%*s' $(( _DS_LIST_W - 46 )) ''
}

screen_device_select() {
    scan_devices

    draw_chrome
    get_term_size

    _DS_PANEL_H=$(( TH - 6 ))
    local panel_w=$(( TW - 4 ))
    _DS_PANEL_R=3
    _DS_PANEL_C=3

    draw_box "$_DS_PANEL_R" "$_DS_PANEL_C" "$_DS_PANEL_H" "$panel_w" "$C" "Select Target Device"

    _DS_LIST_W=$(( panel_w * 40 / 100 ))
    _DS_DETAIL_C=$(( _DS_PANEL_C + _DS_LIST_W + 1 ))
    _DS_DETAIL_W=$(( panel_w - _DS_LIST_W - 3 ))
    _DS_INNER_H=$(( _DS_PANEL_H - 2 ))
    _DS_INNER_R=$(( _DS_PANEL_R + 1 ))

    local i
    for (( i=0; i<_DS_INNER_H; i++ )); do
        move $(( _DS_INNER_R + i )) $(( _DS_PANEL_C + _DS_LIST_W ))
        printf "%b│%b" "$DK" "$RST"
    done

    local hdr_r=$_DS_INNER_R
    move "$hdr_r" $(( _DS_PANEL_C + 1 ))
    printf "%b%b %-6s %-10s %-18s %-6s%b" "$BO" "$LC" "DEV" "SIZE" "MODEL" "TRAN" "$RST"
    (( hdr_r++ ))
    move "$hdr_r" $(( _DS_PANEL_C + 1 ))
    printf "%b" "$DK"; repeat_char '─' $(( _DS_LIST_W - 1 )); printf "%b" "$RST"
    (( hdr_r++ ))

    _DS_LIST_START=$hdr_r
    _DS_INNER_R=$hdr_r   
    if [[ ${#USB_DEVICES[@]} -eq 0 ]]; then
        move "$hdr_r" $(( _DS_PANEL_C + 2 ))
        printf "%b%b No USB drives found. %b" "$Y" "$BO" "$RST"
        move $(( hdr_r + 1 )) $(( _DS_PANEL_C + 2 ))
        printf "%b Connect a drive and press %br%b to rescan.%b" "$DK" "$LC" "$DK" "$RST"
    fi

    _DS_SELECTED=0
    _ds_draw_device_list
    _ds_draw_device_detail
    _ds_draw_list_hint

    while true; do
        local key seq
        IFS= read -rsn1 key

        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 seq || seq=""
                case "$seq" in
                    '[A')
                        (( _DS_SELECTED > 0 )) && (( _DS_SELECTED-- ))
                        _ds_draw_device_list; _ds_draw_device_detail ;;
                    '[B')
                        (( _DS_SELECTED < ${#USB_DEVICES[@]} - 1 )) && (( _DS_SELECTED++ ))
                        _ds_draw_device_list; _ds_draw_device_detail ;;
                esac ;;
            '')
                if [[ ${#USB_DEVICES[@]} -gt 0 ]]; then
                    IFS=: read -r SEL_DEVICE _ <<< "${USB_DEVICES[$_DS_SELECTED]}"
                    return 0
                fi ;;
            r|R)
                scan_devices
                _DS_SELECTED=0
                _ds_draw_device_list; _ds_draw_device_detail ;;
            q|Q|$'\x03')
                tui_quit ;;
        esac
    done
}

 Option arrays — set once in screen_configure, read by helpers
declare -a CFG_WIPE_OPTS=()
declare -a CFG_PTABLE_OPTS=()
declare -a CFG_FS_OPTS=()
declare -a CFG_SECTION_ROWS=(0 0 0 0)
declare -a CFG_SECTION_HEIGHTS=(0 0 0 0)
declare -a CFG_SECTION_ITEM_COUNTS=(0 0 0 0)

_cfg_draw_section() {
    local sec=$1
    local active=$(( sec == CFG_CUR_SECTION ? 1 : 0 ))
    local row=${CFG_SECTION_ROWS[$sec]}
    local bcolor; [[ $active -eq 1 ]] && bcolor="$C" || bcolor="$DK"
    local titles=("Wipe Method" "Partition Table" "Filesystem" "Options")
    local title="${titles[$sec]}"
    local bh=${CFG_SECTION_HEIGHTS[$sec]}
    local lw=$CFG_LEFT_W
    local pc=$CFG_PANEL_C

    draw_box "$row" "$pc" "$bh" "$lw" "$bcolor" "$title"

    local ir=$(( row + 1 ))
    local idx val label note time dot

    case $sec in
    0)
        for (( idx=0; idx<${#CFG_WIPE_OPTS[@]}; idx++ )); do
            IFS=: read -r val label time <<< "${CFG_WIPE_OPTS[$idx]}"
            move "$ir" $(( pc + 2 ))
            local dot; [[ $val -eq $SEL_WIPE ]] && dot="${LC}●${RST}" || dot="${DK}○${RST}"
            if [[ $active -eq 1 && $idx -eq $CFG_CUR_ITEM ]]; then
                printf "\033[7m\033[1m %-36s %-9s\033[m\033[K" \
                    "$(printf '%s %s' "• $label")" "$time"
            else
                printf " %b %-30s%b%s%b\033[K" "$dot" "$label" "$DK" "$time" "$RST"
            fi
            (( ir++ ))
        done ;;
    1)
        for (( idx=0; idx<${#CFG_PTABLE_OPTS[@]}; idx++ )); do
            IFS=: read -r val label note <<< "${CFG_PTABLE_OPTS[$idx]}"
            move "$ir" $(( pc + 2 ))
            local dot; [[ $val -eq $SEL_PTABLE ]] && dot="${LC}●${RST}" || dot="${DK}○${RST}"
            if [[ $active -eq 1 && $idx -eq $CFG_CUR_ITEM ]]; then
                printf "\033[7m\033[1m %-36s %-9s\033[m\033[K" \
                    "$(printf '%s %s' "• $label")" "$note"
            else
                printf " %b %-28s%b%s%b\033[K" "$dot" "$label" "$DK" "$note" "$RST"
            fi
            (( ir++ ))
        done ;;
    2)
        for (( idx=0; idx<${#CFG_FS_OPTS[@]}; idx++ )); do
            IFS=: read -r val label note <<< "${CFG_FS_OPTS[$idx]}"
            move "$ir" $(( pc + 2 ))
            local dot; [[ $val -eq $SEL_FS ]] && dot="${LC}●${RST}" || dot="${DK}○${RST}"
            if [[ $active -eq 1 && $idx -eq $CFG_CUR_ITEM ]]; then
                printf "\033[7m\033[1m %-36s %-14s\033[m\033[K" \
                    "$(printf '%s %s' "• $label")" "$note"
            else
                printf " %b %-28s%b%s%b\033[K" "$dot" "$label" "$DK" "$note" "$RST"
            fi
            (( ir++ ))
        done ;;
    3)
        move "$ir" $(( pc + 2 ))
        if [[ $active -eq 1 && $CFG_CUR_ITEM -eq 0 ]]; then
            printf "\033[7m\033[1m %-50s\033[m\033[K" "  Label: $SEL_LABEL   (press l to edit)"
        else
            printf " %bLabel:%b  %b%s%b   %b(press l to edit)%b\033[K" \
                "$DK" "$RST" "$LW" "$SEL_LABEL" "$RST" "$DK" "$RST"
        fi
        (( ir++ ))
        move "$ir" $(( pc + 2 ))
        local enc_mark; [[ $SEL_ENCRYPT -eq 1 ]] && enc_mark="[✓]" || enc_mark="[ ]"
        if [[ $active -eq 1 && $CFG_CUR_ITEM -eq 1 ]]; then
            printf "\033[7m\033[1m %-50s\033[m\033[K" " $enc_mark Encrypt with LUKS2   (Tab to toggle)"
        else
            local em_col; [[ $SEL_ENCRYPT -eq 1 ]] && em_col="$LG" || em_col="$DK"
            printf " %b%s%b %bEncrypt with LUKS2%b   %b(Tab to toggle)%b\033[K" \
                "$em_col" "$enc_mark" "$RST" "$DK" "$RST" "$DK" "$RST"
        fi
        (( ir++ ))
        move "$ir" $(( pc + 2 ))
        local mnt_mark; [[ $SEL_MOUNT -eq 1 ]] && mnt_mark="[✓]" || mnt_mark="[ ]"
        if [[ $active -eq 1 && $CFG_CUR_ITEM -eq 2 ]]; then
            printf "\033[7m\033[1m %-50s\033[m\033[K" " $mnt_mark Mount after completion  (Tab to toggle)"
        else
            local mm_col; [[ $SEL_MOUNT -eq 1 ]] && mm_col="$LG" || mm_col="$DK"
            printf " %b%s%b %bMount after completion%b  %b(Tab to toggle)%b\033[K" \
                "$mm_col" "$mnt_mark" "$RST" "$DK" "$RST" "$DK" "$RST"
        fi
        (( ir++ ))
        if [[ $SEL_MOUNT -eq 1 ]]; then
            move "$ir" $(( pc + 2 ))
            printf "   %bMount name:%b  %b/mnt/%s%b  %b(press m to edit)%b\033[K" \
                "$DK" "$RST" "$LW" "$SEL_MOUNTNAME" "$RST" "$DK" "$RST"
        else
            move "$ir" $(( pc + 2 )); printf "\033[K"
        fi ;;
    esac
}

_cfg_draw_right_panel() {
    local row=$CFG_PANEL_R
    local rc=$CFG_RIGHT_C
    local rw=$(( CFG_RIGHT_W - 1 ))
    local i

    
    for (( i=3; i<=TH-2; i++ )); do
        move "$i" "$rc"
        printf '%*s' "$rw" ''
    done
    row=3

    move "$row" "$rc"; (( row++ ))
    printf "%b%b  Configuration Summary%b" "$C" "$BO" "$RST"
    move "$row" "$rc"; (( row++ ))
    printf "%b  ─────────────────────────────────%b" "$DK" "$RST"

    local wipe_names=("None (quick format)" "Zero fill" "Random" "Shred 3-pass" "DoD 7-pass")
    local pt_names=("" "GPT" "MBR")
    local fs_names=("" "ext4" "exFAT" "FAT32" "NTFS")

    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  %b%s%b" "$DK" "Device"     "$RST" "$LW" "$SEL_DEVICE  ($CFG_DEV_SIZE)"  "$RST"
    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  %b%s%b" "$DK" "Wipe"       "$RST" "$LW" "${wipe_names[$SEL_WIPE]}"       "$RST"
    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  %b%s%b" "$DK" "Partition"  "$RST" "$LW" "${pt_names[$SEL_PTABLE]}"       "$RST"
    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  %b%s%b" "$DK" "Filesystem" "$RST" "$LW" "${fs_names[$SEL_FS]}  (label: $SEL_LABEL)" "$RST"

    local enc_s mnt_s
    [[ $SEL_ENCRYPT -eq 1 ]] && enc_s="${LG}Yes — LUKS2${RST}" || enc_s="${DK}No${RST}"
    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  " "$DK" "Encrypt" "$RST"; printf "%b" "$enc_s"

    [[ $SEL_MOUNT -eq 1 ]] && mnt_s="${LG}/mnt/$SEL_MOUNTNAME${RST}" || mnt_s="${DK}No${RST}"
    move "$row" "$rc"; (( row++ ))
    printf "  %b%-14s%b  " "$DK" "Mount" "$RST"; printf "%b" "$mnt_s"

    (( row++ ))
    move "$row" "$rc"; (( row++ ))
    printf "%b  ─────────────────────────────────%b" "$DK" "$RST"

    local est_spd=$(( 100 * 1048576 ))
    local wipe_mult=(0 1 1 3 7)
    local mult=${wipe_mult[$SEL_WIPE]}
    move "$row" "$rc"; (( row++ ))
    if (( mult == 0 )); then
        printf "  %bEstimated time:%b  %b< 1 minute%b" "$LG" "$RST" "$LW" "$RST"
    else
        local est_t; est_t=$(fmt_dur $(( CFG_DEV_BYTES * mult / est_spd + 1 )))
        printf "  %bEstimated time:%b  %b~%s%b  %b(wipe)%b" "$Y" "$RST" "$LW" "$est_t" "$RST" "$DK" "$RST"
    fi

    (( row += 2 ))
    draw_box "$row" "$rc" 5 $(( CFG_RIGHT_W - 1 )) "$Y"
    move $(( row + 1 )) $(( rc + 2 ))
    printf "%b%b ⚠  ALL DATA WILL BE LOST%b" "$Y" "$BO" "$RST"
    move $(( row + 2 )) $(( rc + 2 ))
    printf "%b  Review your choices carefully.%b" "$DK" "$RST"
    move $(( row + 3 )) $(( rc + 2 ))
    printf "%b  This cannot be undone.%b" "$DK" "$RST"

    local hint_r=$(( TH - 2 ))
    move "$hint_r" "$rc"
    printf "%b  F10 / Enter on last section:%b" "$DK" "$RST"
    move $(( hint_r + 1 )) "$rc"
    printf "%b  Proceed to confirmation →%b" "$LC" "$RST"
}

_cfg_redraw_all() {
    local s
    for (( s=0; s<4; s++ )); do _cfg_draw_section "$s"; done
    _cfg_draw_right_panel
}


screen_configure() {
    draw_chrome
    get_term_size

    CFG_PANEL_W=$(( TW - 4 ))
    CFG_PANEL_R=4
    CFG_PANEL_C=3
    CFG_LEFT_W=$(( CFG_PANEL_W * 55 / 100 ))
    CFG_RIGHT_C=$(( CFG_PANEL_C + CFG_LEFT_W + 2 ))
    CFG_RIGHT_W=$(( CFG_PANEL_W - CFG_LEFT_W - 3 ))

    CFG_DEV_BYTES=$(get_device_bytes "$SEL_DEVICE")
    CFG_DEV_SIZE=$(lsblk -nd -o SIZE "$SEL_DEVICE" 2>/dev/null | tr -d ' \n' || echo "?")
    CFG_DEV_MODEL=$(lsblk -nd -o MODEL "$SEL_DEVICE" 2>/dev/null | tr -d ' \n' || echo "Unknown")
    [[ -z "$CFG_DEV_SIZE" ]] && CFG_DEV_SIZE="?"

    local est_spd=$(( 100 * 1048576 ))

    
    move "$CFG_PANEL_R" "$CFG_PANEL_C"
    printf "%b%b%b" "$BG_DK" "$LC" "$BO"
    printf ' %-*s ' $(( CFG_PANEL_W - 2 )) \
        "  Device: $SEL_DEVICE   $CFG_DEV_SIZE   $CFG_DEV_MODEL"
    printf "%b" "$RST"
    (( CFG_PANEL_R++ ))

    
    CFG_WIPE_OPTS=(
        "0:Quick format (no wipe):instant"
        "1:Zero fill (single pass):~$(fmt_dur $(( CFG_DEV_BYTES / est_spd + 1 )))"
        "2:Random data (single pass):~$(fmt_dur $(( CFG_DEV_BYTES / est_spd + 1 )))"
        "3:Shred 3-pass:~$(fmt_dur $(( CFG_DEV_BYTES * 3 / est_spd + 1 )))"
        "4:DoD 7-pass:~$(fmt_dur $(( CFG_DEV_BYTES * 7 / est_spd + 1 )))"
    )
    CFG_PTABLE_OPTS=(
        "1:GPT — modern, recommended:>2TB, UEFI"
        "2:MBR — legacy compatible:BIOS, <2TB"
    )
    CFG_FS_OPTS=(
        "1:ext4 — Linux native, journaled:Linux only"
        "2:exFAT — cross-platform, large files:Win/Mac/Linux, >4GB files"
        "3:FAT32 — universal, max 4GB/file:All systems"
        "4:NTFS — Windows native:Win primary, Linux read/write"
    )

    CFG_SECTION_ITEM_COUNTS=(${#CFG_WIPE_OPTS[@]} ${#CFG_PTABLE_OPTS[@]} ${#CFG_FS_OPTS[@]} 3)
    CFG_SECTION_HEIGHTS=(
        $(( ${#CFG_WIPE_OPTS[@]}   + 3 ))
        $(( ${#CFG_PTABLE_OPTS[@]} + 3 ))
        $(( ${#CFG_FS_OPTS[@]}     + 3 ))
        6
    )

    CFG_SECTION_ROWS[0]=$(( CFG_PANEL_R + 1 ))
    CFG_SECTION_ROWS[1]=$(( CFG_SECTION_ROWS[0] + CFG_SECTION_HEIGHTS[0] + 1 ))
    CFG_SECTION_ROWS[2]=$(( CFG_SECTION_ROWS[1] + CFG_SECTION_HEIGHTS[1] + 1 ))
    CFG_SECTION_ROWS[3]=$(( CFG_SECTION_ROWS[2] + CFG_SECTION_HEIGHTS[2] + 1 ))

    CFG_CUR_SECTION=0
    CFG_CUR_ITEM=0

    _cfg_redraw_all

    while true; do
        local key seq
        IFS= read -rsn1 key

        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 seq || seq=""
                case "$seq" in
                    '[A')   # Up
                        if (( CFG_CUR_ITEM > 0 )); then
                            (( CFG_CUR_ITEM-- ))
                        else
                            if (( CFG_CUR_SECTION > 0 )); then
                                (( CFG_CUR_SECTION-- ))
                                CFG_CUR_ITEM=$(( CFG_SECTION_ITEM_COUNTS[CFG_CUR_SECTION] - 1 ))
                            fi
                        fi
                        _cfg_redraw_all ;;
                    '[B')   # Down
                        if (( CFG_CUR_ITEM < CFG_SECTION_ITEM_COUNTS[CFG_CUR_SECTION] - 1 )); then
                            (( CFG_CUR_ITEM++ ))
                        else
                            if (( CFG_CUR_SECTION < 3 )); then
                                (( CFG_CUR_SECTION++ ))
                                CFG_CUR_ITEM=0
                            fi
                        fi
                        _cfg_redraw_all ;;
                    '[Z')   
                        (( CFG_CUR_SECTION > 0 )) && (( CFG_CUR_SECTION-- ))
                        CFG_CUR_ITEM=0
                        _cfg_redraw_all ;;
                esac ;;
            '')     
                case $CFG_CUR_SECTION in
                    0) IFS=: read -r SEL_WIPE   _ <<< "${CFG_WIPE_OPTS[$CFG_CUR_ITEM]}" ;;
                    1) IFS=: read -r SEL_PTABLE _ <<< "${CFG_PTABLE_OPTS[$CFG_CUR_ITEM]}" ;;
                    2) IFS=: read -r SEL_FS     _ <<< "${CFG_FS_OPTS[$CFG_CUR_ITEM]}" ;;
                    3) return 0 ;;
                esac
                if (( CFG_CUR_SECTION < 3 )); then
                    (( CFG_CUR_SECTION++ ))
                    CFG_CUR_ITEM=0
                fi
                _cfg_redraw_all ;;
            $'\t')  
                if (( CFG_CUR_SECTION == 3 )); then
                    case $CFG_CUR_ITEM in
                        1) SEL_ENCRYPT=$(( 1 - SEL_ENCRYPT )) ;;
                        2) SEL_MOUNT=$(( 1 - SEL_MOUNT )) ;;
                    esac
                else
                    (( CFG_CUR_SECTION < 3 )) && (( CFG_CUR_SECTION++ ))
                    CFG_CUR_ITEM=0
                fi
                _cfg_redraw_all ;;
            l|L)
                if (( CFG_CUR_SECTION == 3 )); then
                    local opt_row=$(( CFG_SECTION_ROWS[3] + 1 ))
                    move "$opt_row" $(( CFG_PANEL_C + 11 ))
                    printf "%b%b                    %b" "$BG_DK" "$LW" "$RST"
                    move "$opt_row" $(( CFG_PANEL_C + 11 ))
                    printf "%b%b%b" "$SHOW" "$BG_DK" "$LW"
                    local newlabel
                    IFS= read -r newlabel
                    printf "%b%b" "$HIDE" "$RST"
                    [[ -n "$newlabel" ]] && SEL_LABEL="${newlabel:0:15}"
                    _cfg_redraw_all
                fi ;;
            m|M)
                if (( CFG_CUR_SECTION == 3 && SEL_MOUNT == 1 )); then
                    local opt_row=$(( CFG_SECTION_ROWS[3] + 3 ))
                    move "$opt_row" $(( CFG_PANEL_C + 20 ))
                    printf "%b%b              %b" "$BG_DK" "$LW" "$RST"
                    move "$opt_row" $(( CFG_PANEL_C + 20 ))
                    printf "%b%b%b" "$SHOW" "$BG_DK" "$LW"
                    local newmnt
                    IFS= read -r newmnt
                    printf "%b%b" "$HIDE" "$RST"
                    [[ -n "$newmnt" ]] && SEL_MOUNTNAME="${newmnt//[^a-zA-Z0-9_-]/}"
                    _cfg_redraw_all
                fi ;;
            q|Q|$'\x1b')
                screen_device_select; return ;;
        esac
    done
}


screen_confirm() {
    draw_chrome
    get_term_size

    local cw=$(( TW - 10 ))
    local cr=$(( (TH - 24) / 2 ))
    (( cr < 3 )) && cr=3
    local cc=5

    draw_box "$cr" "$cc" 22 "$cw" "$R" "⚠  POINT OF NO RETURN"

    local r=$(( cr + 2 ))
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b%b  ALL DATA ON THE FOLLOWING DEVICE WILL BE PERMANENTLY ERASED:%b" "$LR" "$BO" "$RST"
    (( r++ ))

    local dev_bytes; dev_bytes=$(get_device_bytes "$SEL_DEVICE")
    local dev_size; dev_size=$(lsblk -nd -o SIZE "$SEL_DEVICE" 2>/dev/null | tr -d ' \n' || echo "?")
    local dev_model; dev_model=$(lsblk -nd -o MODEL "$SEL_DEVICE" 2>/dev/null | tr -d ' \n' || echo "")

    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b%b%b  %-*s  %b" "$BG_RED" "$LW" "$BO" $(( cw - 12 )) \
        "  $SEL_DEVICE   $dev_size   $dev_model" "$RST"

    (( r++ ))
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b  Operation plan:%b" "$Y" "$RST"

    local wipe_names=("None (quick format)" "Zero fill — single pass" "Random data — single pass" "Shred — 3 passes" "DoD 5220.22-M — 7 passes")
    local ptable_names=("" "GPT" "MBR")
    local fs_names=("" "ext4" "exFAT" "FAT32" "NTFS")

    move "$r" $(( cc + 4 )); (( r++ ))
    printf "  %bWipe      :%b  %b%s%b" "$DK" "$RST" "$LW" "${wipe_names[$SEL_WIPE]}" "$RST"
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "  %bPartition :%b  %b%s%b" "$DK" "$RST" "$LW" "${ptable_names[$SEL_PTABLE]}" "$RST"
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "  %bFilesystem:%b  %b%s  (label: %s)%b" "$DK" "$RST" "$LW" "${fs_names[$SEL_FS]}" "$SEL_LABEL" "$RST"

    if [[ $SEL_ENCRYPT -eq 1 ]]; then
        move "$r" $(( cc + 4 )); (( r++ ))
        printf "  %bEncryption:%b  %bLUKS2 (AES-XTS-512 + argon2id)%b" "$DK" "$RST" "$LG" "$RST"
    fi

    (( r++ ))
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b  ────────────────────────────────────────────────────────────%b" "$DK" "$RST"

    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b%b  Step 1 of 2:%b  Type the exact device path to confirm:" "$Y" "$BO" "$RST"
    move "$r" $(( cc + 4 ))
    printf "%b  ›%b  " "$DK" "$RST"
    printf "%b" "$SHOW"
    local dev_confirm
    IFS= read -r dev_confirm
    printf "%b" "$HIDE"

    if [[ "$dev_confirm" != "$SEL_DEVICE" ]]; then
        (( r++ ))
        move "$r" $(( cc + 4 )); (( r++ ))
        printf "%b  ✗  Mismatch. Got '%s', expected '%s'. Aborted.%b" \
            "$R" "$dev_confirm" "$SEL_DEVICE" "$RST"
        move $(( r+1 )) $(( cc + 4 ))
        printf "%b  Press any key to go back...%b" "$DK" "$RST"
        read -rsn1
        screen_configure; return
    fi

    (( r++ ))
    move "$r" $(( cc + 4 )); (( r++ ))
    printf "%b%b  Step 2 of 2:%b  Type %b%b NUKE IT %b to begin (case-sensitive):" \
        "$LR" "$BO" "$RST" "$BG_RED" "$LW" "$RST"
    move "$r" $(( cc + 4 ))
    printf "%b  ›%b  " "$DK" "$RST"
    printf "%b" "$SHOW"
    local nuke_confirm
    IFS= read -r nuke_confirm
    printf "%b" "$HIDE"

    if [[ "$nuke_confirm" != "NUKE IT" ]]; then
        (( r++ ))
        move "$r" $(( cc + 4 ))
        printf "%b  ✗  Confirmation failed. Aborted.%b" "$R" "$RST"
        move $(( r+2 )) $(( cc + 4 ))
        printf "%b  Press any key to go back...%b" "$DK" "$RST"
        read -rsn1
        screen_configure; return
    fi

    CONFIRMED=1
}


_SPIN_PID=""

spin_start() {
    local row=$1 col=$2 label="${3:-}"
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            move "$row" "$col"
            printf "%b%s%b %s   " "$C" "${frames[$((i % 10))]}" "$RST" "$label"
            sleep 0.1
            (( i++ ))
        done
    ) &
    _SPIN_PID=$!
}

spin_stop() {
    local row=$1 col=$2 label="${3:-}" ok="${4:-1}"
    if [[ -n "$_SPIN_PID" ]]; then
        kill -9 "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=""
    fi
    move "$row" "$col"
    if [[ $ok -eq 1 ]]; then
        printf "%b✓%b %-50s %bdone%b" "$LG" "$RST" "$label" "$DK" "$RST"
    else
        printf "%b✗%b %-50s %bFAILED%b" "$R" "$RST" "$label" "$R" "$RST"
    fi
}


_draw_progress() {
    local row=$1 col=$2 pct=$3 written=$4 total=$5 speed="${6:-}" eta="${7:-}"
    local bw=$(( TW - col - 30 ))
    (( bw < 10 )) && bw=10
    local filled=$(( bw * pct / 100 ))
    local empty=$(( bw - filled ))

    move "$row" "$col"
    printf "%b" "$C";  repeat_char '█' "$filled"
    printf "%b" "$DK"; repeat_char '░' "$empty"
    printf "%b %b%3d%%%b" "$RST" "$BO" "$pct" "$RST"

    move $(( row + 1 )) "$col"
    printf "%b%s / %s%b   %b%s%b   %bETA %s%b%*s" \
        "$DK" "$(fmt_bytes "$written")" "$(fmt_bytes "$total")" "$RST" \
        "$W"  "$speed" "$RST" \
        "$DK" "$eta"   "$RST" 10 ''
}


run_dd_pass() {
    local source=$1 dest=$2 label=$3 total_bytes=$4
    local prog_row=$5 prog_col=$6
    local progress_file; progress_file=$(mktemp /tmp/.nuke_dd.XXXXXX)
    local start=$SECONDS

    sudo dd if="$source" of="$dest" bs=4M 2>"$progress_file" &
    local dd_pid=$!

    move "$prog_row" "$prog_col"
    printf "%b%s%b" "$DK" "$label" "$RST"

    while kill -0 "$dd_pid" 2>/dev/null; do
        sudo kill -USR1 "$dd_pid" 2>/dev/null || true
        sleep 1
        local line=""
        line=$(grep -E "^[0-9]+ bytes" "$progress_file" 2>/dev/null | tail -1 || true)
        if [[ "$line" =~ ^([0-9]+)[[:space:]]bytes ]]; then
            local written="${BASH_REMATCH[1]}" pct=0 speed="" eta="—"
            (( total_bytes > 0 )) && pct=$(( written * 100 / total_bytes ))
            (( pct > 100 )) && pct=100
            [[ "$line" =~ ([0-9.]+[[:space:]][KMGT]?B/s) ]] && speed="${BASH_REMATCH[1]}"
            local elapsed=$(( SECONDS - start ))
            if (( elapsed > 0 && written > 0 && total_bytes > written )); then
                local rate=$(( written / elapsed ))
                (( rate > 0 )) && eta=$(fmt_dur $(( (total_bytes - written) / rate )))
            fi
            _draw_progress "$prog_row" "$prog_col" "$pct" "$written" "$total_bytes" "$speed" "$eta"
        fi
    done

    wait "$dd_pid" 2>/dev/null; local rc=$?
    rm -f "$progress_file"

    local elapsed=$(( SECONDS - start )); (( elapsed < 1 )) && elapsed=1
    local avg=$(( total_bytes / elapsed / 1048576 ))
    _draw_progress "$prog_row" "$prog_col" 100 "$total_bytes" "$total_bytes" "${avg} MB/s" "done"
    move $(( prog_row + 2 )) "$prog_col"

    [[ $rc -eq 0 || $rc -eq 1 ]] && return 0 || return "$rc"
}


run_shred_pass() {
    local device=$1 passes=$2 prog_row=$3 prog_col=$4
    local total=$(( passes + 1 ))
    local progress_file; progress_file=$(mktemp /tmp/.nuke_shred.XXXXXX)

    sudo shred -v -n "$passes" -z "$device" 2>"$progress_file" &
    local shred_pid=$!

    while kill -0 "$shred_pid" 2>/dev/null; do
        sleep 1
        local line=""
        line=$(grep -E "pass [0-9]+/[0-9]+" "$progress_file" 2>/dev/null | tail -1 || true)
        if [[ "$line" =~ pass[[:space:]]([0-9]+)/([0-9]+) ]]; then
            local cur="${BASH_REMATCH[1]}" tot="${BASH_REMATCH[2]}" ptype="" in_pct=0
            local _ptype_re='\(([^)]+)\)'
            [[ "$line" =~ $_ptype_re ]] && ptype="${BASH_REMATCH[1]}"
            [[ "$line" =~ \.\.\.([0-9]+)% ]] && in_pct="${BASH_REMATCH[1]}"
            local pct=$(( ( (cur-1)*100 + in_pct ) / tot ))
            (( pct > 100 )) && pct=100

            local bw=$(( TW - prog_col - 30 ))
            (( bw < 10 )) && bw=10
            local filled=$(( bw * pct / 100 ))
            local empty=$(( bw - filled ))

            move "$prog_row" "$prog_col"
            printf "%b" "$M";  repeat_char '█' "$filled"
            printf "%b" "$DK"; repeat_char '░' "$empty"
            printf "%b %b%3d%%%b  %bpass %d/%d (%s)%b" \
                "$RST" "$BO" "$pct" "$RST" "$DK" "$cur" "$tot" "$ptype" "$RST"
        fi
    done

    wait "$shred_pid" 2>/dev/null; local rc=$?
    rm -f "$progress_file"
    move "$prog_row" "$prog_col"
    printf "%b✓ Shred complete (%d passes)%b%*s" "$LG" "$total" "$RST" 20 ''
    return $rc
}


declare -a EXEC_STEPS=()

_exec_draw_steps() {
    local active_step=$1
    local step_row=5
    local si
    for (( si=0; si<${#EXEC_STEPS[@]}; si++ )); do
        move $(( step_row + si )) 3
        if (( si < active_step )); then
            printf "  %b✓%b  %b%s%b%*s" "$LG" "$RST" "$DK" "${EXEC_STEPS[$si]}" "$RST" 4 ''
        elif (( si == active_step )); then
            printf "  %b▶%b  %b%b%s%b%*s" "$LC" "$RST" "$LW" "$BO" "${EXEC_STEPS[$si]}" "$RST" 4 ''
        else
            printf "  %b○  %s%b%*s" "$DK" "${EXEC_STEPS[$si]}" "$RST" 4 ''
        fi
    done
}

_exec_log() {
    move "$EXEC_LOG_ROW" 3
    printf "%b[%s]%b %s%*s" "$DK" "$(date +'%H:%M:%S')" "$RST" "$1" \
        $(( TW - ${#1} - 15 )) ''
    (( EXEC_LOG_ROW++ ))
    (( EXEC_LOG_ROW > TH - 3 )) && EXEC_LOG_ROW=$(( EXEC_LOG_ROW - 5 ))
}

_exec_ok() {
    move "$EXEC_LOG_ROW" 3
    printf "%b✓%b %s%*s" "$LG" "$RST" "$1" $(( TW - ${#1} - 6 )) ''
    (( EXEC_LOG_ROW++ ))
}

_exec_err() {
    move "$EXEC_LOG_ROW" 3
    printf "%b%b✗ ERROR: %s%b" "$LR" "$BO" "$1" "$RST"
    (( EXEC_LOG_ROW++ ))
    move $(( EXEC_LOG_ROW + 1 )) 3
    printf "%bPress any key to exit...%b" "$DK" "$RST"
    printf "%b" "$SHOW"
    read -rsn1
    tui_quit 1
}

_exec_warn() {
    move "$EXEC_LOG_ROW" 3
    printf "%b⚠  %s%b%*s" "$Y" "$1" "$RST" $(( TW - ${#1} - 6 )) ''
    (( EXEC_LOG_ROW++ ))
}


screen_execute() {
    [[ $CONFIRMED -ne 1 ]] && return

    draw_chrome
    get_term_size

    local dev_bytes; dev_bytes=$(get_device_bytes "$SEL_DEVICE")

    move 3 3
    printf "%b%b  Executing operations on:%b  %b%b%s%b  %b%s%b" \
        "$C" "$BO" "$RST" "$LW" "$BO" "$SEL_DEVICE" "$RST" \
        "$DK" "$(lsblk -nd -o SIZE,MODEL "$SEL_DEVICE" 2>/dev/null | tr -s ' ')" "$RST"
    hline 4 1 "$TW" '─' "$DK"

    EXEC_STEPS=()
    [[ $SEL_WIPE    -ne 0 ]] && EXEC_STEPS+=("Wipe device")
    EXEC_STEPS+=("Create partition table")
    [[ $SEL_ENCRYPT -eq 1 ]] && EXEC_STEPS+=("Setup LUKS2 encryption")
    EXEC_STEPS+=("Format filesystem")
    [[ $SEL_MOUNT   -eq 1 ]] && EXEC_STEPS+=("Mount device")

    local total_steps=${#EXEC_STEPS[@]}
    local work_row=$(( 5 + total_steps + 2 ))
    hline $(( 5 + total_steps + 1 )) 1 "$TW" '─' "$DK"

    EXEC_LOG_ROW=$(( work_row + 1 ))

    local active_step=0
    local PART="" MAPPED_DEV="" MOUNT_NAME="$SEL_MOUNTNAME"
    local rc=0

    _exec_draw_steps 0

   
    local mounted_parts part
    mounted_parts=$(mount | grep "^$SEL_DEVICE" | awk '{print $1}' || true)
    if [[ -n "$mounted_parts" ]]; then
        _exec_log "Unmounting existing partitions..."
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            if sudo umount "$part" 2>/dev/null; then
                _exec_ok "Unmounted $part"
            else
                sudo umount -l "$part" 2>/dev/null \
                    && _exec_warn "Lazy-unmounted $part" \
                    || _exec_warn "Could not unmount $part"
            fi
        done <<< "$mounted_parts"
        sync; sleep 1
    fi

 
    if [[ $SEL_WIPE -ne 0 ]]; then
        _exec_draw_steps $active_step
        local wipe_prog_row=$work_row
        local wipe_prog_col=5

        case $SEL_WIPE in
        1)  _exec_log "Starting zero-fill wipe..."
            run_dd_pass /dev/zero "$SEL_DEVICE" "Zero fill" "$dev_bytes" \
                "$wipe_prog_row" "$wipe_prog_col" || _exec_warn "dd ended at device boundary (normal)"
            sync; _exec_ok "Zero wipe complete" ;;
        2)  _exec_log "Starting random wipe..."
            run_dd_pass /dev/urandom "$SEL_DEVICE" "Random wipe" "$dev_bytes" \
                "$wipe_prog_row" "$wipe_prog_col" || _exec_warn "dd ended at device boundary (normal)"
            sync; _exec_ok "Random wipe complete" ;;
        3)  _exec_log "Starting shred (3-pass)..."
            run_shred_pass "$SEL_DEVICE" 3 "$wipe_prog_row" "$wipe_prog_col" \
                || _exec_err "shred failed — device may be disconnected"
            _exec_ok "Shred complete" ;;
        4)  _exec_log "Starting DoD 7-pass wipe..."
            local p
            _exec_log "Pass group 1/3: 2× zeros"
            for p in 1 2; do
                run_dd_pass /dev/zero "$SEL_DEVICE" "DoD zeros pass $p/7" "$dev_bytes" \
                    "$wipe_prog_row" "$wipe_prog_col" || true
                sync
            done
            _exec_log "Pass group 2/3: 3× random"
            for p in 3 4 5; do
                run_dd_pass /dev/urandom "$SEL_DEVICE" "DoD random pass $p/7" "$dev_bytes" \
                    "$wipe_prog_row" "$wipe_prog_col" || true
                sync
            done
            _exec_log "Pass group 3/3: 2× zeros"
            for p in 6 7; do
                run_dd_pass /dev/zero "$SEL_DEVICE" "DoD zeros pass $p/7" "$dev_bytes" \
                    "$wipe_prog_row" "$wipe_prog_col" || true
                sync
            done
            _exec_ok "DoD 7-pass wipe complete" ;;
        esac
        (( active_step++ ))
    fi

  
    _exec_draw_steps $active_step
    local pt_name; [[ $SEL_PTABLE -eq 1 ]] && pt_name="gpt" || pt_name="msdos"
    local pt_label; [[ $SEL_PTABLE -eq 1 ]] && pt_label="GPT" || pt_label="MBR"

    spin_start "$work_row" 5 "Creating $pt_label partition table"
    sudo parted "$SEL_DEVICE" --script mklabel "$pt_name" 2>/dev/null; rc=$?
    spin_stop "$work_row" 5 "Partition table: $pt_label" $(( rc==0 ? 1 : 0 ))
    [[ $rc -ne 0 ]] && _exec_err "Failed to create partition table on $SEL_DEVICE"

    EXEC_LOG_ROW=$(( work_row + 2 ))
    spin_start "$EXEC_LOG_ROW" 5 "Creating primary partition (100%)"
    sudo parted "$SEL_DEVICE" --script mkpart primary 1MiB 100% 2>/dev/null; rc=$?
    spin_stop "$EXEC_LOG_ROW" 5 "Primary partition created" $(( rc==0 ? 1 : 0 ))
    [[ $rc -ne 0 ]] && _exec_err "Failed to create partition on $SEL_DEVICE"

    (( EXEC_LOG_ROW++ ))
    spin_start "$EXEC_LOG_ROW" 5 "Refreshing kernel partition table"
    sync
    sudo partprobe "$SEL_DEVICE" 2>/dev/null || sudo blockdev --rereadpt "$SEL_DEVICE" 2>/dev/null || true
    sleep 3

    if [[ "$SEL_DEVICE" =~ (nvme|mmcblk|loop) ]]; then
        PART="${SEL_DEVICE}p1"
    else
        PART="${SEL_DEVICE}1"
    fi

    local waited=0
    while [[ ! -b "$PART" && $waited -lt 10 ]]; do sleep 1; (( waited++ )); done
    if [[ ! -b "$PART" ]]; then
        [[ "$SEL_DEVICE" =~ (nvme|mmcblk|loop) ]] && PART="${SEL_DEVICE}1" || PART="${SEL_DEVICE}p1"
        waited=0
        while [[ ! -b "$PART" && $waited -lt 5 ]]; do sleep 1; (( waited++ )); done
    fi

    local part_ok=0; [[ -b "$PART" ]] && part_ok=1
    spin_stop "$EXEC_LOG_ROW" 5 "Partition node: $PART" $part_ok
    [[ $part_ok -eq 0 ]] && _exec_err "Partition node $PART never appeared — try: sudo partprobe $SEL_DEVICE"
    (( EXEC_LOG_ROW++ ))
    (( active_step++ ))

   
    MAPPED_DEV="$PART"
    if [[ $SEL_ENCRYPT -eq 1 ]]; then
        _exec_draw_steps $active_step
        MAPPER_NAME="usb_nuke_$(date +%s)"
        [[ -b "/dev/mapper/$MAPPER_NAME" ]] && \
            sudo cryptsetup close "$MAPPER_NAME" 2>/dev/null || true

        move "$EXEC_LOG_ROW" 3; (( EXEC_LOG_ROW++ ))
        printf "%b  You will be prompted for a passphrase TWICE.%b" "$Y" "$RST"
        move "$EXEC_LOG_ROW" 3; (( EXEC_LOG_ROW++ ))
        printf "%b" "$SHOW"

        sudo cryptsetup luksFormat \
            --type luks2 --cipher aes-xts-plain64 \
            --key-size 512 --hash sha512 \
            --pbkdf argon2id --iter-time 4000 \
            --use-random "$PART" 2>/dev/null
        rc=$?
        printf "%b" "$HIDE"
        [[ $rc -ne 0 ]] && _exec_err "luksFormat failed — bad passphrase or device error"

        spin_start "$EXEC_LOG_ROW" 5 "Opening encrypted container"
        sudo cryptsetup open "$PART" "$MAPPER_NAME" 2>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "LUKS2 container: /dev/mapper/$MAPPER_NAME" $(( rc==0 ? 1 : 0 ))
        [[ $rc -ne 0 ]] && _exec_err "Could not open LUKS container"
        MAPPED_DEV="/dev/mapper/$MAPPER_NAME"
        (( EXEC_LOG_ROW++ ))
        (( active_step++ ))
    fi

  
    _exec_draw_steps $active_step
    local label="${SEL_LABEL:0:15}"

    spin_start "$EXEC_LOG_ROW" 5 "Formatting filesystem"
    case $SEL_FS in
    1)  sudo mkfs.ext4 -F -L "$label" \
            -O ^64bit,^metadata_csum \
            -E lazy_itable_init=0,lazy_journal_init=0 \
            "$MAPPED_DEV" &>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "ext4 formatted  (label: $label)" $(( rc==0 ? 1 : 0 )) ;;
    2)  sudo mkfs.exfat -n "$label" "$MAPPED_DEV" &>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "exFAT formatted  (label: $label)" $(( rc==0 ? 1 : 0 )) ;;
    3)  local fat_label="${label:0:11}"
        sudo mkfs.vfat -F 32 -n "$fat_label" "$MAPPED_DEV" &>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "FAT32 formatted  (label: $fat_label)" $(( rc==0 ? 1 : 0 )) ;;
    4)  sudo mkfs.ntfs -f -L "$label" "$MAPPED_DEV" &>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "NTFS formatted  (label: $label)" $(( rc==0 ? 1 : 0 )) ;;
    esac
    [[ $rc -ne 0 ]] && _exec_err "Filesystem formatting failed on $MAPPED_DEV"
    sync
    (( EXEC_LOG_ROW++ ))
    (( active_step++ ))

    if [[ $SEL_MOUNT -eq 1 ]]; then
        _exec_draw_steps $active_step
        local mount_dir="/mnt/$MOUNT_NAME"

        spin_start "$EXEC_LOG_ROW" 5 "Mounting $MAPPED_DEV → $mount_dir"
        sudo mkdir -p "$mount_dir" 2>/dev/null
        sudo mount "$MAPPED_DEV" "$mount_dir" 2>/dev/null; rc=$?
        spin_stop "$EXEC_LOG_ROW" 5 "Mounted: $mount_dir" $(( rc==0 ? 1 : 0 ))
        if [[ $rc -eq 0 ]]; then
            sudo chown -R "$USER:$(id -gn)" "$mount_dir" 2>/dev/null || true
            sudo chmod 755 "$mount_dir"
        else
            _exec_warn "Mount failed — mount manually: sudo mount $MAPPED_DEV $mount_dir"
        fi
        (( EXEC_LOG_ROW++ ))
        (( active_step++ ))
    fi

    _exec_draw_steps "$total_steps"
    hline $(( EXEC_LOG_ROW + 1 )) 1 "$TW" '─' "$DK"

    screen_done "$PART" "$MAPPED_DEV" "$MOUNT_NAME"
}


screen_done() {
    local part="$1" mapped="$2" mount_name="$3"
    get_term_size

    local total_elapsed=$(( $(date +%s) - SCRIPT_START ))
    local bw=$(( TW - 8 ))
    local br=$(( TH - 16 ))
    (( br < 3 )) && br=3

    draw_box "$br" 4 14 "$bw" "$G" "✓  Operation Complete"

    local r=$(( br + 2 ))
    move "$r" 8; (( r++ ))
    printf "%b%b  USB drive prepared successfully in %s%b" "$LG" "$BO" "$(fmt_dur "$total_elapsed")" "$RST"

    (( r++ ))
    local wipe_names=("None" "Zero fill" "Random" "Shred 3-pass" "DoD 7-pass")
    local fs_names=("" "ext4" "exFAT" "FAT32" "NTFS")
    local pt_names=("" "GPT" "MBR")

    move "$r" 8; (( r++ )); printf "  %bDevice    :%b  %b%s%b" "$DK" "$RST" "$LW" "$SEL_DEVICE" "$RST"
    move "$r" 8; (( r++ )); printf "  %bPartition :%b  %b%s%b" "$DK" "$RST" "$LW" "$part" "$RST"
    move "$r" 8; (( r++ ))
    printf "  %bWipe      :%b  %b%s%b    %bPartition table:%b  %b%s%b" \
        "$DK" "$RST" "$LW" "${wipe_names[$SEL_WIPE]}" "$RST" \
        "$DK" "$RST" "$LW" "${pt_names[$SEL_PTABLE]}" "$RST"
    move "$r" 8; (( r++ ))
    printf "  %bFilesystem:%b  %b%s%b    %bLabel:%b  %b%s%b" \
        "$DK" "$RST" "$LW" "${fs_names[$SEL_FS]}" "$RST" \
        "$DK" "$RST" "$LW" "$SEL_LABEL" "$RST"

    if [[ $SEL_ENCRYPT -eq 1 ]]; then
        move "$r" 8; (( r++ ))
        printf "  %bEncrypted :%b  %bLUKS2  (/dev/mapper/%s)%b" "$DK" "$RST" "$LG" "$MAPPER_NAME" "$RST"
    fi
    if [[ $SEL_MOUNT -eq 1 ]]; then
        move "$r" 8; (( r++ ))
        printf "  %bMounted   :%b  %b/mnt/%s%b" "$DK" "$RST" "$LG" "$mount_name" "$RST"
    fi

    if [[ $SEL_ENCRYPT -eq 1 && -n "$MAPPER_NAME" ]]; then
        (( r++ ))
        move "$r" 8; (( r++ ))
        printf "  %bEncryption cheatsheet:%b" "$C" "$RST"
        move "$r" 8; (( r++ ))
        printf "  %bOpen :%b  sudo cryptsetup open %s %s" "$DK" "$RST" "$part" "$MAPPER_NAME"
        move "$r" 8; (( r++ ))
        printf "  %bClose:%b  sudo umount /mnt/%s && sudo cryptsetup close %s" \
            "$DK" "$RST" "$mount_name" "$MAPPER_NAME"
    fi

    move $(( br + 13 )) 8
    printf "%b  Press %bq%b to quit, %br%b to run again%b" \
        "$DK" "$LC" "$DK" "$LC" "$DK" "$RST"

    printf "%b" "$SHOW"
    while true; do
        local key; IFS= read -rsn1 key
        case "$key" in
            q|Q|$'\x03') tui_quit 0 ;;
            r|R) main ;;
        esac
    done
}


tui_quit() {
    local code="${1:-0}"
    if [[ -n "${_SPIN_PID:-}" ]]; then
        kill -9 "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=""
    fi
    [[ $_IN_ALT -eq 1 ]] && printf "%b" "$ALT_OFF"
    printf "%b\n" "$SHOW"
    if [[ $code -ne 0 ]]; then
        printf "%bExited with error.%b\n" "$R" "$RST"
    fi
    exit "$code"
}

_on_exit() {
    local code=$?
    if [[ -n "${_SPIN_PID:-}" ]]; then
        kill -9 "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    if [[ -n "${MAPPER_NAME:-}" && -b "/dev/mapper/${MAPPER_NAME:-}" ]]; then
        sudo cryptsetup close "$MAPPER_NAME" 2>/dev/null || true
    fi
    [[ $_IN_ALT -eq 1 ]] && printf "%b" "$ALT_OFF"
    printf "%b" "$SHOW"
    exit $code
}


main() {
    get_term_size
    if (( TW < 90 || TH < 24 )); then
        printf "%bTerminal too small. Minimum: 90×24. Current: %dx%d%b\n" "$Y" "$TW" "$TH" "$RST"
        printf "Resize your terminal and re-run.\n"
        exit 1
    fi

    trap '_on_exit' EXIT
    trap 'tui_quit 130' INT TERM

    printf "%b%b" "$ALT_ON" "$HIDE"
    _IN_ALT=1

    screen_splash
    screen_device_select
    screen_configure
    screen_confirm
    screen_execute
}

main "$@"
