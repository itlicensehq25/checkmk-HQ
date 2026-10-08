#!/usr/bin/env bash
# =====================================================================
# Local Check Checkmk: Daily Battery Health Monitor
# Scheduled to run once a day at 16:00
# =====================================================================
CACHE_DIR="/var/lib/check_mk_agent/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_FILE="$CACHE_DIR/cache_battery_health.txt"

CURRENT_HOUR=$(date +%H)
TODAY_16=$(date -d "16:00:00" +%s 2>/dev/null)

if [ -z "$TODAY_16" ]; then
    TODAY_16=$(date +%s -d "16:00:00" 2>/dev/null)
fi

if [ "$CURRENT_HOUR" -lt 16 ]; then
    LAST_16=$(date -d "yesterday 16:00:00" +%s 2>/dev/null)
else
    LAST_16=$TODAY_16
fi

if [ -z "$LAST_16" ]; then
    LAST_16=$(( TODAY_16 - 86400 ))
fi

need_update() {
    local file=$1
    local threshold=$2
    if [ ! -f "$file" ]; then
        return 0
    fi
    local file_ts
    file_ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if [ "$file_ts" -lt "$threshold" ]; then
        return 0
    fi
    return 1
}

if need_update "$CACHE_FILE" "$LAST_16"; then
    > "$CACHE_FILE"
    
    has_battery=false
    bat_path=""
    
    if command -v upower >/dev/null 2>&1; then
        bat_path=$(upower -e 2>/dev/null | grep -i "battery" | head -n 1)
        if [ -n "$bat_path" ]; then
            has_battery=true
        fi
    fi
    
    state="Fully Charged"
    design_wh=0
    full_wh=0
    health=100
    bat_level=100

    if [ "$has_battery" = true ]; then
        bat_info=$(upower -i "$bat_path" 2>/dev/null)
        state_raw=$(echo "$bat_info" | grep -i "state:" | cut -d":" -f2 | xargs)
        
        case "$state_raw" in
            "fully-charged") state="Fully Charged" ;;
            "discharging")   state="Discharging" ;;
            "charging")      state="Charging" ;;
            *)               state="Fully Charged" ;;
        esac

        e_design_str=$(echo "$bat_info" | grep -i "energy-full-design:" | awk "{print \$2}")
        e_full_str=$(echo "$bat_info" | grep -i "energy-full:" | awk "{print \$2}")
        pct_str=$(echo "$bat_info" | grep -i "percentage:" | grep -o -E "[0-9.]+" | head -n1)

        [ -n "$pct_str" ] && bat_level=$(awk "BEGIN {print int($pct_str)}")

        if [ -n "$e_design_str" ] && [ -n "$e_full_str" ]; then
            design_wh=$(awk "BEGIN {print int($e_design_str)}")
            full_wh=$(awk "BEGIN {print int($e_full_str)}")
            if [ "$design_wh" -gt 0 ]; then
                health=$(awk "BEGIN {print int(($e_full_str / $e_design_str) * 100)}")
            fi
        fi
    else
        # Fallback to Sysfs
        sys_bat_dir=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n 1)
        if [ -n "$sys_bat_dir" ]; then
            has_battery=true
            state_raw=$(cat "$sys_bat_dir/status" 2>/dev/null | tr "A-Z" "a-z")
            case "$state_raw" in
                "full"|"fully-charged") state="Fully Charged" ;;
                "discharging")          state="Discharging" ;;
                "charging")             state="Charging" ;;
                *)                      state="Fully Charged" ;;
            esac

            bat_level=$(cat "$sys_bat_dir/capacity" 2>/dev/null || echo "100")
            
            ef_design=$(cat "$sys_bat_dir/energy_full_design" 2>/dev/null || cat "$sys_bat_dir/charge_full_design" 2>/dev/null || echo 0)
            ef_now=$(cat "$sys_bat_dir/energy_full" 2>/dev/null || cat "$sys_bat_dir/charge_full" 2>/dev/null || echo 0)

            if [ "$ef_design" -gt 0 ] 2>/dev/null; then
                design_wh=$(( ef_design / 1000000 ))
                full_wh=$(( ef_now / 1000000 ))
                [ "$design_wh" -eq 0 ] && design_wh=1
                health=$(awk "BEGIN {print int(($ef_now / $ef_design) * 100)}")
            fi
        fi
    fi

    if [ "$has_battery" = true ]; then
        status=0
        if [ "$health" -le 20 ]; then
            status=2
        elif [ "$health" -le 40 ]; then
            status=1
        fi

        echo "$status "Health_Battery" -  Status Battery : $state | Design Capacity : ${design_wh}w/h | Current Capacity :  ${full_wh}w/h | Health : ${health}% | Battery Level : ${bat_level}%" >> "$CACHE_FILE"
    else
        echo "0 "Health_Battery" -  Status Battery : N/A | Device is PC/Desktop, there is no battery." >> "$CACHE_FILE"
    fi
fi

cat "$CACHE_FILE" 2>/dev/null
