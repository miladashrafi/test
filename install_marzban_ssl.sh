#!/bin/bash

set -euo pipefail

echo "🔧 Installing Marzban..."
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install

echo "⏳ Waiting for Marzban containers to start..."
sleep 15
docker ps --format "table {{.Names}}\t{{.Status}}"

# Function to read input with validation and optional default
read_input() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local input=""
  while true; do
    if [ -n "$default" ]; then
      read -p "$prompt [$default]: " input
      input="${input:-$default}"
    else
      read -p "$prompt: " input
    fi
    if [ -n "$input" ]; then
      printf -v "$varname" '%s' "$input"
      break
    else
      echo "⚠️ Input cannot be empty. Please try again."
    fi
  done
}

# Get inputs with validation
read_input "🌐 Enter your domain (e.g. example.com)" CF_Domain
read_input "🔌 Enter Marzban port" Marzban_Port "443"
read_input "👤 Enter admin username" Admin_User

# Read password silently with confirmation
while true; do
  read -s -p "🔐 Enter admin password: " Admin_Pass
  echo
  read -s -p "🔐 Confirm admin password: " Admin_Pass_Confirm
  echo
  if [[ "$Admin_Pass" == "$Admin_Pass_Confirm" && -n "$Admin_Pass" ]]; then
    break
  else
    echo "⚠️ Passwords do not match or empty. Please try again."
  fi
done

read_input "🔑 Enter your Cloudflare API Token" CF_Token
read_input "🆔 Enter your Cloudflare Account ID" CF_Account_ID

echo "🔒 Installing acme.sh..."
curl -sSf https://get.acme.sh | sh

export CF_Token="$CF_Token"
export CF_Account_ID="$CF_Account_ID"
export CF_Domain="$CF_Domain"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# Retry loop for issuing certificate
until ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$CF_Domain"; do
  echo "❌ Certificate issuance failed. Please verify your domain and Cloudflare credentials."
  read -p "Try again? (y/n): " retry
  if [[ "$retry" != "y" ]]; then
    echo "Exiting due to failure."
    exit 1
  fi
done

CERT_DIR="/var/lib/marzban/certs"
mkdir -p "$CERT_DIR"

echo "💾 Installing certificate and copying to $CERT_DIR..."
~/.acme.sh/acme.sh --install-cert -d "$CF_Domain" \
--key-file       /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key \
--fullchain-file /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer \
--reloadcmd "cp /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key ${CERT_DIR}/${CF_Domain}.key && cp /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer ${CERT_DIR}/${CF_Domain}-fullchain.cer && docker restart marzban-marzban-1"

echo "👤 Creating admin user..."
cd /opt/marzban || { echo "❌ /opt/marzban not found"; exit 1; }

# Use echo pipe to input password interactively
echo "$Admin_Pass" | docker compose exec -T marzban marzban cli admin create -u "$Admin_User" --sudo

echo "⚙️ Updating .env configuration..."
ENV_FILE="/opt/marzban/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "❌ $ENV_FILE not found!"
  exit 1
fi

sed -i "s|^UVICORN_SSL_CERTFILE=.*|UVICORN_SSL_CERTFILE=${CERT_DIR}/${CF_Domain}-fullchain.cer|" "$ENV_FILE"
sed -i "s|^UVICORN_SSL_KEYFILE=.*|UVICORN_SSL_KEYFILE=${CERT_DIR}/${CF_Domain}.key|" "$ENV_FILE"
sed -i "s|^UVICORN_PORT=.*|UVICORN_PORT=${Marzban_Port}|" "$ENV_FILE"

echo "🔁 Restarting Marzban container..."
docker compose down && docker compose up -d

echo "✅ Marzban installation and SSL setup complete."
