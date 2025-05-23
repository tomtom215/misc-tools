#!/bin/bash
# audio-device-check.sh - Comprehensive audio device diagnostic script
#
# This script provides a complete overview of USB audio device configuration
# Useful for checking system state before/after installers or configuration changes

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}▶ $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# Function to print subsection headers
print_subheader() {
    echo
    echo -e "${CYAN}◆ $1${NC}"
    echo -e "${CYAN}$(printf '─%.0s' {1..60})${NC}"
}

# Function to check if command exists
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        echo -e "${YELLOW}Warning: $1 command not found${NC}"
        return 1
    fi
}

# Function to print file content with existence check
print_file_content() {
    local file="$1"
    local description="$2"
    local needs_sudo="$3"
    
    if [ -f "$file" ] || [ -e "$file" ]; then
        if [ "$needs_sudo" = "true" ] && [ "$EUID" -ne 0 ]; then
            echo -e "${YELLOW}Note: Running without sudo - some information may be limited${NC}"
            sudo cat "$file" 2>/dev/null || echo -e "${RED}Cannot read $file without sudo privileges${NC}"
        else
            cat "$file" 2>/dev/null || echo -e "${RED}Cannot read $file${NC}"
        fi
    else
        echo -e "${YELLOW}$description not found${NC}"
    fi
}

