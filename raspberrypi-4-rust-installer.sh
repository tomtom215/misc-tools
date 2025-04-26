#!/bin/bash
# Raspberry Pi 4 Rust Production Installation Script
# Version: 1.2.0
# License: MIT
# Error Codes:
# 1 - Missing dependencies
# 2 - Architecture mismatch
# 3 - Installation failure
# 4 - Verification failure

set -eo pipefail
IFS=$'\n\t'

# Configuration
RUST_PROFILE="minimal"
SUPPORTED_ARCHS=("arm64" "armhf")
CARGO_CONFIG_PATH="$HOME/.cargo/config.toml"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

header() {
    echo -e "${GREEN}"
    echo "============================================"
    echo "  Raspberry Pi Rust Production Installer"
    echo "============================================"
    echo -e "${NC}"
}

cleanup() {
    echo -e "${YELLOW}[CLEANUP] Removing temporary files...${NC}"
    rm -rf /tmp/rustup-init /tmp/cargo-setup
}

trap cleanup EXIT

validate_architecture() {
    echo -e "\n[1/7] Validating system architecture..."
    local user_arch=$(dpkg --print-architecture)
    local kernel_arch=$(uname -m)
    
    if [[ ! " ${SUPPORTED_ARCHS[@]} " =~ " ${user_arch} " ]]; then
        echo -e "${RED}ERROR: Unsupported architecture ${user_arch}${NC}" >&2
        exit 2
    fi

    case "$user_arch" in
        "arm64") RUST_TARGET="aarch64-unknown-linux-gnu" ;;
        "armhf") RUST_TARGET="armv7-unknown-linux-gnueabihf" ;;
        *) exit 2 ;;
    esac

    echo -e "Detected: Userland=${user_arch}, Kernel=${kernel_arch}"
    echo -e "Using Rust target: ${RUST_TARGET}"
}

install_dependencies() {
    echo -e "\n[2/7] Installing system dependencies..."
    local deps=(
        git build-essential libssl-dev 
        pkg-config curl gcc-arm-linux-gnueabihf
    )

    if ! sudo apt-get update; then
        echo -e "${RED}ERROR: Failed to update package lists${NC}" >&2
        exit 1
    fi

    if ! sudo apt-get install -y "${deps[@]}"; then
        echo -e "${RED}ERROR: Dependency installation failed${NC}" >&2
        exit 1
    fi
}

install_rust() {
    echo -e "\n[3/7] Installing Rust toolchain..."
    local rustup_opts=(
        -y 
        --default-host "$RUST_TARGET" 
        --profile "$RUST_PROFILE"
    )

    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- "${rustup_opts[@]}"; then
        echo -e "${RED}ERROR: Rust installation failed${NC}" >&2
        exit 3
    fi
}

configure_environment() {
    echo -e "\n[4/7] Configuring environment..."
    
    # Add to PATH if not already present
    if ! grep -q ".cargo/bin" "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    # Modern cargo configuration
    mkdir -p "$(dirname "$CARGO_CONFIG_PATH")"
    cat > "$CARGO_CONFIG_PATH" <<EOF
[target.$RUST_TARGET]
linker = "arm-linux-gnueabihf-gcc"
EOF

    # Immediate environment setup
    source "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"
}

verify_installation() {
    echo -e "\n[5/7] Verifying installation..."
    local rustc_version cargo_version

    if ! command -v rustc &> /dev/null; then
        echo -e "${RED}ERROR: rustc not found in PATH${NC}" >&2
        exit 4
    fi

    rustc_version=$(rustc --version | awk '{print $2}')
    cargo_version=$(cargo --version | awk '{print $2}')

    echo -e "${GREEN}Rustc version: ${rustc_version}${NC}"
    echo -e "${GREEN}Cargo version: ${cargo_version}${NC}"
}

post_install_check() {
    echo -e "\n[6/7] Performing system checks..."
    echo -e "Linker verification:"
    arm-linux-gnueabihf-gcc --version | head -n1

    echo -e "\nToolchain components:"
    rustup show
}

finalize() {
    echo -e "\n[7/7] Finalizing installation..."
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo -e "Recommended next steps:"
    echo -e "1. Start a new terminal session"
    echo -e "2. Run 'rustc --version' to verify"
    echo -e "3. Create test project: cargo new hello_world"
}

main() {
    header
    validate_architecture
    install_dependencies
    install_rust
    configure_environment
    verify_installation
    post_install_check
    finalize
}

main "$@"
