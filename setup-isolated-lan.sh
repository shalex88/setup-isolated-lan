#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# =========================
# Config
# =========================
LAN_IFACE_FILE="${SCRIPT_DIR}/lan-iface"
LAN_ADDR="${LAN_ADDR:-10.44.0.1/24}"
LAN_IP="${LAN_IP:-10.44.0.1}"
DHCP_START="${DHCP_START:-10.44.0.100}"
DHCP_END="${DHCP_END:-10.44.0.199}"
DHCP_MASK="${DHCP_MASK:-255.255.255.0}"
LEASE_TIME="${LEASE_TIME:-12h}"

NETPLAN_FILE="/etc/netplan/90-isolated-lan.yaml"
DNSMASQ_FILE="/etc/dnsmasq.d/isolated-lan.conf"
SYSCTL_FILE="/etc/sysctl.d/99-isolated-lan.conf"
BACKUP_DIR="/var/backups/setup-isolated-lan"

# =========================
# Helpers
# =========================
log() {
  echo "[+] $*"
}

fail() {
  echo "[!] $*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run this script as root: sudo $0"
}

check_iface() {
  ip link show "${LAN_IFACE}" >/dev/null 2>&1 || fail "Interface '${LAN_IFACE}' not found"
}

wait_for_iface() {
  local tries_left=10

  while (( tries_left > 0 )); do
    if ip link show "${LAN_IFACE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((tries_left--))
  done

  fail "Interface '${LAN_IFACE}' did not become ready after netplan apply"
}

backup_file() {
  local file="$1"
  local backup_name

  if [[ -f "$file" ]]; then
    mkdir -p "${BACKUP_DIR}"
    backup_name="$(echo "${file#/}" | tr '/' '_')"
    cp -a "$file" "${BACKUP_DIR}/${backup_name}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

read_lan_iface() {
  local iface
  local iface_list

  if [[ ! -f "${LAN_IFACE_FILE}" ]]; then
    iface_list="$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | sed 's/^/  - /')"
    [[ -n "${iface_list}" ]] || iface_list="  - unknown"
    cat >&2 <<EOF
[!] LAN interface file not found: ${LAN_IFACE_FILE}
Available interfaces:
${iface_list}
Hint: run 'ip -br link' for a detailed view.
EOF
    read -r -p "Enter LAN interface name: " iface
    [[ -n "${iface}" ]] || fail "No interface name provided"
    printf '%s\n' "${iface}" > "${LAN_IFACE_FILE}"
    echo "[+] Saved LAN interface name to ${LAN_IFACE_FILE}" >&2
  fi

  IFS= read -r iface < "${LAN_IFACE_FILE}" || true
  [[ -n "${iface}" ]] || fail "LAN interface file '${LAN_IFACE_FILE}' is empty"

  printf '%s\n' "${iface}"
}

# =========================
# Main
# =========================
LAN_IFACE="${LAN_IFACE:-$(read_lan_iface)}"

require_root
check_iface

log "Installing dnsmasq"
apt update
apt install -y dnsmasq

log "Writing Netplan config to ${NETPLAN_FILE}"
backup_file "${NETPLAN_FILE}"
cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  ethernets:
    ${LAN_IFACE}:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      addresses:
        - ${LAN_ADDR}
EOF
chmod 600 "${NETPLAN_FILE}"

log "Applying Netplan"
netplan generate
netplan apply
wait_for_iface

log "Writing dnsmasq config to ${DNSMASQ_FILE}"
mkdir -p /etc/dnsmasq.d
backup_file "${DNSMASQ_FILE}"
cat > "${DNSMASQ_FILE}" <<EOF
interface=${LAN_IFACE}
bind-dynamic

# DHCP only, no DNS
port=0

dhcp-range=${DHCP_START},${DHCP_END},${DHCP_MASK},${LEASE_TIME}
dhcp-authoritative

# No default gateway and no DNS advertised to clients
dhcp-option=option:router
dhcp-option=option:dns-server
EOF

log "Disabling IPv4 forwarding"
echo "net.ipv4.ip_forward=0" > "${SYSCTL_FILE}"
sysctl -p "${SYSCTL_FILE}"

log "Testing dnsmasq config"
dnsmasq --test

log "Restarting dnsmasq"
systemctl enable dnsmasq
systemctl restart dnsmasq

log "Current interface state:"
ip -br addr show "${LAN_IFACE}"

log "dnsmasq listening status:"
ss -lunp | grep ':67' || true

cat <<EOF

Done.

Expected result:
- ${LAN_IFACE} has static IP ${LAN_IP}
- Clients on the switch get DHCP addresses ${DHCP_START} - ${DHCP_END}
- No gateway is advertised
- No DNS server is advertised
- LAN stays isolated unless you manually bridge or route it

Verify from a client:
- It should receive an IP in 10.44.0.0/24
- It should NOT have a default route

Useful commands:
  journalctl -u dnsmasq -b --no-pager
  ip route
  ip addr show ${LAN_IFACE}

EOF
