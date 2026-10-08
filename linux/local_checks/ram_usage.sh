#!/usr/bin/env bash
# ==============================================================================
# Local Check Checkmk: RAM Usage (Physical RAM Utilization)
# OK: < 85% | Warning: >= 85% | Critical: >= 95%
# ==============================================================================

WARN=85
CRIT=95

if [ -f /proc/meminfo ]; then
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        mem_used=$((mem_total - mem_avail))
        pct=$((mem_used * 100 / mem_total))
        
        total_gb=$(awk "BEGIN {printf \"%.2f\", $mem_total/1024/1024}")
        used_gb=$(awk "BEGIN {printf \"%.2f\", $mem_used/1024/1024}")
        free_gb=$(awk "BEGIN {printf \"%.2f\", $mem_avail/1024/1024}")
    else
        # Fallback to free command
        total_gb_int=$(free -g | awk '/^Mem:/{print $2}')
        used_gb_int=$(free -g | awk '/^Mem:/{print $3}')
        free_gb_int=$(free -g | awk '/^Mem:/{print $4}')
        pct=$((used_gb_int * 100 / total_gb_int))
        total_gb=$(printf "%.2f" "$total_gb_int")
        used_gb=$(printf "%.2f" "$used_gb_int")
        free_gb=$(printf "%.2f" "$free_gb_int")
    fi
else
    # Fallback for systems without /proc/meminfo
    total_gb_int=$(free -g | awk '/^Mem:/{print $2}')
    used_gb_int=$(free -g | awk '/^Mem:/{print $3}')
    free_gb_int=$(free -g | awk '/^Mem:/{print $4}')
    pct=$((used_gb_int * 100 / total_gb_int))
    total_gb=$(printf "%.2f" "$total_gb_int")
    used_gb=$(printf "%.2f" "$used_gb_int")
    free_gb=$(printf "%.2f" "$free_gb_int")
fi

# Determine status
status=0
status_txt="OK"
if [ "$pct" -ge "$CRIT" ]; then
    status=2
    status_txt="Critical"
elif [ "$pct" -ge "$WARN" ]; then
    status=1
    status_txt="Warning"
fi

# Output in clean Checkmk format using unicode vertical bar ❘
echo "$status \"Info_RAM_Usage\" - Status : $status_txt ❘ Used: ${pct}% ❘ Used Space: ${used_gb} GB ❘ Free: ${free_gb} GB ❘ Total: ${total_gb} GB"
