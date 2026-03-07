#!/usr/bin/env bash
#
# vault-reader.sh — VOLT plugin for reading secrets from HashiCorp Vault
#
# Uses the Vault HTTP API (via curl) to fetch secrets from a given path
# and outputs the key-value pairs as VOLT variables.
#
# Required:
#   VAULT_ADDR   — Base URL of the Vault server (e.g. https://vault.example.com)
#   VAULT_TOKEN  — Authentication token for Vault
#   VAULT_PATH   — Secret path to read (e.g. secret/data/myapp) or pass as $1
#
# Optional:
#   VAULT_API_VERSION — KV engine version: "v2" (default) or "v1"

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
SECRET_PATH="${VAULT_PATH:-${1:-}}"
API_VERSION="${VAULT_API_VERSION:-v2}"

if [[ -z "$VAULT_ADDR" ]]; then
    echo "Error: VAULT_ADDR is not set." >&2
    exit 1
fi

if [[ -z "$VAULT_TOKEN" ]]; then
    echo "Error: VAULT_TOKEN is not set." >&2
    exit 1
fi

if [[ -z "$SECRET_PATH" ]]; then
    echo "Error: No secret path provided." >&2
    echo "Set VAULT_PATH or pass the path as the first argument." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify curl is available
# ---------------------------------------------------------------------------
if ! command -v curl &>/dev/null; then
    echo "Error: curl is not installed or not in PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch the secret from Vault
# ---------------------------------------------------------------------------
RESPONSE=$(curl -sf \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "${VAULT_ADDR}/v1/${SECRET_PATH}" 2>&1) || {
    echo "Error: Failed to read secret at ${SECRET_PATH}" >&2
    echo "$RESPONSE" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Parse the response and build VOLT variables
#
# KV v2 nests data under .data.data; KV v1 uses .data directly.
# We use grep/sed to avoid requiring jq as a dependency.
# ---------------------------------------------------------------------------
if [[ "$API_VERSION" == "v2" ]]; then
    # Extract inner data block for KV v2
    DATA_BLOCK=$(echo "$RESPONSE" | grep -o '"data":{[^}]*}' | tail -1)
else
    DATA_BLOCK=$(echo "$RESPONSE" | grep -o '"data":{[^}]*}' | head -1)
fi

if [[ -z "$DATA_BLOCK" ]]; then
    echo "Error: Could not parse secret data from Vault response." >&2
    exit 1
fi

# Build a JSON variables object from the key-value pairs
VARS=$(echo "$DATA_BLOCK" \
    | sed 's/^"data"://' \
    | sed 's/[{}]//g' \
    | tr ',' '\n' \
    | sed 's/^ *//' \
    | awk -F: '{printf "    %s: %s,\n", $1, $2}' \
    | sed '$ s/,$//')

cat <<EOF
{
  "variables": {
${VARS}
  }
}
EOF
