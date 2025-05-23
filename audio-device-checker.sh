#!/bin/bash
# audio-device-checker.sh v1.3 - Comprehensive audio device diagnostic script
#
# This script provides a complete overview of USB audio device configuration
# Useful for checking system state before/after installers or configuration changes
#
# Version 1.3 adds:
# - Better handling of busy audio devices
# - Complete audio group membership listing
# - Enhanced summary with more statistics
# - Fixed latency calculations and escape sequences
# - Improved error handling and readability

# Script version
readonly SCRIPT_VERSION="1.3"
readonly SCRIPT_DATE="2025-05-24"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Configuration
TEMP_DIR="/tmp/audio-device-checker-$$"
LOG_FILE="${TEMP_DIR}/diagnostic.log"

# Known mono devices (USB ID patterns)
declare -A KNOWN_MONO_DEVICES=(
    ["0bda:4809"]="Realtek USB Audio (often mono mic)"
    ["0c76:161f"]="JMTek USB Microphone"
    ["1b3f:2008"]="Generalplus USB Audio Device"
)

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Initialize temporary directory
mkdir -p "$TEMP_DIR" 2>/dev/null || true

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
        echo -e "${YELLOW}Warning: $1 command not found${NC}" >&2
        return 1
    fi
}

# Function to print file content with existence check
print_file_content() {
    local file="$1"
    local description="$2"
    local needs_sudo="${3:-false}"
    
    if [ -f "$file" ] || [ -e "$file" ]; then
        if [ "$needs_sudo" = "true" ] && [ "$EUID" -ne 0 ]; then
            echo -e "${YELLOW}Note: Running without sudo - some information may be limited${NC}"
            if sudo -n cat "$file" 2>/dev/null; then
                sudo cat "$file" 2>/dev/null
            else
                cat "$file" 2>/dev/null || echo -e "${RED}Cannot read $file without sudo privileges${NC}"
            fi
        else
            cat "$file" 2>/dev/null || echo -e "${RED}Cannot read $file${NC}"
        fi
    else
        echo -e "${YELLOW}$description not found${NC}"
    fi
}

# Function to safely read file
safe_read_file() {
    local file="$1"
    local default="${2:-}"
    
    if [[ -r "$file" ]]; then
        cat "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Function to get USB device speed in human readable format
get_usb_speed_string() {
    local speed="$1"
    case "$speed" in
        1.5) echo "Low Speed (1.5 Mbps)" ;;
        12) echo "Full Speed (12 Mbps)" ;;
        480) echo "High Speed (480 Mbps)" ;;
        5000) echo "Super Speed (5 Gbps)" ;;
        10000) echo "Super Speed+ (10 Gbps)" ;;
        *) echo "${speed} Mbps" ;;
    esac
}

# Function to calculate USB bandwidth utilization
calculate_usb_bandwidth() {
    local channels="$1"
    local bit_depth="$2"
    local sample_rate="$3"
    local speed_mbps="$4"
    
    # Calculate required bandwidth in bits per second
    local bandwidth_bps=$((channels * bit_depth * sample_rate))
    
    # Convert to Mbps with proper precision
    local bandwidth_mbps=$(echo "scale=2; $bandwidth_bps / 1000000" | bc 2>/dev/null || echo "0")
    
    # Calculate utilization percentage
    local utilization=$(echo "scale=1; ($bandwidth_mbps / $speed_mbps) * 100" | bc 2>/dev/null || echo "0")
    
    echo "Required: ${bandwidth_mbps} Mbps (${utilization}% of USB bandwidth)"
}

# Function to detect if a device is truly mono
detect_mono_device() {
    local card_num="$1"
    local card_id="$2"
    local usb_id="${3:-}"
    
    # Check against known mono devices
    if [[ -n "$usb_id" ]] && [[ -n "${KNOWN_MONO_DEVICES[$usb_id]:-}" ]]; then
        echo -e "${GREEN}✓ True mono device - ${KNOWN_MONO_DEVICES[$usb_id]}${NC}"
        return
    fi
    
    # Try to get actual channel support
    if check_command "arecord"; then
        # Try mono recording test
        local test_file="${TEMP_DIR}/mono_test_${card_num}.wav"
        if timeout 0.5s arecord -D "hw:${card_num}" -c 1 -f S16_LE -r 48000 "$test_file" &>/dev/null; then
            echo -e "${GREEN}✓ Device supports true mono recording${NC}"
            rm -f "$test_file" 2>/dev/null
            return
        fi
        
        # Check channel info from dump
        local channels=$(arecord -D "hw:$card_num" --dump-hw-params 2>&1 | grep "^CHANNELS:" | grep -o "[0-9]" | sort -u | tr '\n' ' ')
        if [[ -n "$channels" ]]; then
            echo "  Actual channel support: $channels"
            if echo "$channels" | grep -q "1"; then
                echo -e "    ${GREEN}✓ True mono recording supported${NC}"
            else
                echo -e "    ${YELLOW}⚠ Only stereo recording available${NC}"
            fi
            return
        fi
    fi
    
    # Check device name patterns
    case "${card_id,,}" in
        *mono*|*mic*|*microphone*)
            echo -e "${YELLOW}⚠ Device name suggests mono capability${NC}"
            ;;
        *)
            echo "  Unable to determine mono/stereo configuration"
            ;;
    esac
}

