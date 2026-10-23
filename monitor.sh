#!/usr/bin/env bash

# ============================================================
# Pixel 8a/11 / VW Golf Wireless Charging Monitor
# v5.2
#
# Primary positioning metric:
#   Wireless input power, auto-detected from wlcin-* or dc/
#
# Features:
#   - 1 sec refresh
#   - 5 sec moving average
#   - Dynamic session peak
#   - Position quality score
#   - Color-coded compact dashboard
#   - Wireless input / charger / battery data
#   - Android charging limits
#   - No CSV logging
# ============================================================

INTERVAL=1
AVG_SECONDS=5

ADB="adb"

find_pixel() {
    local serial model

    while IFS= read -r serial; do
        [[ -z "$serial" ]] && continue

        model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')

        if [[ "$model" == *"Pixel 11"* || "$model" == *"Pixel 8a"* ]]; then
            printf '%s\n' "$serial"
            return 0
        fi
    done < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')

    return 1
}

PIXEL_SERIAL=$(find_pixel) || {
    echo "No supported Pixel 8a/11 found. Check: adb devices"
    exit 1
}

ADB="adb -s $PIXEL_SERIAL"
printf 'Using device: %s\n' "$PIXEL_SERIAL"
printf 'command: %s\n' "${ADB}"



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
    $ADB shell '
        read_value() {
            if [ -r "$2" ]; then
                printf "%s=" "$1"
                head -n 1 "$2"
            else
                printf "%s=\n" "$1"
            fi
        }

        printf "model="
        getprop ro.product.model

        # Read each possible wireless-input interface. Pixel 11 uses
        # wlcin-mains / wlcin-max77779; Pixel 8a commonly uses dc.
        for name in wlcin-mains wlcin-max77779 dc; do
            base="/sys/class/power_supply/$name"
            read_value "${name}_voltage" "$base/voltage_now"
            read_value "${name}_current" "$base/current_now"
            read_value "${name}_voltage_max" "$base/voltage_max"
            read_value "${name}_current_max" "$base/current_max"
            read_value "${name}_online" "$base/online"
            read_value "${name}_present" "$base/present"
        done

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

    model=$(get_value model)

    # Prefer the dedicated wireless-input interface when it is online
    # and reports usable voltage/current; otherwise fall back to dc.
    input_name=""
    for candidate in wlcin-mains wlcin-max77779 dc; do
        c_online=$(num "$(get_value "${candidate}_online")")
        c_present=$(num "$(get_value "${candidate}_present")")
        c_voltage=$(num "$(get_value "${candidate}_voltage")")
        c_current=$(num "$(get_value "${candidate}_current")")
        if (( c_online == 1 && c_present == 1 && c_voltage > 0 && c_current > 0 )); then
            input_name="$candidate"
            input_voltage_uv=$c_voltage
            input_current_ua=$c_current
            input_voltage_max_uv=$(num "$(get_value "${candidate}_voltage_max")")
            input_current_max_ua=$(num "$(get_value "${candidate}_current_max")")
            input_online="$c_online"
            input_present="$c_present"
            break
        fi
    done

    if [[ -z "$input_name" ]]; then
        input_voltage_uv=0; input_current_ua=0
        input_voltage_max_uv=0; input_current_max_ua=0
        input_online=0; input_present=0
    fi

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
    if [[ "$wireless" == "true" || "$charger_status" == "Charging" || "$battery_status" == "Charging" ]]; then
        charging=true
    fi


    # ========================================================
    # POWER
    # ========================================================

    if (( input_voltage_uv > 0 && input_current_ua > 0 )); then
        input_power_uw=$(power_uw \
            "$input_voltage_uv" "$input_current_ua")
    else
        input_power_uw=0
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

    power_history+=("$input_power_uw")

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

    (( input_power_uw > peak_power_uw )) &&
        peak_power_uw=$input_power_uw

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

    if (( input_voltage_max_uv > 0 &&
          input_current_max_ua > 0 )); then

        input_limit_power_uw=$(power_uw \
            "$input_voltage_max_uv" "$input_current_max_ua")

        input_utilization=$(
            awk -v p="$avg_power_uw" \
                -v m="$input_limit_power_uw" \
                'BEGIN {
                    if (m > 0)
                        printf "%.0f", p/m*100
                    else
                        print 0
                }'
        )
    else
        input_limit_power_uw=0
        input_utilization=0
    fi


    # ========================================================
    # EFFICIENCY
    # ========================================================

    if (( input_power_uw > 0 &&
          battery_power_uw > 0 )); then

        efficiency=$(
            awk -v b="$battery_power_uw" \
                -v d="$input_power_uw" \
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

    echo -e "${BOLD}${CYAN} ${model:-Pixel} / VW Golf — Wireless Charging Monitor v5.2${RESET}"
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

echo -e "${BOLD}${CYAN} WIRELESS INPUT${RESET}                         ${BOLD}${CYAN}CHARGER${RESET}                       ${BOLD}${CYAN}BATTERY${RESET}"

printf " %-29s %-29s %-29s\n" \
    "Voltage  $(fmt_v "$input_voltage_uv") V" \
    "Type     ${charger_type:-N/A}" \
    "Voltage  $(fmt_v "$battery_voltage_uv") V"

printf " %-29s %-29s %-29s\n" \
    "Current  $(fmt_a "$input_current_ua") A" \
    "Status   ${charger_status:-N/A}" \
    "Current  $(fmt_a "$battery_current_ua") A"

printf " %-29s %-29s %-29s\n" \
    "Power    $(fmt_w "$input_power_uw") W" \
    "Power    $(fmt_w "$charger_power_uw") W" \
    "Power    $(fmt_w "$battery_power_uw") W"

printf " %-29s %-29s %-29s\n" \
    "5-sec    $(fmt_w "$avg_power_uw") W" \
    "Voltage  $(fmt_v "$charger_voltage_uv") V" \
    "Temp     $(awk -v t="$battery_temp" 'BEGIN {printf "%.1f",t/10}')°C"

echo


    # --------------------------------------------------------
    # LIMITS
    # --------------------------------------------------------

    echo -e "${BOLD}${YELLOW} REPORTED INPUT LIMITS (if exposed)${RESET}"

    printf " %s: %s V × %s A = %s W    Utilization: %s%%\n" \
        "$input_name" \
        "$(fmt_v "$input_voltage_max_uv")" \
        "$(fmt_a "$input_current_max_ua")" \
        "$(fmt_w "$input_limit_power_uw")" \
        "$input_utilization"

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

    printf " Input: %s   Online: %s   Present: %s   Battery/input ratio: ~%s%%   Avg window: %ss\n" \
        "${input_name:-N/A}" \
        "$input_online" \
        "$input_present" \
        "${efficiency:-N/A}" \
        "$AVG_SECONDS"

    echo
    if [[ -z "$input_name" ]]; then
        echo -e "${BG_RED} WARNING: no usable wireless-input voltage/current source detected. ${RESET}"
        echo -e "${YELLOW} Position score is not meaningful until input power is available. ${RESET}"
    fi

    echo -e "${DIM} Move the phone slowly to find the highest position score.  Ctrl+C to exit.${RESET}"

    sleep "$INTERVAL"

done