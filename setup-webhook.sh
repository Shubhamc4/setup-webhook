#!/bin/bash

set -e

# Check if user has sudo access
if ! [ -x "$(command -v sudo)" ]; then
  echo 'Error: sudo is not installed.' >&2
  exit 1
fi

#######################################
# 1. Install requirements
#######################################
echo "Installing requirements..."
sudo apt-get update -qq > /dev/null 2>&1 && sudo apt-get install -y -qq webhook jq curl git openssl logrotate > /dev/null 2>&1

#######################################
# 2. Open firewall port
#######################################
if sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active. Opening port 9000..."
  sudo ufw allow 9000/tcp
else
  echo "UFW is not active. Skipping firewall rule configuration."
fi

#######################################
# 3. Paths + Project Info
#######################################
DEPLOY_BASE_PATH="/var/www/deploy-webhook"

if [ -d "$PROJECT_PATH" ]; then
  read -p "Enter Deploy Webhook Base Path [$DEPLOY_BASE_PATH]: " input
  DEPLOY_BASE_PATH=${input:-$DEPLOY_BASE_PATH}
fi

read -p "Enter your project path (e.g., /var/www/my-app): " PROJECT_PATH
PROJECT_NAME=$(basename "$PROJECT_PATH")
HOOK_ID="redeploy-${PROJECT_NAME}"

# Scoped directory for this specific project
PROJECT_CONFIG_DIR="$DEPLOY_BASE_PATH/$PROJECT_NAME"
sudo mkdir -p "$PROJECT_CONFIG_DIR"
sudo chown -R "$USER:$USER" "$PROJECT_CONFIG_DIR"

HOOK_SECRET=$(openssl rand -hex 16)
PUBLIC_IP=$(hostname -I | awk '{print $1}')
WEBHOOK_URL="http://${PUBLIC_IP}:9000/hooks/${HOOK_ID}"

echo "-------------------------------------------------------"
echo "🔔 SETUP VALUES"
echo "Webhook URL:  $WEBHOOK_URL"
echo "Secret Token: $HOOK_SECRET"
echo "Config Dir:   $PROJECT_CONFIG_DIR"
echo "-------------------------------------------------------"
read -p "Press ENTER once GitLab is configured..."

#######################################
# 4. Git Configuration
#######################################
read -p "Enter GitLab Repo Https path: " REPO_PATH
read -p "Enter branch to deploy: " BRANCH_NAME
read -p "Enter GitLab Project Access Token: " GIT_TOKEN
read -p "Enter Discord Webhook URL (Blank to skip): " DISCORD_URL

REPO_DOMAIN=$(echo "$REPO_PATH" | sed -E 's#^https?://##; s#\.git$##')
AUTH_REPO_URL="https://oauth2:${GIT_TOKEN}@${REPO_DOMAIN}.git"

# Create project-specific askpass
GIT_ASKPASS_FILE="$PROJECT_CONFIG_DIR/.git-askpass"
echo "echo \"$GIT_TOKEN\"" > "$GIT_ASKPASS_FILE"
chmod 700 "$GIT_ASKPASS_FILE"

# Verify repo access
if ! git ls-remote --heads "$AUTH_REPO_URL" "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  echo "❌ ERROR: Cannot access repo or branch '$BRANCH_NAME' doesn't exist."
  exit 1
fi

#######################################
# 5. Initial Clone/Integrity Check
#######################################
if [ -d "$PROJECT_PATH" ]; then
  if [ ! -d "$PROJECT_PATH/.git" ]; then
    echo "⚠️  WARNING: $PROJECT_PATH exists but is NOT a git repo."
    read -p "Delete directory and re-clone? (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] && sudo rm -rf "$PROJECT_PATH" || exit 1
  fi
fi

if [ ! -d "$PROJECT_PATH" ]; then
  git clone -b "$BRANCH_NAME" "$AUTH_REPO_URL" "$PROJECT_PATH"
fi

#######################################
# 6. Create Redeploy Script (Rich Notifications)
#######################################
DEPLOY_SCRIPT="$PROJECT_CONFIG_DIR/redeploy.sh"
SERVER_NAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/bin/bash
set -e

export GIT_ASKPASS="GITASKPASS_PLACEHOLDER"
export GIT_TERMINAL_PROMPT=0
cd "PROJECT_PATH_PLACEHOLDER"

send_discord() {
  [ -z "DISCORD_URL_PLACEHOLDER" ] && return

  local MSG="$1"
  local COLOR="$2"   # Discord integer color
  local STATUS="$3"  # "STARTED", "SUCCESS", "FAILED", "UP-TO-DATE"

  # Commit info
  local COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
  local COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "N/A")
  local COMMIT_AUTHOR=$(git log -1 --pretty=%an 2>/dev/null || echo "N/A")
  local COMMIT_URL="REPO_PATH_PLACEHOLDER/-/commit/$(git rev-parse HEAD 2>/dev/null || echo "")"

  # Construct JSON payload
  PAYLOAD=$(jq -n \
    --arg title "🚀 Deployment: PROJECT_NAME_PLACEHOLDER" \
    --arg desc "$MSG" \
    --arg status "$STATUS" \
    --arg branch "BRANCH_NAME_PLACEHOLDER" \
    --arg commit_hash "$COMMIT_HASH" \
    --arg commit_msg "$COMMIT_MSG" \
    --arg commit_author "$COMMIT_AUTHOR" \
    --arg commit_url "$COMMIT_URL" \
    --arg server "SERVER_NAME_PLACEHOLDER" \
    --arg ip "LOCAL_IP_PLACEHOLDER" \
    --arg path "PROJECT_PATH_PLACEHOLDER" \
    --arg color "$COLOR" \
    '{
      username: "\($server) Bot",
      embeds: [{
        title: $title,
        description: $desc,
        color: ($color|tonumber),
        fields: [
          {name: "Server", value: $server, inline: true},
          {name: "IP", value: $ip, inline: true},
          {name: "Path", value: ("`" + $path + "`"), inline: false},
          {name: "Status", value: $status, inline: true},
          {name: "Branch", value: $branch, inline: true},
          {name: "Commit", value: "[\($commit_hash)](\($commit_url))", inline: true},
          {name: "Author", value: $commit_author, inline: true},
          {name: "Commit Message", value: $commit_msg, inline: false}
        ],
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        footer: {text: "Deploy System • \($server)"}
      }]
    }'
  )

  curl -s -H "Content-Type: application/json" -d "$PAYLOAD" "DISCORD_URL_PLACEHOLDER" > /dev/null 2>&1
}

