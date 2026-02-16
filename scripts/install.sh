#!/bin/sh
# Volt installer — https://github.com/volt-api/volt
# Usage: curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash
set -e

REPO="volt-api/volt"
INSTALL_DIR="${VOLT_INSTALL:-/usr/local/bin}"

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Linux)  OS_NAME="linux" ;;
  Darwin) OS_NAME="macos" ;;
  *)      echo "Error: Unsupported OS: $OS"; exit 1 ;;
esac

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)       ARCH_NAME="x86_64" ;;
  aarch64|arm64) ARCH_NAME="aarch64" ;;
  *)            echo "Error: Unsupported architecture: $ARCH"; exit 1 ;;
esac

ARTIFACT="volt-${OS_NAME}-${ARCH_NAME}"

# Resolve version
if [ -n "$VOLT_VERSION" ]; then
  VERSION="$VOLT_VERSION"
else
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')"
fi

if [ -z "$VERSION" ]; then
  echo "Error: Could not determine latest version"
  exit 1
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ARTIFACT}"
CHECKSUMS_URL="https://github.com/${REPO}/releases/download/v${VERSION}/checksums.txt"

echo "Installing Volt v${VERSION} (${OS_NAME}/${ARCH_NAME})..."

# Create temp directory
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Download binary
curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/volt"

# Verify checksum
curl -fsSL "$CHECKSUMS_URL" -o "${TMP_DIR}/checksums.txt"
EXPECTED="$(grep "$ARTIFACT" "${TMP_DIR}/checksums.txt" | awk '{print $1}')"
if [ -n "$EXPECTED" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TMP_DIR}/volt" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "${TMP_DIR}/volt" | awk '{print $1}')"
  else
    echo "Warning: No sha256sum or shasum found, skipping checksum verification"
    ACTUAL="$EXPECTED"
  fi

  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "Error: Checksum verification failed"
    echo "  Expected: $EXPECTED"
    echo "  Actual:   $ACTUAL"
    exit 1
  fi
  echo "Checksum verified."
else
  echo "Warning: Could not find checksum for $ARTIFACT, skipping verification"
fi

# Install
chmod +x "${TMP_DIR}/volt"
if [ -w "$INSTALL_DIR" ]; then
  mv "${TMP_DIR}/volt" "${INSTALL_DIR}/volt"
else
  sudo mv "${TMP_DIR}/volt" "${INSTALL_DIR}/volt"
fi

echo "Volt v${VERSION} installed to ${INSTALL_DIR}/volt"
echo "Run 'volt --help' to get started."
