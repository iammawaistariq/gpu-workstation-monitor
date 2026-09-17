#!/bin/bash

########################################
# GPU Guardian
# Portable system-level version
########################################

REAL_USER="${SUDO_USER:-${USER:-root}}"

if [[ "$REAL_USER" == "root" ]]; then
    REAL_HOME="/root"
else
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
fi

# When started by systemd, use the installation path supplied by installer.
LOG_DIR="${GPU_MONITOR_LOG_DIR:-${REAL_HOME}/gpu-monitoring/logs/guardian}"
LOG="$LOG_DIR/guardian.log"

DRY_RUN=true

GPU_STATE="NORMAL"

ALERT_COOLDOWN=60
LAST_ALERT_TIME=0


########################################
# Prepare logging
########################################

mkdir -p "$LOG_DIR"
touch "$LOG"


########################################
# Find active graphical user
########################################

get_active_user()
{
    ACTIVE_USER=""
    ACTIVE_UID=""
    ACTIVE_DISPLAY=""

    while read -r SESSION UID USER SEAT TTY
    do
        [ -z "$SESSION" ] && continue

        ACTIVE=$(loginctl show-session "$SESSION" -p Active --value 2>/dev/null)
        TYPE=$(loginctl show-session "$SESSION" -p Type --value 2>/dev/null)

        if [ "$ACTIVE" = "yes" ] && \
           { [ "$TYPE" = "x11" ] || [ "$TYPE" = "wayland" ]; }; then

            ACTIVE_USER="$USER"
            ACTIVE_UID="$UID"

            ACTIVE_DISPLAY=$(loginctl show-session "$SESSION" \
                -p Display --value 2>/dev/null)

            [ -z "$ACTIVE_DISPLAY" ] && ACTIVE_DISPLAY=":0"

            return 0
        fi

    done < <(loginctl list-sessions --no-legend 2>/dev/null)

    return 1
}


########################################
# Desktop notification
########################################

desktop_notify()
{
    URGENCY="$1"
    TIMEOUT="$2"
    TITLE="$3"
    BODY="$4"

    if ! get_active_user; then
        echo "$(date) NOTIFICATION SKIPPED - no active graphical user" >> "$LOG"
        return
    fi

    if ! command -v notify-send >/dev/null 2>&1; then
        echo "$(date) NOTIFICATION SKIPPED - notify-send unavailable" >> "$LOG"
        return
    fi

    sudo -u "$ACTIVE_USER" \
        env \
        DISPLAY="$ACTIVE_DISPLAY" \
        XDG_RUNTIME_DIR="/run/user/$ACTIVE_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$ACTIVE_UID/bus" \
        notify-send \
        -u "$URGENCY" \
        -t "$TIMEOUT" \
        "$TITLE" \
        "$BODY" \
        >/dev/null 2>&1
}


########################################
# Send alert with cooldown
########################################

send_alert()
{
    LEVEL="$1"
    MESSAGE="$2"

    NOW=$(date +%s)
    TIME_DIFF=$((NOW - LAST_ALERT_TIME))

    if [ "$TIME_DIFF" -lt "$ALERT_COOLDOWN" ]; then
        echo "$(date) ALERT SUPPRESSED [$LEVEL] cooldown active" >> "$LOG"
        return
    fi

    LAST_ALERT_TIME=$NOW

    echo "$(date) ALERT [$LEVEL] $MESSAGE" >> "$LOG"

    case "$LEVEL" in

        EMERGENCY)
            desktop_notify \
                critical \
                15000 \
                "🚨 GPU GUARDIAN EMERGENCY" \
                "$MESSAGE"
            ;;

        CRITICAL_WARNING)
            desktop_notify \
                critical \
                8000 \
                "⚠ GPU CRITICAL WARNING" \
                "$MESSAGE"
            ;;

        WARNING)
            desktop_notify \
                normal \
                5000 \
                "⚠ GPU WARNING" \
                "$MESSAGE"
            ;;

    esac
}


########################################
# Find largest heavy GPU workload
########################################

find_gpu_target()
{
    TARGET_PID=""
    TARGET_MEMORY=0
    TARGET_CMD=""
    TARGET_USER=""

    while IFS=',' read -r PID MEMORY PROCESS
    do

        PID=$(echo "$PID" | xargs)
        MEMORY=$(echo "$MEMORY" | xargs)
        PROCESS=$(echo "$PROCESS" | xargs)

        MEM_VALUE=$(echo "$MEMORY" | awk '{print $1}')

        [ -z "$PID" ] && continue
        [ -z "$MEM_VALUE" ] && continue

        # Ignore small desktop GPU allocations
        if [ "$MEM_VALUE" -lt 500 ]; then
            continue
        fi

        if [ "$MEM_VALUE" -gt "$TARGET_MEMORY" ]; then

            TARGET_MEMORY="$MEM_VALUE"
            TARGET_PID="$PID"
            TARGET_CMD="$PROCESS"
            TARGET_USER=$(ps -o user= -p "$PID" 2>/dev/null | xargs)

        fi

    done < <(
        nvidia-smi \
        --query-compute-apps=pid,used_memory,process_name \
        --format=csv,noheader,nounits 2>/dev/null
    )

    if [ -n "$TARGET_PID" ]; then

        TARGET_CMD=$(ps -p "$TARGET_PID" -o args= 2>/dev/null)

        echo "$(date) EMERGENCY TARGET USER=$TARGET_USER PID=$TARGET_PID MEMORY=${TARGET_MEMORY}MiB" >> "$LOG"
        echo "$(date) TARGET COMMAND=$TARGET_CMD" >> "$LOG"

    else

        echo "$(date) NO HEAVY GPU TARGET FOUND" >> "$LOG"

    fi
}


