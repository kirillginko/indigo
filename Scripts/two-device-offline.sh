#!/usr/bin/env bash
#
# Drives the offline stage of the two-device sync test: waits for the runner to
# say it is ready, turns Wi-Fi off, lets it make its changes, turns Wi-Fi back
# on, and tells it to go on. It cuts this Mac off the network for about a
# minute. Always turns Wi-Fi back on, however it ends.
#
#   Scripts/two-device-offline.sh <runner-output-file>
#
set -uo pipefail
OUT="$1"
SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
DIR="$SUPPORT/TwoDeviceSync"
DEVICE=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
[ -z "$DEVICE" ] && { echo "no Wi-Fi interface found"; exit 1; }
trap 'networksetup -setairportpower "$DEVICE" on' EXIT

until grep -q READY_FOR_OFFLINE "$OUT" 2>/dev/null; do sleep 2; done
echo "turning Wi-Fi ($DEVICE) off"
networksetup -setairportpower "$DEVICE" off
touch "$DIR/offline.flag"
until grep -q CHANGES_MADE "$OUT" 2>/dev/null; do sleep 2; done
sleep 8
echo "turning Wi-Fi on"
networksetup -setairportpower "$DEVICE" on
sleep 15
touch "$DIR/online.flag"
