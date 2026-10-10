#!/usr/bin/env bash

# ============================================================
# Pixel 8a / VW Golf Wireless Charging Monitor
# v5.1
#
# Primary positioning metric:
#   DC input power from /sys/class/power_supply/dc/
#
# Features:
#   - 1 sec refresh
#   - 5 sec moving average
#   - Dynamic session peak
#   - Position quality score
#   - Color-coded compact dashboard
#   - DC input / charger / battery data
#   - Android charging limits
#   - No CSV logging
# ============================================================

INTERVAL=1
AVG_SECONDS=5

ADB="adb"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
WHITE='\033[37m'
MAGENTA='\033[35m'

BG_GREEN='\033[42;30m'
BG_YELLOW='\033[43;30m'
BG_RED='\033[41;37m'
BG_BLUE='\033[44;37m'


# ------------------------------------------------------------
# ADB
# ------------------------------------------------------------

if ! $ADB get-state >/dev/null 2>&1; then
    echo -e "${RED}ERROR:${RESET} ADB device not available."
    echo "Run: adb devices"
    exit 1
fi


# ------------------------------------------------------------
# Read sysfs safely
#
# IMPORTANT:
# Some Pixel sysfs nodes can occasionally return more than
# one line / stale values. We explicitly select the first
# valid numeric line.
# ------------------------------------------------------------

read_num() {
    local path="$1"

    $ADB shell "cat '$path' 2>/dev/null" 2>/dev/null |
        tr -d '\r' |
        grep -m1 -E '^-?[0-9]+$'
}


read_text() {
    local path="$1"

    $ADB shell "cat '$path' 2>/dev/null" 2>/dev/null |
        tr -d '\r' |
        head -n1
}


num() {
    local v="$1"

    if [[ "$v" =~ ^-?[0-9]+$ ]]; then
        echo "$v"
    else
        echo 0
    fi
}


fmt_a() {
    awk -v x="$1" 'BEGIN {
        printf "%.3f", x/1000000
    }'
}


fmt_v() {
    awk -v x="$1" 'BEGIN {
        printf "%.3f", x/1000000
    }'
}


fmt_w() {
    awk -v x="$1" 'BEGIN {
        printf "%.2f", x/1000000
    }'
}


# µV × µA -> µW
power_uw() {
    echo $(( $1 * $2 / 1000000 ))
}


# ------------------------------------------------------------
# Bar
# ------------------------------------------------------------

bar() {
    local percent="$1"
    local width="${2:-42}"

    (( percent < 0 )) && percent=0
    (( percent > 100 )) && percent=100

    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    printf '['
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '.'
    printf ']'
}


# ------------------------------------------------------------
# Position color
# ------------------------------------------------------------

position_color() {
    local p="$1"

    if (( p >= 95 )); then
        echo "$GREEN"
    elif (( p >= 85 )); then
        echo "$CYAN"
    elif (( p >= 70 )); then
        echo "$YELLOW"
    else
        echo "$RED"
    fi
}


position_label() {
    local p="$1"

    if (( p >= 95 )); then
        echo "EXCELLENT"
    elif (( p >= 85 )); then
        echo "GOOD"
    elif (( p >= 70 )); then
        echo "FAIR"
    else
        echo "POOR"
    fi
}


# ------------------------------------------------------------
# History
# ------------------------------------------------------------

declare -a power_history=()

peak_power_uw=0
max_avg_power_uw=0


# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------

read_all() {
    adb shell '
        read_value() {
            if [ -r "$2" ]; then
                printf "%s=" "$1"
                cat "$2"
            else
                printf "%s=\n" "$1"
            fi
        }

        read_value dc_voltage /sys/class/power_supply/dc/voltage_now
        read_value dc_current /sys/class/power_supply/dc/current_now
        read_value dc_current_max /sys/class/power_supply/dc/current_max
        read_value dc_voltage_max /sys/class/power_supply/dc/voltage_max
        read_value dc_online /sys/class/power_supply/dc/online
        read_value dc_present /sys/class/power_supply/dc/present

        read_value charger_status /sys/class/power_supply/main-charger/status
        read_value charger_type /sys/class/power_supply/main-charger/charge_type
        read_value charger_current /sys/class/power_supply/main-charger/current_now
        read_value charger_voltage /sys/class/power_supply/main-charger/voltage_now

        read_value battery_current /sys/class/power_supply/battery/current_now
        read_value battery_voltage /sys/class/power_supply/battery/voltage_now
        read_value battery_capacity /sys/class/power_supply/battery/capacity
        read_value battery_temp /sys/class/power_supply/battery/temp
        read_value battery_status /sys/class/power_supply/battery/status

        dumpsys battery
    ' 2>/dev/null | tr -d '\r'
}

