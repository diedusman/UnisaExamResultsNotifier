#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# UNISA Results Checker — LXC Deployment Script
# Tested on: Ubuntu 22.04 / 24.04 host with lxc-utils installed
# Usage: chmod +x deploy_lxc.sh && sudo ./deploy_lxc.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

# ── Config ────────────────────────────────────────────────────────────────────
CONTAINER_NAME="unisa-checker"
UBUNTU_RELEASE="noble"       # 24.04 — change to "jammy" for 22.04
GITHUB_REPO="https://github.com/diedusman/UnisaExamResultsNotifier.git"
APP_DIR="/opt/unisa-checker"
SERVICE_NAME="unisa-checker"
# ─────────────────────────────────────────────────────────────────────────────

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
# ─────────────────────────────────────────────────────────────────────────────

# Check running as root
[ "$EUID" -ne 0 ] && error "Please run as root: sudo ./deploy_lxc.sh"

# Check lxc is installed
command -v lxc-create &>/dev/null || error "lxc-utils not installed. Run: apt install lxc lxc-utils"

# ── Collect credentials ───────────────────────────────────────────────────────
info "Collecting your UNISA credentials..."
echo ""

read -p  "UNISA student number  : " UNISA_USERNAME
read -sp "UNISA password        : " UNISA_PASSWORD; echo
read -p  "Telegram bot token    : " TELEGRAM_BOT_TOKEN
read -p  "Telegram chat ID      : " TELEGRAM_CHAT_ID
read -p  "Academic year  [2026] : " ACADEMIC_YEAR;   ACADEMIC_YEAR=${ACADEMIC_YEAR:-2026}
read -p  "Academic period  [10] : " ACADEMIC_PERIOD; ACADEMIC_PERIOD=${ACADEMIC_PERIOD:-10}
read -p  "Check interval (secs) [300]: " CHECK_INTERVAL; CHECK_INTERVAL=${CHECK_INTERVAL:-300}

echo ""

# ── Create container ──────────────────────────────────────────────────────────
if lxc-info -n "$CONTAINER_NAME" &>/dev/null; then
    warning "Container '$CONTAINER_NAME' already exists — stopping and destroying it."
    lxc-stop -n "$CONTAINER_NAME" --kill 2>/dev/null || true
    lxc-destroy -n "$CONTAINER_NAME"
fi

info "Creating LXC container '$CONTAINER_NAME' (Ubuntu $UBUNTU_RELEASE)..."
lxc-create -n "$CONTAINER_NAME" -t download -- \
    --dist ubuntu --release "$UBUNTU_RELEASE" --arch amd64

# ── Patch container config for Proxmox compatibility ─────────────────────────
# Proxmox unprivileged containers need these to start and to run Chromium
info "Configuring container..."
CONFIG_FILE="/var/lib/lxc/$CONTAINER_NAME/config"
cat >> "$CONFIG_FILE" <<EOF

# Proxmox / Playwright compatibility
lxc.apparmor.profile = unconfined
lxc.cap.drop =
lxc.cgroup2.devices.allow = a
EOF

info "Starting container..."
lxc-start -n "$CONTAINER_NAME"
sleep 10

# Wait for container to be fully running
for i in $(seq 1 15); do
    STATE=$(lxc-info -n "$CONTAINER_NAME" -sH 2>/dev/null)
    [ "$STATE" = "RUNNING" ] && break
    sleep 2
done
[ "$(lxc-info -n "$CONTAINER_NAME" -sH 2>/dev/null)" = "RUNNING" ] || error "Container failed to reach RUNNING state"

# ── Helper: run command inside container ─────────────────────────────────────
run() {
    lxc-attach -n "$CONTAINER_NAME" -- bash -c "$1"
}

# ── Install dependencies ──────────────────────────────────────────────────────
info "Updating packages..."
run "apt-get update -qq && apt-get upgrade -y -qq"

info "Installing Python, git and dependencies..."
run "apt-get install -y -qq python3 python3-pip python3-venv git"

# ── Clone repo ────────────────────────────────────────────────────────────────
info "Cloning repo from $GITHUB_REPO..."
run "git clone $GITHUB_REPO $APP_DIR"

# ── Create virtual environment and install Python packages ───────────────────
info "Installing Python packages..."
run "python3 -m venv $APP_DIR/venv"
run "$APP_DIR/venv/bin/pip install --quiet -r $APP_DIR/requirements.txt"
run "$APP_DIR/venv/bin/playwright install chromium"
run "$APP_DIR/venv/bin/playwright install-deps chromium"

# ── Write .env file ───────────────────────────────────────────────────────────
info "Writing .env file..."
lxc-attach -n "$CONTAINER_NAME" -- bash -c "cat > $APP_DIR/.env <<EOF
UNISA_USERNAME=$UNISA_USERNAME
UNISA_PASSWORD=$UNISA_PASSWORD
STUDENT_NUMBER=$UNISA_USERNAME
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
ACADEMIC_YEAR=$ACADEMIC_YEAR
ACADEMIC_PERIOD=$ACADEMIC_PERIOD
CHECK_INTERVAL=$CHECK_INTERVAL
STATE_DIR=$APP_DIR/data
EOF"

run "mkdir -p $APP_DIR/data"

# ── Create systemd service ────────────────────────────────────────────────────
info "Creating systemd service..."
lxc-attach -n "$CONTAINER_NAME" -- bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=UNISA Results Checker
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/checker.py
Restart=on-failure
RestartSec=30
EnvironmentFile=$APP_DIR/.env

[Install]
WantedBy=multi-user.target
EOF"

run "systemctl daemon-reload"
run "systemctl enable $SERVICE_NAME"
run "systemctl start $SERVICE_NAME"

# ── Done ──────────────────────────────────────────────────────────────────────
CONTAINER_IP=$(lxc-info -n "$CONTAINER_NAME" -iH 2>/dev/null | head -1)

echo ""
info "Deployment complete!"
echo ""
echo "  Container : $CONTAINER_NAME"
echo "  IP        : ${CONTAINER_IP:-unknown (check with: lxc-info -n $CONTAINER_NAME)}"
echo ""
echo "  Useful commands:"
echo "    View logs  : lxc-attach -n $CONTAINER_NAME -- journalctl -fu $SERVICE_NAME"
echo "    Stop       : lxc-attach -n $CONTAINER_NAME -- systemctl stop $SERVICE_NAME"
echo "    Restart    : lxc-attach -n $CONTAINER_NAME -- systemctl restart $SERVICE_NAME"
echo "    Shell      : lxc-attach -n $CONTAINER_NAME"
echo "    Destroy    : lxc-stop -n $CONTAINER_NAME && lxc-destroy -n $CONTAINER_NAME"
echo ""
