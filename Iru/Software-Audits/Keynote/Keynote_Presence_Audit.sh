#!/bin/bash

# Define the path to the application
APP_PATH="/Applications/Keynote.app"

# Check if the application exists
if [ -d "$APP_PATH" ]; then
    echo "Keynote.app is present. Exiting with error."
    exit 1
else
    echo "Keynote.app is not found. Exiting successfully."
    exit 0
fi
