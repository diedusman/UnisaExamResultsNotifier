#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# UNISA Results Checker — LXC Deployment Script
# Runs on Proxmox VE host shell (no git required)
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/diedusman/UnisaExamResultsNotifier/main/deploy_lxc.sh)"
# ─────────────────────────────────────────────────────────────────────────────

set -e

CONTAINER_NAME="unisa-checker"
UBUNTU_RELEASE="noble"       # Ubuntu 24.04
GITHUB_REPO="https://github.com/diedusman/UnisaExamResultsNotifier.git"
APP_DIR="/opt/unisa-checker"
SERVICE_NAME="unisa-checker"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "\n${CYAN}$1${NC}"; echo "$(printf '─%.0s' {1..60})"; }
# ─────────────────────────────────────────────────────────────────────────────

[ "$EUID" -ne 0 ] && error "Please run as root"
command -v lxc-create &>/dev/null || error "lxc-utils not installed. Run: apt install lxc lxc-utils"

# ── Container settings ────────────────────────────────────────────────────────
header "Container Settings"

# Detect available bridges
BRIDGES=$(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}' | tr '\n' ' ')
echo "  Available bridges: ${BRIDGES:-none detected}"
read -p  "  Network bridge     [vmbr0] : " BRIDGE;   BRIDGE=${BRIDGE:-vmbr0}

echo ""
echo "  IP configuration:"
echo "    1) DHCP (automatic)"
echo "    2) Static"
read -p  "  Choice             [1]     : " IP_CHOICE; IP_CHOICE=${IP_CHOICE:-1}

if [ "$IP_CHOICE" = "2" ]; then
    read -p "  Static IP (CIDR)           : " CT_IP
    read -p "  Gateway                    : " CT_GW
    read -p "  DNS                [8.8.8.8]: " CT_DNS; CT_DNS=${CT_DNS:-8.8.8.8}
fi

echo ""
read -p  "  RAM (MB)           [512]   : " CT_RAM;  CT_RAM=${CT_RAM:-512}
read -p  "  Disk (GB)          [8]     : " CT_DISK; CT_DISK=${CT_DISK:-8}
read -p  "  CPUs               [1]     : " CT_CPUS; CT_CPUS=${CT_CPUS:-1}

# ── UNISA credentials ─────────────────────────────────────────────────────────
header "UNISA Credentials"

read -p  "  Student number             : " UNISA_USERNAME
read -sp "  Password                   : " UNISA_PASSWORD; echo
read -p  "  Telegram bot token         : " TELEGRAM_BOT_TOKEN
read -p  "  Telegram chat ID           : " TELEGRAM_CHAT_ID
read -p  "  Academic year      [2026]  : " ACADEMIC_YEAR;   ACADEMIC_YEAR=${ACADEMIC_YEAR:-2026}
read -p  "  Academic period    [10]    : " ACADEMIC_PERIOD; ACADEMIC_PERIOD=${ACADEMIC_PERIOD:-10}
read -p  "  Check interval (secs) [300]: " CHECK_INTERVAL;  CHECK_INTERVAL=${CHECK_INTERVAL:-300}

echo ""

# ── Destroy existing container if present ────────────────────────────────────
if lxc-info -n "$CONTAINER_NAME" &>/dev/null; then
    warning "Container '$CONTAINER_NAME' already exists — destroying it."
    lxc-stop -n "$CONTAINER_NAME" --kill 2>/dev/null || true
    lxc-destroy -n "$CONTAINER_NAME"
fi

# ── Create container ──────────────────────────────────────────────────────────
header "Creating Container"
info "Creating '$CONTAINER_NAME' (Ubuntu $UBUNTU_RELEASE)..."
lxc-create -n "$CONTAINER_NAME" -t download -- \
    --dist ubuntu --release "$UBUNTU_RELEASE" --arch amd64

# ── Write container config ────────────────────────────────────────────────────
info "Writing container config..."
CONFIG_FILE="/var/lib/lxc/$CONTAINER_NAME/config"

# Remove any existing network config from the template
sed -i '/^lxc\.net\./d' "$CONFIG_FILE"

# Append full config
cat >> "$CONFIG_FILE" <<EOF

# Resources
lxc.cgroup2.memory.max = $((CT_RAM * 1024 * 1024))
lxc.cgroup2.cpu.weight = $((1 + (CT_CPUS - 1) * 99))

