#!/bin/bash
# Universal Raspberry Pi Rust Installation Script
# Version: 2.0.0
# License: MIT
# Description: Installs Rust toolchain optimized for any Raspberry Pi model
# 
# Error Codes:
# 1 - Missing dependencies or command failure
# 2 - Architecture/platform not supported
# 3 - Installation failure
# 4 - Verification failure
# 5 - Insufficient permissions
# 6 - Network connectivity issues
# 7 - Configuration error

# ---------- CONFIGURATION ----------
# Can be overridden with environment variables
: "${RUST_PROFILE:=minimal}"
: "${LOG_FILE:=/tmp/rust-pi-installer.log}"
: "${CARGO_CONFIG_PATH:=$HOME/.cargo/config.toml}"
: "${RUSTUP_INIT_TEMP:=/tmp/rustup-init}"
: "${DEBUG_MODE:=false}"

# ---------- CONSTANTS ----------
# Color codes for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# ---------- GLOBAL VARIABLES ----------
DETECTED_PI_MODEL=""
RUST_TARGET=""
LINKER=""
NEED_RUSTUP_REINSTALL=false
SUPPORTED_ARCHS=("arm64" "armhf" "armel")
VERBOSITY=1 # 0=quiet, 1=normal, 2=verbose

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
echo "# Rust Pi Installer Log - $(date)" > "$LOG_FILE"

# ---------- UTILITY FUNCTIONS ----------

# Logging function with levels: DEBUG, INFO, WARN, ERROR
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Always log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Terminal output based on verbosity and level
    case $level in
        "DEBUG")
            [[ "$DEBUG_MODE" == "true" ]] && echo -e "${CYAN}[DEBUG] $message${NC}"
            ;;
        "INFO")
            [[ $VERBOSITY -ge 1 ]] && echo -e "${GREEN}[INFO] $message${NC}"
            ;;
        "WARN")
            [[ $VERBOSITY -ge 1 ]] && echo -e "${YELLOW}[WARN] $message${NC}"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR] $message${NC}" >&2
            ;;
        *)
            echo -e "$message"
            ;;
    esac
}

# Print section header
print_header() {
    local step=$1
    local title=$2
    echo -e "\n${MAGENTA}[$step] $title ${NC}"
    log "INFO" "Starting: $title"
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check for root/sudo
check_permissions() {
    if [[ $EUID -eq 0 ]]; then
        log "WARN" "Running as root is not recommended. Consider using a regular user with sudo privileges."
    elif ! command_exists sudo; then
        log "ERROR" "sudo command not found. Please install sudo or run as root."
        exit 5
    fi
}

# Check internet connectivity
check_connectivity() {
    log "INFO" "Checking internet connectivity..."
    
    # Next try HTTP requests which may work even if ICMP is blocked
    if curl --max-time 5 --silent --head https://www.rust-lang.org &>/dev/null || 
       curl --max-time 5 --silent --head https://www.google.com &>/dev/null; then
        log "DEBUG" "HTTP connectivity successful"
        return 0
    fi
    
    # Try DNS lookups which don't require ping permissions
    if command_exists host && (host -W 2 rust-lang.org &>/dev/null || host -W 2 google.com &>/dev/null); then
        log "DEBUG" "DNS resolution successful"
        return 0
    fi
    
    # Finally try ping if available and allowed
    if command_exists ping; then
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
            log "DEBUG" "Ping successful"
            return 0
        fi
    fi
    
    # If we get here, connectivity checks failed
    log "WARN" "Internet connectivity checks failed."
    
    # Ask user if they want to continue anyway
    echo -e "${YELLOW}We couldn't verify your internet connection.${NC}"
    echo -e "This script needs internet access to download Rust."
    echo -ne "Continue anyway? [y/N]: "
    
    local response
    read -r response
    case "$response" in
        [Yy]*)
            log "INFO" "Proceeding without confirmed connectivity by user request"
            return 0
            ;;
        *)
            log "ERROR" "Installation aborted: no internet connectivity detected"
            exit 6
            ;;
    esac
}

# Safe command execution with error handling
safe_exec() {
    local cmd=$1
    local error_msg=$2
    local exit_code=$3
    
    log "DEBUG" "Executing: $cmd"
    if ! eval "$cmd"; then
        log "ERROR" "$error_msg"
        exit "${exit_code:-1}"
    fi
}

