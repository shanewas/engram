#!/usr/bin/env bash
# Engram 2.0: Linux/macOS/WSL One-Command Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<you>/engram-memory/main/scripts/install.sh | bash -s -- [remote-url]
set -euo pipefail

REMOTE="${1:-${ENGRAM_REMOTE:-}}"
ENGRAM_DIR="${ENGRAM_HOME:-$HOME/engram}"

echo "============================================================"
echo "       Engram 2.0: Personal Memory & Harness Installer       "
echo "============================================================"

# Check requirements
command -v git >/dev/null 2>&1 || { echo "Error: git is not installed."; exit 1; }
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "Error: python 3.8+ is required."; exit 1;
fi

# Clone or verify
if [ ! -d "$ENGRAM_DIR/.git" ]; then
    if [ -z "$REMOTE" ]; then
        read -rp "[engram] Enter your private memory git repository URL: " REMOTE
        if [ -z "$REMOTE" ]; then
            echo "Error: No repository URL provided."; exit 1
        fi
    fi
    echo "[engram] Cloning repository from $REMOTE..."
    git clone "$REMOTE" "$ENGRAM_DIR"
else
    echo "[engram] Repository already exists at $ENGRAM_DIR"
fi

# Link binary to ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$ENGRAM_DIR/bin/engram" "$HOME/.local/bin/engram"
echo "[engram] Symlinked engram -> $HOME/.local/bin/engram"

# Secrets file template
mkdir -p "$HOME/.config/dotfiles"
SECRETS_FILE="$HOME/.config/dotfiles/secrets.env"
if [ ! -f "$SECRETS_FILE" ]; then
    cat <<'EOF' > "$SECRETS_FILE"
# Engram per-machine secrets (chmod 600, never committed)
GITHUB_TOKEN=  # engram:not-a-secret
MINIMAX_API_KEY=  # engram:not-a-secret
AGY_MCP_AUTH=  # engram:not-a-secret
EOF
    chmod 600 "$SECRETS_FILE"
    echo "[engram] Created template secrets file at $SECRETS_FILE"
fi

# Marker
touch "$ENGRAM_DIR/.git/engram-apply-dotfiles"

# Connect harnesses
echo ""
echo "[engram] Connecting agent harnesses..."
$PYTHON_BIN "$ENGRAM_DIR/scripts/engram_cli.py" connect --all

# Cron registration (30-min background sync)
CRON_CMD="*/30 * * * * bash $ENGRAM_DIR/scripts/sync.sh push >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -Fv "$ENGRAM_DIR/scripts/sync.sh" || true; echo "$CRON_CMD") | crontab -
echo "[engram] Registered 30-min cron sync."

# Doctor
echo ""
echo "[engram] Running health check..."
$PYTHON_BIN "$ENGRAM_DIR/scripts/engram_cli.py" doctor || true

echo ""
echo "============================================================"
echo "       Engram 2.0 Installation Complete!                    "
echo "============================================================"
echo "Ensure ~/.local/bin is in your PATH."
echo "Run 'engram status' to inspect sync state and harnesses."
