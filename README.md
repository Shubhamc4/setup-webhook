# GitLab Webhook Auto-Deploy Script

Automated deployment system for GitLab repositories using [adnanh/webhook](https://github.com/adnanh/webhook). This script handles Git synchronization, dependency installation (PHP/Node), and Discord notifications on deployment events.

## Features

- **Automated Setup**: Installs dependencies (`webhook`, `jq`, `git`, etc.), sets up firewall, and configures systemd.
- **Secure Authentication**: Uses GitLab Personal Access Tokens (stored securely via `.git-askpass`).
- **Smart Deployment**: Checks git hashes before pulling to prevent redundant operations.
- **Rich Notifications**: Sends detailed deployment status to Discord (Commit hash, message, author, status).
- **Dependency Management**: Automatically runs `npm install` and `composer install` if configuration files are detected.
- **Service Management**: Creates and manages the `webhook` systemd service automatically.

## Prerequisites

- Ubuntu/Debian server
- Sudo privileges
- GitLab Repository

## Installation

### 1. Create GitLab Access Token

You need a token to allow the script to clone your private repository.

1.  Go to **GitLab** (User Settings > Access Tokens) or **Project Settings** (Settings > Access Tokens).
2.  Create a token with these scopes:
    - `read_repository`
    - `read_api` (or `api`)
3.  **Copy the token** You will need it during setup.

### 2. Download and Run

Run as a **standard user** (not root). The script configures the service to run under your user account.

**Option 1: Quick Run**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Shubhamc4/setup-webhook/main/setup-webhook.sh)"
```

**Option 2: Download & Inspect**

```bash
curl -fsSL https://raw.githubusercontent.com/Shubhamc4/setup-webhook/main/setup-webhook.sh -o setup-webhook.sh
chmod +x setup-webhook.sh
./setup-webhook.sh
```

### 3. Follow the Prompts

The script will ask for:

| Prompt              | Description                                                   |
| ------------------- | ------------------------------------------------------------- |
| **Project Path**    | Absolute path to your project (e.g., `/var/www/html/my-app`). |
| **GitLab Repo URL** | The HTTPS URL of your repository.                             |
| **Branch**          | The branch to deploy (e.g., `main`).                          |
| **GitLab Token**    | Access token with `read_repository` or `api` scope.           |
| **Discord Webhook** | (Optional) URL for deployment notifications.                  |

> **Note**: If you pre-define `PROJECT_PATH` env var, it may also prompt for the webhook base config path.

### 4. Setup GitLab Webhook

Once the script finishes, it will output valid **Webhook URL** and **Secret Token**.

1.  Go to your GitLab Project > Settings > Webhooks.
2.  **URL**: Paste the URL provided by the script.
3.  **Secret Token**: Paste the generated Secret Token.
4.  **Trigger**: Select "Push events".
5.  **SSL verification**: Enable if your server has HTTPS, otherwise disable.
6.  Click **Add webhook**.

## How It Works

1.  **Configuration**: Creates a config directory at `/var/www/deploy-webhook/<project-name>` containing:
    - `hooks.json`: The webhook definition.
    - `.git-askpass`: Helper script for git authentication using your token.
    - `redeploy.sh`: The actual deployment logic.
2.  **Service**: Registers a systemd service (`webhook.service`) listening on port **9000**.
3.  **Trigger**: When GitLab pushes code, the `webhook` tool verifies the secret and executes `redeploy.sh`.
4.  **Action**:
    - Fetches latest code from origin.
    - Compares local and remote hashes.
    - Running `git checkout` to update files.
    - Runs `npm install` (if `package.json` exists).
    - Runs `composer install` (if `composer.json` exists).
    - Sends Discord notification with status.

## Maintenance

**Check Deployment Status:**

```bash
sudo systemctl status webhook
```

**View Logs:**

```bash
tail -f /var/www/deploy-webhook/webhook.log
```

**Restart Service:**

```bash
sudo systemctl restart webhook
```

**Manual Trigger:**
You can run the deployment script manually to test:

```bash
/var/www/deploy-webhook/<project-name>/redeploy.sh
```

## Security

- **Firewall**: The script attempts to open port `9000` using `ufw`. Ensure your cloud provider firewall (AWS Security Groups, DigitalOcean, etc.) also allows traffic on port 9000.
- **Permissions**: The webhook service runs as the user who executed the setup script.
- **Secrets**: The GitLab token is stored in a file readable only by the owner `chmod 700`.

## Troubleshooting

- **"Cannot access repo"**: Verify your Token has `read_repository` or `api` scope and the branch exists.
- **Permission Denied**: Ensure your user has write access to the `PROJECT_PATH`.
- **Webhook not triggering**: Check if port 9000 is open (`sudo ufw status`) and accessible from the internet.
- **Logs**: Check `/var/www/deploy-webhook/webhook.log` for execution errors.
