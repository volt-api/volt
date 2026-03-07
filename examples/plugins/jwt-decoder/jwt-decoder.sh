#!/usr/bin/env bash
#
# jwt-decoder.sh — VOLT plugin for decoding JWTs in API responses
#
# Reads a response body from stdin (or from file path in $1), finds JWT
# tokens matching the xxx.yyy.zzz pattern, decodes the header and payload,
# and checks whether the token has expired.
#
# Output is printed to stdout for display in VOLT's post-response summary.

set -euo pipefail

# ---------------------------------------------------------------------------
# Read the response body
# ---------------------------------------------------------------------------
if [[ -n "${1:-}" && -f "${1:-}" ]]; then
    BODY=$(cat "$1")
else
    BODY=$(cat)
fi

if [[ -z "$BODY" ]]; then
    echo "jwt-decoder: no response body to inspect" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Locate JWT tokens (three base64url segments separated by dots)
# ---------------------------------------------------------------------------
JWT_PATTERN='[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
TOKENS=$(echo "$BODY" | grep -oE "$JWT_PATTERN" || true)

if [[ -z "$TOKENS" ]]; then
    echo "jwt-decoder: no JWT tokens found in response"
    exit 0
fi

# ---------------------------------------------------------------------------
# Helper: base64url decode (handles missing padding)
# ---------------------------------------------------------------------------
b64url_decode() {
    local data="$1"
    # Replace URL-safe characters with standard base64
    data="${data//-/+}"
    data="${data//_//}"
    # Add padding if needed
    local mod=$((${#data} % 4))
    if [[ $mod -eq 2 ]]; then data="${data}=="; fi
    if [[ $mod -eq 3 ]]; then data="${data}="; fi
    echo "$data" | base64 -d 2>/dev/null || echo "(decode error)"
}

# ---------------------------------------------------------------------------
# Process each token
# ---------------------------------------------------------------------------
TOKEN_NUM=0
echo "$TOKENS" | while IFS= read -r token; do
    TOKEN_NUM=$((TOKEN_NUM + 1))

    # Split into parts
    HEADER_B64=$(echo "$token" | cut -d. -f1)
    PAYLOAD_B64=$(echo "$token" | cut -d. -f2)

    HEADER=$(b64url_decode "$HEADER_B64")
    PAYLOAD=$(b64url_decode "$PAYLOAD_B64")

    echo "--- JWT #${TOKEN_NUM} ---"
    echo "Header:  $HEADER"
    echo "Payload: $PAYLOAD"

    # Check expiration (exp claim)
    EXP=$(echo "$PAYLOAD" | grep -oE '"exp":[0-9]+' | head -1 | cut -d: -f2)
    if [[ -n "$EXP" ]]; then
        NOW=$(date +%s)
        if [[ "$EXP" -lt "$NOW" ]]; then
            echo "Status:  EXPIRED (exp=$EXP, now=$NOW)"
        else
            REMAINING=$(( EXP - NOW ))
            echo "Status:  VALID (expires in ${REMAINING}s)"
        fi
    else
        echo "Status:  No exp claim found"
    fi
    echo ""
done