# Network — bridge: $BRIDGE
lxc.net.0.type = veth
lxc.net.0.link = $BRIDGE
lxc.net.0.flags = up
lxc.net.0.hwaddr = 00:16:3e:$(openssl rand -hex 3 | sed 's/\(..\)/\1:/g;s/:$//')
EOF

# Static IP config written inside the container after first boot
if [ "$IP_CHOICE" = "2" ]; then
    STATIC_IP="$CT_IP"
    STATIC_GW="$CT_GW"
    STATIC_DNS="$CT_DNS"
fi

# Proxmox / Playwright compatibility
cat >> "$CONFIG_FILE" <<EOF

# Proxmox / Playwright compatibility
lxc.apparmor.profile = unconfined
lxc.cap.drop =
EOF

# ── Start container ───────────────────────────────────────────────────────────
info "Starting container..."
lxc-start -n "$CONTAINER_NAME"

info "Waiting for container to be ready..."
for i in $(seq 1 30); do
    STATE=$(lxc-info -n "$CONTAINER_NAME" -sH 2>/dev/null)
    [ "$STATE" = "RUNNING" ] && break
    sleep 2
done
[ "$(lxc-info -n "$CONTAINER_NAME" -sH 2>/dev/null)" = "RUNNING" ] || error "Container failed to reach RUNNING state"
sleep 5  # give networking a moment

# ── Helper ────────────────────────────────────────────────────────────────────
run() { lxc-attach -n "$CONTAINER_NAME" -- bash -c "$1"; }

# ── Static IP (if chosen) ─────────────────────────────────────────────────────
if [ "$IP_CHOICE" = "2" ]; then
    info "Configuring static IP $STATIC_IP..."
    lxc-attach -n "$CONTAINER_NAME" -- bash -c "cat > /etc/netplan/10-static.yaml <<EOF
network:
  version: 2
  ethernets:
    eth0:
      addresses: [$STATIC_IP]
      routes:
        - to: default
          via: $STATIC_GW
      nameservers:
        addresses: [$STATIC_DNS]
EOF
netplan apply"
fi

# ── Install dependencies ──────────────────────────────────────────────────────
header "Installing Dependencies"
info "Updating packages..."
run "apt-get update -qq && apt-get upgrade -y -qq"

info "Installing Python, git, and system dependencies..."
run "apt-get install -y -qq python3 python3-pip python3-venv git ca-certificates curl"

# ── Clone repo ────────────────────────────────────────────────────────────────
info "Cloning repo..."
run "git clone $GITHUB_REPO $APP_DIR"

# ── Python venv + packages ────────────────────────────────────────────────────
info "Installing Python packages..."
run "python3 -m venv $APP_DIR/venv"
run "$APP_DIR/venv/bin/pip install --quiet -r $APP_DIR/requirements.txt"

info "Installing Playwright + Chromium (this takes a few minutes)..."
run "$APP_DIR/venv/bin/playwright install chromium"
run "$APP_DIR/venv/bin/playwright install-deps chromium"

# ── Write .env ────────────────────────────────────────────────────────────────
header "Writing Config"
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

# ── Systemd service ───────────────────────────────────────────────────────────
info "Creating systemd service..."
lxc-attach -n "$CONTAINER_NAME" -- bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=UNISA Results Checker
After=network-online.target
Wants=network-online.target

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
echo "  IP        : ${CONTAINER_IP:-unknown — run: lxc-info -n $CONTAINER_NAME}"
echo "  RAM       : ${CT_RAM} MB"
echo "  CPUs      : ${CT_CPUS}"
echo "  Bridge    : ${BRIDGE}"
echo ""
echo "  Useful commands:"
echo "    View logs  : lxc-attach -n $CONTAINER_NAME -- journalctl -fu $SERVICE_NAME"
echo "    Stop       : lxc-attach -n $CONTAINER_NAME -- systemctl stop $SERVICE_NAME"
echo "    Restart    : lxc-attach -n $CONTAINER_NAME -- systemctl restart $SERVICE_NAME"
echo "    Shell      : lxc-attach -n $CONTAINER_NAME"
echo "    Destroy    : lxc-stop -n $CONTAINER_NAME --kill && lxc-destroy -n $CONTAINER_NAME"
echo ""