# Cleanup function registered with trap
cleanup() {
    local exit_code=$?
    
    log "INFO" "Cleaning up temporary files..."
    rm -rf "$RUSTUP_INIT_TEMP"
    
    if [[ $exit_code -ne 0 ]]; then
        log "WARN" "Installation exited with code $exit_code. See $LOG_FILE for details."
    fi
}

# ---------- DETECTION FUNCTIONS ----------

# Detect the exact Raspberry Pi model
detect_pi_model() {
    local model=""
    local revision=""
    
    if [[ -f /proc/device-tree/model ]]; then
        model=$(tr -d '\0' < /proc/device-tree/model)
    fi
    
    if [[ -f /proc/cpuinfo ]]; then
        revision=$(grep "Revision" /proc/cpuinfo | awk '{print $3}' | sed 's/^1000//' || echo "")
    fi
    
    if [[ -z "$model" || ! "$model" =~ "Raspberry Pi" ]]; then
        log "WARN" "Could not positively identify as a Raspberry Pi. Continuing with generic ARM configuration."
        DETECTED_PI_MODEL="Unknown ARM Device"
        return
    fi
    
    DETECTED_PI_MODEL="$model"
    log "INFO" "Detected Raspberry Pi model: $DETECTED_PI_MODEL (Hardware revision: $revision)"
}

# Detect system architecture and set appropriate Rust target
detect_architecture() {
    local user_arch="unknown"
    local kernel_arch=$(uname -m)
    local cpu_info=""
    
    log "INFO" "Detecting system architecture..."
    
    # Try to get userland architecture through different methods
    if command_exists dpkg; then
        user_arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    elif command_exists lscpu; then
        user_arch=$(lscpu | grep "Architecture" | awk '{print $2}')
    fi
    
    log "DEBUG" "Userland architecture: $user_arch"
    log "DEBUG" "Kernel architecture: $kernel_arch"
    
    # Read CPU information for more specific detection
    if [[ -f /proc/cpuinfo ]]; then
        # First check for Hardware field which is common on ARM systems
        local hw=$(grep -i "Hardware" /proc/cpuinfo | head -1 | awk -F': ' '{print $2}' || echo "")
        local model=$(grep -i "model name" /proc/cpuinfo | head -1 | awk -F': ' '{print $2}' || echo "")
        local cpu_arch=$(grep -i "CPU architecture" /proc/cpuinfo | head -1 | awk -F': ' '{print $2}' || echo "")
        
        log "DEBUG" "Hardware: $hw"
        log "DEBUG" "CPU Model: $model"
        log "DEBUG" "CPU Architecture: $cpu_arch"
        
        # Combine relevant info
        cpu_info="$hw $model $cpu_arch"
    fi
    
    # Determine architecture based on kernel
    if [[ -z "$RUST_TARGET" ]]; then
        case "$kernel_arch" in
            "aarch64")
                RUST_TARGET="aarch64-unknown-linux-gnu"
                LINKER="gcc"
                ;;
            "armv7l")
                # Most Pi 2+ models
                RUST_TARGET="armv7-unknown-linux-gnueabihf"
                LINKER="arm-linux-gnueabihf-gcc"
                ;;
            "armv6l")
                # Pi 1, Zero, Zero W
                RUST_TARGET="arm-unknown-linux-gnueabihf"
                LINKER="arm-linux-gnueabihf-gcc"
                ;;
            "x86_64")
                # Just in case someone runs this on x86
                RUST_TARGET="x86_64-unknown-linux-gnu"
                LINKER="gcc"
                ;;
            "i686")
                RUST_TARGET="i686-unknown-linux-gnu"
                LINKER="gcc"
                ;;
            *)
                # Further attempt to determine architecture
                if [[ "$cpu_info" =~ "BCM" || "$cpu_info" =~ "Raspberry" ]]; then
                    # It's definitely a Raspberry Pi, default to ARM
                    log "WARN" "Unknown ARM architecture. Defaulting to armv7-unknown-linux-gnueabihf"
                    RUST_TARGET="armv7-unknown-linux-gnueabihf"
                    LINKER="arm-linux-gnueabihf-gcc"
                else
                    log "ERROR" "Could not determine appropriate Rust target for architecture: $kernel_arch"
                    log "ERROR" "Please specify the target manually with --target=TARGET"
                    exit 2
                fi
                ;;
        esac
    fi
    
    # Adjust target based on Pi model if needed
    if [[ "$DETECTED_PI_MODEL" =~ "Pi 1" || "$DETECTED_PI_MODEL" =~ "Zero" ]]; then
        if [[ "$kernel_arch" == "armv6l" ]]; then
            RUST_TARGET="arm-unknown-linux-gnueabihf"
            LINKER="arm-linux-gnueabihf-gcc"
            log "INFO" "Adjusted target for Raspberry Pi 1/Zero model"
        fi
    fi
    
    # Verify we have a target
    if [[ -z "$RUST_TARGET" ]]; then
        log "ERROR" "Failed to determine Rust target. Please specify manually with --target=TARGET"
        exit 2
    fi
    
    log "INFO" "Selected Rust target: $RUST_TARGET"
    log "INFO" "Selected linker: $LINKER"
}

