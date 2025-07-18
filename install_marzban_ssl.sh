#!/bin/bash

# === Step 1: Install Marzban ===
echo "🔧 Installing Marzban..."
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install

echo "⏳ Waiting for Marzban containers to start..."
sleep 15
docker ps --format "table {{.Names}}\t{{.Status}}"

# === Step 2: Get Required Info ===
read -p "🌐 Enter your domain (e.g. example.com): " CF_Domain
read -p "🔌 Enter Marzban port (e.g. 8000): " Marzban_Port
read -p "👤 Enter admin username: " Admin_User
read -s -p "🔐 Enter admin password: " Admin_Pass && echo
read -p "🔑 Enter your Cloudflare API Token: " CF_Token
read -p "🆔 Enter your Cloudflare Account ID: " CF_Account_ID

# === Step 3: Install acme.sh and Get SSL Certificate ===
echo "🔒 Installing acme.sh..."
curl https://get.acme.sh | sh

export CF_Token="$CF_Token"
export CF_Account_ID="$CF_Account_ID"
export CF_Domain="$CF_Domain"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "📜 Issuing certificate for $CF_Domain ..."
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$CF_Domain"

echo "💾 Installing certificate..."
~/.acme.sh/acme.sh --install-cert -d "$CF_Domain" \
--key-file       /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key \
--fullchain-file /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer \
--reloadcmd     "cp /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key /var/lib/marzban/certs/${CF_Domain}.key && cp /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer /var/lib/marzban/certs/${CF_Domain}-fullchain.cer && docker restart marzban-marzban-1"

# === Step 4: Create Admin User ===
echo "👤 Creating admin user..."
cd /opt/marzban
echo "$Admin_Pass" | docker compose exec -T marzban marzban cli admin create -u "$Admin_User" --sudo

# === Step 5: Update Marzban .env File ===
echo "⚙️ Updating .env configuration..."
ENV_FILE="/opt/marzban/.env"
CERT_PATH="/var/lib/marzban/certs/${CF_Domain}-fullchain.cer"
KEY_PATH="/var/lib/marzban/certs/${CF_Domain}.key"

sed -i "s|^UVICORN_SSL_CERTFILE=.*|UVICORN_SSL_CERTFILE=${CERT_PATH}|" "$ENV_FILE"
sed -i "s|^UVICORN_SSL_KEYFILE=.*|UVICORN_SSL_KEYFILE=${KEY_PATH}|" "$ENV_FILE"
sed -i "s|^UVICORN_PORT=.*|UVICORN_PORT=${Marzban_Port}|" "$ENV_FILE"

# === Step 6: Restart Marzban ===
echo "🔁 Restarting Marzban container..."
cd /opt/marzban
docker compose down
docker compose up -d

echo "✅ Marzban installation and SSL setup complete."