while true; do

    data=$(read_all)

    get_value() {
    printf '%s\n' "$data" |
        awk -F= -v key="$1" '$1 == key { print $2; exit }'
    }

    dc_voltage_uv=$(num "$(get_value dc_voltage)")
    dc_current_ua=$(num "$(get_value dc_current)")
    dc_current_max_ua=$(num "$(get_value dc_current_max)")
    dc_voltage_max_uv=$(num "$(get_value dc_voltage_max)")
    dc_online=$(get_value dc_online)
    dc_present=$(get_value dc_present)

    charger_status=$(get_value charger_status)
    charger_type=$(get_value charger_type)
    charger_current_ua=$(num "$(get_value charger_current)")
    charger_voltage_uv=$(num "$(get_value charger_voltage)")

    battery_current_ua=$(num "$(get_value battery_current)")
    battery_voltage_uv=$(num "$(get_value battery_voltage)")
    battery_capacity=$(num "$(get_value battery_capacity)")
    battery_temp=$(num "$(get_value battery_temp)")
    battery_status=$(get_value battery_status)

    wireless=$(printf '%s\n' "$data" | awk -F': ' '/Wireless powered:/ {print $2; exit}')
    max_charge_current=$(printf '%s\n' "$data" | awk -F': ' '/Max charging current:/ {print $2; exit}')
    max_charge_voltage=$(printf '%s\n' "$data" | awk -F': ' '/Max charging voltage:/ {print $2; exit}')
    android_level=$(printf '%s\n' "$data" | awk -F': ' '$1 == "  level" {print $2; exit}')
    android_voltage_mv=$(printf '%s\n' "$data" | awk -F': ' '$1 == "  voltage" {print $2; exit}')
    android_temp=$(printf '%s\n' "$data" | awk -F': ' '$1 == "  temperature" {print $2; exit}')


    # ========================================================
    # CHARGING
    # ========================================================

    charging=false

    if [[ "$dc_online" == "1" &&
          "$dc_present" == "1" &&
          "$wireless" == "true" ]]; then
        charging=true
    fi


    # ========================================================
    # POWER
    # ========================================================

    if (( dc_voltage_uv > 0 && dc_current_ua > 0 )); then
        dc_power_uw=$(power_uw \
            "$dc_voltage_uv" "$dc_current_ua")
    else
        dc_power_uw=0
    fi


    if (( battery_voltage_uv > 0 &&
          battery_current_ua > 0 )); then

        battery_power_uw=$(power_uw \
            "$battery_voltage_uv" "$battery_current_ua")
    else
        battery_power_uw=0
    fi


    if (( charger_voltage_uv > 0 &&
          charger_current_ua > 0 )); then

        charger_power_uw=$(power_uw \
            "$charger_voltage_uv" "$charger_current_ua")
    else
        charger_power_uw=0
    fi


    # ========================================================
    # 5 SECOND AVERAGE
    # ========================================================

    power_history+=("$dc_power_uw")

    while (( ${#power_history[@]} > AVG_SECONDS )); do
        power_history=("${power_history[@]:1}")
    done

    sum=0

    for p in "${power_history[@]}"; do
        sum=$((sum + p))
    done

    if (( ${#power_history[@]} )); then
        avg_power_uw=$((sum / ${#power_history[@]}))
    else
        avg_power_uw=0
    fi


    # ========================================================
    # PEAK
    # ========================================================

    (( dc_power_uw > peak_power_uw )) &&
        peak_power_uw=$dc_power_uw

    (( avg_power_uw > max_avg_power_uw )) &&
        max_avg_power_uw=$avg_power_uw


    # ========================================================
    # POSITION QUALITY
    # ========================================================

    if (( max_avg_power_uw > 0 )); then
        position_quality=$(
            awk -v a="$avg_power_uw" \
                -v m="$max_avg_power_uw" \
                'BEGIN {
                    printf "%.0f", a/m*100
                }'
        )
    else
        position_quality=0
    fi

    (( position_quality > 100 )) &&
        position_quality=100

    pc=$(position_color "$position_quality")
    pl=$(position_label "$position_quality")


    # ========================================================
    # DC LIMIT
    # ========================================================

    if (( dc_voltage_max_uv > 0 &&
          dc_current_max_ua > 0 )); then

        dc_limit_power_uw=$(power_uw \
            "$dc_voltage_max_uv" "$dc_current_max_ua")

        dc_utilization=$(
            awk -v p="$avg_power_uw" \
                -v m="$dc_limit_power_uw" \
                'BEGIN {
                    if (m > 0)
                        printf "%.0f", p/m*100
                    else
                        print 0
                }'
        )
    else
        dc_limit_power_uw=0
        dc_utilization=0
    fi


    # ========================================================
    # EFFICIENCY
    # ========================================================

    if (( dc_power_uw > 0 &&
          battery_power_uw > 0 )); then

        efficiency=$(
            awk -v b="$battery_power_uw" \
                -v d="$dc_power_uw" \
                'BEGIN {
                    printf "%.0f", b/d*100
                }'
        )
    else
        efficiency=0
    fi


    # ========================================================
    # BATTERY DIRECTION
    # ========================================================

    if (( battery_current_ua >= 0 )); then
        battery_direction="${GREEN}CHG${RESET}"
    else
        battery_direction="${RED}LOAD${RESET}"
    fi


    # ========================================================
    # STATUS
    # ========================================================

    if $charging; then
        status="${BG_GREEN} CHARGING ${RESET}"
    else
        status="${BG_RED} NOT CHARGING ${RESET}"
    fi


    # ========================================================
    # RENDER
    # ========================================================

    printf '\033[2J\033[H'

    echo -e "${BOLD}${CYAN} Pixel 8a / VW Golf — Wireless Charging Monitor v5.1${RESET}"
    echo -e "${DIM} $(date '+%H:%M:%S')${RESET}"
    echo

    # --------------------------------------------------------
    # STATUS LINE
    # --------------------------------------------------------

    echo -e " STATUS: $status   Wireless: ${BOLD}${wireless:-false}${RESET}   Battery: ${BOLD}${android_level:-$battery_capacity}%${RESET}   Temp: ${BOLD}$(awk -v t="${android_temp:-$battery_temp}" 'BEGIN {printf "%.1f",t/10}')°C${RESET}"
    echo


    # --------------------------------------------------------
    # POSITION
    # --------------------------------------------------------

    echo -e "${BOLD}${WHITE} POSITION QUALITY${RESET}"

    printf " "
    echo -ne "${pc}"
    bar "$position_quality" 50
    echo -e " ${BOLD}${position_quality}%${RESET} ${pl}${RESET}"

    echo -e " Best: ${BOLD}$(fmt_w "$max_avg_power_uw") W${RESET}   Now: ${BOLD}$(fmt_w "$avg_power_uw") W${RESET}   Peak: ${BOLD}$(fmt_w "$peak_power_uw") W${RESET}"
    echo


    # --------------------------------------------------------
    # THREE COLUMN MEASUREMENTS
    # --------------------------------------------------------

echo -e "${BOLD}${CYAN} INPUT${RESET}                         ${BOLD}${CYAN}CHARGER${RESET}                       ${BOLD}${CYAN}BATTERY${RESET}"

printf " %-29s %-29s %-29s\n" \
    "Voltage  $(fmt_v "$dc_voltage_uv") V" \
    "Type     ${charger_type:-N/A}" \
    "Voltage  $(fmt_v "$battery_voltage_uv") V"

printf " %-29s %-29s %-29s\n" \
    "Current  $(fmt_a "$dc_current_ua") A" \
    "Status   ${charger_status:-N/A}" \
    "Current  $(fmt_a "$battery_current_ua") A"

printf " %-29s %-29s %-29s\n" \
    "Power    $(fmt_w "$dc_power_uw") W" \
    "Power    $(fmt_w "$charger_power_uw") W" \
    "Power    $(fmt_w "$battery_power_uw") W"

printf " %-29s %-29s %-29s\n" \
    "5-sec    $(fmt_w "$avg_power_uw") W" \
    "Voltage  $(fmt_v "$charger_voltage_uv") V"

echo


    # --------------------------------------------------------
    # LIMITS
    # --------------------------------------------------------

    echo -e "${BOLD}${YELLOW} REPORTED INPUT LIMITS${RESET}"

    printf " DC: %s V × %s A = %s W    Utilization: %s%%\n" \
        "$(fmt_v "$dc_voltage_max_uv")" \
        "$(fmt_a "$dc_current_max_ua")" \
        "$(fmt_w "$dc_limit_power_uw")" \
        "$dc_utilization"

    printf " Android: %s V × %s A\n" \
        "$(awk -v x="${max_charge_voltage:-0}" \
            'BEGIN {printf "%.3f",x/1000000}')" \
        "$(awk -v x="${max_charge_current:-0}" \
            'BEGIN {printf "%.3f",x/1000000}')"

    echo


    # --------------------------------------------------------
    # EXTRA
    # --------------------------------------------------------

    echo -e "${BOLD}${MAGENTA} OTHER${RESET}"

    printf " DC online: %s   Present: %s   DC→battery: ~%s%%   Avg window: %ss\n" \
        "$dc_online" \
        "$dc_present" \
        "${efficiency:-N/A}" \
        "$AVG_SECONDS"

    echo
    echo -e "${DIM} Move the phone slowly to find the highest position score.  Ctrl+C to exit.${RESET}"

    sleep "$INTERVAL"

done