# ---------- INSTALLATION FUNCTIONS ----------

# Install required system dependencies
install_dependencies() {
    local standard_deps=(
        git curl gcc make pkg-config
    )
    
    local debian_deps=(
        build-essential libssl-dev 
    )
    
    local arm_deps=()
    local package_manager=""
    local update_cmd=""
    local install_cmd=""
    
    # Detect package manager
    if command_exists apt-get; then
        package_manager="apt"
        update_cmd="sudo apt-get update"
        install_cmd="sudo apt-get install -y"
    elif command_exists dnf; then
        package_manager="dnf"
        update_cmd="sudo dnf check-update || true"  # dnf returns 100 if updates are available
        install_cmd="sudo dnf install -y"
        debian_deps=(
            gcc-c++ openssl-devel
        )
    elif command_exists yum; then
        package_manager="yum"
        update_cmd="sudo yum check-update || true"
        install_cmd="sudo yum install -y"
        debian_deps=(
            gcc-c++ openssl-devel
        )
    elif command_exists pacman; then
        package_manager="pacman"
        update_cmd="sudo pacman -Sy"
        install_cmd="sudo pacman -S --noconfirm"
        debian_deps=(
            base-devel openssl
        )
    elif command_exists zypper; then
        package_manager="zypper"
        update_cmd="sudo zypper refresh"
        install_cmd="sudo zypper install -y"
        debian_deps=(
            gcc-c++ libopenssl-devel
        )
    else
        log "WARN" "Could not detect package manager. Skipping automatic dependency installation."
        log "INFO" "Please ensure the following are installed: git, curl, gcc, make, pkg-config, libssl-dev"
        
        # Verify critical dependencies even if we can't install
        for dep in curl git gcc; do
            if ! command_exists "$dep"; then
                log "ERROR" "Critical dependency '$dep' not installed."
                log "ERROR" "Please install required dependencies manually and try again."
                exit 1
            fi
        done
        return
    fi
    
    log "INFO" "Detected package manager: $package_manager"
    
    # Add architecture-specific dependencies based on package manager
    if [[ "$package_manager" == "apt" ]]; then
        case "$RUST_TARGET" in
            *"gnueabihf"*)
                arm_deps+=(gcc-arm-linux-gnueabihf libc6-dev-armhf-cross)
                ;;
            *"gnueabi"*)
                arm_deps+=(gcc-arm-linux-gnueabi libc6-dev-armel-cross)
                ;;
        esac
    else
        log "WARN" "Cross-compilation dependencies may need to be installed manually for $package_manager"
    fi
    
    log "INFO" "Installing system dependencies..."
    
    # Combine all dependencies
    local all_deps=("${standard_deps[@]}" "${debian_deps[@]}" "${arm_deps[@]}")
    
    # Update package lists
    log "DEBUG" "Running update command: $update_cmd"
    if ! eval "$update_cmd"; then
        log "WARN" "Package manager update failed. Attempting to continue with installation."
    fi
    
    # Install dependencies
    log "DEBUG" "Installing packages: ${all_deps[*]}"
    if ! eval "$install_cmd ${all_deps[*]}"; then
        log "WARN" "Some packages failed to install. Attempting to continue."
        
        # Try installing packages one by one
        log "INFO" "Trying to install packages individually..."
        for pkg in "${all_deps[@]}"; do
            eval "$install_cmd $pkg" || log "WARN" "Failed to install $pkg"
        done
    fi
    
    # Verify critical dependencies
    for dep in curl git gcc; do
        if ! command_exists "$dep"; then
            log "ERROR" "Critical dependency '$dep' not installed."
            exit 1
        fi
    done
}

