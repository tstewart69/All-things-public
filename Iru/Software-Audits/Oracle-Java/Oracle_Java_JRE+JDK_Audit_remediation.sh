#!/bin/bash

# --- Remediation Script for Oracle Java ---
#
# Description:
# This script finds and removes all Oracle Java JRE and JDK installations.
# It is designed to be run as a remediation script from an MDM like Kandji.
#
# Kandji Instructions:
# 1. Add this script to your Kandji Library.
# 2. Assign it to a Blueprint to run on devices.

# Define paths for Java installations
JRE_PLUGIN_PATH="/Library/Internet Plug-Ins/JavaAppletPlugin.plugin"
JDK_INSTALL_DIR="/Library/Java/JavaVirtualMachines"

echo "Starting Oracle Java remediation check..."

# --- Remediate Oracle JRE ---
if [[ -d "$JRE_PLUGIN_PATH" ]]; then
    echo "Found Java JRE plugin. Checking vendor..."
    # Check if the bundle identifier contains "oracle"
    jre_vendor=$(defaults read "${JRE_PLUGIN_PATH}/Contents/Enabled.plist" CFBundleIdentifier 2>/dev/null | grep -Eo "oracle")
    
    if [[ "$jre_vendor" == "oracle" ]]; then
        echo "Oracle JRE detected. Removing..."
        rm -rf "$JRE_PLUGIN_PATH"
        if [[ ! -d "$JRE_PLUGIN_PATH" ]]; then
            echo "Successfully removed Oracle JRE."
        else
            echo "ERROR: Failed to remove Oracle JRE at ${JRE_PLUGIN_PATH}."
        fi
    else
        echo "A non-Oracle JRE was found. No action taken."
    fi
else
    echo "No Java JRE plugin found. Skipping JRE check."
fi

# --- Remediate Oracle JDK ---
if [[ -d "$JDK_INSTALL_DIR" ]] && [[ -n "$(ls -A "$JDK_INSTALL_DIR")" ]]; then
    echo "Found JDK installations. Checking each for Oracle vendor..."
    
    # Loop through each installed JDK
    for jdk_path in "${JDK_INSTALL_DIR}"/*; do
        if [[ -d "$jdk_path" ]]; then
            echo "Checking JDK at ${jdk_path}..."
            # Check if the bundle identifier contains "oracle"
            jdk_vendor=$(defaults read "${jdk_path}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null | grep -Eo "oracle")

            if [[ "$jdk_vendor" == "oracle" ]]; then
                echo "Oracle JDK detected. Removing ${jdk_path}..."
                rm -rf "$jdk_path"
                if [[ ! -d "$jdk_path" ]]; then
                    echo "Successfully removed Oracle JDK."
                else
                    echo "ERROR: Failed to remove Oracle JDK at ${jdk_path}."
                fi
            else
                echo "Non-Oracle JDK found at ${jdk_path}. No action taken."
            fi
        fi
    done
else
    echo "No JDK installations found in ${JDK_INSTALL_DIR}."
fi

echo "Oracle Java remediation script finished."

sudo /usr/local/bin/kandji display-alert --title "Application Uninstalled" --message "Oracle Java is not allowed to be installed. If Java is needed, please use OpenJDK or reach out to IT for assistance" --help-url "https://support.example.com"
exit 0