# Function to measure audio latency
measure_audio_latency() {
    local card_num="$1"
    
    if ! check_command "arecord"; then
        echo "  arecord not available for latency testing"
        return
    fi
    
    # Test different buffer sizes
    local buffer_sizes=(64 128 256 512 1024 2048)
    local results=""
    
    for buffer_size in "${buffer_sizes[@]}"; do
        # Calculate theoretical latency at 48kHz with proper precision
        local latency=$(echo "scale=2; $buffer_size / 48000 * 1000" | bc 2>/dev/null || echo "0")
        # Ensure we show at least 2 decimal places
        if [[ "$latency" == "0" ]]; then
            latency=$(echo "scale=2; $buffer_size / 48" | bc 2>/dev/null || echo "0")
        fi
        results="${results}${buffer_size} samples (${latency}ms), "
    done
    
    if [[ -n "$results" ]]; then
        echo "  Theoretical latencies @ 48kHz: ${results%, }"
    fi
}

# Function to get audio levels for a device
get_audio_levels() {
    local card_num="$1"
    local card_id="$2"
    
    if ! check_command "amixer"; then
        echo "  amixer not available"
        return
    fi
    
    # Get all controls (with error handling for busy devices)
    local controls=$(amixer -c "$card_num" contents 2>&1)
    if [[ "$controls" =~ "Device or resource busy" ]]; then
        echo "  Device busy - cannot read mixer controls"
        return
    elif [[ -z "$controls" ]]; then
        echo "  No mixer controls available"
        return
    fi
    
    # Parse capture controls
    echo "  Capture Controls:"
    local capture_found=false
    amixer -c "$card_num" scontents 2>/dev/null | grep -A5 "Capture" | grep -E "Capture|Mic|Input" | while read -r line; do
        if [[ "$line" =~ \[([0-9]+)%\] ]]; then
            capture_found=true
            local level="${BASH_REMATCH[1]}"
            local control_name=$(echo "$line" | cut -d"'" -f2)
            
            # Color code the level
            if [[ $level -gt 90 ]]; then
                echo -e "    $control_name: ${RED}${level}% (may cause clipping)${NC}"
            elif [[ $level -lt 30 ]]; then
                echo -e "    $control_name: ${YELLOW}${level}% (low level)${NC}"
            else
                echo -e "    $control_name: ${GREEN}${level}%${NC}"
            fi
        fi
    done
    
    # Parse playback controls
    local playback=$(amixer -c "$card_num" scontents 2>/dev/null | grep -A5 "Playback" | grep -E "Playback|Master|PCM|Speaker" | grep -E "\[[0-9]+%\]")
    if [[ -n "$playback" ]]; then
        echo "  Playback Controls:"
        echo "$playback" | while read -r line; do
            if [[ "$line" =~ \[([0-9]+)%\] ]]; then
                local level="${BASH_REMATCH[1]}"
                local control_name=$(echo "$line" | cut -d"'" -f2)
                echo -e "    $control_name: ${level}%"
            fi
        done
    fi
}

# Function to detect RTSP streams and audio processes
detect_audio_processes() {
    echo -e "${CYAN}Audio-Related Processes:${NC}"
    
    # Common audio applications
    local audio_apps="pulseaudio|pipewire|jackd|alsa|ffmpeg|ffplay|ffprobe|arecord|aplay|sox|audacity|vlc|mpv|gstreamer|rtsp"
    
    # Find processes
    local processes=$(ps aux | grep -E "$audio_apps" | grep -v grep)
    
    if [[ -n "$processes" ]]; then
        echo "$processes" | while read -r line; do
            local pid=$(echo "$line" | awk '{print $2}')
            local cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')
            local user=$(echo "$line" | awk '{print $1}')
            
            # Check if it's using audio devices (with error handling)
            local audio_files=$(lsof -p "$pid" 2>/dev/null | grep -E "/dev/snd|/dev/dsp" | awk '{print $NF}' | sort -u | tr '\n' ' ')
            
            # Special handling for RTSP
            if echo "$cmd" | grep -q "rtsp"; then
                echo -e "  ${MAGENTA}[RTSP]${NC} PID: $pid, User: $user"
                echo "    Command: $cmd"
                if [[ -n "$audio_files" ]]; then
                    echo "    Audio devices: $audio_files"
                fi
                
                # Check network connections for RTSP
                local rtsp_conn=$(ss -tnp 2>/dev/null | grep ":554\|:8554" | grep "$pid" | head -1)
                if [[ -n "$rtsp_conn" ]]; then
                    echo "    RTSP connection detected"
                fi
            else
                # Regular audio process
                echo "  PID: $pid, User: $user, Process: $(echo "$cmd" | cut -d' ' -f1)"
                if [[ -n "$audio_files" ]]; then
                    echo "    Audio devices: $audio_files"
                fi
            fi
        done
    else
        echo "  No audio-related processes detected"
    fi
    
    # Check for RTSP services
    echo
    echo -e "${CYAN}RTSP Services:${NC}"
    local rtsp_services=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -i rtsp)
    if [[ -n "$rtsp_services" ]]; then
        echo "$rtsp_services" | while read -r line; do
            local service=$(echo "$line" | awk '{print $1}')
            echo -e "  ${GREEN}✓${NC} $service is running"
        done
    else
        echo "  No RTSP services detected"
    fi
    
    # Check network listeners on RTSP ports
    local rtsp_listeners=$(ss -tln 2>/dev/null | grep -E ":554|:8554")
    if [[ -n "$rtsp_listeners" ]]; then
        echo
        echo -e "${CYAN}RTSP Port Listeners:${NC}"
        echo "$rtsp_listeners" | while read -r line; do
            echo "  $line"
        done
    fi
}

