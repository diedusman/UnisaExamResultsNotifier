#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# UNISA Results Checker — Proxmox LXC Deployment Script
# Runs on Proxmox VE host shell (no git required)
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/diedusman/UnisaExamResultsNotifier/main/deploy_lxc.sh)"
# ─────────────────────────────────────────────────────────────────────────────

set -e

GITHUB_REPO="https://github.com/diedusman/UnisaExamResultsNotifier.git"
APP_DIR="/opt/unisa-checker"
SERVICE_NAME="unisa-checker"
CT_HOSTNAME="unisa-checker"
UBUNTU_TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
TEMPLATE_STORAGE="local"
ROOTFS_STORAGE="local-lvm"

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
# ─────────────────────────────────────────────────���───────────────────────────

[ "$EUID" -ne 0 ] && error "Please run as root"
command -v pct &>/dev/null || error "pct not found — this script must run on a Proxmox VE host"

# ── Pick next free VMID ───────────────────────────────────────────────────────
NEXT_VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "")
[ -z "$NEXT_VMID" ] && NEXT_VMID=200

# ── Container settings ────────────────────────────────────────────────────────
header "Container Settings"

read -p "  VMID                   [$NEXT_VMID] : " CT_ID
CT_ID=${CT_ID:-$NEXT_VMID}

# Detect available bridges
BRIDGES=$(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}' | tr '\n' ' ')
echo "  Available bridges: ${BRIDGES:-none detected}"
read -p "  Network bridge         [vmbr0] : " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

echo ""
echo "  IP configuration:"
echo "    1) DHCP (automatic)"
echo "    2) Static"
read -p "  Choice                 [1]     : " IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}

if [ "$IP_CHOICE" = "2" ]; then
    read -p "  Static IP (CIDR, e.g. 192.168.1.50/24) : " CT_IP
    read -p "  Gateway (e.g. 192.168.1.1)             : " CT_GW
    read -p "  DNS                        [8.8.8.8]   : " CT_DNS
    CT_DNS=${CT_DNS:-8.8.8.8}
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW}"
else
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

echo ""

# Detect available storages
STORAGES=$(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
echo "  Available storages: ${STORAGES:-local local-lvm}"
read -p "  Template storage       [local]     : " TEMPLATE_STORAGE
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
read -p "  Container storage      [local-lvm] : " ROOTFS_STORAGE
ROOTFS_STORAGE=${ROOTFS_STORAGE:-local-lvm}

echo ""
read -p "  RAM (MB)               [512]   : " CT_RAM;  CT_RAM=${CT_RAM:-512}
read -p "  Disk (GB)              [8]     : " CT_DISK; CT_DISK=${CT_DISK:-8}
read -p "  CPUs                   [1]     : " CT_CPUS; CT_CPUS=${CT_CPUS:-1}

# ── UNISA credentials ─────────────────────────────────────────────────────────
header "UNISA Credentials"

read -p  "  Student number                     : " UNISA_USERNAME
read -sp "  Password                           : " UNISA_PASSWORD; echo
read -p  "  Telegram bot token                 : " TELEGRAM_BOT_TOKEN
read -p  "  Telegram chat ID                   : " TELEGRAM_CHAT_ID
read -p  "  Academic year          [2026]       : " ACADEMIC_YEAR;   ACADEMIC_YEAR=${ACADEMIC_YEAR:-2026}
read -p  "  Academic period        [10]         : " ACADEMIC_PERIOD; ACADEMIC_PERIOD=${ACADEMIC_PERIOD:-10}
read -p  "  Check interval (secs)  [300]        : " CHECK_INTERVAL;  CHECK_INTERVAL=${CHECK_INTERVAL:-300}

echo ""

# ── Destroy existing container if same VMID exists ───────────────────────────
if pct status "$CT_ID" &>/dev/null; then
    warning "Container $CT_ID already exists — stopping and destroying it."
    pct stop "$CT_ID" 2>/dev/null || true
    pct destroy "$CT_ID"
fi

# ── Download template if not present ─────────────────────────────────────────
header "Preparing Template"
TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${UBUNTU_TEMPLATE}"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$UBUNTU_TEMPLATE"; then
    info "Downloading Ubuntu 24.04 template..."
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$UBUNTU_TEMPLATE" || {
        # Try to find whatever ubuntu 24.04 template is available
        UBUNTU_TEMPLATE=$(pveam available | grep "ubuntu-24.04" | tail -1 | awk '{print $2}')
        [ -z "$UBUNTU_TEMPLATE" ] && error "No Ubuntu 24.04 template available. Run: pveam update"
        info "Using template: $UBUNTU_TEMPLATE"
        pveam download "$TEMPLATE_STORAGE" "$UBUNTU_TEMPLATE"
        TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${UBUNTU_TEMPLATE}"
    }
else
    info "Template already present."
fi

# ── Create container ──────────────────────────────────────────────────────────
header "Creating Container"
info "Creating CT $CT_ID ($CT_HOSTNAME)..."

pct create "$CT_ID" "$TEMPLATE_PATH" \
    --hostname "$CT_HOSTNAME" \
    --memory "$CT_RAM" \
    --cores "$CT_CPUS" \
    --rootfs "${ROOTFS_STORAGE}:${CT_DISK}" \
    --net0 "$NET_CONFIG" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 1

info "Waiting for container to be ready..."
for i in $(seq 1 30); do
    STATUS=$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')
    [ "$STATUS" = "running" ] && break
    sleep 2
done
[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" = "running" ] || error "Container $CT_ID failed to reach running state"
sleep 5

# ── Helper ────────────────────────────────────────────────────────────────────
run() { pct exec "$CT_ID" -- bash -c "$1"; }

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
pct exec "$CT_ID" -- bash -c "cat > $APP_DIR/.env <<'EOF'
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
pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service <<'EOF'
[Unit]
Description=UNISA Results Checker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
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
CT_IP_ASSIGNED=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

echo ""
info "Deployment complete!"
echo ""
echo "  VMID      : $CT_ID"
echo "  Hostname  : $CT_HOSTNAME"
echo "  IP        : ${CT_IP_ASSIGNED:-unknown — check Proxmox UI or run: pct exec $CT_ID -- hostname -I}"
echo "  RAM       : ${CT_RAM} MB"
echo "  CPUs      : ${CT_CPUS}"
echo "  Disk      : ${CT_DISK} GB"
echo "  Bridge    : ${BRIDGE}"
echo "  Autostart : yes"
echo ""
echo "  Useful commands:"
echo "    View logs  : pct exec $CT_ID -- journalctl -fu $SERVICE_NAME"
echo "    Stop       : pct stop $CT_ID"
echo "    Restart    : pct exec $CT_ID -- systemctl restart $SERVICE_NAME"
echo "    Shell      : pct enter $CT_ID"
echo "    Destroy    : pct stop $CT_ID && pct destroy $CT_ID"
echo ""
