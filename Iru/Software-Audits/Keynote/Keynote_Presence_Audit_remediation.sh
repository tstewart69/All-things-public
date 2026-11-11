#!/bin/bash

# Define the path to the application
APP_PATH="/Applications/Keynote.app"

# Check if the application exists
if [ -d "$APP_PATH" ]; then
    echo "Uninstalling Pages..."
    sudo rm -rf "$APP_PATH"
    
    if [ $? -eq 0 ]; then
        echo "Keynote has been successfully uninstalled."
    else
        echo "Failed to uninstall Keynote. Please check your permissions."
    fi
else
    echo "Keynote.app was not found in /Applications."
fi
