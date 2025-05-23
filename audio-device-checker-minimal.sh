#!/bin/bash
# audio-check-minimal.sh - Minimal audio device check script

echo "=== Audio Device Status Check ==="
echo "Date: $(date)"
echo

echo "=== Sound Cards ==="
cat /proc/asound/cards 2>/dev/null || echo "Error: Cannot read sound cards"
echo

echo "=== Recording Devices ==="
arecord -l 2>/dev/null || echo "Error: arecord command not found"
echo

echo "=== USB Devices ==="
lsusb 2>/dev/null || echo "Error: lsusb command not found"
echo

echo "=== USB Audio Devices (filtered) ==="
lsusb 2>/dev/null | grep -iE "audio|microphone|sound|mic" || echo "No USB audio devices found"
echo

echo "=== Udev Rules ==="
if [ -f /etc/udev/rules.d/99-usb-soundcards.rules ]; then
    if [ "$EUID" -eq 0 ]; then
        cat /etc/udev/rules.d/99-usb-soundcards.rules
    else
        echo "Note: Run with sudo to see udev rules"
        sudo cat /etc/udev/rules.d/99-usb-soundcards.rules 2>/dev/null || echo "Cannot read without sudo"
    fi
else
    echo "No USB soundcard rules file found"
fi