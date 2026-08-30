#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# AirSmith - "Walk This Wireless"
# Interactive Wi-Fi monitor mode helper for passive capture/analysis.
# No packet injection required or assumed.
#
# Author: Jermal Smith
# Repo:   https://github.com/jermsmit/airsmith
# License: GPLv3
#
# Usage: sudo bash airsmith.sh
#
# ---------------------------------------------------------------------------
# LEGAL / ETHICAL USE NOTICE
# This tool is intended for use only on networks and devices you own, or
# where you have explicit written authorization to test. Unauthorized
# interception or interference with wireless networks may be illegal in
# your jurisdiction. You are responsible for how you use this tool.
# ---------------------------------------------------------------------------

set -uo pipefail

VERSION="0.2.0"
REPO_RAW_URL="https://raw.githubusercontent.com/jermsmit/airsmith/main/airsmith.sh"
REPO_URL="https://github.com/jermsmit/airsmith"
STATE_FILE="/tmp/airsmith.state"
CAPTURE_DIR="${HOME}/airsmith-captures"

# ---------- color palette (teal / amber, distinct from airgeddon's cyan/orange) ----------

if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_TEAL="\033[38;5;37m"       # section headers
    C_TEAL_BOLD="\033[1;38;5;37m"
    C_AMBER="\033[38;5;214m"     # tagline / accents
    C_AMBER_BOLD="\033[1;38;5;214m"
    C_GREEN="\033[38;5;71m"      # OK / success
    C_RED="\033[1;38;5;196m"     # missing / error / warning
    C_GRAY="\033[38;5;245m"      # secondary text
    C_WHITE_BOLD="\033[1;37m"
else
    C_RESET=""; C_TEAL=""; C_TEAL_BOLD=""; C_AMBER=""; C_AMBER_BOLD=""
    C_GREEN=""; C_RED=""; C_GRAY=""; C_WHITE_BOLD=""
fi

# ---------- banner ----------