echo "--- Fetching origin ---"
git fetch origin "BRANCH_NAME_PLACEHOLDER"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" != "BRANCH_NAME_PLACEHOLDER" ]; then
    echo "--- Switching to BRANCH_NAME_PLACEHOLDER ---"
    git checkout "BRANCH_NAME_PLACEHOLDER" || git checkout -b "BRANCH_NAME_PLACEHOLDER" --track origin/"BRANCH_NAME_PLACEHOLDER"
fi

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/"BRANCH_NAME_PLACEHOLDER")

if [ "$LOCAL_HASH" == "$REMOTE_HASH" ]; then
    send_discord "✅ Already up to date. Skipping pull." 3447003 "UP-TO-DATE"
    exit 0
fi

echo "--- Pulling latest changes ---"
git pull origin "BRANCH_NAME_PLACEHOLDER"

# Post-deploy hooks
if [ -f "package.json" ]; then
    echo "Installing Node dependencies..."
    npm install > /dev/null 2>&1
fi
if [ -f "composer.json" ]; then
    echo "Installing PHP dependencies..."
    sudo composer install --no-dev --no-interaction --optimize-autoloader > /dev/null 2>&1
fi

send_discord "🚀 Successfully deployed the code and built assets." 3066993 "SUCCESS"
echo "--- Finished: $(date) ---"
EOF

# Replace placeholders with actual values
sed -i "s|GITASKPASS_PLACEHOLDER|$GIT_ASKPASS_FILE|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_PATH_PLACEHOLDER|$PROJECT_PATH|g" "$DEPLOY_SCRIPT"
sed -i "s|DISCORD_URL_PLACEHOLDER|$DISCORD_URL|g" "$DEPLOY_SCRIPT"
sed -i "s|REPO_PATH_PLACEHOLDER|${REPO_PATH%.git}|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_NAME_PLACEHOLDER|$PROJECT_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|BRANCH_NAME_PLACEHOLDER|$BRANCH_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|SERVER_NAME_PLACEHOLDER|$SERVER_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|LOCAL_IP_PLACEHOLDER|$LOCAL_IP|g" "$DEPLOY_SCRIPT"

chmod +x "$DEPLOY_SCRIPT"

#######################################
# 7. Webhook Configuration
#######################################
HOOKS_FILE="$DEPLOY_BASE_PATH/hooks.json"
NEW_HOOK=$(jq -n --arg id "$HOOK_ID" --arg cmd "$DEPLOY_SCRIPT" --arg dir "$PROJECT_PATH" --arg secret "$HOOK_SECRET" --arg ref "refs/heads/$BRANCH_NAME" \
'{id: $id, "execute-command": $cmd, "command-working-directory": $dir, "trigger-rule": {"and": [{"match": {"type": "value", "value": "push", "parameter": {"source": "payload", "name": "object_kind"}}}, {"match": {"type": "value", "value": $ref, "parameter": {"source": "payload", "name": "ref"}}}, {"match": {"type": "value", "value": $secret, "parameter": {"source": "header", "name": "X-Gitlab-Token"}}}]}}')

if [ -f "$HOOKS_FILE" ]; then
  jq --argjson hook "$NEW_HOOK" 'map(select(.id != $hook.id)) + [$hook]' "$HOOKS_FILE" > "$HOOKS_FILE.tmp" && mv "$HOOKS_FILE.tmp" "$HOOKS_FILE"
else
  echo "$NEW_HOOK" | jq -s '.' > "$HOOKS_FILE"
fi

#######################################
# 8. Systemd & Service Refresh
#######################################
LOG_FILE="$DEPLOY_BASE_PATH/webhook.log"
sudo touch "$LOG_FILE"
sudo chown "$USER:$USER" "$LOG_FILE"

sudo bash -c "cat <<EOF > /etc/systemd/system/webhook.service
[Unit]
Description=Git Webhook Listener
After=network.target

[Service]
ExecStart=/usr/bin/webhook -hooks $HOOKS_FILE -hotreload -verbose
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable webhook
sudo systemctl restart webhook

echo "-------------------------------------------------------"
echo "✅ DEPLOYMENT SYSTEM READY"
echo "Project:       $PROJECT_NAME"
echo "Webhook URL:   $WEBHOOK_URL"
echo "Config Path:   $PROJECT_CONFIG_DIR"
echo "-------------------------------------------------------"
