#!/usr/bin/env bash

# ============================================================
# Pixel 8a Wireless Charging Monitor v4.1
#
# Google Pixel 8a + VW Golf wireless charging pad
#
# Dynamic position quality:
#   - Uses the highest 5-second average measured this session
#     as the dynamic maximum.
#   - Position quality = current 5-sec average / session max.
#
# No CSV logging.
# ============================================================

INTERVAL=1
AVG_SECONDS=5
MAX_SAMPLES=$((AVG_SECONDS / INTERVAL))

# Dynamic maximum charging current seen during this session
max_avg_current_ua=0

# Peak instantaneous current
peak_current_ua=0

declare -a samples=()

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

get_battery_value() {
    adb shell dumpsys battery 2>/dev/null |
        sed 's/\r//' |
        grep -m1 -E "^[[:space:]]*$1:" |
        sed -E 's/^[[:space:]]*[^:]+:[[:space:]]*//'
}

get_current() {
    adb shell cat /sys/class/power_supply/battery/current_now 2>/dev/null
}

# ------------------------------------------------------------
# Check ADB
# ------------------------------------------------------------

if ! adb get-state >/dev/null 2>&1; then
    echo "ERROR: Pixel 8a not connected through ADB."
    echo
    echo "Check with:"
    echo "  adb devices"
    exit 1
fi

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------

