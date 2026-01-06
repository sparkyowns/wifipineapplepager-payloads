#!/bin/bash
# Title: External MediaTek Loader (Auto-Detect
# Version: 2.0

set -u

# --- Configuration ---
# MediaTek 7612u/7610u ID
MTK_VID="0e8d"
MTK_PID="7961"

# Target Settings
EXT_RADIO="radio2"
EXT_IFACE="wlan2mon"
EXT_CONFIG_SECTION="default_radio2"

# --- Helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
log_y() { have LOG && LOG yellow "$1" || echo -e "\033[33m[*] $1\033[0m"; }
log_g() { have LOG && LOG green  "$1" || echo -e "\033[32m[+] $1\033[0m"; }
err() {
  if have ERROR_DIALOG; then ERROR_DIALOG "$1"; else echo "ERROR: $1" >&2; fi
  exit 1
}

# ==========================================
# 1. SMART DETECTION & FILTERING
# ==========================================

log_y "Scanning for External MediaTek ($MTK_VID:$MTK_PID)..."

# A. Build Blocklist (Identify Internal Radio Path)
# We find where wlan0/wlan1 live so we NEVER touch them.
INTERNAL_BLOCKLIST=""
for iface in wlan0 wlan1 wlan0mon wlan1mon; do
    if [ -e "/sys/class/net/$iface/device" ]; then
        RP=$(readlink -f "/sys/class/net/$iface/device")
        INTERNAL_BLOCKLIST="$INTERNAL_BLOCKLIST $RP"
    fi
done

SELECTED_PATH=""
SELECTED_EP_ID=""
HIGHEST_SCORE=-1

