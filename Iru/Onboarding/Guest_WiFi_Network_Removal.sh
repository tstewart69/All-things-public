#!/bin/zsh


###################################################################################################
#
# PURPOSE
#
# This script removes a specific wireless network from the preferred list. If removal is performed,
# the script will attempt to switch to the preferred network if it is within range.
#
#
# EXAMPLE SCENARIO
#
# The correctNetwork uses 802.1x authentication, therefor the Mac must connected to a different
# network, often guest wifi at an office, to receive the 802.1x profile. Once this is accomplished
# the Mac may remain connected to the guest network due to the order in the preferred list.   
#

###################################### VARIABLES ##################################################
###################################################################################################

# The SSID of the network that you want to remove from the preferred list.
removeNetwork="Guest-WiFi"

# The SSID of the network that your Mac should be connected to.
correctNetwork="Corp-WiFi"

###################################################################################################
############################ MAIN LOGIC - DO NOT MODIFY BELOW #####################################
###################################################################################################

wifiAdapter="$(/usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/Wi-Fi/{getline; print $2}')"
currentNetwork="$(/usr/sbin/networksetup -getairportnetwork $wifiAdapter | /usr/bin/awk -F": " '{print $2}')"
preferredNetworks="$(/usr/sbin/networksetup -listpreferredwirelessnetworks $wifiAdapter)"
airport=/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport

if [[ ! $preferredNetworks =~ "$removeNetwork" ]]; then
     /bin/echo "$removeNetwork was not found in the preferred networks list"
     exit 0
else
    if [ "$currentNetwork" = "$correctNetwork" ]; then
        /bin/echo "Mac is already connected to $correctNetwork."    
        /usr/sbin/networksetup -removepreferredwirelessnetwork $wifiAdapter "$removeNetwork"
        /bin/echo "$removeNetwork has been removed from the preferred networks list"
        exit 0
    else
        if [[ $($airport -s "$correctNetwork") != "No networks found" ]]; then
            /bin/echo "Mac is not connected to $correctNetwork"
            /usr/sbin/networksetup -removepreferredwirelessnetwork $wifiAdapter "$removeNetwork"
            /bin/echo "Cycling Wi-Fi power to reconnect"
            /usr/sbin/networksetup -setairportpower $wifiAdapter off
            /usr/sbin/networksetup -setairportpower $wifiAdapter on

            until /usr/sbin/ipconfig getifaddr $wifiAdapter >/dev/null; do
                /bin/echo "Waiting for network connectivity..."
                /bin/sleep 1
            done

            until /sbin/ping -c1 -S $(/usr/sbin/ipconfig getifaddr $wifiAdapter) 8.8.8.8 >/dev/null 2>&1; do
                /bin/echo "Waiting for internet connectivity..."
            done
        
            currentNetwork="$(/usr/sbin/networksetup -getairportnetwork $wifiAdapter | /usr/bin/awk -F": " '{print $2}')"
        
            if [ "$currentNetwork" = "$correctNetwork" ]; then
                /bin/echo "Succesfully removed $removeNetwork and connected to $correctNetwork"
                exit 0
             else
                /bin/echo "Failed to connect to $correctNetwork"
                exit 1
            fi
        else
            /usr/sbin/networksetup -removepreferredwirelessnetwork $wifiAdapter "$removeNetwork"
            /bin/echo "$removeNetwork has been removed from the preferred networks list"
            /bin/echo "$correctNetwork is not available, skipping Wi-Fi power cycle"
            exit 0
        fi
    fi
fi
