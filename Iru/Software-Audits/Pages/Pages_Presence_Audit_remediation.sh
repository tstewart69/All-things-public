#!/bin/bash

# Define the path to the application
APP_PATH="/Applications/Pages.app"

# Check if the application exists
if [ -d "$APP_PATH" ]; then
    echo "Uninstalling Pages..."
    sudo rm -rf "$APP_PATH"
    
    if [ $? -eq 0 ]; then
        echo "Pages has been successfully uninstalled."
    else
        echo "Failed to uninstall Pages. Please check your permissions."
    fi
else
    echo "Pages.app was not found in /Applications."
fi
