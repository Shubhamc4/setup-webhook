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
sudo apt-get update -qq > /dev/null 2>&1 && sudo apt-get install -y -qq webhook jq curl git openssl > /dev/null 2>&1

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

read -p "Enter Deploy Webhook Base Path [$DEPLOY_BASE_PATH]: " input
DEPLOY_BASE_PATH=${input:-$DEPLOY_BASE_PATH}

read -p "Enter your project path (e.g., /var/www/my-app): " PROJECT_PATH
PROJECT_NAME=$(basename "$PROJECT_PATH")
HOOK_ID="redeploy-${PROJECT_NAME}"

PROJECT_CONFIG_DIR="$DEPLOY_BASE_PATH/$PROJECT_NAME"
sudo mkdir -p "$PROJECT_CONFIG_DIR"
sudo chown -R "$USER:$USER" "$PROJECT_CONFIG_DIR"

HOOK_SECRET=$(openssl rand -hex 16)
PUBLIC_IP=$(hostname -I | awk '{print $1}')
WEBHOOK_URL="http://${PUBLIC_IP}:9000/hooks/${HOOK_ID}"

#######################################
# 4. SSH Key Generation (Deploy Key)
#######################################
SSH_KEY_PATH="$PROJECT_CONFIG_DIR/id_ed25519"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Generating new SSH Deploy Key..."
    ssh-keygen -t ed25519 -C "deploy@$PROJECT_NAME" -f "$SSH_KEY_PATH" -N ""
fi

PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")

echo "-------------------------------------------------------"
echo "🔑 ACTION REQUIRED: ADD DEPLOY KEY TO GITLAB"
echo "1. Go to your GitLab Repository -> Settings -> Repository -> Deploy Keys"
echo "2. Title: Webhook-Deploy-$PROJECT_NAME"
echo "3. Key:"
echo "$PUB_KEY"
echo "-------------------------------------------------------"
echo "🔔 WEBHOOK SETUP VALUES"
echo "Webhook URL:  $WEBHOOK_URL"
echo "Secret Token: $HOOK_SECRET"
echo "-------------------------------------------------------"
read -p "Press ENTER once the Deploy Key is added to GitLab..."

#######################################
# 5. Git Configuration
#######################################
read -p "Enter GitLab Repo SSH path (e.g., git@gitlab.com:user/repo.git): " REPO_PATH
read -p "Enter branch to deploy: " BRANCH_NAME
read -p "Enter Discord Webhook URL (Blank to skip): " DISCORD_URL

# Extract domain for SSH config (usually gitlab.com)
REPO_DOMAIN=$(echo "$REPO_PATH" | sed -E 's/.*@([^:]+).*/\1/')

# Configure SSH to use this specific key for this domain
# We use a custom SSH command in the redeploy script rather than modifying ~/.ssh/config globally
SSH_WRAPPER="$PROJECT_CONFIG_DIR/ssh_wrapper.sh"
cat > "$SSH_WRAPPER" <<EOF
#!/bin/bash
ssh -i "$SSH_KEY_PATH" -o "StrictHostKeyChecking=accept-new" "\$@"
EOF
chmod +x "$SSH_WRAPPER"

# Verify repo access
echo "Testing connection..."
if ! GIT_SSH="$SSH_WRAPPER" git ls-remote --heads "$REPO_PATH" "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  echo "❌ ERROR: Cannot access repo. Ensure the Deploy Key is added and has read access."
  exit 1
fi

#######################################
# 6. Initial Clone
#######################################
if [ -d "$PROJECT_PATH" ]; then
  if [ ! -d "$PROJECT_PATH/.git" ]; then
    echo "⚠️  WARNING: $PROJECT_PATH exists but is NOT a git repo."
    read -p "Delete directory and re-clone? (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] && sudo rm -rf "$PROJECT_PATH" || exit 1
  fi
fi

if [ ! -d "$PROJECT_PATH" ]; then
  GIT_SSH="$SSH_WRAPPER" git clone -b "$BRANCH_NAME" "$REPO_PATH" "$PROJECT_PATH"
fi

#######################################
# 7. Create Redeploy Script
#######################################
DEPLOY_SCRIPT="$PROJECT_CONFIG_DIR/redeploy.sh"
SERVER_NAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/bin/bash
set -e

# Force git to use the specific deploy key
export GIT_SSH="SSH_WRAPPER_PLACEHOLDER"
cd "PROJECT_PATH_PLACEHOLDER"

