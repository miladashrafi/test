#!/bin/bash

# === Step 1: Install Marzban ===
echo "🔧 Installing Marzban..."
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install

# === Step 2: Wait for container to be healthy ===
echo "⏳ Waiting for Marzban to be ready (max 2 min)..."
timeout=120
start_time=$(date +%s)
while true; do
    logs=$(docker logs marzban-marzban-1 2>&1)
    if echo "$logs" | grep -q "Press CTRL+C to quit"; then
        echo "✅ Marzban container is ready."
        break
    fi
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $timeout ]; then
        echo "❌ Timeout reached. Marzban did not start within 2 minutes."
        exit 1
    fi
    sleep 2
done

docker ps --format "table {{.Names}}\t{{.Status}}"

# === Step 3: Get Required Info ===
read -p "🌐 Enter your domain (e.g. example.com): " CF_Domain
read -p "🔌 Enter Marzban port (e.g. 8000): " Marzban_Port
read -p "👤 Enter admin username: " Admin_User
read -s -p "🔐 Enter admin password: " Admin_Pass && echo
read -p "🔑 Enter your Cloudflare API Token: " CF_Token
read -p "🆔 Enter your Cloudflare Account ID: " CF_Account_ID

# === Step 4: Install acme.sh and Get SSL Certificate ===
echo "🔒 Installing acme.sh..."
curl https://get.acme.sh | sh

export CF_Token="$CF_Token"
export CF_Account_ID="$CF_Account_ID"
export CF_Domain="$CF_Domain"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "📜 Issuing certificate for $CF_Domain ..."
~/.acme.sh/acme.sh --issue -f --dns dns_cf -d "$CF_Domain"

echo "💾 Installing certificate..."
~/.acme.sh/acme.sh --install-cert -f -d "$CF_Domain" \
--key-file       /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key \
--fullchain-file /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer \
--reloadcmd     "cp /root/.acme.sh/${CF_Domain}_ecc/${CF_Domain}.key /var/lib/marzban/certs/${CF_Domain}.key && cp /root/.acme.sh/${CF_Domain}_ecc/fullchain.cer /var/lib/marzban/certs/${CF_Domain}-fullchain.cer && docker restart marzban-marzban-1"

# === Step 5: Create Admin User ===
echo "👤 Creating admin user..."
cd /opt/marzban
echo "$Admin_Pass" | docker compose exec -T marzban marzban cli admin create -u "$Admin_User" --sudo

# === Step 6: Update Marzban .env File ===
echo "⚙️ Updating .env configuration..."
ENV_FILE="/opt/marzban/.env"
CERT_PATH="/var/lib/marzban/certs/${CF_Domain}-fullchain.cer"
KEY_PATH="/var/lib/marzban/certs/${CF_Domain}.key"

# Replace or add config lines regardless of spacing or comments
update_env_var() {
    local key=$1
    local value=$2
    if grep -Eq "^\s*#?\s*${key}\s*=" "$ENV_FILE"; then
        sed -i -E "s|^\s*#?\s*${key}\s*=.*|${key} = \"${value}\"|" "$ENV_FILE"
    else
        echo "${key} = \"${value}\"" >> "$ENV_FILE"
    fi
}

update_env_var "UVICORN_SSL_CERTFILE" "$CERT_PATH"
update_env_var "UVICORN_SSL_KEYFILE" "$KEY_PATH"
update_env_var "UVICORN_PORT" "$Marzban_Port"

# === Step 7: Restart Marzban ===
echo "🔁 Restarting Marzban container..."
cd /opt/marzban
docker compose down
docker compose up -d

echo "✅ Marzban installation and SSL setup complete."
