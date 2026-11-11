#!/bin/sh

Check_SafariUpdate=$( softwareupdate -l | grep Safari | grep -o 'Safari[^[:blank:]]*' | head -n 1)
/bin/echo "$Check_SafariUpdate"
 softwareupdate -i "$Check_SafariUpdate"
