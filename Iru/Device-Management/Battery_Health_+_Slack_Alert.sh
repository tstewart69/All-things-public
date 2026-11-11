#!/bin/bash

# Slack webhook URL — replace with your actual webhook
SLACK_WEBHOOK_URL=""

# Get the maximum capacity, cycle count, and current condition
MAX_CAPACITY=$(system_profiler SPPowerDataType | grep "Maximum Capacity:" | awk '{print $3}' | tr -d '%')
CYCLE_COUNT=$(system_profiler SPPowerDataType | grep "Cycle Count:" | awk '{print $3}')
CONDITION=$(system_profiler SPPowerDataType | grep "Condition:" | awk -F': ' '{print $2}' | xargs)

# Get hostname and serial for context in the alert
HOSTNAME=$(scutil --get ComputerName)
SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}')
USER_NAME=$(stat -f%Su /dev/console)

# Output the results in a structured format for easy review
echo "Hostname: $HOSTNAME"
echo "Serial: $SERIAL"
echo "User: $USER_NAME"
echo "Max_Capacity: $MAX_CAPACITY%"
echo "Cycle_Count: $CYCLE_COUNT"
echo "Condition: $CONDITION"

# Determine whether an alert should be sent
ALERT_REASON=""

if [[ -n "$MAX_CAPACITY" && "$MAX_CAPACITY" -le 75 ]]; then
    ALERT_REASON="Max capacity at ${MAX_CAPACITY}% (≤75%)"
fi

if [[ "$CONDITION" == *"Replace"* || "$CONDITION" == *"Service"* ]]; then
    if [[ -n "$ALERT_REASON" ]]; then
        ALERT_REASON="$ALERT_REASON; Condition: $CONDITION"
    else
        ALERT_REASON="Condition: $CONDITION"
    fi
fi

# Send Slack notification if any threshold was tripped
if [[ -n "$ALERT_REASON" ]]; then
    PAYLOAD=$(cat <<EOF
{
  "text": ":battery: *Battery health alert*\n*Host:* ${HOSTNAME}\n*Serial:* ${SERIAL}\n*User:* ${USER_NAME}\n*Max Capacity:* ${MAX_CAPACITY}%\n*Cycle Count:* ${CYCLE_COUNT}\n*Condition:* ${CONDITION}\n*Reason:* ${ALERT_REASON}"
}
EOF
)

    curl -s -X POST -H 'Content-type: application/json' \
        --data "$PAYLOAD" \
        "$SLACK_WEBHOOK_URL" > /dev/null

    echo "Slack alert sent: $ALERT_REASON"
fi

exit 0
