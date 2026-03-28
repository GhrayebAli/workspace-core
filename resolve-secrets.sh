#!/usr/bin/env bash
# Resolve AWS Secrets Manager ARNs in .env files
#
# Reads an .env.example file, replaces any value matching
#   arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME-SUFFIX:JSON_KEY::
# with the actual secret value fetched from AWS Secrets Manager.
# Non-ARN lines pass through unchanged.
#
# Usage:
#   bash resolve-secrets.sh <input.env.example> <output.env>
#
# Requires: aws cli v2, jq
# Env vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (or configured AWS profile)

set -e

INPUT_FILE="$1"
OUTPUT_FILE="$2"

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "Usage: bash resolve-secrets.sh <input.env.example> <output.env>"
  exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "[resolve-secrets] ERROR: Input file not found: $INPUT_FILE"
  exit 1
fi

# ── Check dependencies ──
if ! command -v aws &> /dev/null; then
  echo "[resolve-secrets] ERROR: AWS CLI not installed. Install with: curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "[resolve-secrets] ERROR: jq not installed. Install with: sudo apt-get install -y jq"
  exit 1
fi

# Verify AWS credentials are available
if ! aws sts get-caller-identity &> /dev/null; then
  echo "[resolve-secrets] ERROR: AWS credentials not configured or invalid. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
  exit 1
fi

# ── Secret cache (file-based for bash 3 compatibility) ──
CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$CACHE_DIR"' EXIT
RESOLVED_COUNT=0
FETCH_COUNT=0

fetch_secret() {
  local secret_name="$1"
  local region="$2"
  local cache_file="$CACHE_DIR/$(echo "$secret_name" | tr '/' '_')"

  if [ -f "$cache_file" ]; then
    return 0
  fi

  local result
  result=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_name" \
    --region "$region" \
    --query SecretString \
    --output text 2>&1)

  if [ $? -ne 0 ]; then
    echo "[resolve-secrets] ERROR: Failed to fetch secret '$secret_name' in region '$region'"
    echo "[resolve-secrets] AWS error: $result"
    exit 1
  fi

  echo "$result" > "$cache_file"
  FETCH_COUNT=$((FETCH_COUNT + 1))
}

extract_key() {
  local secret_name="$1"
  local json_key="$2"
  local cache_file="$CACHE_DIR/$(echo "$secret_name" | tr '/' '_')"

  local value
  value=$(jq -r --arg key "$json_key" '.[$key] // empty' < "$cache_file")

  if [ -z "$value" ]; then
    echo "[resolve-secrets] ERROR: Key '$json_key' not found in secret '$secret_name'"
    exit 1
  fi

  echo "$value"
}

# ── Process the file ──
> "$OUTPUT_FILE"

while IFS= read -r line || [ -n "$line" ]; do
  # Skip empty lines and comments — pass through
  if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
    echo "$line" >> "$OUTPUT_FILE"
    continue
  fi

  # Split on first = sign
  var_name="${line%%=*}"
  var_value="${line#*=}"

  # Strip surrounding quotes from value
  stripped_value=$(echo "$var_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')

  # Check if value is an AWS Secrets Manager ARN
  if [[ "$stripped_value" =~ ^arn:aws:secretsmanager:([^:]+):([^:]+):secret:([^:]+):([^:]+)::$ ]]; then
    region="${BASH_REMATCH[1]}"
    # account="${BASH_REMATCH[2]}"  # not needed for fetch
    secret_id="${BASH_REMATCH[3]}"
    json_key="${BASH_REMATCH[4]}"

    # Strip the 6-char random suffix AWS appends (e.g., washmendbs-kJ2Lhq -> washmendbs)
    secret_name=$(echo "$secret_id" | sed 's/-[A-Za-z0-9]\{6\}$//')

    # Fetch (cached) and extract
    fetch_secret "$secret_name" "$region"
    resolved_value=$(extract_key "$secret_name" "$json_key")

    echo "${var_name}=${resolved_value}" >> "$OUTPUT_FILE"
    RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
  else
    # Non-ARN line — pass through unchanged
    echo "$line" >> "$OUTPUT_FILE"
  fi
done < "$INPUT_FILE"

echo "[resolve-secrets] Done: $(basename "$INPUT_FILE") -> $(basename "$OUTPUT_FILE") | Resolved $RESOLVED_COUNT secrets from $FETCH_COUNT AWS SM calls"
