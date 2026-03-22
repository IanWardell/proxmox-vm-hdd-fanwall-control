#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

install -Dm644 "$BASE_DIR/proxmox/etc/hdd-fanwall-control.cfg" /etc/hdd-fanwall-control.cfg
install -Dm755 "$BASE_DIR/proxmox/usr-local-sbin/hdd_fanwall_control.sh" /usr/local/sbin/hdd_fanwall_control.sh
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.service" /etc/systemd/system/hdd-fanwall-control.service
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.timer" /etc/systemd/system/hdd-fanwall-control.timer

mkdir -p /var/lib/fan-control/vm-unraid-hdd

systemctl daemon-reload
systemctl enable --now hdd-fanwall-control.timer

echo "Proxmox deployment complete."