# B. Scan All USB Devices
for dev in /sys/bus/usb/devices/*; do
    if [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ]; then
        VID=$(cat "$dev/idVendor")
        PID=$(cat "$dev/idProduct")

        # Match MediaTek ID
        if [ "$VID" == "$MTK_VID" ] && [ "$PID" == "$MTK_PID" ]; then
            
            FULL_DEV_PATH=$(readlink -f "$dev")
            
            # Check Blocklist: Skip if this is the internal radio
            IS_INTERNAL=0
            for int_path in $INTERNAL_BLOCKLIST; do
                if [[ "$int_path" == *"$FULL_DEV_PATH"* ]]; then
                    IS_INTERNAL=1
                    break
                fi
            done
            
            if [ "$IS_INTERNAL" -eq 1 ]; then
                continue
            fi

            # C. Endpoint Selection Logic (King of the Hill)
            # We look at all endpoints to find the best injection interface
            for endpoint_dir in "$dev":*; do
                if [ -f "$endpoint_dir/bInterfaceClass" ]; then
                    CLASS=$(cat "$endpoint_dir/bInterfaceClass")
                    
                    # Score the endpoint
                    CURRENT_SCORE=0
                    
                    # Class ff (Vendor Specific) is Gold (Score 20)
                    if [ "$CLASS" == "ff" ]; then
                        CURRENT_SCORE=20
                    # Class e0 (Wireless) is Silver (Score 10)
                    elif [ "$CLASS" == "e0" ]; then
                        CURRENT_SCORE=10
                    else
                        # Skip Storage (08), Hubs (09), etc.
                        continue
                    fi
                    
                    # Add endpoint number to score (Higher index = better tiebreaker)
                    EP_ID=$(echo "$endpoint_dir" | awk -F: '{print $NF}') # "1.3"
                    EP_NUM=$(echo "$EP_ID" | awk -F. '{print $2}')       # "3"
                    
                    FINAL_SCORE=$((CURRENT_SCORE + EP_NUM))
                    
                    if [ "$FINAL_SCORE" -gt "$HIGHEST_SCORE" ]; then
                        HIGHEST_SCORE=$FINAL_SCORE
                        SELECTED_PATH="$endpoint_dir"
                        SELECTED_EP_ID="$EP_ID"
                    fi
                fi
            done
        fi
    fi
done

# ==========================================
# 2. NO DEVICE FOUND -> DISABLE LOGIC
# ==========================================
if [ -z "$SELECTED_PATH" ]; then
    log_y "No External MediaTek Radio found."
    log_y "Cleaning up: Disabling External Radio Config..."
    
    # Disable Wireless
    uci set wireless.${EXT_RADIO}.disabled='1'
    uci set wireless.${EXT_CONFIG_SECTION}.disabled='1'
    
    # Disable PineAP usage
    uci set pineapd.${EXT_IFACE}.disable='1'
    uci set pineapd.${EXT_IFACE}.primary='0'
    uci set pineapd.${EXT_IFACE}.inject='0'

    uci commit wireless
    uci commit pineapd
    
    log_y "Reloading services..."
    wifi reload && service pineapd restart
    
    exit 0
fi

# ==========================================
# 3. DEVICE FOUND -> CONFIGURE
# ==========================================

log_g "Target Acquired: Endpoint $SELECTED_EP_ID"

# Prepare Path (Strip /sys/devices/ prefix)
UCI_PATH=$(readlink -f "$SELECTED_PATH" | sed 's#^/sys/devices/##')
log_y "Binding $EXT_RADIO to: $UCI_PATH"

# 1. Radio Device
uci set wireless.${EXT_RADIO}=wifi-device
uci set wireless.${EXT_RADIO}.type='mac80211'
uci set wireless.${EXT_RADIO}.path="${UCI_PATH}"
uci set wireless.${EXT_RADIO}.band='5g'
uci set wireless.${EXT_RADIO}.channel='auto'
uci set wireless.${EXT_RADIO}.htmode='VHT80'
uci set wireless.${EXT_RADIO}.disabled='0'

# 2. Interface (default_radio2)
uci set wireless.${EXT_CONFIG_SECTION}=wifi-iface
uci set wireless.${EXT_CONFIG_SECTION}.device="${EXT_RADIO}"
uci set wireless.${EXT_CONFIG_SECTION}.ifname="${EXT_IFACE}"
uci set wireless.${EXT_CONFIG_SECTION}.mode='monitor'
uci set wireless.${EXT_CONFIG_SECTION}.disabled='0'

uci commit wireless

# ==========================================
# 4. RELOAD & WAIT
# ==========================================

log_y "Reloading WiFi..."
wifi reload

log_y "Waiting for driver to attach..."
# Loop check for up to 15 seconds
MAX_RETRIES=15
COUNT=0
DRIVER_LOADED=0

while [ $COUNT -lt $MAX_RETRIES ]; do
    if [ -d "/sys/class/net/${EXT_IFACE}" ]; then
        DRIVER_LOADED=1
        break
    fi
    sleep 1
    COUNT=$((COUNT+1))
done

if [ $DRIVER_LOADED -eq 0 ]; then
    err "Driver Timeout!
    The system attempted to load endpoint $SELECTED_EP_ID.
    Please check dmesg for errors."
fi

# ==========================================
# 5. FINAL SETUP & MIRRORING
# ==========================================

DRV=$(ethtool -i ${EXT_IFACE} 2>/dev/null | grep driver | cut -d' ' -f2)
log_g "Success! Driver: $DRV"

# Determine Internal Bands for Mirroring
INT_IFACE="wlan1mon"
[ ! -d "/sys/class/net/$INT_IFACE" ] && INT_IFACE="wlan1"
CURRENT_BANDS=$(uci -q get pineapd.${INT_IFACE}.bands)
[ -z "$CURRENT_BANDS" ] && CURRENT_BANDS="2,5"

# Configure PineAP
uci set pineapd.${EXT_IFACE}.disable='0'
uci set pineapd.${EXT_IFACE}.primary='0'
uci set pineapd.${EXT_IFACE}.inject='0'
uci set pineapd.${EXT_IFACE}.hop='1'
uci set pineapd.${EXT_IFACE}.bands="$CURRENT_BANDS"
uci commit pineapd

service pineapd restart
log_g "DONE."
