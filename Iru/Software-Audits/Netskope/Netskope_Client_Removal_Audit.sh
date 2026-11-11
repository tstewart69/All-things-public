#!/bin/bash
#script for installing NSAgent on OSX machines
#will check to see if Netskope is Installed
function Test_NSClient(){
xz=$(/usr/bin/mdfind kMDItemFSName == Netskope Client.app -onlyin /Library/Application\ Support/)
if [ -e "$xz" ]; then
    echo "$xz found netskope client is installed"
exit 1
else
    echo "client does not exist"
exit 0
fi
}
Test_NSClient
#end script
