#!/bin/sh
# v6: Sets a capitalized ComputerName/HostName, while keeping LocalHostName lowercase for compatibility.

# ---
# STEP 1: Reliably get all required information.
# ---
get_device_naming_info() {
    echo "Gathering device and user information..."

    # === SERIAL NUMBER ===
    # Only use System Profiler.
    SERIAL_NUMBER="$(system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}')"

    # === USER NAME ===
    # Only look up the user on the device.
    echo "  Looking up user on device."
    
    local logged_in_user
    logged_in_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && !/loginwindow/ { print $3 }')

    if [ -z "$logged_in_user" ]; then
        echo "  ERROR: No user is logged into the GUI. Cannot determine name."
        return 1
    fi
    echo "  Found console user: $logged_in_user"

    local full_name
    full_name=$(dscl . -read "/Users/$logged_in_user" RealName | awk 'NR==2 {sub(/^[ \t]+|[ \t]+$/, ""); print}')

    if [ -z "$full_name" ]; then
        echo "  ERROR: Found user '$logged_in_user' but could not read their Full Name."
        return 1
    fi
    
    FIRST_NAME=$(echo "$full_name" | awk '{print $1}')
    LAST_NAME=$(echo "$full_name" | awk '{print $NF}')
}

# ---
# STEP 2: Run the script's main logic.
# ---

get_device_naming_info || exit 1

# === Debug Logging ===
echo "Serial Number: [$SERIAL_NUMBER]"
echo "First Name: [$FIRST_NAME]"
echo "Last Name: [$LAST_NAME]"

# === Validate inputs ===
if [ -z "$SERIAL_NUMBER" ] || [ -z "$FIRST_NAME" ] || [ -z "$LAST_NAME" ]; then
    echo "ERROR: Missing required values after lookup. Cannot continue."
    exit 1
fi

# === Construct base name with desired capitalization ===
first_initial=$(echo "$FIRST_NAME" | cut -c1)
base_name="${SERIAL_NUMBER}-${first_initial}${LAST_NAME}"

# === Truncate the name if it's too long ===
max_length=26
if [ $(echo "$base_name" | wc -c) -gt $max_length ]; then
    echo "  Name is too long. Truncating to $max_length characters."
    device_name=$(echo "$base_name" | cut -c1-$max_length)
else
    device_name="$base_name"
fi

# === Create and sanitize a separate, lowercase version for LocalHostName ===
# LocalHostName (for .local address) must be lowercase and contain only letters, numbers, hyphens.
echo "  Creating a sanitized, lowercase version for LocalHostName."
local_host_name=$(echo "$device_name" | tr '[:upper:]' '[:lower:]')
local_host_name=$(echo "$local_host_name" | tr -cd 'a-z0-9-')
local_host_name=$(echo "$local_host_name" | sed 's/^-*//; s/-*$//')

# === Final validation ===
if [ -z "$device_name" ] || [ -z "$local_host_name" ]; then
    echo "ERROR: A required name field was empty after processing. Exiting."
    exit 1
fi

# === Set device names ===
echo "Setting device names..."
scutil --set ComputerName "$device_name"
scutil --set HostName "$device_name"
scutil --set LocalHostName "$local_host_name"

echo "Device name set successfully."
echo "  ComputerName: $device_name"
echo "  HostName:     $device_name"
echo "  LocalHostName: $local_host_name"
