#!/usr/bin/env bash
# ==========================================
# Real-Time Network Info & Rate (Checkmk)
# Format Template: OK - IP Address | Total | Rate
# ==========================================

declare -A RX_OLD
declare -A TX_OLD
declare -A IP_ADDR

# ------------------------------------------
# FASE 1: Ambil Data Awal
# ------------------------------------------
for IFACE in $(ls /sys/class/net/ | grep -v "^lo$"); do
    STATE=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)
    if [ "$STATE" == "up" ]; then
        RX_OLD[$IFACE]=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        TX_OLD[$IFACE]=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
        
        # Ekstrak IP Address
        IP_ADDR[$IFACE]=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
    fi
done

# ------------------------------------------
# FASE 2: Jeda 1 Detik
# ------------------------------------------
sleep 1

# ------------------------------------------
# FASE 3: Kalkulasi, Konversi & Output
# ------------------------------------------
for IFACE in "${!RX_OLD[@]}"; do
    RX_NEW=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    TX_NEW=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)

    # 1. Hitung Kecepatan (Rate)
    RX_RATE=$((RX_NEW - RX_OLD[$IFACE]))
    TX_RATE=$((TX_NEW - TX_OLD[$IFACE]))

    [ "$RX_RATE" -lt 0 ] && RX_RATE=0
    [ "$TX_RATE" -lt 0 ] && TX_RATE=0

    # 2. Format Human-Readable untuk Total Download & Upload
    RX_TOTAL_HR=$(awk -v b="$RX_NEW" 'BEGIN { 
        if(b>=1073741824) printf "%.2f GB", b/1073741824; 
        else if(b>=1048576) printf "%.2f MB", b/1048576; 
        else printf "%.2f KB", b/1024; 
    }')
    TX_TOTAL_HR=$(awk -v b="$TX_NEW" 'BEGIN { 
        if(b>=1073741824) printf "%.2f GB", b/1073741824; 
        else if(b>=1048576) printf "%.2f MB", b/1048576; 
        else printf "%.2f KB", b/1024; 
    }')

    # 3. Format Human-Readable untuk RX & TX Rate
    RX_RATE_HR=$(awk -v b="$RX_RATE" 'BEGIN { 
        if(b>=1048576) printf "%.2f MB/s", b/1048576; 
        else if(b>=1024) printf "%.2f KB/s", b/1024; 
        else printf "%d B/s", b; 
    }')
    TX_RATE_HR=$(awk -v b="$TX_RATE" 'BEGIN { 
        if(b>=1048576) printf "%.2f MB/s", b/1048576; 
        else if(b>=1024) printf "%.2f KB/s", b/1024; 
        else printf "%d B/s", b; 
    }')

    # 4. Validasi IP
    IP=${IP_ADDR[$IFACE]}
    [ -z "$IP" ] && IP="No IP"

    # 5. Cetak Output sesuai Template yang diminta
    echo "0 \"Info_Network_$IFACE\" in=${RX_NEW}c|out=${TX_NEW}c OK - IP Address: $IP | Total Download: $RX_TOTAL_HR | Total Upload: $TX_TOTAL_HR | RX Rate : $RX_RATE_HR | TX Rate : $TX_RATE_HR"
done