# Install Rust toolchain
install_rust() {
    local rustup_opts=(
        -y 
        --default-host "$RUST_TARGET" 
        --profile "$RUST_PROFILE"
        --no-modify-path
    )
    
    log "INFO" "Installing Rust toolchain for $RUST_TARGET..."
    
    # Check if rustup is already installed
    if command_exists rustup && [[ "$NEED_RUSTUP_REINSTALL" != "true" ]]; then
        log "INFO" "rustup already installed, updating components..."
        safe_exec "rustup update" "Failed to update existing Rust installation" 3
        safe_exec "rustup target add $RUST_TARGET" "Failed to add target $RUST_TARGET" 3
    else
        # Download rustup-init
        log "INFO" "Downloading rustup installer..."
        safe_exec "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o $RUSTUP_INIT_TEMP" \
            "Failed to download rustup installer" 6
        
        # Make executable
        safe_exec "chmod +x $RUSTUP_INIT_TEMP" "Failed to make rustup installer executable" 5
        
        # Run rustup-init
        log "INFO" "Running rustup installer with options: ${rustup_opts[*]}"
        if ! "$RUSTUP_INIT_TEMP" "${rustup_opts[@]}"; then
            log "ERROR" "Rust installation failed. Check $LOG_FILE for details."
            exit 3
        fi
    fi
}

# Configure Rust environment
configure_environment() {
    local cargo_env="$HOME/.cargo/env"
    local cargo_config_dir=$(dirname "$CARGO_CONFIG_PATH")
    
    log "INFO" "Configuring Rust environment..."
    
    # Create cargo config directory if it doesn't exist
    if [[ ! -d "$cargo_config_dir" ]]; then
        safe_exec "mkdir -p $cargo_config_dir" "Failed to create cargo config directory" 7
    fi
    
    # Update PATH in shell config if not already present
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rcfile" ]]; then
            if ! grep -q "\.cargo/env" "$rcfile"; then
                log "INFO" "Adding cargo to PATH in $rcfile"
                echo 'source "$HOME/.cargo/env"' >> "$rcfile"
            fi
        fi
    done
    
    # Create cargo config
    log "INFO" "Creating cargo configuration for $RUST_TARGET..."
    cat > "$CARGO_CONFIG_PATH" <<EOF
# Auto-generated by Universal Raspberry Pi Rust Installer
# Target-specific settings
[target.$RUST_TARGET]
linker = "$LINKER"

# Optimize for Raspberry Pi
[profile.release]
lto = true
codegen-units = 1
opt-level = 3
debug = false
EOF
    
    # Source cargo environment for the current session
    if [[ -f "$cargo_env" ]]; then
        source "$cargo_env"
        export PATH="$HOME/.cargo/bin:$PATH"
    else
        log "WARN" "Cargo environment file not found at $cargo_env."
    fi
}

# ---------- VERIFICATION FUNCTIONS ----------

# Verify the Rust installation
verify_installation() {
    log "INFO" "Verifying Rust installation..."
    
    # Check for required binaries
    for cmd in rustc cargo rustup; do
        if ! command_exists "$cmd"; then
            log "ERROR" "$cmd not found in PATH"
            log "DEBUG" "Current PATH: $PATH"
            exit 4
        fi
    done
    
    # Get versions
    local rustc_version=$(rustc --version | awk '{print $2}')
    local cargo_version=$(cargo --version | awk '{print $2}')
    local rustup_version=$(rustup --version | awk '{print $2}')
    
    log "INFO" "Rustc version: $rustc_version"
    log "INFO" "Cargo version: $cargo_version"
    log "INFO" "Rustup version: $rustup_version"
    
    # Verify target
    if ! rustup target list --installed | grep -q "$RUST_TARGET"; then
        log "WARN" "Target $RUST_TARGET not installed. Attempting to add it."
        safe_exec "rustup target add $RUST_TARGET" "Failed to add target $RUST_TARGET" 4
    fi
}