print_banner() {
    echo -e "${C_TEAL_BOLD}"
    cat <<'EOF'
     _    _      ____              _  _   _
    / \  (_)_ __/ ___| _ __ ___   (_)| |_| |__
   / _ \ | | '__\___ \| '_ ` _ \  | ||  _| '_ \
  / ___ \| | |   ___) | | | | | | || | | | | |
 /_/   \_\_|_|  |____/|_| |_| |_|_(_)_| |_| |_|
EOF
    echo -e "${C_RESET}"
    echo -e "${C_AMBER_BOLD}            \"Walk This Wireless\"${C_RESET}"
    echo -e "${C_GRAY}          AirSmith v${VERSION} — by Jermal Smith${C_RESET}"
    echo -e "${C_GRAY}          ${REPO_URL}${C_RESET}"
    echo
    echo -e "${C_RED}  For use only on networks/devices you own or are"
    echo -e "  authorized to test. You are responsible for your use.${C_RESET}"
    echo
}

# ---------- helpers ----------

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}This needs root. Re-run as: sudo bash $0${C_RESET}" >&2
        exit 1
    fi
}

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

load_state() {
    IFACE=""
    MON_IFACE=""
    if [[ -f "$STATE_FILE" ]]; then
        IFACE="$(sed -n '1p' "$STATE_FILE" 2>/dev/null)"
        MON_IFACE="$(sed -n '2p' "$STATE_FILE" 2>/dev/null)"
    fi
}

save_state() {
    printf '%s\n%s\n' "$IFACE" "$MON_IFACE" > "$STATE_FILE"
}

current_mode() {
    iw dev "$1" info 2>/dev/null | awk '/type/ {print $2; exit}'
}

confirm() {
    local reply
    read -rp "$1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

section() {
    echo -e "${C_TEAL_BOLD}== $1 ==${C_RESET}"
}

ok_line() {
    printf "  %-16s ${C_GREEN}.... Ok${C_RESET}\n" "$1"
}

missing_line() {
    printf "  %-16s ${C_RED}.... Missing${C_RESET}  (package: %s)\n" "$1" "$2"
}

# ---------- chipset lookup ----------

get_chipset() {
    # $1 = interface name. Tries PCI first, then USB.
    local iface="$1"
    local devpath chipset

    devpath="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null)"
    [[ -z "$devpath" ]] && { echo "unknown"; return; }

    if [[ "$devpath" == *"/pci"*"/"* ]] && command -v lspci >/dev/null 2>&1; then
        local pciaddr
        pciaddr="$(basename "$devpath")"
        chipset="$(lspci -s "$pciaddr" 2>/dev/null | sed -E 's/^[0-9a-f:.]+ [^:]+: //')"
    fi

    if [[ -z "${chipset:-}" ]] && command -v lsusb >/dev/null 2>&1; then
        local uevent vid pid
        uevent="$(find "$devpath/.." -maxdepth 3 -name uevent -exec grep -l PRODUCT= {} \; 2>/dev/null | head -1)"
        if [[ -n "$uevent" ]]; then
            local product
            product="$(grep '^PRODUCT=' "$uevent" 2>/dev/null | cut -d= -f2)"
            vid="$(echo "$product" | cut -d/ -f1)"
            pid="$(echo "$product" | cut -d/ -f2)"
            if [[ -n "$vid" && -n "$pid" ]]; then
                chipset="$(lsusb 2>/dev/null | grep -i "$(printf '%04x' "0x$vid" 2>/dev/null):$(printf '%04x' "0x$pid" 2>/dev/null)" | sed -E 's/^.*ID [0-9a-f]{4}:[0-9a-f]{4} //')"
            fi
        fi
    fi

    echo "${chipset:-unknown}"
}

# ---------- dependency management ----------

check_dependencies() {
    section "Dependency Check"
    local all_ok=1

    echo -e "${C_WHITE_BOLD}-- Required --${C_RESET}"
    local req_tools=("iw:iw" "nmcli:network-manager" "airmon-ng:aircrack-ng" "airodump-ng:aircrack-ng")
    for entry in "${req_tools[@]}"; do
        local tool="${entry%%:*}"
        local pkg="${entry##*:}"
        if command -v "$tool" >/dev/null 2>&1; then
            ok_line "$tool"
        else
            missing_line "$tool" "$pkg"
            all_ok=0
            if [[ $EUID -eq 0 ]]; then
                if confirm "  Install '$pkg' now?"; then
                    apt update && apt install -y "$pkg"
                fi
            else
                echo -e "${C_GRAY}    (run as root to be offered an install prompt)${C_RESET}"
            fi
        fi
    done

    echo -e "${C_WHITE_BOLD}-- Optional (capture/analysis) --${C_RESET}"
    local opt_tools=("tshark:tshark" "wireshark:wireshark" "tcpdump:tcpdump" "hcxdumptool:hcxdumptool" "hcxpcapngtool:hcxtools")
    for entry in "${opt_tools[@]}"; do
        local tool="${entry%%:*}"
        local pkg="${entry##*:}"
        if command -v "$tool" >/dev/null 2>&1; then
            ok_line "$tool"
        else
            missing_line "$tool" "$pkg"
            if [[ $EUID -eq 0 ]]; then
                if confirm "  Install '$pkg' now?"; then
                    apt update && apt install -y "$pkg"
                fi
            fi
        fi
    done

    echo -e "${C_WHITE_BOLD}-- Wireless capability (rfkill) --${C_RESET}"
    if command -v rfkill >/dev/null 2>&1; then
        local blocked
        blocked="$(rfkill list 2>/dev/null | grep -ci "blocked: yes")"
        if [[ "$blocked" -gt 0 ]]; then
            echo -e "${C_RED}  WARNING: rfkill reports one or more blocked wireless devices.${C_RESET}"
            rfkill list 2>/dev/null
            echo -e "${C_GRAY}  Use the rfkill unblock menu option if needed.${C_RESET}"
        else
            echo -e "${C_GREEN}  rfkill: no blocks reported. OK${C_RESET}"
        fi
    fi

    echo
    if [[ "$all_ok" -eq 0 ]]; then
        echo -e "${C_RED}Some required tools may still be missing.${C_RESET}"
        echo "Re-run this check (menu option) after installing, or some actions will fail."
    else
        echo -e "${C_GREEN}All required tools present. You're good to go.${C_RESET}"
    fi
    pause
}

rfkill_unblock() {
    need_root
    echo "Running: rfkill unblock all"
    rfkill unblock all
    echo
    rfkill list
    pause
}

# ---------- update check ----------

check_for_updates() {
    section "Check for Updates"
    echo "Current version: v${VERSION}"
    echo "Checking $REPO_RAW_URL ..."
    echo

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${C_RED}curl is not installed — can't check for updates.${C_RESET}"
        echo "Install it with: sudo apt install curl"
        pause
        return
    fi

    local remote_line remote_version
    remote_line="$(curl -fsSL --max-time 8 "$REPO_RAW_URL" 2>/dev/null | grep -m1 '^VERSION=')"

    if [[ -z "$remote_line" ]]; then
        echo -e "${C_RED}Couldn't reach the repo (offline, or repo/file not found yet).${C_RESET}"
        echo "Check manually at: $REPO_URL"
        pause
        return
    fi

    remote_version="$(echo "$remote_line" | sed -E 's/VERSION="([^"]+)"/\1/')"

    if [[ "$remote_version" == "$VERSION" ]]; then
        echo -e "${C_GREEN}You're up to date (v${VERSION}).${C_RESET}"
        pause
        return
    fi

    echo -e "${C_AMBER_BOLD}Update available: v${remote_version} (you have v${VERSION})${C_RESET}"
    echo

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -d "${script_dir}/.git" ]]; then
        echo "This looks like a git checkout at: $script_dir"
        if confirm "Run 'git pull' now?"; then
            (cd "$script_dir" && git pull)
            echo "Update pulled. Restart AirSmith to use the new version."
        fi
    else
        echo "This doesn't look like a git checkout, so I can't auto-update it."
        echo "Get the latest version with:"
        echo "  git clone ${REPO_URL}.git"
        echo "or download the raw script directly from:"
        echo "  $REPO_RAW_URL"
    fi
    pause
}

# ---------- core actions ----------

list_interfaces() {
    section "Wireless Interfaces"
    printf "${C_WHITE_BOLD}%-4s %-16s %-12s %-10s %s${C_RESET}\n" "#" "INTERFACE" "DRIVER" "MODE" "CHIPSET"
    local i=1
    WIFI_IFACES=()
    while read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == p2p-dev-* ]] && continue
        local driver mode chipset
        driver="$(basename "$(readlink -f "/sys/class/net/$name/device/driver" 2>/dev/null)" 2>/dev/null)"
        [[ -z "$driver" ]] && driver="?"
        mode="$(current_mode "$name")"
        [[ -z "$mode" ]] && mode="?"
        chipset="$(get_chipset "$name")"
        printf "%-4s %-16s %-12s " "$i)" "$name" "$driver"
        if [[ "$mode" == "monitor" ]]; then
            printf "${C_AMBER_BOLD}%-10s${C_RESET} " "$mode"
        else
            printf "%-10s " "$mode"
        fi
        printf "%s\n" "$chipset"
        WIFI_IFACES+=("$name")
        ((i++))
    done < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}')

    if [[ ${#WIFI_IFACES[@]} -eq 0 ]]; then
        echo -e "${C_RED}No wireless interfaces found.${C_RESET}"
    fi
}

select_interface() {
    list_interfaces
    if [[ ${#WIFI_IFACES[@]} -eq 0 ]]; then
        pause
        return
    fi
    echo
    read -rp "Select interface number: " num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#WIFI_IFACES[@]} )); then
        IFACE="${WIFI_IFACES[$((num-1))]}"
        MON_IFACE=""
        save_state
        echo -e "${C_GREEN}Selected: $IFACE${C_RESET}"
    else
        echo -e "${C_RED}Invalid selection.${C_RESET}"
    fi
    pause
}

enable_monitor() {
    need_root
    if [[ -z "${IFACE:-}" ]]; then
        echo -e "${C_RED}No interface selected yet. Choose one from the menu first.${C_RESET}"
        pause
        return
    fi

    local mode
    mode="$(current_mode "$IFACE")"
    if [[ "$mode" == "monitor" ]]; then
        echo "$IFACE is already in monitor mode."
        MON_IFACE="$IFACE"
        save_state
        pause
        return
    fi

    echo "Stopping NetworkManager and killing interfering processes..."
    systemctl stop NetworkManager
    airmon-ng check kill >/dev/null 2>&1 || true

    echo "Enabling monitor mode on $IFACE..."
    airmon-ng start "$IFACE"

    MON_IFACE="$(iw dev | awk '
        /Interface/ {name=$2}
        /type monitor/ {print name; exit}
    ')"

    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${C_RED}Warning: could not confirm monitor interface name via 'iw dev'.${C_RESET}"
        MON_IFACE="$IFACE"
    fi

    save_state
    echo
    echo -e "${C_GREEN}Monitor mode is up on: $MON_IFACE${C_RESET}"
    echo "Point Wireshark/tshark/tcpdump at '$MON_IFACE'."
    pause
}

disable_monitor() {
    need_root
    load_state
    if [[ -z "${MON_IFACE:-}" ]]; then
        echo "No known monitor interface for this session."
        read -rp "Enter monitor interface name manually (or blank to cancel): " manual
        [[ -z "$manual" ]] && { pause; return; }
        MON_IFACE="$manual"
    fi

    echo "Disabling monitor mode on $MON_IFACE..."
    airmon-ng stop "$MON_IFACE" || echo -e "${C_RED}airmon-ng didn't find $MON_IFACE (already gone?).${C_RESET}"

    echo "Restarting NetworkManager..."
    systemctl start NetworkManager
    sleep 2

    if [[ -n "${IFACE:-}" ]]; then
        nmcli device connect "$IFACE" >/dev/null 2>&1 || true
    fi

    MON_IFACE=""
    save_state
    echo -e "${C_GREEN}Done.${C_RESET}"
    pause
}

scan_managed() {
    if [[ -z "${IFACE:-}" ]]; then
        echo -e "${C_RED}No interface selected yet.${C_RESET}"
        pause
        return
    fi
    local mode
    mode="$(current_mode "$IFACE")"
    if [[ "$mode" != "managed" ]]; then
        echo "$IFACE is not in managed mode (currently: $mode)."
        echo "Use this scan before enabling monitor mode, or use the live"
        echo "channel survey option instead once monitor mode is on."
        pause
        return
    fi

    need_root
    echo "Scanning... (a few seconds)"
    echo
    printf "${C_WHITE_BOLD}%-32s %-6s %-6s %s${C_RESET}\n" "SSID" "CHAN" "SIGNAL" "SECURITY"
    iw dev "$IFACE" scan 2>/dev/null | awk '
        /^BSS/ { ssid=""; chan=""; sig=""; sec="OPEN" }
        /SSID:/ { $1=""; ssid=$0; sub(/^ /,"",ssid) }
        /signal:/ { sig=$2 " " $3 }
        /freq:/ {
            freq=$2
            if (freq >= 2412 && freq <= 2484) chan=int((freq-2407)/5)
            else chan=int((freq-5000)/5)
        }
        /RSN:/ { sec="WPA2/3" }
        /WPA:/ { if (sec=="OPEN") sec="WPA" }
        /SSID:/ {
            printf "%-32s %-6s %-6s %s\n", (ssid==""?"<hidden>":ssid), chan, sig, sec
        }
    '
    pause
}

live_channel_survey() {
    load_state
    if [[ -z "${MON_IFACE:-}" ]]; then
        echo -e "${C_RED}Monitor mode isn't on yet. Enable it first (option 3).${C_RESET}"
        pause
        return
    fi
    need_root
    echo "Launching airodump-ng on $MON_IFACE — live channel/AP survey."
    echo "Watch the CH column for active channels in your area."
    echo "Press Ctrl+C to stop and return to the menu."
    echo
    sleep 2
    airodump-ng "$MON_IFACE"
    pause
}

capture_to_pcap() {
    load_state
    if [[ -z "${MON_IFACE:-}" ]]; then
        echo -e "${C_RED}Monitor mode isn't on yet. Enable it first (option 3).${C_RESET}"
        pause
        return
    fi
    need_root
    mkdir -p "$CAPTURE_DIR"

    local default_name
    default_name="capture-$(date +%Y%m%d-%H%M%S)"
    read -rp "Capture file name [${default_name}]: " name
    name="${name:-$default_name}"
    local out_path="${CAPTURE_DIR}/${name}"

    echo
    echo "Writing capture to: ${out_path}-01.pcap (airodump-ng naming)"
    echo "Press Ctrl+C to stop capturing. File(s) will remain in:"
    echo "  $CAPTURE_DIR"
    echo
    sleep 2
    airodump-ng --write "$out_path" --output-format pcap "$MON_IFACE"

    echo
    echo "Capture stopped. Files in $CAPTURE_DIR:"
    ls -lh "$CAPTURE_DIR" | grep "$name" || true
    echo
    echo -e "${C_AMBER}Open in Wireshark with: wireshark ${out_path}-01.pcap${C_RESET}"
    pause
}

set_channel() {
    load_state
    if [[ -z "${MON_IFACE:-}" ]]; then
        echo -e "${C_RED}Monitor mode isn't on yet. Enable it first (option 3).${C_RESET}"
        pause
        return
    fi
    need_root
    read -rp "Enter channel number to lock $MON_IFACE to: " ch
    if [[ "$ch" =~ ^[0-9]+$ ]]; then
        iw dev "$MON_IFACE" set channel "$ch" && echo -e "${C_GREEN}Channel set to $ch.${C_RESET}"
    else
        echo -e "${C_RED}Invalid channel.${C_RESET}"
    fi
    pause
}

show_status() {
    load_state
    section "Current State"
    echo "Selected interface: ${IFACE:-none}"
    echo "Monitor interface:  ${MON_IFACE:-none}"
    echo "Capture directory:  $CAPTURE_DIR"
    echo
    echo -e "${C_WHITE_BOLD}-- nmcli device status --${C_RESET}"
    nmcli device status 2>/dev/null || true
    echo
    echo -e "${C_WHITE_BOLD}-- iw dev --${C_RESET}"
    iw dev 2>/dev/null || true
    pause
}

# ---------- menu ----------

main_menu() {
    load_state
    clear
    print_banner
    echo -e "${C_GRAY}Let's check if you have what AirSmith needs.${C_RESET}"
    pause
    check_dependencies
    while true; do
        clear
        print_banner
        echo "Selected interface: ${IFACE:-none}    Monitor iface: ${MON_IFACE:-none}"
        echo -e "${C_TEAL}---------------------------------------${C_RESET}"
        echo "1)  List / refresh wireless interfaces"
        echo "2)  Select interface"
        echo "3)  Enable monitor mode"
        echo "4)  Disable monitor mode"
        echo "5)  Scan nearby networks (managed mode)"
        echo "6)  Live channel survey (monitor mode)"
        echo "7)  Capture to pcap file (monitor mode)"
        echo "8)  Set/change channel (monitor mode)"
        echo "9)  rfkill unblock all"
        echo "10) Show status"
        echo "11) Check / install dependencies"
        echo "12) Check for updates"
        echo "0)  Exit"
        echo -e "${C_TEAL}---------------------------------------${C_RESET}"
        read -rp "Choice: " choice
        case "$choice" in
            1) list_interfaces; pause ;;
            2) select_interface ;;
            3) enable_monitor ;;
            4) disable_monitor ;;
            5) scan_managed ;;
            6) live_channel_survey ;;
            7) capture_to_pcap ;;
            8) set_channel ;;
            9) rfkill_unblock ;;
            10) show_status ;;
            11) check_dependencies ;;
            12) check_for_updates ;;
            0) echo "Bye."; exit 0 ;;
            *) echo -e "${C_RED}Invalid choice.${C_RESET}"; sleep 1 ;;
        esac
    done
}

main_menu
