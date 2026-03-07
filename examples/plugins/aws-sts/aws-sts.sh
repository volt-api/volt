#!/usr/bin/env bash
#
# aws-sts.sh — VOLT plugin for AWS STS temporary credentials
#
# Calls `aws sts assume-role` to obtain temporary credentials and outputs
# them as VOLT variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_SESSION_TOKEN) for use in subsequent .volt requests.
#
# Required:
#   AWS_ROLE_ARN   — The ARN of the role to assume (env var or $1)
#   AWS_SESSION    — Optional session name (defaults to "volt-session")
#
# The caller must have valid AWS credentials configured (via env, profile,
# or instance role) with permission to call sts:AssumeRole.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ROLE_ARN="${AWS_ROLE_ARN:-${1:-}}"
SESSION_NAME="${AWS_SESSION:-volt-session}"
DURATION="${AWS_STS_DURATION:-3600}"

if [[ -z "$ROLE_ARN" ]]; then
    echo "Error: No role ARN provided." >&2
    echo "Set AWS_ROLE_ARN or pass the ARN as the first argument." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the AWS CLI is available
# ---------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
    echo "Error: AWS CLI is not installed or not in PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assume the role
# ---------------------------------------------------------------------------
STS_OUTPUT=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "$SESSION_NAME" \
    --duration-seconds "$DURATION" \
    --output json 2>&1) || {
    echo "Error: Failed to assume role $ROLE_ARN" >&2
    echo "$STS_OUTPUT" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Extract credentials
# ---------------------------------------------------------------------------
ACCESS_KEY=$(echo "$STS_OUTPUT"  | grep -o '"AccessKeyId": *"[^"]*"'     | head -1 | cut -d'"' -f4)
SECRET_KEY=$(echo "$STS_OUTPUT"  | grep -o '"SecretAccessKey": *"[^"]*"' | head -1 | cut -d'"' -f4)
TOKEN=$(echo "$STS_OUTPUT"       | grep -o '"SessionToken": *"[^"]*"'    | head -1 | cut -d'"' -f4)
EXPIRATION=$(echo "$STS_OUTPUT"  | grep -o '"Expiration": *"[^"]*"'      | head -1 | cut -d'"' -f4)

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$TOKEN" ]]; then
    echo "Error: Could not parse STS credentials from response." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Output variables for VOLT
# ---------------------------------------------------------------------------
cat <<EOF
{
  "variables": {
    "AWS_ACCESS_KEY_ID": "$ACCESS_KEY",
    "AWS_SECRET_ACCESS_KEY": "$SECRET_KEY",
    "AWS_SESSION_TOKEN": "$TOKEN",
    "AWS_STS_EXPIRATION": "$EXPIRATION"
  }
}
EOF