send_discord() {
  [ -z "DISCORD_URL_PLACEHOLDER" ] && return
  local MSG="$1"
  local COLOR="$2"
  local STATUS="$3"

  local COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
  local COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "N/A")
  local COMMIT_AUTHOR=$(git log -1 --pretty=%an 2>/dev/null || echo "N/A")
  local COMMIT_URL="REPO_PATH_PLACEHOLDER/-/commit/$(git rev-parse HEAD 2>/dev/null || echo "")"

  PAYLOAD=$(jq -n \
    --arg title "🚀 Deployment: PROJECT_NAME_PLACEHOLDER" \
    --arg desc "$MSG" --arg status "$STATUS" --arg branch "BRANCH_NAME_PLACEHOLDER" \
    --arg hash "$COMMIT_HASH" --arg msg "$COMMIT_MSG" --arg auth "$COMMIT_AUTHOR" \
    --arg url "$COMMIT_URL" --arg srv "SERVER_NAME_PLACEHOLDER" --arg ip "LOCAL_IP_PLACEHOLDER" \
    --arg path "PROJECT_PATH_PLACEHOLDER" --arg color "$COLOR" \
    '{username: "\($srv) Bot", embeds: [{title: $title, description: $desc, color: ($color|tonumber), fields: [
      {name: "Server", value: $srv, inline: true}, {name: "IP", value: $ip, inline: true},
      {name: "Path", value: ("`" + $path + "`"), inline: false}, {name: "Status", value: $status, inline: true},
      {name: "Branch", value: $branch, inline: true}, {name: "Commit", value: "[\($hash)](\($url))", inline: true},
      {name: "Author", value: $auth, inline: true}, {name: "Message", value: $msg, inline: false}
    ], timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), footer: {text: "Deploy System"}}]}')

  curl -s -H "Content-Type: application/json" -d "$PAYLOAD" "DISCORD_URL_PLACEHOLDER" > /dev/null 2>&1
}

git fetch origin "BRANCH_NAME_PLACEHOLDER"
LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/"BRANCH_NAME_PLACEHOLDER")

if [ "$LOCAL_HASH" == "$REMOTE_HASH" ]; then
    send_discord "✅ Already up to date." 3447003 "UP-TO-DATE"
    exit 0
fi

git pull origin "BRANCH_NAME_PLACEHOLDER"

# Optional Hooks
[ -f "package.json" ] && npm install > /dev/null 2>&1
[ -f "composer.json" ] && composer install --no-dev --no-interaction --optimize-autoloader > /dev/null 2>&1

send_discord "🚀 Successfully deployed." 3066993 "SUCCESS"
EOF

# Placeholder Replacements
sed -i "s|SSH_WRAPPER_PLACEHOLDER|$SSH_WRAPPER|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_PATH_PLACEHOLDER|$PROJECT_PATH|g" "$DEPLOY_SCRIPT"
sed -i "s|DISCORD_URL_PLACEHOLDER|$DISCORD_URL|g" "$DEPLOY_SCRIPT"
# Convert SSH git path to HTTP for Discord Link mapping
HTTP_REPO_LINK=$(echo "$REPO_PATH" | sed -E 's#git@([^:]+):#https://\1/#; s#\.git$##')
sed -i "s|REPO_PATH_PLACEHOLDER|$HTTP_REPO_LINK|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_NAME_PLACEHOLDER|$PROJECT_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|BRANCH_NAME_PLACEHOLDER|$BRANCH_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|SERVER_NAME_PLACEHOLDER|$SERVER_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|LOCAL_IP_PLACEHOLDER|$LOCAL_IP|g" "$DEPLOY_SCRIPT"

chmod +x "$DEPLOY_SCRIPT"

#######################################
# 8. Webhook & Systemd (Remains largely the same)
#######################################
HOOKS_FILE="$DEPLOY_BASE_PATH/hooks.json"
NEW_HOOK=$(jq -n --arg id "$HOOK_ID" --arg cmd "$DEPLOY_SCRIPT" --arg dir "$PROJECT_PATH" --arg secret "$HOOK_SECRET" --arg ref "refs/heads/$BRANCH_NAME" \
'{id: $id, "execute-command": $cmd, "command-working-directory": $dir, "trigger-rule": {"and": [{"match": {"type": "value", "value": "push", "parameter": {"source": "payload", "name": "object_kind"}}}, {"match": {"type": "value", "value": $ref, "parameter": {"source": "payload", "name": "ref"}}}, {"match": {"type": "value", "value": $secret, "parameter": {"source": "header", "name": "X-Gitlab-Token"}}}]}}')

if [ -f "$HOOKS_FILE" ]; then
  jq --argjson hook "$NEW_HOOK" 'map(select(.id != $hook.id)) + [$hook]' "$HOOKS_FILE" > "$HOOKS_FILE.tmp" && mv "$HOOKS_FILE.tmp" "$HOOKS_FILE"
else
  echo "$NEW_HOOK" | jq -s '.' > "$HOOKS_FILE"
fi

sudo bash -c "cat <<EOF > /etc/systemd/system/webhook.service
[Unit]
Description=Git Webhook Listener
After=network.target

[Service]
ExecStart=/usr/bin/webhook -hooks $HOOKS_FILE -hotreload -verbose
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable webhook
sudo systemctl restart webhook

echo "✅ SETUP COMPLETE"