# Function to provide microphone recommendations
provide_mic_recommendations() {
    echo -e "${BOLD}Microphone Configuration Recommendations:${NC}"
    echo
    echo -e "1. ${BOLD}Input Levels:${NC}"
    echo "   - Set capture level between 60-80% to avoid clipping"
    echo "   - Use 70% as starting point, adjust based on source"
    echo "   - Monitor levels during recording to ensure no clipping"
    echo
    echo -e "2. ${BOLD}Sample Rate Selection:${NC}"
    echo "   - 48kHz: Recommended for video/broadcast applications"
    echo "   - 44.1kHz: Standard for music production"
    echo "   - Higher rates (96/192kHz): Only if specifically needed"
    echo
    echo -e "3. ${BOLD}Bit Depth:${NC}"
    echo "   - 24-bit: Recommended for recording (more headroom)"
    echo "   - 16-bit: Sufficient for final output/streaming"
    echo
    echo -e "4. ${BOLD}Mono vs Stereo:${NC}"
    echo "   - Use mono for single microphones (saves bandwidth/storage)"
    echo "   - Force mono in software if device reports stereo incorrectly"
    echo "   - Example: ffmpeg -f alsa -ac 1 -i hw:1 output.wav"
    echo
    echo -e "5. ${BOLD}Noise Reduction:${NC}"
    echo "   - Keep microphone away from computer fans and electronics"
    echo "   - Use pop filter for vocal recording"
    echo "   - Consider acoustic treatment for room recording"
}

# Function to list audio group members
list_audio_group_members() {
    echo -e "${CYAN}Audio Group Members:${NC}"
    
    # Get audio group info
    local audio_group=$(getent group audio 2>/dev/null)
    if [[ -n "$audio_group" ]]; then
        local group_name=$(echo "$audio_group" | cut -d: -f1)
        local group_id=$(echo "$audio_group" | cut -d: -f3)
        local members=$(echo "$audio_group" | cut -d: -f4)
        
        echo "  Group: $group_name (GID: $group_id)"
        
        if [[ -n "$members" ]]; then
            echo "  Members:"
            # Split comma-separated list and display each member
            IFS=',' read -ra member_array <<< "$members"
            for member in "${member_array[@]}"; do
                echo -e "    - ${GREEN}$member${NC}"
                # Try to get more info about the user
                local user_info=$(getent passwd "$member" 2>/dev/null | cut -d: -f5)
                if [[ -n "$user_info" ]]; then
                    echo "      Full name: $user_info"
                fi
            done
        else
            echo "  No members in audio group (only users with audio as primary group)"
        fi
        
        # Also check for users with audio as primary group
        echo
        echo "  Users with audio as primary group:"
        local primary_users=$(awk -F: -v gid="$group_id" '$4 == gid {print $1 " (" $5 ")"}' /etc/passwd 2>/dev/null)
        if [[ -n "$primary_users" ]]; then
            echo "$primary_users" | while read -r user; do
                echo -e "    - ${GREEN}$user${NC}"
            done
        else
            echo "    None"
        fi
    else
        echo "  Audio group not found in system"
    fi
}

# Function to check device status
is_device_busy() {
    local card_num="$1"
    
    # Check if any PCM devices are open
    if lsof /dev/snd/pcmC${card_num}* 2>/dev/null | grep -q .; then
        return 0  # Device is busy
    fi
    
    return 1  # Device is not busy
}

