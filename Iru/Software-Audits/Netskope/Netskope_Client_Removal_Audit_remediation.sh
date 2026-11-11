#!/bin/bash

# 1. Variables
INPASSWORD=""
# This is the path to the internal uninstaller tool
STUNINSTALL="/Library/Application Support/Netskope/STAgent/stagentui.app/Contents/Resources/stuninstall"

echo "Starting Netskope removal via stuninstall..."

# 2. Check if the internal uninstaller exists
if [ -f "$STUNINSTALL" ]; then
    echo "Direct uninstaller found. Executing..."
    
    # 3. Execute with the password flag
    # Newer versions use --password, older ones just take the string
    "$STUNINSTALL" --password "$INPASSWORD"
    
    # Give it a few seconds to unload the System Extension
    sleep 15
else
    echo "Internal uninstaller not found at $STUNINSTALL."
    echo "Attempting backup path..."
    # Fallback for some versions
    /Applications/Netskope\ Client.app/Contents/Resources/stuninstall --password "$INPASSWORD"
fi

# 4. Force kill remaining processes to release file locks
/usr/bin/pkill -9 "Netskope"
/usr/bin/pkill -9 "stagent"
/usr/bin/pkill -9 "Netskope Endpoint DLP"

# 5. Clean up the application and support folders
echo "Cleaning up leftover files..."
rm -rf "/Applications/Netskope Client.app"
rm -rf "/Applications/Remove Netskope Client.app"
rm -rf "/Library/Application Support/Netskope"

# 6. Final Verification
if [ ! -d "/Applications/Netskope Client.app" ]; then
    echo "Netskope successfully removed."
    exit 0
else
    echo "Removal failed. The app is still present."
    exit 1
fi