# Main diagnostic function
main() {
    echo -e "${BOLD}${GREEN}Audio Device Diagnostic Report${NC}"
    echo -e "${GREEN}Generated: $(date)${NC}"
    echo -e "${GREEN}Hostname: $(hostname)${NC}"
    echo -e "${GREEN}Kernel: $(uname -r)${NC}"
    
    # System Information
    print_header "System Audio Information"
    
    print_subheader "ALSA Version"
    if check_command "aplay"; then
        aplay --version | head -n1 || echo "ALSA version unavailable"
    fi
    
    print_subheader "Sound Modules Loaded"
    lsmod | grep -E "^snd|^usb_audio" | sort || echo "No sound modules found"
    
    print_subheader "Audio Groups"
    getent group audio 2>/dev/null || echo "audio group not found"
    echo -n "Current user ($(whoami)) audio access: "
    if groups | grep -q audio; then
        echo -e "${GREEN}Yes${NC}"
    else
        echo -e "${YELLOW}No (may need to add user to audio group)${NC}"
    fi
    
    # Sound Cards
    print_header "Sound Cards (/proc/asound/cards)"
    print_file_content "/proc/asound/cards" "Sound cards information"
    
    # Recording Devices
    print_header "Recording Devices (arecord -l)"
    if check_command "arecord"; then
        arecord -l 2>/dev/null || echo "No recording devices found"
    fi
    
    # Playback Devices
    print_header "Playback Devices (aplay -l)"
    if check_command "aplay"; then
        aplay -l 2>/dev/null || echo "No playback devices found"
    fi
    
    # USB Devices
    print_header "USB Devices (lsusb)"
    if check_command "lsusb"; then
        echo -e "${CYAN}All USB devices:${NC}"
        lsusb 2>/dev/null || echo "Cannot list USB devices"
        echo
        echo -e "${CYAN}Audio-related USB devices:${NC}"
        lsusb 2>/dev/null | grep -iE "audio|microphone|sound|mic" || echo "No USB audio devices found"
    fi
    
    # Device Nodes
    print_header "Audio Device Nodes"
    
    print_subheader "Character Devices (/dev/snd/)"
    if [ -d /dev/snd ]; then
        ls -la /dev/snd/ | grep -v "^total"
    else
        echo "/dev/snd/ directory not found"
    fi
    
    print_subheader "Device Symlinks (/dev/sound/by-id/)"
    if [ -d /dev/sound/by-id ]; then
        ls -la /dev/sound/by-id/ 2>/dev/null | grep -v "^total" || echo "No symlinks found"
    else
        echo "/dev/sound/by-id/ directory not found"
    fi
    
    print_subheader "Device Symlinks (/dev/sound/by-path/)"
    if [ -d /dev/sound/by-path ]; then
        ls -la /dev/sound/by-path/ 2>/dev/null | grep -v "^total" || echo "No symlinks found"
    else
        echo "/dev/sound/by-path/ directory not found"
    fi
    
    # Udev Rules
    print_header "Udev Rules"
    
    print_subheader "USB Sound Card Rules (/etc/udev/rules.d/99-usb-soundcards.rules)"
    print_file_content "/etc/udev/rules.d/99-usb-soundcards.rules" "USB soundcard rules file" "true"
    
    print_subheader "Other Audio-Related Udev Rules"
    if [ -d /etc/udev/rules.d ]; then
        local found_rules=false
        for rule in /etc/udev/rules.d/*; do
            if [ -f "$rule" ] && grep -q -iE "sound|audio|alsa" "$rule" 2>/dev/null; then
                if [ "$found_rules" = false ]; then
                    found_rules=true
                fi
                echo -e "${CYAN}Found in: $(basename "$rule")${NC}"
                grep -iE "sound|audio|alsa" "$rule" | head -5
                echo
            fi
        done
        if [ "$found_rules" = false ]; then
            echo "No other audio-related rules found"
        fi
    fi
    
    # Process Information
    print_header "Audio Process Information"
    
    print_subheader "Processes Using Audio Devices"
    if check_command "lsof"; then
        local audio_procs
        audio_procs=$(lsof /dev/snd/* 2>/dev/null | grep -v "^COMMAND")
        if [ -n "$audio_procs" ]; then
            echo "PID    COMMAND         USER     DEVICE"
            echo "$audio_procs" | awk '{printf "%-6s %-15s %-8s %s\n", $2, $1, $3, $NF}'
        else
            echo "No processes currently using audio devices"
        fi
    else
        echo "lsof not available - install with: sudo apt-get install lsof"
    fi
    
    print_subheader "PulseAudio Status"
    if check_command "pactl"; then
        pactl info 2>/dev/null | grep -E "^Server|^Default" || echo "PulseAudio not running or not accessible"
    else
        echo "PulseAudio tools not installed"
    fi
    
    # ALSA Configuration
    print_header "ALSA Configuration"
    
    print_subheader "ALSA Card Controls"
    for card in /proc/asound/card[0-9]*; do
        if [ -d "$card" ]; then
            card_num=$(basename "$card" | sed 's/card//')
            if [ -f "$card/id" ]; then
                card_id=$(cat "$card/id" 2>/dev/null)
                echo -e "${CYAN}Card $card_num: $card_id${NC}"
                
                # Show USB path if it's a USB device
                if [ -f "$card/usbbus" ]; then
                    echo -n "  USB Bus: "
                    cat "$card/usbbus" 2>/dev/null || echo "unknown"
                fi
                
                if [ -f "$card/usbid" ]; then
                    echo -n "  USB ID: "
                    cat "$card/usbid" 2>/dev/null || echo "unknown"
                fi
                
                # Check for mixer controls
                if check_command "amixer"; then
                    control_count=$(amixer -c "$card_num" scontrols 2>/dev/null | wc -l)
                    echo "  Mixer controls: $control_count"
                fi
            fi
        fi
    done
    
    # Summary
    print_header "Summary"
    
    # Count devices
    total_cards=$(grep -c "^ *[0-9]" /proc/asound/cards 2>/dev/null || echo "0")
    usb_cards=$(grep -c "USB-Audio" /proc/asound/cards 2>/dev/null || echo "0")
    
    echo -e "${BOLD}Total sound cards:${NC} $total_cards"
    echo -e "${BOLD}USB audio devices:${NC} $usb_cards"
    
    # Check for persistent rules
    if [ -f /etc/udev/rules.d/99-usb-soundcards.rules ]; then
        rule_count=$(grep -c "^SUBSYSTEM" /etc/udev/rules.d/99-usb-soundcards.rules 2>/dev/null || echo "0")
        echo -e "${BOLD}Persistent naming rules:${NC} $rule_count"
    else
        echo -e "${BOLD}Persistent naming rules:${NC} ${YELLOW}Not configured${NC}"
    fi
    
    # Check for common issues
    echo
    echo -e "${BOLD}Potential Issues:${NC}"
    issues_found=false
    
    if [ "$total_cards" -eq 0 ]; then
        echo -e "  ${RED}• No sound cards detected${NC}"
        issues_found=true
    fi
    
    if [ "$usb_cards" -eq 0 ]; then
        echo -e "  ${YELLOW}• No USB audio devices detected${NC}"
        issues_found=true
    fi
    
    if ! groups | grep -q audio; then
        echo -e "  ${YELLOW}• Current user not in audio group${NC}"
        issues_found=true
    fi
    
    if [ ! -d /dev/snd ]; then
        echo -e "  ${RED}• /dev/snd directory missing - ALSA may not be properly installed${NC}"
        issues_found=true
    fi
    
    if [ "$issues_found" = false ]; then
        echo -e "  ${GREEN}• No obvious issues detected${NC}"
    fi
    
    echo
    echo -e "${BOLD}${GREEN}Diagnostic report complete${NC}"
}

# Run main function
main "$@"