# Run a simple test program
test_installation() {
    local test_dir="/tmp/rust-pi-test"
    local test_program="
fn main() {
    println!(\"Hello from Rust on {}\", std::env::consts::OS);
    println!(\"Architecture: {}\", std::env::consts::ARCH);
    println!(\"Rust version: {}\", rustc_version::version_meta().unwrap().semver);
}
"
    local cargo_toml="
[package]
name = \"rust_pi_test\"
version = \"0.1.0\"
edition = \"2021\"

[dependencies]
rustc_version = \"0.4.0\"
"
    
    log "INFO" "Running test program..."
    
    # Create test directory and files
    rm -rf "$test_dir"
    mkdir -p "$test_dir/src"
    echo "$cargo_toml" > "$test_dir/Cargo.toml"
    echo "$test_program" > "$test_dir/src/main.rs"
    
    # Build and run
    cd "$test_dir"
    if cargo build --release; then
        log "INFO" "Test program build successful."
        
        # Try to run the test program
        if cargo run --release; then
            log "INFO" "Test program ran successfully! Rust is working correctly."
        else
            log "WARN" "Test program built but failed to run. This may indicate an issue with the target configuration."
        fi
    else
        log "WARN" "Test program failed to build. There may be an issue with the Rust toolchain."
    fi
    
    # Cleanup test
    cd "$OLDPWD"
    rm -rf "$test_dir"
}

# ---------- MAIN EXECUTION ----------

display_banner() {
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║  Universal Raspberry Pi Rust Installation Tool  ║"
    echo "║             Version 2.0.0 - MIT License         ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

display_summary() {
    echo -e "\n${GREEN}════════ INSTALLATION SUMMARY ════════${NC}"
    echo -e "Device:       ${CYAN}$DETECTED_PI_MODEL${NC}"
    echo -e "Rust Target:  ${CYAN}$RUST_TARGET${NC}"
    echo -e "Linker:       ${CYAN}$LINKER${NC}"
    echo -e "Profile:      ${CYAN}$RUST_PROFILE${NC}"
    echo -e "Cargo Config: ${CYAN}$CARGO_CONFIG_PATH${NC}"
    echo -e "Log File:     ${CYAN}$LOG_FILE${NC}"
    echo
    echo -e "${GREEN}════════ NEXT STEPS ════════${NC}"
    echo -e "1. Start a new terminal session or run: ${CYAN}source ~/.cargo/env${NC}"
    echo -e "2. Verify installation: ${CYAN}rustc --version${NC}"
    echo -e "3. Create a new project: ${CYAN}cargo new hello_world${NC}"
    echo -e "4. Build and run: ${CYAN}cd hello_world && cargo run${NC}"
    echo
    echo -e "For troubleshooting, check the log at: ${CYAN}$LOG_FILE${NC}"
}

parse_args() {
    local arg
    
    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                echo "Universal Raspberry Pi Rust Installer"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --help, -h              Show this help message"
                echo "  --verbose, -v           Enable verbose output"
                echo "  --quiet, -q             Minimize output"
                echo "  --debug, -d             Enable debug mode"
                echo "  --profile=PROFILE       Set Rust profile (minimal, default, complete)"
                echo "  --target=TARGET         Manually set Rust target"
                echo "  --reinstall             Force reinstallation of rustup"
                echo ""
                exit 0
                ;;
            --verbose|-v)
                VERBOSITY=2
                DEBUG_MODE=true
                ;;
            --quiet|-q)
                VERBOSITY=0
                ;;
            --debug|-d)
                DEBUG_MODE=true
                ;;
            --profile=*)
                RUST_PROFILE="${arg#*=}"
                ;;
            --target=*)
                RUST_TARGET="${arg#*=}"
                ;;
            --reinstall)
                NEED_RUSTUP_REINSTALL=true
                ;;
            *)
                log "WARN" "Unknown option: $arg (ignoring)"
                ;;
        esac
    done
}

main() {
    # Parse command line arguments
    parse_args "$@"
    
    # Register cleanup function
    trap cleanup EXIT
    
    # Start installation
    display_banner
    
    # Initial checks
    check_permissions
    check_connectivity
    
    # Architecture detection
    print_header "1/8" "Detecting hardware"
    detect_pi_model
    detect_architecture
    
    # Install dependencies
    print_header "2/8" "Installing dependencies"
    install_dependencies
    
    # Install Rust
    print_header "3/8" "Installing Rust"
    install_rust
    
    # Configure environment
    print_header "4/8" "Configuring environment"
    configure_environment
    
    # Verify installation
    print_header "5/8" "Verifying installation"
    verify_installation
    
    # Test installation
    print_header "6/8" "Testing installation"
    test_installation
    
    # Show post-install information
    print_header "7/8" "Installation complete"
    display_summary
    
    log "INFO" "Installation completed successfully"
    return 0
}

# Execute main function
main "$@"
