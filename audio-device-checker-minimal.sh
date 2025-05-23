#!/bin/bash
# audio-check-minimal.sh - User-friendly audio device check script

# Simple color support (works in most terminals)
if [ -t 1 ]; then
    BOLD=$(tput bold 2>/dev/null || echo "")
    NORMAL=$(tput sgr0 2>/dev/null || echo "")
    GREEN=$(tput setaf 2 2>/dev/null || echo "")
    YELLOW=$(tput setaf 3 2>/dev/null || echo "")
    CYAN=$(tput setaf 6 2>/dev/null || echo "")
else
    BOLD=""
    NORMAL=""
    GREEN=""
    YELLOW=""
    CYAN=""
fi

# Header
echo "${BOLD}Audio Device Status Report${NORMAL}"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Sound Cards
echo "${BOLD}📢 SOUND CARDS${NORMAL}"
if [ -f /proc/asound/cards ]; then
    card_content=$(cat /proc/asound/cards 2>/dev/null)
    if [ -n "$card_content" ]; then
        echo "$card_content"
        # Count cards
        card_count=$(echo "$card_content" | grep -c "^ *[0-9]")
        usb_count=$(echo "$card_content" | grep -c "USB-Audio")
        echo
        echo "  ${GREEN}Total cards: $card_count${NORMAL}"
        [ $usb_count -gt 0 ] && echo "  ${GREEN}USB audio devices: $usb_count${NORMAL}"
    else
        echo "  ${YELLOW}No sound cards detected${NORMAL}"
    fi
else
    echo "  ${YELLOW}Cannot read sound card information${NORMAL}"
fi
echo

# Recording Devices
echo "${BOLD}🎤 RECORDING DEVICES${NORMAL}"
if command -v arecord >/dev/null 2>&1; then
    rec_output=$(arecord -l 2>/dev/null)
    if [ -n "$rec_output" ] && ! echo "$rec_output" | grep -q "no soundcards found"; then
        echo "$rec_output"
        # Count recording devices
        rec_count=$(echo "$rec_output" | grep -c "^card")
        echo
        echo "  ${GREEN}Recording devices found: $rec_count${NORMAL}"
    else
        echo "  ${YELLOW}No recording devices found${NORMAL}"
        echo "  (This is normal if you only have playback devices)"
    fi
else
    echo "  ${YELLOW}arecord command not found - install alsa-utils${NORMAL}"
fi
echo

# USB Devices
echo "${BOLD}🔌 USB DEVICES${NORMAL}"
if command -v lsusb >/dev/null 2>&1; then
    echo "${CYAN}All connected USB devices:${NORMAL}"
    lsusb 2>/dev/null | nl -w2 -s'. ' || echo "  Cannot list USB devices"
    echo
    
    # Filter audio devices
    echo "${CYAN}Audio-related USB devices:${NORMAL}"
    audio_devices=$(lsusb 2>/dev/null | grep -iE "audio|microphone|sound|mic|webcam")
    if [ -n "$audio_devices" ]; then
        echo "$audio_devices" | nl -w2 -s'. '
        audio_count=$(echo "$audio_devices" | wc -l)
        echo
        echo "  ${GREEN}USB audio devices found: $audio_count${NORMAL}"
    else
        echo "  ${YELLOW}No USB audio devices detected${NORMAL}"
        echo "  (USB microphones should appear here when connected)"
    fi
else
    echo "  ${YELLOW}lsusb command not found - install usbutils${NORMAL}"
fi
echo

# Udev Rules
echo "${BOLD}⚙️  PERSISTENT NAMING RULES${NORMAL}"
rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
if [ -f "$rules_file" ]; then
    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        echo "${CYAN}USB sound card mappings:${NORMAL}"
        rules_content=$(sudo cat "$rules_file" 2>/dev/null || cat "$rules_file" 2>/dev/null)
        
        # Extract and display friendly names
        friendly_names=$(echo "$rules_content" | grep -oP 'ATTR{id}="\K[^"]+' | sort -u)
        if [ -n "$friendly_names" ]; then
            echo "$friendly_names" | while read -r name; do
                # Find the vendor/product for this name
                vendor=$(echo "$rules_content" | grep -B1 "ATTR{id}=\"$name\"" | grep -oP 'idVendor}=="\K[^"]+' | head -1)
                product=$(echo "$rules_content" | grep -B1 "ATTR{id}=\"$name\"" | grep -oP 'idProduct}=="\K[^"]+' | head -1)
                echo "  • $name (USB ID: ${vendor:-????}:${product:-????})"
            done
            
            rule_count=$(echo "$friendly_names" | wc -l)
            echo
            echo "  ${GREEN}Persistent mappings configured: $rule_count${NORMAL}"
        fi
        
        # Show full rules if requested
        echo
        echo "${CYAN}Full rules content:${NORMAL}"
        echo "$rules_content"
    else
        echo "  ${YELLOW}Note: Run with 'sudo' to see udev rules${NORMAL}"
        echo "  Example: sudo $0"
    fi
else
    echo "  ${YELLOW}No persistent naming rules configured${NORMAL}"
    echo "  (Run usb-soundcard-mapper.sh to create persistent device names)"
fi
echo

# Quick Status Summary
echo "${BOLD}📊 SUMMARY${NORMAL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create a simple status report
problems=0

# Check for sound cards
if [ -f /proc/asound/cards ]; then
    card_check=$(grep -c "^ *[0-9]" /proc/asound/cards 2>/dev/null || echo "0")
    if [ "$card_check" -gt 0 ]; then
        echo "✓ Sound system: ${GREEN}Working${NORMAL} ($card_check cards detected)"
    else
        echo "✗ Sound system: ${YELLOW}No cards detected${NORMAL}"
        problems=$((problems + 1))
    fi
else
    echo "✗ Sound system: ${YELLOW}Cannot check${NORMAL}"
    problems=$((problems + 1))
fi

# Check for USB audio
if command -v lsusb >/dev/null 2>&1; then
    usb_audio_check=$(lsusb 2>/dev/null | grep -ciE "audio|microphone|sound|mic")
    if [ "$usb_audio_check" -gt 0 ]; then
        echo "✓ USB audio: ${GREEN}Found${NORMAL} ($usb_audio_check devices)"
    else
        echo "✗ USB audio: ${YELLOW}None detected${NORMAL}"
    fi
else
    echo "✗ USB audio: ${YELLOW}Cannot check (lsusb missing)${NORMAL}"
fi

# Check for persistent rules
if [ -f "$rules_file" ]; then
    echo "✓ Persistent names: ${GREEN}Configured${NORMAL}"
else
    echo "✗ Persistent names: ${YELLOW}Not configured${NORMAL}"
fi

echo
if [ $problems -eq 0 ]; then
    echo "${GREEN}${BOLD}Status: All systems operational${NORMAL}"
else
    echo "${YELLOW}${BOLD}Status: Some issues detected (see above)${NORMAL}"
fi
echo