while true; do

    # ========================================================
    # Read current
    # ========================================================

    raw_current=$(get_current)

    if ! [[ "$raw_current" =~ ^-?[0-9]+$ ]]; then
        raw_current=0
    fi

    current_a=$(awk \
        "BEGIN {printf \"%.3f\", $raw_current / 1000000}")

    abs_current=$(awk \
        "BEGIN {
            v=$raw_current/1000000
            if(v<0)v=-v
            printf \"%.3f\",v
        }")

    # ========================================================
    # Read battery information
    # ========================================================

    wireless=$(get_battery_value "Wireless powered")
    status=$(get_battery_value "status")
    level=$(get_battery_value "level")
    voltage_mv=$(get_battery_value "voltage")
    temperature_raw=$(get_battery_value "temperature")

    max_current_raw=$(get_battery_value "Max charging current")
    max_voltage_raw=$(get_battery_value "Max charging voltage")

    # ========================================================
    # Validate values
    # ========================================================

    [[ "$level" =~ ^[0-9]+$ ]] || level=0
    [[ "$voltage_mv" =~ ^[0-9]+$ ]] || voltage_mv=0
    [[ "$temperature_raw" =~ ^[0-9]+$ ]] || temperature_raw=0
    [[ "$max_current_raw" =~ ^[0-9]+$ ]] || max_current_raw=0
    [[ "$max_voltage_raw" =~ ^[0-9]+$ ]] || max_voltage_raw=0

    temperature=$(awk \
        "BEGIN {printf \"%.1f\", $temperature_raw / 10}")

    voltage=$(awk \
        "BEGIN {printf \"%.3f\", $voltage_mv / 1000}")

    max_current=$(awk \
        "BEGIN {printf \"%.3f\", $max_current_raw / 1000000}")

    max_voltage=$(awk \
        "BEGIN {printf \"%.2f\", $max_voltage_raw / 1000000}")

    # ========================================================
    # Determine charging state
    #
    # Pixel 8a:
    #   status 2 = CHARGING
    #   status 3 = DISCHARGING
    #   status 4 = NOT CHARGING
    #   status 5 = FULL
    # ========================================================

    charging=false

    if [[ "$raw_current" -gt 0 ]] &&
       [[ "$wireless" == "true" ]] &&
       [[ "$status" == "2" ]]; then
        charging=true
    fi

    # ========================================================
    # Charging sample history
    # ========================================================

    if $charging; then

        samples+=("$raw_current")

        if (( ${#samples[@]} > MAX_SAMPLES )); then
            samples=("${samples[@]:1}")
        fi

        # ----------------------------------------------------
        # Calculate 5-second average
        # ----------------------------------------------------

        sum=0

        for value in "${samples[@]}"; do
            sum=$((sum + value))
        done

        sample_count=${#samples[@]}

        avg_current_ua=$((sum / sample_count))

        avg_current=$(awk \
            "BEGIN {printf \"%.3f\", $avg_current_ua / 1000000}")

        # ----------------------------------------------------
        # Dynamic maximum
        #
        # Highest 5-second average seen this session.
        # ----------------------------------------------------

        if (( avg_current_ua > max_avg_current_ua )); then
            max_avg_current_ua=$avg_current_ua
        fi

        max_avg_current=$(awk \
            "BEGIN {printf \"%.3f\", $max_avg_current_ua / 1000000}")

        # ----------------------------------------------------
        # Instantaneous peak
        # ----------------------------------------------------

        if (( raw_current > peak_current_ua )); then
            peak_current_ua=$raw_current
        fi

        peak_current=$(awk \
            "BEGIN {printf \"%.3f\", $peak_current_ua / 1000000}")

    else

        samples=()
        avg_current_ua=0
        avg_current=0

        # Don't reset max_avg_current_ua.
        # It survives temporary disconnects during this run.

        max_avg_current=$(awk \
            "BEGIN {printf \"%.3f\", $max_avg_current_ua / 1000000}")

    fi

    # ========================================================
    # Power
    # ========================================================

    instant_power=$(awk \
        "BEGIN {
            printf \"%.2f\",
            ($raw_current/1000000) * ($voltage_mv/1000)
        }")

    avg_power=$(awk \
        "BEGIN {
            printf \"%.2f\",
            ($avg_current_ua/1000000) * ($voltage_mv/1000)
        }")

    # ========================================================
    # Dynamic position quality
    #
    # 100% = best average measured this session
    # ========================================================

    if $charging && (( max_avg_current_ua > 0 )); then

        quality_percent=$(awk \
            "BEGIN {
                q=($avg_current_ua/$max_avg_current_ua)*100
                if(q>100)q=100
                if(q<0)q=0
                printf \"%d\",q+0.5
            }")

        # 70 character bar
        filled=$(awk \
            "BEGIN {
                printf \"%d\",
                ($avg_current_ua/$max_avg_current_ua)*70
            }")

        (( filled < 0 )) && filled=0
        (( filled > 70 )) && filled=70

        empty=$((70-filled))

        bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
        bar="$bar$(printf '%*s' "$empty" '' | tr ' ' '.')"

        # Text classification
        if (( quality_percent >= 95 )); then
            quality="EXCELLENT"
        elif (( quality_percent >= 85 )); then
            quality="VERY GOOD"
        elif (( quality_percent >= 70 )); then
            quality="GOOD"
        elif (( quality_percent >= 50 )); then
            quality="FAIR"
        elif (( quality_percent >= 30 )); then
            quality="POOR"
        else
            quality="VERY POOR"
        fi

    else

        quality_percent=0
        quality="NOT CHARGING"
        bar="......................................................................"

    fi

    # ========================================================
    # Status
    # ========================================================

    if $charging; then

        charge_status="CHARGING"
        wireless_status="YES"

    else

        wireless_status="NO"

        case "$status" in
            3)
                charge_status="DISCHARGING"
                ;;
            4)
                charge_status="NOT CHARGING"
                ;;
            5)
                charge_status="FULL"
                ;;
            *)
                charge_status="UNKNOWN"
                ;;
        esac

    fi

    # ========================================================
    # Clear screen
    # ========================================================

    printf '\033[2J\033[H'

    # ========================================================
    # Display
    # ========================================================

    echo "======================================================================"
    echo "                 PIXEL 8a WIRELESS CHARGE MONITOR"
    echo "======================================================================"
    echo

    printf "Charging     : %-14s Wireless: %s\n" \
        "$charge_status" "$wireless_status"

    printf "Battery      : %3s %%          Temperature: %5s °C\n" \
        "$level" "$temperature"

    printf "Voltage      : %5s V\n" "$voltage"

    echo
    echo "----------------------------------------------------------------------"
    echo

    if $charging; then

        echo "ACTUAL BATTERY CHARGING CURRENT"
        echo "Average : ${AVG_SECONDS} seconds"
        echo

        printf "[%s]\n" "$bar"

        printf "                    %.3f A\n" \
            "$avg_current"

        echo
        printf "Instant      : %6.3f A       %5.2f W\n" \
            "$current_a" "$instant_power"

        printf "5-sec average: %6.3f A       %5.2f W\n" \
            "$avg_current" "$avg_power"

        printf "Peak         : %6.3f A\n" \
            "$peak_current"

    else

        echo "BATTERY CONSUMPTION"
        echo

        printf "Current draw : %6.3f A\n" \
            "$abs_current"

        printf "Power draw   : %6.2f W\n" \
            "$(awk "BEGIN {
                printf \"%.2f\",
                $abs_current * ($voltage_mv/1000)
            }")"

        echo
        echo "Charging current: N/A"

    fi

    echo
    echo "----------------------------------------------------------------------"
    echo

    echo "ANDROID CHARGING LIMITS"
    echo

    if [[ "$max_current_raw" -gt 0 ]]; then
        printf "Reported max : %6.3f A\n" "$max_current"
    else
        echo "Reported max : N/A"
    fi

    if [[ "$max_voltage_raw" -gt 0 ]]; then
        printf "Max voltage  : %6.2f V\n" "$max_voltage"
    else
        echo "Max voltage  : N/A"
    fi

    echo
    echo "----------------------------------------------------------------------"
    echo

    echo "DYNAMIC POSITION REFERENCE"
    echo

    printf "Session max  : %6.3f A  (best 5-sec average)\n" \
        "$max_avg_current"

    if $charging; then
        printf "Current       : %6.3f A\n" \
            "$avg_current"

        printf "Position      : %3d %%  %s\n" \
            "$quality_percent" "$quality"

        echo
        printf "[%s]\n" "$bar"
    else
        echo "Position      : N/A (not charging)"
        echo
        echo "[......................................................................]"
    fi

    echo
    echo "----------------------------------------------------------------------"
    echo
    echo "Reference resets when this script is restarted."
    echo "Press Ctrl+C to exit."
    echo

    sleep "$INTERVAL"

done