# Main diagnostic function
main() {
    echo -e "${BOLD}${GREEN}Audio Device Diagnostic Report v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}Generated: $(date)${NC}"
    echo -e "${GREEN}Hostname: $(hostname)${NC}"
    echo -e "${GREEN}Kernel: $(uname -r)${NC}"
    
    # Check if running with sudo
    if [ "$EUID" -eq 0 ]; then
        echo -e "${GREEN}Running with root privileges${NC}"
    else
        echo -e "${YELLOW}Running without root privileges - some information may be limited${NC}"
    fi
    
    # System Information
    print_header "System Audio Information"
    
    print_subheader "ALSA Version"
    if check_command "aplay"; then
        aplay --version 2>/dev/null | head -n1 || echo "ALSA version unavailable"
    fi
    
    print_subheader "Sound Modules Loaded"
    lsmod 2>/dev/null | grep -E "^snd|^usb_audio" | sort || echo "No sound modules found"
    
    print_subheader "Audio Groups and Membership"
    list_audio_group_members
    echo
    echo -n "Current user ($(whoami)) audio access: "
    # Special case for root
    if [ "$EUID" -eq 0 ]; then
        echo -e "${GREEN}Yes (root has all permissions)${NC}"
    elif groups 2>/dev/null | grep -q audio; then
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
    
    # USB Audio Device Analysis
    print_header "USB Audio Device Analysis"
    
    for card in /proc/asound/card[0-9]*; do
        if [ -d "$card" ] && [ -f "$card/usbid" ]; then
            card_num=$(basename "$card" | sed 's/card//')
            card_id=$(cat "$card/id" 2>/dev/null || echo "unknown")
            usb_id=$(cat "$card/usbid" 2>/dev/null || echo "")
            usb_bus=$(cat "$card/usbbus" 2>/dev/null || echo "")
            
            print_subheader "Card $card_num: $card_id"
            
            # Check if device is busy
            if is_device_busy "$card_num"; then
                echo -e "${YELLOW}⚠ Device is currently in use${NC}"
            fi
            
            # USB information
            echo "USB ID: $usb_id"
            if [[ -n "$usb_bus" ]]; then
                echo "USB Bus: $usb_bus"
            fi
            
            # Parse USB bus info for speed and bandwidth
            if [[ "$usb_bus" =~ ([0-9]+)/([0-9]+) ]]; then
                bus="${BASH_REMATCH[1]}"
                dev="${BASH_REMATCH[2]}"
                
                # USB descriptors
                if check_command "lsusb"; then
                    echo
                    echo -e "${CYAN}USB Audio Descriptors:${NC}"
                    lsusb -v -s "${bus}:${dev}" 2>/dev/null | grep -A 50 "AudioControl" | grep -E "bNrChannels|wMaxPacketSize|bInterval|bBitResolution" | sed 's/^/    /' | head -10 || echo "  Unable to read descriptors"
                fi
                
                # Find USB speed
                for usb_dev in /sys/bus/usb/devices/*; do
                    if [ -f "$usb_dev/busnum" ] && [ -f "$usb_dev/devnum" ]; then
                        if [ "$(cat "$usb_dev/busnum" 2>/dev/null)" = "$bus" ] && \
                           [ "$(cat "$usb_dev/devnum" 2>/dev/null)" = "$dev" ]; then
                            
                            if [ -f "$usb_dev/speed" ]; then
                                speed=$(cat "$usb_dev/speed" 2>/dev/null)
                                echo
                                echo -e "${CYAN}USB Connection:${NC}"
                                echo "  Speed: $(get_usb_speed_string "$speed")"
                                
                                # Calculate bandwidth if we have bc
                                if check_command "bc" && [[ "$speed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                                    echo
                                    echo -e "${CYAN}Bandwidth Utilization:${NC}"
                                    echo "  16-bit 48kHz stereo: $(calculate_usb_bandwidth 2 16 48000 "$speed")"
                                    echo "  24-bit 48kHz stereo: $(calculate_usb_bandwidth 2 24 48000 "$speed")"
                                    echo "  24-bit 96kHz stereo: $(calculate_usb_bandwidth 2 24 96000 "$speed")"
                                fi
                            fi
                            break
                        fi
                    fi
                done
            fi
            
            # Reported USB capabilities from stream info
            if [ -f "$card/stream0" ]; then
                echo
                echo -e "${CYAN}Reported USB Capabilities:${NC}"
                grep -A 3 "Altset" "$card/stream0" 2>/dev/null | grep -E "Format:|Channels:|Rates:" | sed 's/^/    /' | head -10
            fi
            
            # Mono device detection
            echo
            echo -e "${CYAN}Channel Configuration:${NC}"
            detect_mono_device "$card_num" "$card_id" "$usb_id"
            
            # Audio levels
            echo
            echo -e "${CYAN}Current Audio Levels:${NC}"
            get_audio_levels "$card_num" "$card_id"
            
            # Latency measurements
            echo
            echo -e "${CYAN}Buffer Latency Information:${NC}"
            measure_audio_latency "$card_num"
            
            echo
        fi
    done
    
    # Device Nodes
    print_header "Audio Device Nodes"
    
    print_subheader "Character Devices (/dev/snd/)"
    if [ -d /dev/snd ]; then
        ls -la /dev/snd/ 2>/dev/null | grep -v "^total"
    else
        echo "/dev/snd/ directory not found"
    fi
    
    print_subheader "Device Symlinks (/dev/snd/by-id/)"
    if [ -d /dev/snd/by-id ]; then
        ls -la /dev/snd/by-id/ 2>/dev/null | grep -v "^total" || echo "No symlinks found"
    else
        echo "/dev/snd/by-id/ directory not found"
    fi
    
    print_subheader "Device Symlinks (/dev/snd/by-path/)"
    if [ -d /dev/snd/by-path ]; then
        ls -la /dev/snd/by-path/ 2>/dev/null | grep -v "^total" || echo "No symlinks found"
    else
        echo "/dev/snd/by-path/ directory not found"
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
                grep -iE "sound|audio|alsa" "$rule" 2>/dev/null | head -5
                echo
            fi
        done
        if [ "$found_rules" = false ]; then
            echo "No other audio-related rules found"
        fi
    fi
    
    # Process and RTSP Detection
    print_header "Audio Processes and Streams"
    detect_audio_processes
    
    # Memory and DMA Information
    print_header "Memory and DMA Information"
    
    print_subheader "Audio Memory Allocation"
    local total_audio_mem=0
    for card in /proc/asound/card[0-9]*; do
        if [ -d "$card" ]; then
            for meminfo in "$card"/pcm*/sub*/info; do
                if [ -r "$meminfo" ]; then
                    local mem_info=$(grep -E "buffer|period" "$meminfo" 2>/dev/null | head -5)
                    if [ -n "$mem_info" ]; then
                        echo "Card $(basename "$card"):"
                        echo "$mem_info" | sed 's/^/  /'
                        echo
                    fi
                fi
            done
        fi
    done
    
    print_subheader "System Memory"
    if [ -r /proc/meminfo ]; then
        grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached):" /proc/meminfo 2>/dev/null
    fi
    
    # System Load Information
    print_subheader "System Load"
    uptime 2>/dev/null || echo "Load information unavailable"
    echo
    echo "CPU cores: $(nproc 2>/dev/null || echo 'unknown')"
    
    # System Thermal Status
    print_header "System Thermal Status"
    
    local max_temp=0
    local temps=""
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [ -r "$zone" ]; then
            local temp=$(cat "$zone" 2>/dev/null || echo "0")
            local temp_c=$((temp / 1000))
            temps="${temps}${temp_c}°C "
            if [ $temp_c -gt $max_temp ]; then
                max_temp=$temp_c
            fi
        fi
    done
    
    if [ -n "$temps" ]; then
        echo "CPU temperatures: $temps"
        if [ $max_temp -gt 80 ]; then
            echo -e "${RED}✗ High temperature detected: ${max_temp}°C - may cause throttling${NC}"
        elif [ $max_temp -gt 70 ]; then
            echo -e "${YELLOW}⚠ Elevated temperature: ${max_temp}°C${NC}"
        else
            echo -e "${GREEN}✓ Temperature normal: ${max_temp}°C maximum${NC}"
        fi
    else
        echo "No thermal information available"
    fi
    
    # CPU Governor
    print_subheader "CPU Frequency Scaling"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "0")
        max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")
        cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
        
        echo "Governor: $governor"
        echo "Frequency range: $((min_freq/1000)) - $((max_freq/1000)) MHz"
        echo "Current frequency: $((cur_freq/1000)) MHz"
        
        if [ "$governor" = "performance" ]; then
            echo -e "${GREEN}✓ Performance governor - optimal for low latency${NC}"
        else
            echo -e "${YELLOW}⚠ Consider 'performance' governor for lowest latency${NC}"
        fi
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
                
                # Check if device is busy
                if is_device_busy "$card_num"; then
                    echo -e "  Status: ${YELLOW}IN USE${NC}"
                else
                    echo "  Status: Available"
                fi
                
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
                
                # Show PCM capabilities
                if [ -f "$card/pcm0c/info" ]; then
                    echo "  Capture capabilities: Yes"
                elif [ -f "$card/pcm0p/info" ]; then
                    echo "  Playback only: Yes"
                fi
            fi
        fi
    done
    
    print_subheader "Global ALSA Configuration"
    if [ -f /etc/asound.conf ]; then
        echo "System-wide config (/etc/asound.conf):"
        head -20 /etc/asound.conf 2>/dev/null
        if [ $(wc -l < /etc/asound.conf 2>/dev/null) -gt 20 ]; then
            echo "... (truncated, file has $(wc -l < /etc/asound.conf) lines)"
        fi
    else
        echo "No system-wide ALSA config found"
    fi
    
    if [ -f "$HOME/.asoundrc" ]; then
        echo
        echo "User config ($HOME/.asoundrc):"
        head -20 "$HOME/.asoundrc" 2>/dev/null
    fi
    
    print_subheader "Buffer Size Recommendations"
    echo -e "${CYAN}For different use cases:${NC}"
    echo
    echo -e "${BOLD}Low Latency (Live monitoring, real-time effects):${NC}"
    echo "  - Buffer size: 64-128 samples"
    echo "  - Period size: 32-64 samples"
    echo "  - Expected latency: 1.3-2.7ms @ 48kHz"
    echo
    echo -e "${BOLD}Balanced (General recording/playback):${NC}"
    echo "  - Buffer size: 256-512 samples"
    echo "  - Period size: 128-256 samples"
    echo "  - Expected latency: 5.3-10.7ms @ 48kHz"
    echo
    echo -e "${BOLD}Stable (Heavy processing, stability priority):${NC}"
    echo "  - Buffer size: 1024-2048 samples"
    echo "  - Period size: 512-1024 samples"
    echo "  - Expected latency: 21.3-42.7ms @ 48kHz"
    
    # Hardware Capabilities
    print_header "Hardware Capabilities"
    
    print_subheader "USB Audio Device Details"
    for card in /proc/asound/card[0-9]*; do
        if [ -f "$card/usbid" ] && [ -f "$card/stream0" ]; then
            card_num=$(basename "$card" | sed 's/card//')
            card_id=$(cat "$card/id" 2>/dev/null)
            echo -e "${CYAN}Card $card_num ($card_id):${NC}"
            
            # Get actual hardware parameters
            echo "  Actual hardware parameters:"
            if [ -f "$card/pcm0c/sub0/hw_params" ]; then
                if [ -s "$card/pcm0c/sub0/hw_params" ]; then
                    echo "    Current capture settings:"
                    cat "$card/pcm0c/sub0/hw_params" 2>/dev/null | sed 's/^/      /'
                else
                    echo "    Device not in use (checking capabilities...)"
                    
                    # Try to probe actual capabilities
                    if check_command "arecord"; then
                        # Get format support
                        formats=$(arecord -D "hw:$card_num" --dump-hw-params 2>&1 | grep -A20 "^ACCESS:" | grep -E "FORMAT:|CHANNELS:|RATE:" | head -6)
                        if [ -n "$formats" ]; then
                            echo "$formats" | sed 's/^/      /'
                        fi
                    fi
                fi
            fi
            echo
        fi
    done
    
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
    
    # Audio Performance Settings
    print_header "Audio Performance Settings"
    
    print_subheader "Real-time Priority"
    if [ -f /etc/security/limits.d/audio.conf ]; then
        echo "Audio limits configuration found:"
        cat /etc/security/limits.d/audio.conf 2>/dev/null | grep -v "^#" | grep -v "^$"
    else
        echo "No specific audio limits configured"
    fi
    
    if check_command "ulimit"; then
        echo
        echo "Current user limits:"
        echo "  Real-time priority: $(ulimit -r 2>/dev/null || echo 'Not available')"
        echo "  Locked memory: $(ulimit -l 2>/dev/null || echo 'Not available')"
    fi
    
    print_subheader "USB Power Management"
    echo "USB Autosuspend status:"
    local found_audio=false
    
    # Check all USB devices for audio interfaces
    for device in /sys/bus/usb/devices/[0-9]*; do
        if [ -d "$device" ]; then
            device_name=$(basename "$device")
            
            # Check if this device has audio interfaces
            has_audio=false
            for interface in "$device"/*:*/bInterfaceClass; do
                if [ -f "$interface" ]; then
                    class=$(cat "$interface" 2>/dev/null)
                    if [ "$class" = "01" ]; then  # Audio class
                        has_audio=true
                        break
                    fi
                fi
            done
            
            # If it's an audio device, check power management
            if [ "$has_audio" = true ]; then
                found_audio=true
                
                # Check autosuspend status
                if [ -f "$device/power/autosuspend" ]; then
                    autosuspend=$(cat "$device/power/autosuspend" 2>/dev/null)
                else
                    autosuspend="unknown"
                fi
                
                # Get device description
                product="Unknown"
                if [ -f "$device/product" ]; then
                    product=$(cat "$device/product" 2>/dev/null)
                fi
                
                # Display status with proper color coding
                if [ "$autosuspend" = "-1" ]; then
                    echo -e "  $device_name ($product): ${GREEN}Disabled (good for audio)${NC}"
                elif [ "$autosuspend" = "unknown" ]; then
                    echo "  $device_name ($product): Status unknown"
                else
                    echo -e "  $device_name ($product): ${YELLOW}Enabled - ${autosuspend}s timeout (may cause audio issues)${NC}"
                fi
                
                # Also check control status
                if [ -f "$device/power/control" ]; then
                    control=$(cat "$device/power/control" 2>/dev/null)
                    echo "    Power control: $control"
                fi
            fi
        fi
    done
    
    if [ "$found_audio" = false ]; then
        echo "  No USB audio devices found to check"
    fi
    
    # Show how to disable autosuspend if needed
    echo
    echo "To disable USB autosuspend for audio devices:"
    echo "  echo -1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend"
    
    print_subheader "CPU Governor and Frequency"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        echo "CPU Governor: $governor"
        
        if [ "$governor" = "performance" ]; then
            echo -e "  ${GREEN}Good for low-latency audio${NC}"
        elif [ "$governor" = "ondemand" ] || [ "$governor" = "conservative" ]; then
            echo -e "  ${YELLOW}May cause audio glitches during frequency changes${NC}"
        fi
        
        # Show current frequencies
        echo
        echo "CPU Frequencies:"
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            if [ -f "$cpu/cpufreq/scaling_cur_freq" ]; then
                cpu_num=$(basename "$cpu")
                freq=$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null)
                freq_mhz=$((freq / 1000))
                echo "  $cpu_num: ${freq_mhz} MHz"
            fi
        done | head -n 4  # Show first 4 CPUs
    fi
    
    print_subheader "System Audio Interrupts"
    echo "Audio-related IRQs:"
    grep -E "snd|usb|xhci" /proc/interrupts 2>/dev/null | while read -r line; do
        irq=$(echo "$line" | awk '{print $1}' | tr -d ':')
        count=$(echo "$line" | awk '{sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}')
        desc=$(echo "$line" | awk '{print $NF}')
        
        # Check CPU affinity
        if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
            cpus=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)
            echo "  IRQ $irq: $desc"
            echo "    Interrupts: $count"
            echo "    CPU affinity: $cpus"
        fi
    done || echo "  Unable to read interrupt information"
    
    # Microphone Configuration Recommendations
    print_header "Microphone Configuration"
    provide_mic_recommendations
    
    # Enhanced Summary
    print_header "Summary"
    
    # Count devices and get names
    echo -e "${BOLD}Audio Devices:${NC}"
    local card_count=0
    local usb_count=0
    local busy_count=0
    local capture_count=0
    local playback_count=0
    
    for card in /proc/asound/card[0-9]*; do
        if [ -f "$card/id" ]; then
            card_num=$(basename "$card" | sed 's/card//')
            card_id=$(cat "$card/id" 2>/dev/null)
            ((card_count++))
            
            # Check if device is busy
            local busy_status=""
            if is_device_busy "$card_num"; then
                ((busy_count++))
                busy_status=" ${GREEN}[IN USE]${NC}"
            fi
            
            # Check capabilities
            if [ -f "$card/pcm0c/info" ]; then
                ((capture_count++))
            fi
            if [ -f "$card/pcm0p/info" ]; then
                ((playback_count++))
            fi
            
            # Check if USB
            if [ -f "$card/usbid" ]; then
                ((usb_count++))
                usb_id=$(cat "$card/usbid" 2>/dev/null)
                echo -e "  Card $card_num: ${CYAN}$card_id${NC} (USB: $usb_id)$busy_status"
                echo "    Status: USB Audio Device"
            else
                echo -e "  Card $card_num: ${CYAN}$card_id${NC}$busy_status"
                echo "    Status: Internal/PCI Audio Device"
            fi
        fi
    done
    
    echo
    echo -e "${BOLD}Statistics:${NC}"
    echo "  Total sound cards: $card_count"
    echo "  USB audio devices: $usb_count"
    echo "  Capture devices: $capture_count"
    echo "  Playback devices: $playback_count"
    echo "  Devices in use: $busy_count"
    
    # Audio group membership
    local audio_members=$(getent group audio 2>/dev/null | cut -d: -f4 | tr ',' ' ' | wc -w)
    echo "  Audio group members: $audio_members users"
    
    # Check for persistent rules
    if [ -f /etc/udev/rules.d/99-usb-soundcards.rules ]; then
        rule_count=$(grep -c "^SUBSYSTEM" /etc/udev/rules.d/99-usb-soundcards.rules 2>/dev/null || echo "0")
        echo "  Persistent naming rules: $rule_count"
    else
        echo "  Persistent naming rules: ${YELLOW}Not configured${NC}"
    fi
    
    # Check for RTSP streams
    local rtsp_count=$(ps aux | grep -i rtsp | grep -v grep | wc -l)
    if [ $rtsp_count -gt 0 ]; then
        echo -e "  RTSP streams/services: ${MAGENTA}$rtsp_count detected${NC}"
    fi
    
    # Audio levels summary
    echo
    echo -e "${BOLD}Audio Levels Summary:${NC}"
    local high_levels=0
    local low_levels=0
    
    for card in /proc/asound/card[0-9]*; do
        if [ -f "$card/id" ]; then
            card_num=$(basename "$card" | sed 's/card//')
            # Check for high/low levels (simplified check)
            local levels=$(amixer -c "$card_num" scontents 2>/dev/null | grep -E "\[[0-9]+%\]" | grep -oE "[0-9]+%" | tr -d '%')
            for level in $levels; do
                if [ "$level" -gt 90 ]; then
                    ((high_levels++))
                elif [ "$level" -lt 30 ]; then
                    ((low_levels++))
                fi
            done
        fi
    done
    
    if [ $high_levels -gt 0 ]; then
        echo -e "  ${RED}High levels (>90%): $high_levels controls${NC}"
    fi
    if [ $low_levels -gt 0 ]; then
        echo -e "  ${YELLOW}Low levels (<30%): $low_levels controls${NC}"
    fi
    if [ $high_levels -eq 0 ] && [ $low_levels -eq 0 ]; then
        echo -e "  ${GREEN}All levels within normal range${NC}"
    fi
    
    # Check for common issues
    echo
    echo -e "${BOLD}Potential Issues:${NC}"
    issues_found=false
    local issue_count=0
    
    if [ "$card_count" -eq 0 ]; then
        echo -e "  ${RED}• No sound cards detected${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    if [ "$usb_count" -eq 0 ]; then
        echo -e "  ${YELLOW}• No USB audio devices detected${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    # Check audio group membership (except for root)
    if [ "$EUID" -ne 0 ] && ! groups 2>/dev/null | grep -q audio; then
        echo -e "  ${YELLOW}• Current user not in audio group${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    if [ ! -d /dev/snd ]; then
        echo -e "  ${RED}• /dev/snd directory missing - ALSA may not be properly installed${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    # Check for USB power management issues
    usb_pm_issues=false
    for device in /sys/bus/usb/devices/[0-9]*; do
        if [ -d "$device" ]; then
            # Check if this device has audio interfaces
            has_audio=false
            for interface in "$device"/*:*/bInterfaceClass; do
                if [ -f "$interface" ]; then
                    class=$(cat "$interface" 2>/dev/null)
                    if [ "$class" = "01" ]; then
                        has_audio=true
                        break
                    fi
                fi
            done
            
            if [ "$has_audio" = true ] && [ -f "$device/power/autosuspend" ]; then
                autosuspend=$(cat "$device/power/autosuspend" 2>/dev/null)
                if [ "$autosuspend" != "-1" ] && [ "$autosuspend" != "unknown" ] && [ -n "$autosuspend" ]; then
                    usb_pm_issues=true
                fi
            fi
        fi
    done
    
    if [ "$usb_pm_issues" = true ]; then
        echo -e "  ${YELLOW}• USB autosuspend enabled for audio devices (may cause dropouts)${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    # Check CPU governor
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        if [ "$governor" != "performance" ] && [ "$governor" != "schedutil" ]; then
            echo -e "  ${YELLOW}• CPU governor '$governor' may cause audio latency issues${NC}"
            issues_found=true
            ((issue_count++))
        fi
    fi
    
    # Check for real-time priority
    rt_prio=$(ulimit -r 2>/dev/null || echo "0")
    if [ "$rt_prio" = "0" ] || [ "$rt_prio" = "-" ]; then
        echo -e "  ${YELLOW}• No real-time priority available for audio applications${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    # Check for mono/stereo mismatches
    for card in /proc/asound/card[0-9]*; do
        if [ -f "$card/id" ] && [ -f "$card/usbid" ]; then
            card_id=$(cat "$card/id" 2>/dev/null)
            usb_id=$(cat "$card/usbid" 2>/dev/null)
            # Check if it's a known mono device
            if [ -n "${KNOWN_MONO_DEVICES[$usb_id]:-}" ]; then
                echo -e "  ${YELLOW}• $card_id may report stereo but is mono (${KNOWN_MONO_DEVICES[$usb_id]})${NC}"
                issues_found=true
                ((issue_count++))
            fi
        fi
    done
    
    # Check for high audio levels
    if [ $high_levels -gt 0 ]; then
        echo -e "  ${RED}• $high_levels audio controls set above 90% (risk of clipping)${NC}"
        issues_found=true
        ((issue_count++))
    fi
    
    if [ "$issues_found" = false ]; then
        echo -e "  ${GREEN}• No obvious issues detected${NC}"
    else
        echo
        echo -e "  ${BOLD}Total issues found: $issue_count${NC}"
    fi
    
    echo
    echo -e "${BOLD}System Performance:${NC}"
    
    # Get load average
    local loadavg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    local cpu_count=$(nproc 2>/dev/null || echo "1")
    echo "  Load average: $loadavg (${cpu_count} CPU cores)"
    
    # Check if system is under load
    local load1=$(echo "$loadavg" | awk '{print $1}' | cut -d. -f1)
    if [ "$load1" -gt "$cpu_count" ]; then
        echo -e "  ${YELLOW}System under heavy load - may affect audio performance${NC}"
    else
        echo -e "  ${GREEN}System load normal${NC}"
    fi
    
    echo
    echo -e "${BOLD}Recommendations:${NC}"
    
    # Provide recommendations based on findings
    if [ "$usb_pm_issues" = true ]; then
        echo "  • Disable USB autosuspend: echo -1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend"
    fi
    
    if [ "$rt_prio" = "0" ] || [ "$rt_prio" = "-" ]; then
        echo "  • Enable real-time audio: sudo usermod -a -G audio $USER && echo '@audio - rtprio 95' | sudo tee /etc/security/limits.d/audio.conf"
    fi
    
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        if [ "$governor" != "performance" ]; then
            echo "  • For lowest latency: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
        fi
    fi
    
    if [ $high_levels -gt 0 ]; then
        echo "  • Reduce capture levels below 90% to prevent clipping"
    fi
    
    if [ $low_levels -gt 0 ]; then
        echo "  • Consider increasing levels above 30% for better signal-to-noise ratio"
    fi
    
    # Always show these
    echo "  • Review audio levels in device analysis sections above"
    echo "  • See Microphone Configuration section for detailed setup guidance"
    
    if [ ! -f /etc/udev/rules.d/99-usb-soundcards.rules ] && [ $usb_count -gt 0 ]; then
        echo "  • Consider creating persistent USB audio device names with udev rules"
    fi
    
    echo
    echo -e "${BOLD}${GREEN}Diagnostic report complete (v${SCRIPT_VERSION})${NC}"
    
    # Save log file location if created
    if [ -d "$TEMP_DIR" ] && [ -f "$LOG_FILE" ]; then
        echo -e "${DIM}Log file: $LOG_FILE${NC}"
    fi
}

# Run main function
main "$@"
