#!/bin/bash

SERIAL_NUMBER=$(system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}')

logged_in_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && !/loginwindow/ { print $3 }')

# No user logged in — can't validate, defer to next check-in
if [ -z "$logged_in_user" ]; then
    echo "No console user. Deferring audit."
    exit 0
fi

full_name=$(dscl . -read "/Users/$logged_in_user" RealName | awk 'NR==2 {sub(/^[ \t]+|[ \t]+$/, ""); print}')
if [ -z "$full_name" ]; then
    echo "Could not read RealName for $logged_in_user. Deferring."
    exit 0
fi

FIRST_NAME=$(echo "$full_name" | awk '{print $1}')
LAST_NAME=$(echo "$full_name" | awk '{print $NF}')
first_initial=$(echo "$FIRST_NAME" | cut -c1)

# Build expected name (must match remediation logic exactly)
expected_base="${SERIAL_NUMBER}-${first_initial}${LAST_NAME}"
max_length=26

if [ ${#expected_base} -gt $max_length ]; then
    expected_name=$(echo "$expected_base" | cut -c1-$max_length | sed 's/-*$//')
else
    expected_name="$expected_base"
fi

expected_local=$(printf '%s' "$expected_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//')

# Read current names
current_computer=$(scutil --get ComputerName 2>/dev/null)
current_host=$(scutil --get HostName 2>/dev/null)
current_local=$(scutil --get LocalHostName 2>/dev/null)

# Compare
if [ "$current_computer" = "$expected_name" ] \
   && [ "$current_host" = "$expected_name" ] \
   && [ "$current_local" = "$expected_local" ]; then
    echo "Names match expected values. No action needed."
    exit 0
else
    echo "Naming drift detected:"
    echo "  ComputerName:  current=[$current_computer]  expected=[$expected_name]"
    echo "  HostName:      current=[$current_host]  expected=[$expected_name]"
    echo "  LocalHostName: current=[$current_local]  expected=[$expected_local]"
    exit 1
fi
