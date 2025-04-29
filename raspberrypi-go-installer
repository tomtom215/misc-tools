#!/bin/bash

set -e

# Error handling function
handle_error() {
    local exit_code=$?
    echo "Error: Command failed with exit code $exit_code"
    echo "Installation failed. Please check the error message above."
    exit $exit_code
}

# Set up error handling
trap handle_error ERR

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
for cmd in curl wget tar; do
    if ! command_exists $cmd; then
        echo "Required command '$cmd' not found. Installing..."
        sudo apt-get update && sudo apt-get install -y $cmd || {
            echo "Failed to install $cmd. Please install it manually and try again."
            exit 1
        }
    fi
done

# Get architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

# Determine Go package based on architecture
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    GO_ARCH="arm64"
    echo "Using 64-bit ARM package"
else
    GO_ARCH="armv6l"
    echo "Using 32-bit ARM package"
fi

# Get latest Go version - using direct version instead of the problematic fetch
GO_VERSION="go1.24.2"
echo "Using Go version: $GO_VERSION"

# Download Go
FILENAME="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
DOWNLOAD_URL="https://go.dev/dl/${FILENAME}"
echo "Downloading from: $DOWNLOAD_URL"

wget -O "$FILENAME" "$DOWNLOAD_URL" || {
    echo "Download failed."
    echo "Trying alternative approach - fetching download page to find latest version..."
    
    # Alternative: Get the latest version by parsing the download page
    LATEST_VERSION=$(curl -s https://go.dev/dl/ | grep -oP 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1)
    if [ -n "$LATEST_VERSION" ]; then
        GO_VERSION=$LATEST_VERSION
        FILENAME="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
        DOWNLOAD_URL="https://go.dev/dl/${FILENAME}"
        echo "Found latest version: $GO_VERSION"
        echo "Downloading from: $DOWNLOAD_URL"
        
        wget -O "$FILENAME" "$DOWNLOAD_URL" || {
            echo "Download failed again. Please check https://go.dev/dl/ manually and verify the correct version."
            exit 1
        }
    else
        echo "Failed to determine latest Go version. Please visit https://go.dev/dl/ manually."
        exit 1
    fi
}

# Remove old installation if exists
if [ -d "/usr/local/go" ]; then
    echo "Removing existing Go installation..."
    sudo rm -rf /usr/local/go
fi

# Extract archive
echo "Extracting Go to /usr/local..."
sudo tar -C /usr/local -xzf "$FILENAME"

# Set up PATH if not already configured
if ! grep -q "/usr/local/go/bin" ~/.profile; then
    echo "Adding Go to your PATH..."
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
    echo "Added Go to PATH in ~/.profile"
fi

# Set up environment for current session
export PATH=$PATH:/usr/local/go/bin

# Verify installation
echo "Verifying installation..."
if command_exists go; then
    GO_INSTALLED_VERSION=$(go version)
    echo "Go installed successfully: $GO_INSTALLED_VERSION"
    
    # Create Go workspace if it doesn't exist
    if [ ! -d "$HOME/go" ]; then
        echo "Creating Go workspace in $HOME/go..."
        mkdir -p "$HOME/go/src" "$HOME/go/bin" "$HOME/go/pkg"
        echo 'export GOPATH=$HOME/go' >> ~/.profile
        echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.profile
    fi
    
    echo "Cleaning up downloaded archive..."
    rm "$FILENAME"
    
    echo "==================================="
    echo "Installation complete!"
    echo "Run 'source ~/.profile' or log out and back in to update your PATH"
    echo "==================================="
else
    echo "Go installation failed. 'go' command not found in PATH."
    exit 1
fi
