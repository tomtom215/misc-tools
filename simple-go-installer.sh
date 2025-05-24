#!/bin/bash

# Simple Go Installer for Linux
# Minimal version that just works

# Exit on error, but handle it gracefully
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Basic config
GO_VERSION="${GO_VERSION:-go1.24.3}"
INSTALL_DIR="/usr/local"
TEMP_DIR="/tmp/go_install_$$"

# Simple logging
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Check root
if [[ $EUID -ne 0 ]]; then
    error "Please run with sudo"
fi

# Get user info
if [[ -n "$SUDO_USER" ]]; then
    ACTUAL_USER="$SUDO_USER"
    USER_HOME="/home/$SUDO_USER"
else
    ACTUAL_USER="$USER"
    USER_HOME="$HOME"
fi

info "Installing Go for user: $ACTUAL_USER"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    armv6l|armv7l) GOARCH="armv6l" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

info "Architecture: $GOARCH"

# Create temp dir
mkdir -p "$TEMP_DIR" || error "Failed to create temp directory"

# Try to get latest version
info "Fetching latest Go version..."
VERSION_URL="https://go.dev/dl/?mode=json"
VERSION_FILE="$TEMP_DIR/versions.json"

if curl -sL "$VERSION_URL" -o "$VERSION_FILE" 2>/dev/null; then
    # Try to parse if we have jq
    if command -v jq >/dev/null 2>&1; then
        LATEST=$(jq -r --arg arch "$GOARCH" '.[] | select(.stable) | .files[] | select(.os=="linux" and .arch==$arch and .kind=="archive") | .version' "$VERSION_FILE" 2>/dev/null | head -1)
        if [[ -n "$LATEST" ]]; then
            GO_VERSION="$LATEST"
            info "Found latest version: $GO_VERSION"
        fi
    fi
fi

# Download Go
info "Downloading $GO_VERSION..."
FILENAME="${GO_VERSION}.linux-${GOARCH}.tar.gz"
DOWNLOAD_URL="https://dl.google.com/go/$FILENAME"
DOWNLOAD_PATH="$TEMP_DIR/$FILENAME"

curl -L --progress-bar "$DOWNLOAD_URL" -o "$DOWNLOAD_PATH" || error "Download failed"

# Verify download
if [[ ! -f "$DOWNLOAD_PATH" ]]; then
    error "Download file not found"
fi

SIZE=$(stat -c%s "$DOWNLOAD_PATH" 2>/dev/null || stat -f%z "$DOWNLOAD_PATH" 2>/dev/null || echo 0)
if [[ $SIZE -lt 50000000 ]]; then
    error "Downloaded file too small"
fi

success "Download complete"

# Remove old installation
if [[ -d "$INSTALL_DIR/go" ]]; then
    info "Removing existing Go installation..."
    rm -rf "$INSTALL_DIR/go" || error "Failed to remove old installation"
fi

# Install
info "Installing Go..."
tar -C "$INSTALL_DIR" -xzf "$DOWNLOAD_PATH" || error "Failed to extract Go"

# Verify installation
if [[ ! -x "$INSTALL_DIR/go/bin/go" ]]; then
    error "Go binary not found after installation"
fi

success "Go installed to $INSTALL_DIR/go"

# Update PATH
info "Updating PATH..."

# System-wide
cat > /etc/profile.d/go.sh << 'EOF'
export PATH="$PATH:/usr/local/go/bin"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"
EOF
chmod 644 /etc/profile.d/go.sh

# User's bashrc
if [[ -f "$USER_HOME/.bashrc" ]]; then
    # Remove old entries
    sed -i '/# Go programming/d' "$USER_HOME/.bashrc" 2>/dev/null || true
    sed -i '/\/go\/bin/d' "$USER_HOME/.bashrc" 2>/dev/null || true
    sed -i '/GOPATH/d' "$USER_HOME/.bashrc" 2>/dev/null || true
    
    # Add new
    echo '' >> "$USER_HOME/.bashrc"
    echo '# Go programming language' >> "$USER_HOME/.bashrc"
    echo 'export PATH="$PATH:/usr/local/go/bin"' >> "$USER_HOME/.bashrc"
    echo 'export GOPATH="$HOME/go"' >> "$USER_HOME/.bashrc"
    echo 'export PATH="$PATH:$GOPATH/bin"' >> "$USER_HOME/.bashrc"
    
    chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/.bashrc" 2>/dev/null || true
fi

success "PATH updated"

# Create workspace
info "Creating Go workspace..."
for dir in "$USER_HOME/go" "$USER_HOME/go/src" "$USER_HOME/go/bin" "$USER_HOME/go/pkg"; do
    mkdir -p "$dir" 2>/dev/null || true
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$dir" 2>/dev/null || true
done
success "Workspace created"

# Test installation
info "Testing installation..."
VERSION=$("$INSTALL_DIR/go/bin/go" version) || error "Failed to run go version"
success "$VERSION"

# Done!
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}    GO INSTALLATION COMPLETED SUCCESSFULLY!     ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "Version:  $GO_VERSION"
echo "Location: $INSTALL_DIR/go"
echo "GOPATH:   $USER_HOME/go"
echo ""
echo "Next steps:"
echo "1. Run: source ~/.bashrc"
echo "2. Test: go version"
echo ""
echo -e "${GREEN}Happy coding!${NC}"
echo ""