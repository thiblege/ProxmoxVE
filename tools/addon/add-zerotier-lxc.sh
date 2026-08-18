#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://zerotier.com/ | Github: https://github.com/zerotier/ZeroTierOne

APP="add-zerotier-lxc"
APP_TYPE="addon"

if ! command -v curl &>/dev/null; then
  printf "\r\e[2K%b" '\033[93m Setup Source \033[m' >&2
  if [[ -f /etc/alpine-release ]]; then
    apk update >/dev/null 2>&1
    apk add --no-cache curl >/dev/null 2>&1
  else
    apt-get update >/dev/null 2>&1
    apt-get install -y curl >/dev/null 2>&1
  fi
fi
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/core.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/tools.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/error_handler.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "add-zerotier-lxc" "addon"

# Enable error handling
set -Eeuo pipefail
trap 'error_handler' ERR

# Initialize all core functions (colors, formatting, icons, STD mode)
load_functions

header_info
require_pve_host

while true; do
  read -rp "This will add ZeroTier to an existing LXC Container ONLY. Proceed (y/n)? " yn
  case "$yn" in
  [Yy]*) break ;;
  [Nn]*) exit 0 ;;
  *) echo "Please answer yes or no." ;;
  esac
done

msg_info "Loading container list..."

NODE=$(hostname)
MSG_MAX_LENGTH=0
CTID_MENU=()

while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  ITEM=$(echo "$line" | awk '{print substr($0,36)}')
  OFFSET=2
  ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
  CTID_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pct list | awk 'NR>1')

stop_spinner
CTID=""
while [[ -z "${CTID}" ]]; do
  CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Containers on $NODE" --radiolist \
    "\nSelect a container to add ZeroTier to:\n" \
    16 $((MSG_MAX_LENGTH + 23)) 6 \
    "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit 0
done

CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"

# Configure TUN/TAP passthrough if not already present
grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CTID_CONFIG_PATH" || echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >>"$CTID_CONFIG_PATH"
grep -q "lxc.mount.entry: /dev/net/tun" "$CTID_CONFIG_PATH" || echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >>"$CTID_CONFIG_PATH"

LXC_STATUS=$(pct status "$CTID" | awk '{print $2}')
if [[ "$LXC_STATUS" != "running" ]]; then
  msg_info "Container $CTID is not running. Starting it now..."
  pct start "$CTID"
  while [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; do
    msg_info "Waiting for the container to start..."
    sleep 2
  done
  msg_ok "Container $CTID is now running."
fi

msg_info "Installing ZeroTier in CT $CTID"

pct exec "$CTID" -- bash -c '
set -e

# Detect OS inside container
if [ -f /etc/alpine-release ]; then
  # ── Alpine Linux ──
  echo "[INFO] Alpine Linux detected, installing ZeroTier via apk..."

  # Enable community repo if not already enabled
  if ! grep -q "^[^#].*community" /etc/apk/repositories 2>/dev/null; then
    ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
  fi

  apk update
  apk add --no-cache zerotier-one

  # Enable and start ZeroTier service
  rc-update add zerotier-one default 2>/dev/null || true
  rc-service zerotier-one start 2>/dev/null || true

else
  # ── Debian / Ubuntu ──
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v curl >/dev/null 2>&1; then
    echo "[INFO] curl not found, installing..."
    apt-get update -qq
    apt-get install -y curl >/dev/null
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y gpg >/dev/null
  fi

  curl -fsSL https://raw.githubusercontent.com/zerotier/ZeroTierOne/main/doc/contact%40zerotier.com.gpg | gpg --import >/dev/null 2>&1 || true
  curl -fsSL https://install.zerotier.com -o /tmp/zerotier-install.sh
  if gpg --verify /tmp/zerotier-install.sh >/dev/null 2>&1; then
    bash /tmp/zerotier-install.sh >/dev/null
  else
    bash /tmp/zerotier-install.sh >/dev/null
  fi
  rm -f /tmp/zerotier-install.sh

  systemctl enable --now zerotier-one 2>/dev/null || true
fi
'

TAGS=$(awk -F': ' '/^tags:/ {print $2}' "$CTID_CONFIG_PATH")
TAGS="${TAGS:+$TAGS; }zerotier"
pct set "$CTID" -tags "$TAGS"

msg_ok "ZeroTier installed on CT $CTID"
echo -e "${YW}Reboot the container${CL} to enable the /dev/net/tun device."
echo -e "Then run '${GN}zerotier-cli join <NETWORK_ID>${CL}' inside the container or console."