########################################
# Startup checks
########################################

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "$(date) ERROR nvidia-smi not found" >> "$LOG"
    exit 1
fi


echo "$(date) GPU Guardian daemon started" >> "$LOG"


########################################
# Main monitoring loop
########################################

while true
do

    ####################################
    # Read GPU statistics
    ####################################

    TEMP=$(nvidia-smi \
        --query-gpu=temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    POWER=$(nvidia-smi \
        --query-gpu=power.draw \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    VRAM=$(nvidia-smi \
        --query-gpu=memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1)


    # Skip iteration if NVIDIA returned invalid data
    if [ -z "$TEMP" ] || [ -z "$POWER" ] || [ -z "$VRAM" ]; then

        echo "$(date) ERROR unable to read GPU metrics" >> "$LOG"

        sleep 5
        continue

    fi


    USED=$(echo "$VRAM" | awk -F',' '{print $1}' | xargs)
    TOTAL=$(echo "$VRAM" | awk -F',' '{print $2}' | xargs)

    VRAM_PERCENT=$((USED * 100 / TOTAL))

    POWER_INT=${POWER%.*}


    echo "$(date) TEMP=${TEMP}C POWER=${POWER}W VRAM=${VRAM_PERCENT}%" >> "$LOG"


    ####################################
    # Determine safety state
    ####################################

    OLD_STATE="$GPU_STATE"


    # EMERGENCY
    if [ "$TEMP" -ge 90 ] || \
       [ "$VRAM_PERCENT" -ge 98 ]; then

        GPU_STATE="EMERGENCY"


    # CRITICAL WARNING
    elif [ "$TEMP" -ge 87 ] || \
         [ "$VRAM_PERCENT" -ge 95 ] || \
         [ "$POWER_INT" -ge 72 ]; then

        GPU_STATE="CRITICAL_WARNING"


    # WARNING
    elif [ "$TEMP" -ge 85 ] || \
         [ "$VRAM_PERCENT" -ge 85 ] || \
         [ "$POWER_INT" -ge 70 ]; then

        GPU_STATE="WARNING"


    else

        GPU_STATE="NORMAL"

    fi


    ####################################
    # State-change handling
    ####################################

    if [ "$GPU_STATE" != "$OLD_STATE" ]; then

        echo "$(date) STATE CHANGE: $OLD_STATE -> $GPU_STATE" >> "$LOG"


        case "$GPU_STATE" in

            WARNING)

                send_alert \
                "WARNING" \
                "GPU entered warning range.

Temperature: ${TEMP}C
Power: ${POWER}W
GPU Memory: ${VRAM_PERCENT}%

Workload may continue, but GPU conditions should be monitored."
                ;;


            CRITICAL_WARNING)

                send_alert \
                "CRITICAL_WARNING" \
                "GPU entered the critical warning range.

Temperature: ${TEMP}C
Power: ${POWER}W
GPU Memory: ${VRAM_PERCENT}%

The system is approaching automatic protection."
                ;;


            NORMAL)

                echo "$(date) GPU returned to NORMAL state" >> "$LOG"
                ;;

        esac
    fi


    ####################################
    # Emergency handling
    ####################################

    if [ "$GPU_STATE" = "EMERGENCY" ]; then

        find_gpu_target


        if [ -n "$TARGET_PID" ]; then

            send_alert \
                "EMERGENCY" \
                "GPU emergency condition detected.

Temperature: ${TEMP}C
Power: ${POWER}W
GPU Memory: ${VRAM_PERCENT}%

Highest GPU workload:
User: ${TARGET_USER}
PID: ${TARGET_PID}
GPU Memory: ${TARGET_MEMORY} MiB

Automatic protection is preparing to stop this workload."

        else

            send_alert \
                "EMERGENCY" \
                "GPU emergency condition detected.

Temperature: ${TEMP}C
Power: ${POWER}W
GPU Memory: ${VRAM_PERCENT}%

No heavy GPU workload was identified."

        fi


        ################################
        # Protection mode
        ################################

        if [ "$DRY_RUN" = true ]; then

            echo "$(date) DRY RUN ACTIVE - NO PROCESS TERMINATED" >> "$LOG"

        else

            # Automatic termination intentionally disabled
            # until deployment testing is complete.
            echo "$(date) PROTECTION ACTION NOT IMPLEMENTED" >> "$LOG"

        fi
    fi


    sleep 5

done
