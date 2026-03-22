#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# === Configuration ===
# Replace the values below with those from your Klipper config files

# HOST MCU (mainboard)
# UUID: from printer.cfg -> [mcu]
HOSTUUID=''                  # example: '4bc297a772bc'
HOSTSERIAL='/dev/ttyACM0'    # Serial path used for USB flashing (do not change if no need)

# TOOLHEAD MCU
# UUID: from printer.cfg -> [mcu extruder_mcu]
TOOLHEADUUID=''              # example: '2455eaeda160'

# CHAMBER MCU (optional)
# UUID: from chamber_hot.cfg -> [mcu hot_mcu]
CHAMBERUUID=''               # example: '2d17deb0ba01'

# Paths
KLIPPER_DIR="$HOME/klipper"
KATAPULT_FLASHTOOL="$HOME/katapult/scripts/flashtool.py"

# Colors
MAGENTA=$'\e[35m'
YELLOW=$'\e[33m'
RED=$'\e[31m'
CYAN=$'\e[36m'
NC=$'\e[0m'

info(){    echo -e "${YELLOW}[INFO]${NC} $*"; }
warn(){    echo -e "${RED}[WARN]${NC} $*"; }
success(){ echo -e "${MAGENTA}[OK]${NC} $*"; }
fatal(){   warn "$*"; sleep 2; exit 1; }

prompt_enter_or_q(){
    local prompt_text="$1"
    local input
    while true; do
        read -r -p "$prompt_text" input
        case "$input" in
            "") return 0 ;;
            q|Q|quit|QUIT) return 1 ;;
            *) warn "Invalid input. Press Enter to continue or type q to cancel." ;;
        esac
    done
}

prompt_yes_or_q(){
    local prompt_text="$1"
    local input
    while true; do
        read -r -p "$prompt_text" input
        case "$input" in
            YES|yes) return 0 ;;
            q|Q|quit|QUIT) return 1 ;;
            *) warn "Invalid input. Type yes/YES to continue or q to cancel." ;;
        esac
    done
}

cleanup(){
    info "Ensuring Klipper is running..."
    sudo service klipper start || true
}
trap cleanup EXIT

validate_uuid(){
    local name="$1"
    local uuid="$2"
    [[ "$uuid" =~ ^[0-9A-Fa-f]{12}$ ]] || {
        warn "Invalid UUID for ${name}: $uuid"
        return 1
    }
}

check_prereqs(){
    command -v make    >/dev/null || fatal "make is required"
    command -v python3 >/dev/null || fatal "python3 is required"
    [ -d "$KLIPPER_DIR" ]       || fatal "$KLIPPER_DIR does not exist"
    [ -f "$KATAPULT_FLASHTOOL" ] || fatal "$KATAPULT_FLASHTOOL not found"

    # HOST UUID + serial are always required
    [ -n "${HOSTUUID:-}"   ] || fatal "HOSTUUID is not set. Exiting."
    [ -n "${HOSTSERIAL:-}" ] || fatal "HOSTSERIAL is not set. Exiting."
    validate_uuid "HOST" "$HOSTUUID" || { sleep 2; exit 1; }

    # TOOLHEAD + CHAMBER UUIDs are required only when can0 is up (checked later)
    if [ -n "${TOOLHEADUUID:-}" ]; then
        validate_uuid "TOOLHEAD" "$TOOLHEADUUID" || { sleep 2; exit 1; }
    fi
    if [ -n "${CHAMBERUUID:-}" ]; then
        validate_uuid "CHAMBER" "$CHAMBERUUID" || { sleep 2; exit 1; }
    fi

    if ip link show can0 >/dev/null 2>&1; then
        CAN0_AVAILABLE=1
        info "can0 is up — full flash mode (HOST + TOOLHEAD + CHAMBER)"
        # When can0 is up, TOOLHEAD UUID is required
        [ -n "${TOOLHEADUUID:-}" ] || fatal "TOOLHEADUUID is not set. Exiting."
    else
        CAN0_AVAILABLE=0
        warn "can0 not found — HOST USB-only mode (TOOLHEAD/CHAMBER unavailable)"
    fi

    info "HOSTSERIAL: $HOSTSERIAL"
}

query_can_nodes(){
    info "Querying CAN nodes..."
    python3 "$KATAPULT_FLASHTOOL" -i can0 -q
}

stop_klipper(){
    info "Stopping Klipper service"
    sudo service klipper stop
}

start_klipper(){
    info "Starting Klipper service"
    sudo service klipper start
}

