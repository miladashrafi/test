#!/bin/bash

set -euo pipefail

echo "🔧 Installing Marzban..."
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install

# --- Function for validated input with optional default ---
read_input() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local input=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$prompt [$default]: " input
      input="${input:-$default}"
    else
      read -rp "$prompt: " input
    fi
    if [[ -n "$input" ]]; then
      printf -v "$varname" '%s' "$input"
      break
    else
      echo "⚠️ Input cannot be empty. Please try again."
    fi
  done
}

# --- Read inputs ---
read_input "🌐 Enter your domain (e.g. example.com)" CF_Domain
read_input "🔌 Enter Marzban port" Marzban_Port "443"
read_input "👤 Enter admin username" Admin_User

# Password input with confirmation
while true; do
  read -rsp "🔐 Enter admin password: " Admin_Pass
  echo
  read -rsp "🔐 Confirm admin password: " Admin_Pass_Confirm
  echo
  if [[ "$Admin_Pass" == "$Admin_Pass_Confirm" && -n "$Admin_Pass" ]]; then
    break
  else
    echo "⚠️ Passwords do not match or empty. Please try again."
  fi
done

read_input "🔑 Enter your Cloudflare API Token" CF_Token
read_input "🆔 Enter your Cloudflare Account ID" CF_Account_ID

echo "🟢 Starting Marzban container in detached mode..."
docker compose up -d

# Get container id
container_id=$(docker ps --filter "name=marzban" --format "{{.ID}}")
if [[ -z "$container_id" ]]; then
  echo "❌ Marzban container not found running."
  exit 1
fi

timeout=120
interval=3
elapsed=0
found=0

echo "⏳ Waiting for startup prompt in logs (timeout: ${timeout}s)..."

# Start background log follow and detect prompt
found_flag_file=$(mktemp)
trap 'rm -f "$found_flag_file"' EXIT

docker logs -f "$container_id" | while IFS= read -r line; do
  echo "$line"
  if [[ "$line" == *"Press CTRL+C to quit"* ]]; then
    touch "$found_flag_file"
    break
  fi
done &
log_pid=$!

while (( elapsed < timeout )); do
  if [[ -f "$found_flag_file" ]]; then
    found=1
    break
  fi
  sleep $interval
  ((elapsed+=interval))
done

# Stop log follower process
kill $log_pid 2>/dev/null || true

if (( found == 1 )); then
  echo "✅ Startup prompt detected, continuing..."
else
  echo "❌ Timeout waiting for startup prompt."
  while true; do
    read -rp "Retry waiting for logs? (y/n): " choice
    case "$choice" in
      y|Y)
        elapsed=0
        found=0
        # Restart log follower
        docker logs -f "$container_id" | while IFS= read -r line; do
          echo "$line"
          if [[ "$line" == *"Press CTRL+C to quit"* ]]; then
            touch "$found_flag_file"
            break
          fi
        done &
        log_pid=$!

        while (( elapsed < timeout )); do
          if [[ -f "$found_flag_file" ]]; then
            found=1
            break
          fi
          sleep $interval
          ((elapsed+=interval))
        done

        kill $log_pid 2>/dev/null || true
        if (( found == 1 )); then
          echo "✅ Startup prompt detected, continuing..."
          break
        else
          echo "❌ Timeout again."
        fi
        ;;
      n|N)
        echo "Exiting script due to startup timeout."
        exit 1
        ;;
      *)
        echo "Please enter y or n."
        ;;
    esac
  done
fi

echo "🔒 Installing acme.sh..."
curl -sSf https://get.acme.sh | sh

export CF_Token="$CF_Token"
export CF_Account_ID="$CF_Account_ID"
export CF_Domain="$CF_Domain"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# Retry loop for certificate issuance
until ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$CF_Domain"; do
  echo "❌ Certificate issuance failed. Please verify your domain and Cloudflare credentials."
  read -rp "Try again? (y/n): " retry
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
echo "$Admin_Pass" | docker compose exec -T marzban marzban cli admin create -u "$Admin_User" --sudo

echo "⚙️ Updating .env configuration..."
ENV_FILE="/opt/marzban/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ $ENV_FILE not found!"
  exit 1
fi

sed -i "s|^UVICORN_SSL_CERTFILE=.*|UVICORN_SSL_CERTFILE=${CERT_DIR}/${CF_Domain}-fullchain.cer|" "$ENV_FILE"
sed -i "s|^UVICORN_SSL_KEYFILE=.*|UVICORN_SSL_KEYFILE=${CERT_DIR}/${CF_Domain}.key|" "$ENV_FILE"
sed -i "s|^UVICORN_PORT=.*|UVICORN_PORT=${Marzban_Port}|" "$ENV_FILE"

echo "🔁 Restarting Marzban container..."
docker compose down
docker compose up -d

echo "✅ Marzban installation and SSL setup complete."
