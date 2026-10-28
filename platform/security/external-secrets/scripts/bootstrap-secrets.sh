#!/usr/bin/env bash
# ==============================================================================
# SUM Store Secrets Manager Bootstrap Script (Offline Reference / Future Execution)
#
# PURPOSE:
#   Populates initial secret values into AWS Secrets Manager containers:
#     - sumstore/mysql
#     - sumstore/rabbitmq
#
# USAGE (Run ONLY AFTER AWS infrastructure is created):
#   AWS_REGION=us-east-1 ./bootstrap-secrets.sh
#
# SAFETY GUARANTEES:
#   - Never commits or persists plaintext secrets to disk.
#   - Never prints passwords to stdout/stderr.
#   - Accepts credentials via environment variables or prompts securely.
#   - Automatically generates strong random passwords if none are supplied.
#   - Does NOT run during initial offline design phase.
# ==============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
MYSQL_SECRET_NAME="${MYSQL_SECRET_NAME:-sumstore/mysql}"
RABBITMQ_SECRET_NAME="${RABBITMQ_SECRET_NAME:-sumstore/rabbitmq}"

echo "================================================="
echo "SUM Store Secrets Manager Bootstrap"
echo "Region: ${AWS_REGION}"
echo "================================================="

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is not installed or not in PATH." >&2
  exit 1
fi

# Verify caller identity
echo "Verifying AWS credentials..."
CALLER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null) || {
  echo "ERROR: Unable to authenticate to AWS. Please configure valid AWS credentials." >&2
  exit 1
}
echo "Authenticated as: ${CALLER_ARN}"

# Helper function to generate high-entropy random password if unset
generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20
  else
    head -c 20 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20
  fi
}

# ------------------------------------------------------------------------------
# 1. Prepare MySQL Credentials
# ------------------------------------------------------------------------------
echo ""
echo "Configuring MySQL secret values (${MYSQL_SECRET_NAME})..."

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(generate_password)}"
MYSQL_DATABASE="${MYSQL_DATABASE:-cities}"
SHIPPING_DB_USER="${SHIPPING_DB_USER:-shipping}"
SHIPPING_DB_PASSWORD="${SHIPPING_DB_PASSWORD:-$(generate_password)}"
RATINGS_DB_USER="${RATINGS_DB_USER:-ratings}"
RATINGS_DB_PASSWORD="${RATINGS_DB_PASSWORD:-$(generate_password)}"

# Construct JSON payload in memory
export MYSQL_ROOT_PASSWORD MYSQL_DATABASE SHIPPING_DB_USER SHIPPING_DB_PASSWORD RATINGS_DB_USER RATINGS_DB_PASSWORD
MYSQL_PAYLOAD=$(python3 -c '
import json, os, sys

data = {
    "MYSQL_ROOT_PASSWORD": os.environ["MYSQL_ROOT_PASSWORD"],
    "MYSQL_DATABASE": os.environ["MYSQL_DATABASE"],
    "SHIPPING_DB_USER": os.environ["SHIPPING_DB_USER"],
    "SHIPPING_DB_PASSWORD": os.environ["SHIPPING_DB_PASSWORD"],
    "RATINGS_DB_USER": os.environ["RATINGS_DB_USER"],
    "RATINGS_DB_PASSWORD": os.environ["RATINGS_DB_PASSWORD"],
}
sys.stdout.write(json.dumps(data))
')

echo "Uploading MySQL credentials to Secrets Manager..."
aws secretsmanager put-secret-value \
  --secret-id "${MYSQL_SECRET_NAME}" \
  --secret-string "${MYSQL_PAYLOAD}" \
  --region "${AWS_REGION}" >/dev/null
echo "✓ Successfully populated ${MYSQL_SECRET_NAME}."

# ------------------------------------------------------------------------------
# 2. Prepare RabbitMQ Credentials
# ------------------------------------------------------------------------------
echo ""
echo "Configuring RabbitMQ secret values (${RABBITMQ_SECRET_NAME})..."

RABBITMQ_DEFAULT_USER="${RABBITMQ_DEFAULT_USER:-sumstore}"
RABBITMQ_DEFAULT_PASS="${RABBITMQ_DEFAULT_PASS:-$(generate_password)}"

export RABBITMQ_DEFAULT_USER RABBITMQ_DEFAULT_PASS
RABBITMQ_PAYLOAD=$(python3 -c '
import json, os, sys

data = {
    "RABBITMQ_DEFAULT_USER": os.environ["RABBITMQ_DEFAULT_USER"],
    "RABBITMQ_DEFAULT_PASS": os.environ["RABBITMQ_DEFAULT_PASS"],
}
sys.stdout.write(json.dumps(data))
')

echo "Uploading RabbitMQ credentials to Secrets Manager..."
aws secretsmanager put-secret-value \
  --secret-id "${RABBITMQ_SECRET_NAME}" \
  --secret-string "${RABBITMQ_PAYLOAD}" \
  --region "${AWS_REGION}" >/dev/null
echo "✓ Successfully populated ${RABBITMQ_SECRET_NAME}."

echo ""
echo "================================================="
echo "Bootstrap complete. All secret containers populated."
echo "External Secrets Operator will automatically synchronize"
echo "these values into Kubernetes Secrets."
echo "================================================="