build_firmware(){
    local name="$1"
    local kconfig="$2"

    cd "$KLIPPER_DIR"
    info "Building Klipper firmware for ${name}"
    make clean

    if ! prompt_enter_or_q "${CYAN}Press Enter to open menuconfig for ${name} (or q to cancel): ${NC}"; then
        warn "User cancelled ${name} build"
        return 1
    fi

    make menuconfig KCONFIG_CONFIG="${kconfig}"

    local JOBS
    JOBS=$(nproc)
    [ "$JOBS" -gt 4 ] && JOBS=4
    make KCONFIG_CONFIG="${kconfig}" -j"$JOBS"

    [ -f "$KLIPPER_DIR/out/klipper.bin" ] || {
        warn "Build failed: klipper.bin missing"
        return 1
    }

    local out_bin="${name,,}_mcu_klipper.bin"
    cp "$KLIPPER_DIR/out/klipper.bin" "$KLIPPER_DIR/$out_bin"
    info "Firmware ready: $KLIPPER_DIR/$out_bin"
    return 0
}

flash_host(){
    build_firmware "HOST" "host.mcu" || return

    local out_bin="host_mcu_klipper.bin"

    # can0 path: request bootloader over CAN first, then flash over serial
    if [ "${CAN0_AVAILABLE}" -eq 1 ]; then
        query_can_nodes
        info "Requesting Katapult bootloader for HOST over CAN (UUID=$HOSTUUID)"
        python3 "$KATAPULT_FLASHTOOL" -i can0 -u "$HOSTUUID" -r
        info "Waiting for HOST to enumerate as USB serial..."
        sleep 5
    else
        # No can0: board should already be in bootloader mode (manually triggered)
        warn "can0 not available — assuming HOST is already in Katapult bootloader mode on $HOSTSERIAL"
    fi

    # Serial device should exist now (either after CAN bootloader request, or manually)
    if [ ! -e "$HOSTSERIAL" ]; then
        warn "HOST serial device not found: $HOSTSERIAL — is the board in bootloader mode?"
        return
    fi

    if ! prompt_yes_or_q "${CYAN}Type YES to flash HOST via serial ($HOSTSERIAL) (or q to cancel): ${NC}"; then
        warn "User cancelled HOST flash"
        return
    fi

    python3 "$KATAPULT_FLASHTOOL" -f "$KLIPPER_DIR/$out_bin" -d "$HOSTSERIAL"
    success "HOST flashed successfully"

    [ "${CAN0_AVAILABLE}" -eq 1 ] && query_can_nodes
    sleep 2
}

flash_canbus(){
    local name="$1"
    local kconfig="$2"
    local uuid="$3"

    [ -n "$uuid" ] || { warn "No UUID for ${name}, skipping"; return; }

    build_firmware "$name" "$kconfig" || return

    local out_bin="${name,,}_mcu_klipper.bin"

    query_can_nodes

    if ! prompt_yes_or_q "${CYAN}Type YES to flash ${name} (UUID=$uuid) over CAN (or q to cancel): ${NC}"; then
        warn "User cancelled ${name} flash"
        return
    fi

    python3 "$KATAPULT_FLASHTOOL" -i can0 -f "$KLIPPER_DIR/$out_bin" -u "$uuid"
    success "${name} flashed successfully"

    query_can_nodes
    sleep 2
}

main_menu(){
    while true; do
        [ -t 1 ] && [ -n "${TERM:-}" ] && clear || true
        echo -e "${MAGENTA}SV_ZERO AUTOMATIC MCU UPDATER${NC}"

        local options
        if [ "${CAN0_AVAILABLE}" -eq 1 ]; then
            if [ -n "${CHAMBERUUID:-}" ]; then
                options=("HOST MCU" "TOOLHEAD MCU" "CHAMBER MCU" "Query CAN nodes" "Quit")
            else
                options=("HOST MCU" "TOOLHEAD MCU" "Query CAN nodes" "Quit")
            fi
        else
            echo -e "${RED}[WARN] can0 not available — HOST USB-only mode${NC}"
            options=("HOST MCU" "Quit")
        fi

        PS3='Select device to update: '
        select opt in "${options[@]}"; do
            case $opt in
                "HOST MCU")
                    flash_host
                    break ;;
                "TOOLHEAD MCU")
                    flash_canbus "TOOLHEAD" "toolhead.mcu" "$TOOLHEADUUID"
                    break ;;
                "CHAMBER MCU")
                    flash_canbus "CHAMBER" "chamber.mcu" "$CHAMBERUUID"
                    break ;;
                "Query CAN nodes")
                    query_can_nodes
                    read -r -p "Press Enter to continue..." dummy
                    break ;;
                "Quit")
                    info "Done"
                    return ;;
                *)
                    warn "Invalid option '$REPLY'"
                    break ;;
            esac
        done
    done
}

# Run
check_prereqs
stop_klipper
main_menu
start_klipper
trap - EXIT
cd "$KLIPPER_DIR"
success "Script complete"