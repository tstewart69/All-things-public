#!/bin/bash

# --- Audit Script for Oracle Java ---
#
# Description:
# This script checks if Oracle Java JRE or JDK is installed.
#
# Exit Codes:
# - Exit 0: Compliant. No Oracle Java was found.
# - Exit 1: Non-Compliant. Oracle Java was found.

# Define paths to check
JRE_PLUGIN_PATH="/Library/Internet Plug-Ins/JavaAppletPlugin.plugin"
JDK_INSTALL_DIR="/Library/Java/JavaVirtualMachines"

# --- Check for Oracle JRE ---
# Check if the JavaAppletPlugin.plugin exists first
if [[ -d "$JRE_PLUGIN_PATH" ]]; then
    
    # If it exists, check its bundle identifier to see if it's from Oracle.
    # Suppress errors in case the plist or key doesn't exist.
    jre_vendor=$(defaults read "${JRE_PLUGIN_PATH}/Contents/Enabled.plist" CFBundleIdentifier 2>/dev/null | grep -Eo "oracle")
    
    if [[ "$jre_vendor" == "oracle" ]]; then
        echo "Audit Failed: Oracle Java JRE found at ${JRE_PLUGIN_PATH}"
        exit 1
    fi
fi

# --- Check for Oracle JDK ---
# Check if the JavaVirtualMachines directory exists and is not empty
if [[ -d "$JDK_INSTALL_DIR" ]] && [[ -n "$(ls -A "$JDK_INSTALL_DIR")" ]]; then

    # Loop through each installed JDK
    for jdk_path in "${JDK_INSTALL_DIR}"/*; do
        # Ensure we are only checking directories
        if [[ -d "$jdk_path" ]]; then
            # Check its bundle identifier to see if it's from Oracle
            jdk_vendor=$(defaults read "${jdk_path}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null | grep -Eo "oracle")

            if [[ "$jdk_vendor" == "oracle" ]]; then
                echo "Audit Failed: Oracle Java JDK found at ${jdk_path}"
                exit 1
            fi
        fi
    done
fi

# --- If we reach this point, no Oracle Java was found ---
echo "Audit Passed: No Oracle Java installations found."
exit 0
